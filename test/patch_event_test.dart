import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

void main() {
  group('PatchEvent', () {
    test('toJson uses the short enum name and omits null fields', () {
      const e = PatchEvent(
        type: PatchEventType.applyFinished,
        version: '1.0.1-h1',
        patchNumber: 3,
        ok: true,
      );
      final j = e.toJson();
      expect(j['type'], 'applyFinished');
      expect(j['version'], '1.0.1-h1');
      expect(j['patchNumber'], 3);
      expect(j['ok'], true);
      expect(j.containsKey('installId'), isFalse);
      expect(j.containsKey('error'), isFalse);
    });

    test('copyWith stamps installId, preserves other fields, and survives a no-arg copy', () {
      const e = PatchEvent(type: PatchEventType.staged, patchNumber: 5);
      final stamped = e.copyWith(installId: 'abc-123');
      expect(stamped.installId, 'abc-123');
      expect(stamped.type, PatchEventType.staged);
      expect(stamped.patchNumber, 5);
      expect(stamped.copyWith().installId, 'abc-123'); // not dropped
      expect(stamped.toJson()['installId'], 'abc-123');
    });

    test('toJson serializes the error category name', () {
      const e = PatchEvent(
        type: PatchEventType.applyFinished,
        ok: false,
        error: PatchApplyError.downgradeRejected,
      );
      final j = e.toJson();
      expect(j['ok'], false);
      expect(j['error'], 'downgradeRejected');
    });
  });
}
