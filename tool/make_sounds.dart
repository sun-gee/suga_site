// ignore_for_file: avoid_print
// Generates Suga's built-in sounds into assets/sounds/ as 16-bit mono WAVs.
//
//   dart run tool/make_sounds.dart
//
// Every sound starts at full attack on the very first samples, so it lands exactly on the beat.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const rate = 44100;
final random = math.Random(7);

void main() {
  final sounds = {'don': don(), 'pang': pang(), 'tsu': tsu(), 'click': click()};
  sounds.forEach((name, samples) {
    final file = File('assets/sounds/$name.wav')..writeAsBytesSync(wav(finish(samples)));
    print('${file.path}: ${(samples.length / rate * 1000).round()} ms');
  });
}

// All four are short, clean metronome-style blips that differ mainly in pitch and tone: no pitch bends, little
// noise, and fast decays so they stay crisp even at high tempos.

/// Don: the low, strong one. A round low "tok" with a bright tick on the front edge so it still cuts through.
List<double> don() => render(0.12, (t) {
  final body = (math.sin(2 * math.pi * 210 * t) + 0.3 * math.sin(2 * math.pi * 420 * t)) * math.exp(-t / 0.022);
  final edge = math.sin(2 * math.pi * 2400 * t) * math.exp(-t / 0.0012) * 0.4;
  return body + edge;
});

/// Pang: higher and slappier. A bright woodblock-style "tak": a mid-high tone with one inharmonic overtone.
List<double> pang() => render(0.07, (t) {
  final env = math.exp(-t / 0.009);
  return (math.sin(2 * math.pi * 950 * t) + 0.45 * math.sin(2 * math.pi * 2550 * t)) * env;
});

/// Tsu: the light one, like just touching a snare. A tiny, dry, high tick with a little air.
List<double> tsu() {
  final air = Biquad.highPass(5000, 0.7);
  return render(0.04, (t) {
    final env = math.exp(-t / 0.005);
    return (air.process(noise()) * 0.7 + math.sin(2 * math.pi * 5200 * t) * 0.35) * env;
  });
}

/// Click: the classic metronome tick. Very short and high.
List<double> click() => render(0.035, (t) {
  final env = math.exp(-t / 0.0035);
  return (math.sin(2 * math.pi * 2000 * t) + 0.4 * math.sin(2 * math.pi * 4400 * t)) * env;
});

double noise() => random.nextDouble() * 2 - 1;

List<double> render(double seconds, double Function(double t) f) =>
    List.generate((seconds * rate).round(), (i) => f(i / rate));

/// Normalizes to a -1 dB peak and fades out the last 5 ms so the end doesn't click.
List<double> finish(List<double> s) {
  final peak = s.fold<double>(0, (m, v) => math.max(m, v.abs()));
  final gain = 0.89 / peak;
  final fade = (rate * 0.005).round();
  return [for (var i = 0; i < s.length; i++) s[i] * gain * (i >= s.length - fade ? (s.length - i) / fade : 1)];
}

Uint8List wav(List<double> samples) {
  final data = ByteData(44 + samples.length * 2);
  void tag(int pos, String s) {
    for (var i = 0; i < 4; i++) {
      data.setUint8(pos + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // Mono
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, (samples[i] * 32767).round().clamp(-32768, 32767), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// A standard RBJ biquad filter.
class Biquad {
  Biquad._(this.b0, this.b1, this.b2, this.a1, this.a2);

  factory Biquad.highPass(double freq, double q) {
    final (cosW, alpha) = _params(freq, q);
    final a0 = 1 + alpha;
    return Biquad._((1 + cosW) / 2 / a0, -(1 + cosW) / a0, (1 + cosW) / 2 / a0, -2 * cosW / a0, (1 - alpha) / a0);
  }

  factory Biquad.bandPass(double freq, double q) {
    final (cosW, alpha) = _params(freq, q);
    final a0 = 1 + alpha;
    return Biquad._(alpha / a0, 0, -alpha / a0, -2 * cosW / a0, (1 - alpha) / a0);
  }

  static (double, double) _params(double freq, double q) {
    final w = 2 * math.pi * freq / rate;
    return (math.cos(w), math.sin(w) / (2 * q));
  }

  final double b0, b1, b2, a1, a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  double process(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}
