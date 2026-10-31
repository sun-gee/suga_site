import 'dart:math' as math;
import 'dart:typed_data';

/// The result of [trimWavToHit].
class TrimResult {
  TrimResult(this.bytes, {required this.removedLeadMs, required this.lengthMs});

  /// The trimmed file, still a WAV in the original sample format.
  final Uint8List bytes;

  /// How much audio before the hit was cut off.
  final double removedLeadMs;

  /// Length of the trimmed sound.
  final double lengthMs;
}

// Onset detection. The hit is the loudest moment in the recording; its start is found by walking back from the
// peak until the level has stayed down at the recording's own background noise for [_quietRunMs]. Anchoring on
// the loudest event means separate noises earlier in the recording (like touching the Record button) are ignored,
// while judging "quiet" against the real noise floor keeps a hit's softer first transient (the stick landing just
// before the loudest point) attached to the hit instead of cut off.
const _onsetLevel = 0.01; // -40 dB below the peak, at least...
const _noiseMargin = 4.0; // ...and at least this many times the background noise
const _quietRunMs = 20.0;
const _preRollMs = 1.0; // Kept before the detected onset so the very start of the attack isn't clipped
// Tail trimming: cut once the sound has decayed below [_tailLevel] of the peak (or near the noise), then fade out.
const _tailLevel = 0.003; // -50 dB below the peak
const _tailPadMs = 20.0;
const _fadeOutMs = 10.0;

/// Decodes [wav] to mono float samples at [targetRate] (channels averaged, rate converted linearly), for mixing.
/// Returns null if [wav] isn't a WAV this can read.
Float32List? decodeWavMono(Uint8List wav, {required int targetRate}) {
  final wave = _Wave.parse(wav);
  if (wave == null) return null;
  final bytes = ByteData.sublistView(wave.data);
  final mono = Float32List(wave.frames);
  for (var f = 0; f < wave.frames; f++) {
    var sum = 0.0;
    for (var c = 0; c < wave.channels; c++) {
      sum += wave.read(bytes, f * wave.frameSize + c * wave.bytesPerSample);
    }
    mono[f] = sum / wave.channels;
  }
  if (wave.rate == targetRate || mono.isEmpty) return mono;
  final ratio = wave.rate / targetRate;
  final out = Float32List((mono.length / ratio).floor());
  for (var i = 0; i < out.length; i++) {
    final pos = i * ratio;
    final i0 = pos.floor();
    final i1 = math.min(i0 + 1, mono.length - 1);
    out[i] = mono[i0] + (mono[i1] - mono[i0]) * (pos - i0);
  }
  return out;
}

/// Trims a WAV recording of a single hit so the sound starts right on the hit, with no silence in front of it,
/// and ends shortly after it has decayed. Returns null if [wav] isn't a WAV this can read, or is silent.
///
/// Supports PCM 8/16/24/32-bit integer and 32-bit float, any channel count.
TrimResult? trimWavToHit(Uint8List wav) {
  final wave = _Wave.parse(wav);
  if (wave == null) return null;

  final frames = wave.frames;
  var peak = 0.0;
  var peakFrame = 0;
  for (var f = 0; f < frames; f++) {
    final level = wave.level(f);
    if (level > peak) {
      peak = level;
      peakFrame = f;
    }
  }
  if (peak < 1e-4) return null;

  final noise = _noiseFloor(wave);
  final quietRun = (wave.rate * _quietRunMs / 1000).round();
  final onsetThreshold = math.max(peak * _onsetLevel, noise * _noiseMargin);
  var onset = 0;
  var quiet = 0;
  for (var f = peakFrame; f >= 0; f--) {
    if (wave.level(f) < onsetThreshold) {
      quiet++;
      if (quiet >= quietRun) break;
    } else {
      quiet = 0;
      onset = f;
    }
  }
  final start = (onset - (wave.rate * _preRollMs / 1000).round()).clamp(0, frames);

  final tailThreshold = math.max(peak * _tailLevel, noise * 2);
  var last = peakFrame;
  for (var f = frames - 1; f > peakFrame; f--) {
    if (wave.level(f) >= tailThreshold) {
      last = f;
      break;
    }
  }
  final end = (last + 1 + (wave.rate * _tailPadMs / 1000).round()).clamp(start + 1, frames);

  final out = Uint8List.fromList(wave.data.sublist(start * wave.frameSize, end * wave.frameSize));
  _fadeOut(wave, out, (wave.rate * _fadeOutMs / 1000).round());

  return TrimResult(
    wave.withData(out),
    removedLeadMs: start * 1000 / wave.rate,
    lengthMs: (end - start) * 1000 / wave.rate,
  );
}

