import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:suga/sample_trim.dart';

const _rate = 44100;

/// A simulated recording: quiet noise, a small "button press" click at 50 ms, a drum-like hit at [hitMs]
/// (fast attack, exponential decay), then silence until [totalMs]. With [preHitMs], the hit also has a softer
/// first transient there (the stick landing) whose ring dips to ~2% of the peak before the loudest part.
List<double> _recording({double hitMs = 300, double totalMs = 1200, double? preHitMs}) {
  final random = math.Random(1);
  return List.generate((_rate * totalMs / 1000).round(), (i) {
    final t = i / _rate * 1000;
    var v = (random.nextDouble() - 0.5) * 0.004; // noise floor around -54 dB
    if (t >= 50 && t < 52) v += 0.2 * math.sin(2 * math.pi * 3000 * (t - 50) / 1000);
    if (preHitMs != null && t >= preHitMs) {
      final dt = (t - preHitMs) / 1000;
      v += 0.33 * math.exp(-dt / 0.003) * math.sin(2 * math.pi * 900 * dt);
      v += 0.02 * math.exp(-dt / 0.1) * math.sin(2 * math.pi * 200 * dt);
    }
    if (t >= hitMs) {
      final dt = (t - hitMs) / 1000;
      v += 0.9 * math.exp(-dt * 25) * math.sin(2 * math.pi * 180 * dt);
    }
    return v;
  });
}

