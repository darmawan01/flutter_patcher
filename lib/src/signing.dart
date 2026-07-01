import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

/// Ed25519 signing helpers for the pack/keygen/doctor CLIs.
///
/// The canonical strings here MUST stay byte-for-byte identical to the device
/// side (`SignatureVerifier.canonicalManifest` / `canonicalRollback` in the
/// Android plugin). Changing a format means bumping the `v1` prefix on both.
class PatchSigning {
  PatchSigning._();

  /// X.509 SubjectPublicKeyInfo DER prefix for an Ed25519 public key. The full
  /// SPKI is this 12-byte header followed by the 32-byte raw key (44 bytes).
  static const List<int> _ed25519SpkiPrefix = [
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
  ];

  /// The canonical signed manifest — identical to the device builder.
  static String canonicalManifest({
    required String version,
    required int patchNumber,
    required int targetVersionCode,
    required String sha256,
  }) =>
      'flutter_patcher.manifest.v1\n'
      'version=$version\n'
      'patchNumber=$patchNumber\n'
      'targetVersionCode=$targetVersionCode\n'
      'sha256=${sha256.toLowerCase()}';

  /// The canonical v2 signed manifest (adds staged-rollout fields) — identical
  /// to the device builder. Used only when rolloutPercent/channel are present.
  static String canonicalManifestV2({
    required String version,
    required int patchNumber,
    required int targetVersionCode,
    required String sha256,
    required int rolloutPercent,
    required String channel,
  }) =>
      'flutter_patcher.manifest.v2\n'
      'version=$version\n'
      'patchNumber=$patchNumber\n'
      'targetVersionCode=$targetVersionCode\n'
      'sha256=${sha256.toLowerCase()}\n'
      'rolloutPercent=$rolloutPercent\n'
      'channel=$channel';

  /// The canonical v3 signed manifest — identical to the device builder. Adds a
  /// delivery mode and an optional announcement on top of v2. The body may be
  /// multi-line, so it is bound by its SHA-256 (the device recomputes it over the
  /// delivered body); title/severity/url are single-line (newlines collapsed to a
  /// space). Empty announcement fields sign as `""`. Used only when the response
  /// carries an announcement or a non-silent delivery; otherwise v2 is used, so
  /// existing signed patches keep verifying unchanged.
  static String canonicalManifestV3({
    required String version,
    required int patchNumber,
    required int targetVersionCode,
    required String sha256,
    required int rolloutPercent,
    required String channel,
    required String delivery,
    String? annTitle,
    String? annBody,
    String? annSeverity,
    String? annUrl,
  }) {
    String oneLine(String? s) => (s ?? '').replaceAll(RegExp(r'[\r\n]+'), ' ');
    final bodySha = (annBody != null && annBody.isNotEmpty)
        ? crypto.sha256.convert(utf8.encode(annBody)).toString()
        : '';
    return 'flutter_patcher.manifest.v3\n'
        'version=$version\n'
        'patchNumber=$patchNumber\n'
        'targetVersionCode=$targetVersionCode\n'
        'sha256=${sha256.toLowerCase()}\n'
        'rolloutPercent=$rolloutPercent\n'
        'channel=$channel\n'
        'delivery=$delivery\n'
        'annTitle=${oneLine(annTitle)}\n'
        'annSeverity=${oneLine(annSeverity)}\n'
        'annUrl=${oneLine(annUrl)}\n'
        'annBodySha256=$bodySha';
  }

  /// The canonical rollback (kill-switch) list — identical to the device builder.
  static String canonicalRollback(List<int> patchNumbers) {
    final sorted = patchNumbers.toSet().toList()..sort();
    return 'flutter_patcher.rollback.v1\npatchNumbers=${sorted.join(',')}';
  }

  /// Generates a new keypair; returns the 32-byte seed (private) and the X.509
  /// SPKI base64 (public, ready for `init(publicKeyBase64:)`).
  static ({String seedBase64, String publicKeySpkiBase64}) generateKeypair() {
    final kp = ed.generateKey();
    final seed = Uint8List.fromList(kp.privateKey.bytes.sublist(0, 32));
    return (
      seedBase64: base64.encode(seed),
      publicKeySpkiBase64: spkiBase64(kp.publicKey.bytes),
    );
  }

  /// Wraps a 32-byte raw Ed25519 public key as X.509 SPKI base64.
  static String spkiBase64(List<int> rawPublicKey) {
    if (rawPublicKey.length != 32) {
      throw ArgumentError('Ed25519 public key must be 32 bytes');
    }
    return base64.encode([..._ed25519SpkiPrefix, ...rawPublicKey]);
  }

  /// Extracts the 32-byte raw key from a raw-32 or X.509-44 base64 public key.
  static Uint8List rawPublicKeyFromBase64(String publicKeyBase64) {
    final bytes = base64.decode(publicKeyBase64.trim());
    if (bytes.length == 32) return Uint8List.fromList(bytes);
    // X.509 SPKI: the 12-byte Ed25519 prefix + the 32-byte key. Require the exact
    // length and prefix rather than blindly taking the last 32 bytes of anything.
    if (bytes.length == 44 && _hasEd25519SpkiPrefix(bytes)) {
      return Uint8List.fromList(bytes.sublist(12));
    }
    throw ArgumentError(
        'invalid Ed25519 public key: expected 32 raw or 44 SPKI bytes, got ${bytes.length}');
  }

  static bool _hasEd25519SpkiPrefix(List<int> bytes) {
    for (var i = 0; i < _ed25519SpkiPrefix.length; i++) {
      if (bytes[i] != _ed25519SpkiPrefix[i]) return false;
    }
    return true;
  }

  /// Signs [message] with the seed, returning the base64 Ed25519 signature.
  static String sign(String seedBase64, String message) {
    final seed = base64.decode(seedBase64.trim());
    if (seed.length != 32) {
      throw ArgumentError('seed must be 32 bytes (got ${seed.length})');
    }
    final priv = ed.newKeyFromSeed(Uint8List.fromList(seed));
    final sig = ed.sign(priv, Uint8List.fromList(utf8.encode(message)));
    return base64.encode(sig);
  }

  /// Verifies a base64 signature over [message] against a raw-32 or X.509 pubkey.
  static bool verify(String publicKeyBase64, String message, String signatureBase64) {
    try {
      final raw = rawPublicKeyFromBase64(publicKeyBase64);
      final sig = base64.decode(signatureBase64.trim());
      return ed.verify(ed.PublicKey(raw), Uint8List.fromList(utf8.encode(message)), Uint8List.fromList(sig));
    } catch (_) {
      return false;
    }
  }
}