/// The recording's background noise level: the median of its loudest sample per millisecond. Most of a
/// one-hit recording is silence, so the median lands on the noise rather than the hit.
double _noiseFloor(_Wave wave) {
  final window = math.max(1, wave.rate ~/ 1000);
  final levels = <double>[];
  for (var start = 0; start + window <= wave.frames; start += window) {
    var m = 0.0;
    for (var f = start; f < start + window; f++) {
      m = math.max(m, wave.level(f));
    }
    levels.add(m);
  }
  if (levels.isEmpty) return 0;
  levels.sort();
  return levels[levels.length ~/ 2];
}

void _fadeOut(_Wave wave, Uint8List data, int fadeFrames) {
  final bytes = ByteData.sublistView(data);
  final frames = data.length ~/ wave.frameSize;
  final n = fadeFrames.clamp(0, frames);
  for (var i = 0; i < n; i++) {
    final f = frames - n + i;
    final gain = 1 - (i + 1) / n;
    for (var c = 0; c < wave.channels; c++) {
      final offset = f * wave.frameSize + c * wave.bytesPerSample;
      wave.write(bytes, offset, wave.read(bytes, offset) * gain);
    }
  }
}

class _Wave {
  _Wave(
    this.fmtChunk,
    this.data, {
    required this.isFloat,
    required this.channels,
    required this.rate,
    required this.bits,
  }) : _bytes = ByteData.sublistView(data);

  /// The complete `fmt ` chunk (header included), copied as-is into the output.
  final Uint8List fmtChunk;
  final Uint8List data;
  final ByteData _bytes;
  final bool isFloat;
  final int channels;
  final int rate;
  final int bits;

  int get bytesPerSample => bits ~/ 8;
  int get frameSize => bytesPerSample * channels;
  int get frames => data.length ~/ frameSize;

  static _Wave? parse(Uint8List wav) {
    if (wav.length < 12 || _tag(wav, 0) != 'RIFF' || _tag(wav, 8) != 'WAVE') return null;
    final view = ByteData.sublistView(wav);
    Uint8List? fmtChunk;
    Uint8List? data;
    var pos = 12;
    while (pos + 8 <= wav.length && data == null) {
      final id = _tag(wav, pos);
      final body = pos + 8;
      // Recorders sometimes leave a placeholder size; never read past the end of the file.
      final size = view.getUint32(pos + 4, Endian.little).clamp(0, wav.length - body);
      if (id == 'fmt ') fmtChunk = Uint8List.sublistView(wav, pos, body + size);
      if (id == 'data') data = Uint8List.sublistView(wav, body, body + size);
      pos = body + size + (size & 1);
    }
    if (fmtChunk == null || data == null || fmtChunk.length < 24) return null;
    data = _skipStrayHeader(data);

    final fmt = ByteData.sublistView(fmtChunk, 8);
    var format = fmt.getUint16(0, Endian.little);
    final channels = fmt.getUint16(2, Endian.little);
    final rate = fmt.getUint32(4, Endian.little);
    final bits = fmt.getUint16(14, Endian.little);
    // WAVE_FORMAT_EXTENSIBLE keeps the real format code at the start of its sub-format GUID.
    if (format == 0xFFFE && fmt.lengthInBytes >= 26) format = fmt.getUint16(24, Endian.little);

    final supported = (format == 1 && const {8, 16, 24, 32}.contains(bits)) || (format == 3 && bits == 32);
    if (!supported || channels == 0 || rate == 0) return null;
    return _Wave(fmtChunk, data, isFloat: format == 3, channels: channels, rate: rate, bits: bits);
  }