Uint8List _wav(List<double> samples, {int bits = 16, int channels = 1, bool float = false, bool badSize = false}) {
  final bytesPerSample = bits ~/ 8;
  final data = ByteData(samples.length * channels * bytesPerSample);
  for (var i = 0; i < samples.length; i++) {
    for (var c = 0; c < channels; c++) {
      final o = (i * channels + c) * bytesPerSample;
      final v = samples[i];
      if (float) {
        data.setFloat32(o, v, Endian.little);
      } else if (bits == 16) {
        data.setInt16(o, (v * 32767).round(), Endian.little);
      } else if (bits == 24) {
        final s = (v * 8388607).round();
        data.setUint8(o, s & 0xFF);
        data.setUint8(o + 1, (s >> 8) & 0xFF);
        data.setUint8(o + 2, (s >> 16) & 0xFF);
      }
    }
  }
  final header = ByteData(44);
  void tag(int pos, String s) {
    for (var i = 0; i < 4; i++) {
      header.setUint8(pos + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  header.setUint32(4, 36 + data.lengthInBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, float ? 3 : 1, Endian.little);
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, _rate, Endian.little);
  header.setUint32(28, _rate * channels * bytesPerSample, Endian.little);
  header.setUint16(32, channels * bytesPerSample, Endian.little);
  header.setUint16(34, bits, Endian.little);
  tag(36, 'data');
  header.setUint32(40, badSize ? 0xFFFFFFFF : data.lengthInBytes, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...data.buffer.asUint8List()]);
}

int _dataLength(Uint8List wav) => ByteData.sublistView(wav).getUint32(40, Endian.little);

void main() {
  test('cuts the silence before the hit, ignoring the earlier button click', () {
    final result = trimWavToHit(_wav(_recording(hitMs: 300)))!;
    // The hit starts at 300 ms; 1 ms of pre-roll is kept, so ~299 ms is removed.
    expect(result.removedLeadMs, closeTo(299, 1));
  });

  test('works regardless of how late the hit comes', () {
    for (final hitMs in [80.0, 500.0, 900.0]) {
      final result = trimWavToHit(_wav(_recording(hitMs: hitMs, totalMs: hitMs + 900)))!;
      expect(result.removedLeadMs, closeTo(hitMs - 1, 1), reason: 'hit at $hitMs ms');
    }
  });

  test('trims the tail after the hit decays and ends silent', () {
    final result = trimWavToHit(_wav(_recording(totalMs: 2000)))!;
    expect(result.lengthMs, lessThan(1000));
    expect(result.lengthMs, greaterThan(150));
    final bytes = ByteData.sublistView(result.bytes);
    final last = bytes.getInt16(result.bytes.length - 2, Endian.little);
    expect(last.abs(), lessThan(50)); // Faded out, no click at the end
  });

  test('output is a valid WAV with a matching data size', () {
    final result = trimWavToHit(_wav(_recording()))!;
    expect(String.fromCharCodes(result.bytes, 0, 4), 'RIFF');
    expect(_dataLength(result.bytes), result.bytes.length - 44);
    // Trimming it again finds the hit right at the start.
    expect(trimWavToHit(result.bytes)!.removedLeadMs, closeTo(0, 0.5));
  });

  test('skips a second copy of the header at the start of the data (the record plugin on Windows)', () {
    // Seen in real recordings: the data chunk opens with 2 zero bytes, a "fmt " chunk and a "data" header.
    // Read as audio it is a loud click at 0 ms that used to be mistaken for the hit.
    final wav = _wav(_recording(hitMs: 300));
    final stray = BytesBuilder()
      ..add([0, 0])
      ..add('fmt '.codeUnits)
      ..add([18, 0, 0, 0, 1, 0, 1, 0, 0x44, 0xAC, 0, 0, 0x88, 0x58, 1, 0, 2, 0, 16, 0, 0, 0])
      ..add('data'.codeUnits)
      ..add([0xFF, 0xFF, 0xFF, 0xFF]);
    final junk = stray.takeBytes();
    final patched = Uint8List.fromList([...wav.sublist(0, 44), ...junk, ...wav.sublist(44)]);
    final view = ByteData.sublistView(patched);
    view.setUint32(4, view.getUint32(4, Endian.little) + junk.length, Endian.little);
    view.setUint32(40, view.getUint32(40, Endian.little) + junk.length, Endian.little);

    final result = trimWavToHit(patched)!;
    expect(result.removedLeadMs, closeTo(299, 1));
    // The stray header is gone from the output too, so the sound doesn't start with a click.
    expect(String.fromCharCodes(result.bytes, 44, result.bytes.length).contains('fmt '), isFalse);
  });

  test('keeps a softer first transient that comes just before the loudest point', () {
    // Also from a real recording: the stick lands (a smaller spike) ~19 ms before the loudest part of the hit,
    // with the level dipping to ~2% of the peak in between. The cut must start at the stick landing.
    final result = trimWavToHit(_wav(_recording(hitMs: 319, preHitMs: 300)))!;
    expect(result.removedLeadMs, closeTo(299, 1));
  });

  test('handles 24-bit stereo, 32-bit float and placeholder sizes', () {
    for (final wav in [
      _wav(_recording(), bits: 24, channels: 2),
      _wav(_recording(), bits: 32, float: true),
      _wav(_recording(), badSize: true),
    ]) {
      expect(trimWavToHit(wav)!.removedLeadMs, closeTo(299, 1));
    }
  });

  test('decodes to mono at the mixing rate', () {
    // A 22050 Hz stereo file: 0.5 in the left channel, 0.0 in the right, for 100 ms.
    final samples = List.filled(2205, 0.5);
    final stereo = _wav(samples, channels: 2);
    final right = ByteData.sublistView(stereo);
    for (var i = 0; i < samples.length; i++) {
      right.setInt16(44 + (i * 2 + 1) * 2, 0, Endian.little); // Silence the right channel
    }
    right.setUint32(24, 22050, Endian.little); // Sample rate
    right.setUint32(28, 22050 * 4, Endian.little); // Byte rate

    final mono = decodeWavMono(stereo, targetRate: 44100)!;
    expect(mono.length, closeTo(4410, 2)); // Same 100 ms at twice the rate
    expect(mono[1000], closeTo(0.25, 0.001)); // Left and right averaged
    expect(decodeWavMono(Uint8List.fromList(List.generate(100, (i) => i)), targetRate: 44100), isNull);
  });

  test('returns null for silence and for non-WAV data', () {
    expect(trimWavToHit(_wav(List.filled(4410, 0.0))), isNull);
    expect(trimWavToHit(Uint8List.fromList(List.generate(100, (i) => i))), isNull);
  });
}
