import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_patcher/src/signing.dart';

/// Validates a packed patch directory before you ship it — or, with --project,
/// validates that a Flutter app is correctly wired up.
///
///   dart run flutter_patcher:doctor --dist dist
///   dart run flutter_patcher:doctor --dist dist --pubkey BASE64   # also verify signature
///   dart run flutter_patcher:doctor --project .                   # validate app wiring
///   dart run flutter_patcher:doctor --project . --check-server    # ...and ping /check
///
/// Dist checks: manifest fields, patch.zip sha256, signature, inner lib map.
/// Project checks: dependency, setupPatcher() wired into main(), a real public
/// key + server URL. Exits non-zero if any check fails.
Future<int> main(List<String> argv) async {
  return exitCode = await _run(argv);
}

Future<int> _run(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('dist', defaultsTo: 'dist', help: 'Directory with manifest.json + patch.zip.')
    ..addOption('pubkey', help: 'Public key (base64) to verify the signature against.')
    ..addOption('project', help: 'Validate app wiring in this Flutter project dir (instead of a dist).')
    ..addFlag('check-server', negatable: false, help: 'With --project: also GET the configured /check URL.')
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
    stdout.writeln('flutter_patcher doctor — validate a packed patch or an app\n');
    stdout.writeln(parser.usage);
    return 0;
  }

  final project = args['project'] as String?;
  if (project != null) {
    return _projectDoctor(project, args['check-server'] as bool);
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

/// Validates that a Flutter app is wired up to flutter_patcher: the dependency
/// is declared, the patcher is initialised from main(), and a real public key +
/// server URL are configured (not the `init` placeholders).
Future<int> _projectDoctor(String dir, bool ping) async {
  final checks = <bool>[];
  var warns = 0;
  void check(String label, bool ok, [String? detail]) {
    checks.add(ok);
    stdout.writeln('  ${ok ? 'OK  ' : 'FAIL'}  $label${detail != null ? ' — $detail' : ''}');
  }

  void warn(String label, String detail) {
    warns++;
    stdout.writeln('  WARN  $label — $detail');
  }

  stdout.writeln('[doctor] project: $dir');
  final pubspec = File('$dir/pubspec.yaml');
  if (!pubspec.existsSync()) {
    stderr.writeln('error: $dir/pubspec.yaml not found — run inside a Flutter project.');
    return 66;
  }
  final pubText = pubspec.readAsStringSync();
  check('flutter_patcher dependency declared',
      RegExp(r'^\s*flutter_patcher\s*:', multiLine: true).hasMatch(pubText));

  final libDir = Directory('$dir/lib');
  final dartFiles = libDir.existsSync()
      ? libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList()
      : <File>[];
  final src = dartFiles.map((f) => f.readAsStringSync()).join('\n');

  check('app references the patcher (FlutterPatcher.init / setupPatcher)',
      src.contains('FlutterPatcher.init(') || src.contains('setupPatcher('));

  final mainFile = File('$dir/lib/main.dart');
  if (mainFile.existsSync()) {
    final m = mainFile.readAsStringSync();
    final wired =
        m.contains('setupPatcher(') || m.contains('FlutterPatcher.init(') || m.contains('checkAndStage(');
    check('main() wires the patcher at startup', wired,
        wired ? null : 'add `await setupPatcher();` in main() before runApp()');
  } else {
    warn('lib/main.dart not found', 'could not confirm the patcher is wired into main()');
  }

  // Public key (from `init`'s kPatchPublicKey or an inline publicKeyBase64:).
  final keyMatch = RegExp("(?:kPatchPublicKey\\s*=\\s*|publicKeyBase64:\\s*)'([^']*)'").firstMatch(src);
  if (keyMatch == null) {
    warn('public key not found', 'no kPatchPublicKey / publicKeyBase64 literal in lib/');
  } else {
    final key = keyMatch.group(1)!;
    if (key.isEmpty || key.contains('PASTE')) {
      check('public key is set (not the placeholder)', false, 'still the init placeholder');
    } else {
      var len = -1;
      try {
        len = base64.decode(key).length;
      } catch (_) {}
      check('public key looks valid', len == 32 || len == 44,
          len == 32 || len == 44 ? '$len-byte key' : 'does not decode to a 32/44-byte Ed25519 key');
    }
  }

  // Server URL (from kPatchCheckUrl or an inline checkAndStage('...')).
  final urlMatch = RegExp("(?:kPatchCheckUrl\\s*=\\s*|checkAndStage\\(\\s*)'([^']*)'").firstMatch(src);
  final url = urlMatch?.group(1);
  if (url == null || url.isEmpty) {
    warn('patch server URL not found', 'no kPatchCheckUrl / checkAndStage(<url>) literal in lib/');
  } else if (url.contains('YOUR-SERVER') || url.contains('PASTE') || url.contains('example.com')) {
    check('patch server URL is set (not the placeholder)', false, url);
  } else {
    check('patch server URL is set', true, url);
    if (ping) {
      try {
        check('server /check reachable', await _pingCheck(url), url);
      } catch (e) {
        check('server /check reachable', false, '$e');
      }
    }
  }

  final passed = checks.every((c) => c);
  stdout.writeln(passed
      ? '[doctor] wiring looks good${warns > 0 ? ' ($warns warning${warns == 1 ? '' : 's'})' : ''}'
      : '[doctor] FAILED');
  return passed ? 0 : 1;
}

Future<bool> _pingCheck(String url) async {
  final base = url.replaceAll(RegExp(r'/+$'), '');
  final checkUrl = base.endsWith('/check') ? base : '$base/check';
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse(checkUrl));
    final resp = await req.close().timeout(const Duration(seconds: 8));
    await resp.drain<void>();
    return resp.statusCode == 200;
  } finally {
    client.close(force: true);
  }
}