  /// Loudest absolute sample across channels in frame [f], from 0 to 1.
  double level(int f) {
    var max = 0.0;
    for (var c = 0; c < channels; c++) {
      final v = read(_bytes, f * frameSize + c * bytesPerSample).abs();
      if (v > max) max = v;
    }
    return max;
  }

  double read(ByteData b, int offset) {
    if (isFloat) return b.getFloat32(offset, Endian.little);
    return switch (bits) {
      8 => (b.getUint8(offset) - 128) / 128,
      16 => b.getInt16(offset, Endian.little) / 32768,
      24 => ((b.getUint8(offset) | b.getUint8(offset + 1) << 8 | b.getInt8(offset + 2) << 16)) / 8388608,
      _ => b.getInt32(offset, Endian.little) / 2147483648,
    };
  }

  void write(ByteData b, int offset, double v) {
    if (isFloat) return b.setFloat32(offset, v, Endian.little);
    switch (bits) {
      case 8:
        b.setUint8(offset, (v * 128 + 128).round().clamp(0, 255));
      case 16:
        b.setInt16(offset, (v * 32768).round().clamp(-32768, 32767), Endian.little);
      case 24:
        final s = (v * 8388608).round().clamp(-8388608, 8388607);
        b.setUint8(offset, s & 0xFF);
        b.setUint8(offset + 1, (s >> 8) & 0xFF);
        b.setUint8(offset + 2, (s >> 16) & 0xFF);
      default:
        b.setInt32(offset, (v * 2147483648).round().clamp(-2147483648, 2147483647), Endian.little);
    }
  }

  /// A complete WAV file with this format and [newData] as its samples.
  Uint8List withData(Uint8List newData) {
    final pad = newData.length & 1;
    final header = ByteData(12);
    _setTag(header, 0, 'RIFF');
    header.setUint32(4, 4 + fmtChunk.length + 8 + newData.length + pad, Endian.little);
    _setTag(header, 8, 'WAVE');
    final dataHeader = ByteData(8);
    _setTag(dataHeader, 0, 'data');
    dataHeader.setUint32(4, newData.length, Endian.little);
    return (BytesBuilder(copy: false)
          ..add(header.buffer.asUint8List())
          ..add(fmtChunk)
          ..add(dataHeader.buffer.asUint8List())
          ..add(newData)
          ..add(Uint8List(pad)))
        .takeBytes();
  }
}

String _tag(Uint8List b, int pos) => String.fromCharCodes(b, pos, pos + 4);

/// Some recorders (the `record` plugin on Windows) write a second copy of the WAV header at the start of the
/// sample data. Read as audio, those bytes are a loud click at 0 ms, which would be mistaken for the hit and
/// would make the sound start with a click. If the data opens with a `fmt ` chunk followed by a `data` header,
/// returns the samples after it; otherwise returns [data] unchanged.
Uint8List _skipStrayHeader(Uint8List data) {
  const searchBytes = 64;
  final limit = data.length < searchBytes ? data.length : searchBytes;
  var sawFmt = false;
  for (var i = 0; i + 8 <= limit; i++) {
    final tag = _tag(data, i);
    if (tag == 'fmt ' || tag == 'RIFF') sawFmt = true;
    if (tag == 'data' && sawFmt) return Uint8List.sublistView(data, i + 8);
  }
  return data;
}

void _setTag(ByteData b, int pos, String tag) {
  for (var i = 0; i < 4; i++) {
    b.setUint8(pos + i, tag.codeUnitAt(i));
  }
}
