import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_patcher/src/delta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeltaCodec', () {
    test('round-trips an identical file (all COPY)', () {
      final base = _bytes(50000, seed: 1);
      final delta = DeltaCodec.buildDelta(base, base);
      expect(DeltaCodec.applyDelta(base, delta), base);
      // identical input → delta far smaller than the file
      expect(delta.length, lessThan(base.length ~/ 2));
    });

    test('round-trips a small in-place edit', () {
      final base = _bytes(60000, seed: 2);
      final target = Uint8List.fromList(base);
      // flip a handful of bytes in the middle
      for (var i = 30000; i < 30010; i++) {
        target[i] = target[i] ^ 0xff;
      }
      final delta = DeltaCodec.buildDelta(base, target);
      expect(DeltaCodec.applyDelta(base, delta), target);
      expect(delta.length, lessThan(target.length ~/ 2));
    });

    test('round-trips an insertion that shifts the tail', () {
      final base = _bytes(40000, seed: 3);
      final inserted = _bytes(500, seed: 99);
      final target = Uint8List.fromList(
        [...base.sublist(0, 20000), ...inserted, ...base.sublist(20000)],
      );
      final delta = DeltaCodec.buildDelta(base, target);
      expect(DeltaCodec.applyDelta(base, delta), target);
    });

    test('round-trips completely different content (all INSERT)', () {
      final base = _bytes(10000, seed: 4);
      final target = _bytes(10000, seed: 5);
      final delta = DeltaCodec.buildDelta(base, target);
      expect(DeltaCodec.applyDelta(base, delta), target);
    });

    test('handles empty target and empty base', () {
      final base = _bytes(1000, seed: 6);
      expect(DeltaCodec.applyDelta(base, DeltaCodec.buildDelta(base, Uint8List(0))),
          Uint8List(0));
      final target = _bytes(1000, seed: 7);
      expect(DeltaCodec.applyDelta(Uint8List(0),
          DeltaCodec.buildDelta(Uint8List(0), target)), target);
    });
  });
}

Uint8List _bytes(int n, {required int seed}) {
  final r = Random(seed);
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}
