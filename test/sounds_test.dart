import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:suga/sample_trim.dart';

void main() {
  for (final name in ['don', 'pang', 'tsu', 'click']) {
    test('$name starts right on the hit', () {
      final result = trimWavToHit(File('assets/sounds/$name.wav').readAsBytesSync())!;
      // Anything before the hit would make the sound play late against the beat.
      expect(result.removedLeadMs, lessThan(0.5));
    });
  }
}
