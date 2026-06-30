import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_patcher/src/signing.dart';

/// Validates a packed patch directory before you ship it.
///
///   dart run flutter_patcher:doctor --dist dist
///   dart run flutter_patcher:doctor --dist dist --pubkey BASE64   # also verify signature
///
/// Checks: manifest fields, patch.zip sha256, signature (if --pubkey), and the
/// inner lib map / ABIs. Exits non-zero if any check fails.
Future<int> main(List<String> argv) async {
  return exitCode = await _run(argv);
}

Future<int> _run(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('dist', defaultsTo: 'dist', help: 'Directory with manifest.json + patch.zip.')
    ..addOption('pubkey', help: 'Public key (base64) to verify the signature against.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help.');

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}');
    stderr.writeln(parser.usage);
    return 64;
  }
  if (args['help'] as bool) {
    stdout.writeln('flutter_patcher doctor — validate a packed patch\n');
    stdout.writeln(parser.usage);
    return 0;
  }

  final dist = args['dist'] as String;
  final pubkey = args['pubkey'] as String?;
  final checks = <bool>[];
  void check(String label, bool ok, [String? detail]) {
    checks.add(ok);
    stdout.writeln('  ${ok ? 'OK  ' : 'FAIL'}  $label${detail != null ? ' — $detail' : ''}');
  }

  final manifestFile = File('$dist/manifest.json');
  final payloadFile = File('$dist/patch.zip');
  if (!manifestFile.existsSync()) {
    stderr.writeln('error: $dist/manifest.json not found');
    return 66;
  }
  if (!payloadFile.existsSync()) {
    stderr.writeln('error: $dist/patch.zip not found');
    return 66;
  }

  final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  stdout.writeln('[doctor] $dist');

  final version = manifest['version'] as String?;
  final declaredSha = manifest['sha256'] as String?;
  final targetVc = manifest['targetVersionCode'];
  final patchNumber = manifest['patchNumber'];
  final signature = manifest['signature'] as String?;
  final abis = manifest['abis'];
  final rolloutPercent = manifest['rolloutPercent'];
  final channel = manifest['channel'];

  check('version present', version != null && version.isNotEmpty);
  check('targetVersionCode present', targetVc is int);
  check('abis present', abis is List && abis.isNotEmpty,
      abis is List ? abis.join(', ') : null);

  final payloadBytes = payloadFile.readAsBytesSync();
  final actualSha = sha256.convert(payloadBytes).toString();
  check('patch.zip sha256 matches manifest', declaredSha == actualSha,
      declaredSha == actualSha ? actualSha : 'manifest=$declaredSha actual=$actualSha');

  // Inner manifest / lib map.
  try {
    final zip = ZipDecoder().decodeBytes(payloadBytes);
    final innerEntry = zip.files.firstWhere((f) => f.name == 'manifest.json');
    final inner = jsonDecode(utf8.decode(innerEntry.content as List<int>)) as Map<String, dynamic>;
    final lib = inner['lib'];
    check('inner lib map present', lib is Map && lib.isNotEmpty);
    if (lib is Map && abis is List) {
      final libAbis = lib.keys.toSet();
      check('inner lib ABIs match outer abis', libAbis.containsAll(abis.cast()),
          libAbis.join(', '));
      // Full-.so entries carry an `md5`; delta entries carry `format: delta` +
      // the `sha256` of the reconstructed .so. Accept either.
      var allChecksummed = true;
      lib.forEach((_, v) {
        if (v is! Map) {
          allChecksummed = false;
          return;
        }
        final hasMd5 = (v['md5'] as String?)?.isNotEmpty == true;
        final isDelta = v['format'] == 'delta' && (v['sha256'] as String?)?.isNotEmpty == true;
        if (!hasMd5 && !isDelta) allChecksummed = false;
      });
      check('each lib entry has a checksum (md5, or delta sha256)', allChecksummed);
    }
  } catch (e) {
    check('patch.zip is a readable package', false, '$e');
  }

  // Signature.
  if (signature != null && signature.isNotEmpty) {
    if (pubkey == null) {
      stdout.writeln('  ??    signature present but no --pubkey to verify it');
    } else if (patchNumber is! int || targetVc is! int || version == null || declaredSha == null) {
      check('signature verifiable', false, 'missing fields to rebuild manifest');
    } else {
      // A staged-rollout patch (rolloutPercent present) is signed as v2; rebuild
      // the matching canonical message or the signature will never verify.
      final msg = rolloutPercent is int
          ? PatchSigning.canonicalManifestV2(
              version: version,
              patchNumber: patchNumber,
              targetVersionCode: targetVc,
              sha256: declaredSha,
              rolloutPercent: rolloutPercent,
              channel: channel is String ? channel : '',
            )
          : PatchSigning.canonicalManifest(
              version: version,
              patchNumber: patchNumber,
              targetVersionCode: targetVc,
              sha256: declaredSha,
            );
      final kind = rolloutPercent is int ? 'v2' : 'v1';
      check('Ed25519 signature verifies ($kind manifest)', PatchSigning.verify(pubkey, msg, signature));
    }
  } else {
    stdout.writeln('  --    unsigned patch (integrity-only)');
  }

  final passed = checks.every((c) => c);
  stdout.writeln(passed ? '[doctor] all checks passed' : '[doctor] FAILED');
  return passed ? 0 : 1;
}
