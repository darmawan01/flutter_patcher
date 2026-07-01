import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:flutter_patcher/src/signing.dart';

void main() {
  group('PatchSigning.canonicalManifestV3', () {
    test('builds the documented canonical string (body bound by sha256)', () {
      final bodySha = sha256.convert(utf8.encode('a\nb')).toString();
      final canonical = PatchSigning.canonicalManifestV3(
        version: '1.0.1-h1',
        patchNumber: 3,
        targetVersionCode: 42,
        sha256: 'abc',
        rolloutPercent: 100,
        channel: '',
        delivery: 'notify',
        annTitle: 'Hi',
        annBody: 'a\nb',
        annSeverity: 'important',
        annUrl: 'https://x',
      );
      expect(
        canonical,
        'flutter_patcher.manifest.v3\nversion=1.0.1-h1\npatchNumber=3\n'
        'targetVersionCode=42\nsha256=abc\nrolloutPercent=100\nchannel=\n'
        'delivery=notify\nannTitle=Hi\nannSeverity=important\nannUrl=https://x\n'
        'annBodySha256=$bodySha',
      );
    });

    test('newlines in title/url collapse to a space', () {
      final canonical = PatchSigning.canonicalManifestV3(
        version: 'v',
        patchNumber: 1,
        targetVersionCode: 1,
        sha256: 'aa',
        rolloutPercent: 100,
        channel: '',
        delivery: 'silent',
        annTitle: 'line1\nline2',
      );
      expect(canonical.contains('annTitle=line1 line2\n'), isTrue);
    });

    test('cross-language vector: fixed seed → fixed signature (matches server + native)', () {
      const seedBase64 = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
      const pubBase64 = 'MCowBQYDK2VwAyEAA6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=';
      const expectedSig =
          '9sXFYT8I03DD+I+IT9xi/TO97tzoqkwhLuoBeKJBozNWvFCy5q3HqnZzp5F+xdgf94RNSuiAJcqrOtP2MM+zDA==';
      final canonical = PatchSigning.canonicalManifestV3(
        version: '1.2.0+5',
        patchNumber: 5,
        targetVersionCode: 4,
        sha256: 'ab' * 32,
        rolloutPercent: 100,
        channel: '',
        delivery: 'notify',
        annTitle: 'Hello',
        annBody: 'line1\nline2',
        annSeverity: 'important',
        annUrl: 'https://x',
      );
      final sig = PatchSigning.sign(seedBase64, canonical);
      expect(sig, expectedSig);
      expect(PatchSigning.verify(pubBase64, canonical, sig), isTrue);
    });
  });
}
