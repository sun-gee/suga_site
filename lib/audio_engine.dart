import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'sample_trim.dart';

/// Called for each metronome step at [frame], the step's exact start in output samples (ahead of real time).
/// Schedule the step's sounds with [AudioEngine.schedule] and return the milliseconds until the next step.
typedef StepCallback = double Function(int frame);

/// Sample-accurate playback for the metronome, plus low-latency one-shot playback for taps and previews.
///
/// Instead of triggering each click "live" (which lands late whenever the OS or the UI is briefly busy), the
/// metronome is mixed here: every scheduled sound is written into the output at its exact sample, a little ahead
/// of time, and the result is streamed to the native engine (SoLoud), which plays it back continuously. Timing
/// therefore depends only on the sample count, never on when Dart code happens to run.
class AudioEngine {
  static const rate = 44100;
  // How far ahead of playback the mix is kept. Must cover the longest stall of the Dart side (a slow frame, a GC
  // pause); changes like a new BPM take effect within this time. The web gets more: there the UI, this mixing and
  // the audio output all share the page's one thread.
  static const _leadMs = kIsWeb ? 300 : 150;
  static const _chunkMs = 10;
  static const _refillEvery = Duration(milliseconds: 10);

  final _soloud = SoLoud.instance;
  final Map<String, Float32List> _samples = {}; // For the metronome mix
  final Map<String, AudioSource> _oneShots = {}; // For taps and previews
  Future<void>? _initDone;

  // Metronome stream state
  AudioSource? _stream;
  SoundHandle? _handle;
  Timer? _refill;
  StepCallback? _onStep;
  int _writtenFrames = 0;
  double _nextStepFrame = 0;
  final List<_Voice> _voices = [];

  bool get isRunning => _stream != null;

  // A small device buffer keeps taps responsive; the metronome's timing doesn't depend on it. On the web the buffer
  // is refilled on the page's thread, so it must outlast a slow frame or the output drops out.
  Future<void> init() => _initDone ??= _soloud.init(sampleRate: rate, bufferSize: kIsWeb ? 2048 : 1024);

  bool isLoaded(String name) => _samples.containsKey(name);

  /// Loads (or replaces) sound [name] from WAV bytes. Returns false if it isn't a WAV this can read.
  Future<bool> load(String name, Uint8List wavBytes) async {
    await init();
    final pcm = decodeWavMono(wavBytes, targetRate: rate);
    if (pcm == null) return false;
    _samples[name] = pcm;
    final old = _oneShots.remove(name);
    if (old != null) await _soloud.disposeSource(old);
    _oneShots[name] = await _soloud.loadMem('$name.wav', wavBytes);
    return true;
  }

  Future<void> unload(String name) async {
    _samples.remove(name);
    final old = _oneShots.remove(name);
    if (old != null) await _soloud.disposeSource(old);
  }

  /// Plays [name] right now, for taps and previews.
  void playNow(String name, {double volume = 1}) {
    final source = _oneShots[name];
    if (source != null) unawaited(_soloud.play(source, volume: volume));
  }

  /// Starts the metronome. [onStep] is called for every step, slightly ahead of time, in order.
  Future<void> start(StepCallback onStep) async {
    await init();
    stop();
    _onStep = onStep;
    _writtenFrames = 0;
    _nextStepFrame = 0;
    _voices.clear();
    final stream = _soloud.setBufferStream(
      bufferingType: BufferingType.released, // Played audio is freed, so a session can run indefinitely
      bufferingTimeNeeds: 0.02,
      sampleRate: rate,
      channels: Channels.mono,
      format: BufferType.f32le,
      // Only happens if the mix fell behind playback, which would be audible as a gap.
      onBuffering: (isBuffering, handle, time) {
        if (isBuffering) debugPrint('Metronome stream ran dry at ${time.toStringAsFixed(2)} s');
      },
    );
    _stream = stream;
    _fill(); // Have audio queued before playback starts
    _handle = await _soloud.play(stream);
    _refill = Timer.periodic(_refillEvery, (_) => _fill());
  }

  void stop() {
    _refill?.cancel();
    _refill = null;
    final handle = _handle, stream = _stream;
    _handle = null;
    _stream = null;
    if (handle != null) unawaited(_soloud.stop(handle));
    if (stream != null) unawaited(_soloud.disposeSource(stream));
  }

  /// Mixes sound [name] into the metronome output starting exactly at [frame]. Call from the step callback.
  void schedule(String name, double volume, int frame) {
    final pcm = _samples[name];
    if (pcm != null && volume > 0) _voices.add(_Voice(pcm, volume, frame));
  }

  /// How much of the metronome output has been played, in frames.
  int get playedFrames {
    final stream = _stream;
    if (stream == null) return 0;
    try {
      return (_soloud.getStreamTimeConsumed(stream).inMicroseconds * rate / 1e6).round();
    } catch (_) {
      return 0;
    }
  }

  void _fill() {
    final stream = _stream;
    final onStep = _onStep;
    if (stream == null || onStep == null) return;
    final lead = rate * _leadMs ~/ 1000;
    final chunk = rate * _chunkMs ~/ 1000;
    final played = playedFrames;
    while (_writtenFrames - played < lead) {
      final start = _writtenFrames;
      final end = start + chunk;
      // Generate every step that starts within this chunk.
      while (_nextStepFrame < end) {
        final intervalMs = onStep(_nextStepFrame.round());
        _nextStepFrame += math.max(1.0, intervalMs * rate / 1000);
      }
      final out = Float32List(chunk);
      _voices.removeWhere((v) => v.mixInto(out, start));
      for (var i = 0; i < out.length; i++) {
        out[i] = out[i].clamp(-1.0, 1.0);
      }
      try {
        _soloud.addAudioDataStream(stream, out.buffer.asUint8List());
      } catch (e) {
        debugPrint('Metronome stream error: $e');
        return;
      }
      _writtenFrames = end;
    }
  }
}

/// One scheduled sound being mixed into the metronome output.
class _Voice {
  _Voice(this.pcm, this.volume, this.startFrame);

  final Float32List pcm;
  final double volume;
  final int startFrame;

  /// Adds this voice's part of the chunk starting at [chunkStart] into [out]. Returns true once it has finished.
  bool mixInto(Float32List out, int chunkStart) {
    final from = math.max(0, startFrame - chunkStart);
    for (var i = from; i < out.length; i++) {
      final s = chunkStart + i - startFrame;
      if (s >= pcm.length) return true;
      out[i] += pcm[s] * volume;
    }
    return chunkStart + out.length - startFrame >= pcm.length;
  }
}
