import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';

/// `flutter_patcher release` — pack a patch and ship it to a server in one step.
///
///   dart run flutter_patcher:release \
///     --apk build/app/outputs/flutter-apk/app-release.apk \
///     --server https://you.up.railway.app --token $FP_ADMIN_TOKEN \
///     --version 1.0.1-h1 --patch-number 3 --target-version-code 42 \
///     --rollout 10 --make-live
///
/// Runs `flutter_patcher:pack` to build dist/patch.zip + manifest.json, uploads
/// them to the server's /api/patches, and (with --make-live) sets it active at
/// the given rollout/channel via /api/config. The server signs the manifest on
/// the fly, so no signing key is needed here. CI-friendly: exits non-zero on
/// any failure.
Future<void> main(List<String> argv) async {
  exitCode = await _run(argv);
}

Future<int> _run(List<String> argv) async {
  final parser = ArgParser()
    // packing (passed through to `pack`)
    ..addOption('apk', abbr: 'a', help: 'Release APK to build the patch from.')
    ..addOption('version', help: 'Patch version string (manifest.version).')
    ..addOption('target-version-code', help: 'Host APK versionCode the patch targets.')
    ..addOption('patch-number', help: 'Monotonic patch number (downgrade protection).')
    ..addOption('from-apk', help: 'Base APK to ship a binary delta against (smaller).')
    ..addOption('base-apk', help: 'Base APK to fingerprint against (engine-drift guard).')
    ..addOption('abi', help: 'ABI(s) to pack, comma-separated. Default: all in the APK.')
    ..addMultiOption('assets', help: 'Flutter asset key(s) to include (see pack --help).')
    ..addOption('dist', defaultsTo: 'dist', help: 'Output dir for the packed patch.')
    ..addFlag('skip-pack', negatable: false, help: 'Upload an already-packed --dist as-is.')
    // shipping
    ..addOption('server', abbr: 's', help: 'Patch server base URL.')
    ..addOption('token', help: 'Admin token (FP_ADMIN_TOKEN) if the server requires one.')
    ..addOption('rollout', help: 'Rollout percent 0–100 (implies --make-live).')
    ..addOption('channel', help: 'Release channel label (implies --make-live).')
    ..addFlag('make-live', negatable: false, help: 'Activate this patch after upload.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help.');

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}\n${parser.usage}');
    return 64;
  }
  if (args['help'] as bool) {
    stdout.writeln('flutter_patcher release — pack and ship a patch in one step\n\n${parser.usage}');
    return 0;
  }

  final server = (args['server'] as String?)?.trim();
  if (server == null || server.isEmpty) {
    stderr.writeln('error: --server is required.');
    return 64;
  }
  final base = server.replaceAll(RegExp(r'/+$'), '');
  final token = (args['token'] as String?)?.trim();
  final dist = args['dist'] as String;
  final version = (args['version'] as String?)?.trim();

  // 1) Pack (unless reusing an existing dist). The server signs on /check, so we
  //    deliberately do NOT pass --key / --rollout-percent / --channel to pack.
  if (!(args['skip-pack'] as bool)) {
    final apk = (args['apk'] as String?)?.trim();
    if (apk == null || apk.isEmpty) {
      stderr.writeln('error: --apk is required (or pass --skip-pack to upload an existing --dist).');
      return 64;
    }
    if (version == null || version.isEmpty) {
      stderr.writeln('error: --version is required.');
      return 64;
    }
    final packArgs = <String>['run', 'flutter_patcher:pack', '--apk', apk, '--version', version, '--out', dist];
    void fwd(String flag) {
      final v = args[flag] as String?;
      if (v != null && v.trim().isNotEmpty) packArgs.addAll(['--$flag', v.trim()]);
    }
    fwd('target-version-code');
    fwd('patch-number');
    fwd('from-apk');
    fwd('base-apk');
    fwd('abi');
    for (final a in (args['assets'] as List<String>)) {
      packArgs.addAll(['--assets', a]);
    }

    stdout.writeln('[release] packing → dart ${packArgs.join(' ')}');
    final proc = await Process.start('dart', packArgs, mode: ProcessStartMode.inheritStdio);
    final code = await proc.exitCode;
    if (code != 0) {
      stderr.writeln('error: pack failed (exit $code).');
      return code;
    }
  }

  // 2) Read the packed artifacts.
  final zipFile = File('$dist/patch.zip');
  final manifestFile = File('$dist/manifest.json');
  if (!zipFile.existsSync() || !manifestFile.existsSync()) {
    stderr.writeln('error: $dist/patch.zip + $dist/manifest.json not found.');
    return 66;
  }
  final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final uploadVersion = (manifest['version'] as String?) ?? version ?? '';

  // 3) Upload to the server.
  stdout.writeln('[release] uploading $uploadVersion → $base/api/patches');
  final Map<String, dynamic> up;
  try {
    up = await _uploadPatch(
      Uri.parse('$base/api/patches'),
      token,
      zipFile.readAsBytesSync(),
      manifestFile.readAsBytesSync(),
    );
  } catch (e) {
    stderr.writeln('error: upload failed — $e');
    return 70;
  }
  final rec = (up['patch'] as Map?) ?? const {};
  stdout.writeln('[release] uploaded ${rec['version']} #${rec['patchNumber']} '
      '(sha256 ${(rec['sha256'] as String? ?? '').padRight(12).substring(0, 12)}…)');

  // 4) Make it live (if requested or implied by --rollout/--channel).
  final rolloutStr = args['rollout'] as String?;
  final channel = args['channel'] as String?;
  final makeLive = (args['make-live'] as bool) || rolloutStr != null || channel != null;
  if (makeLive) {
    final cfg = <String, dynamic>{'activeVersion': uploadVersion};
    // A fresh release goes fully live unless a staged percent is given.
    final rollout = rolloutStr != null ? int.tryParse(rolloutStr) : 100;
    if (rollout == null || rollout < 0 || rollout > 100) {
      stderr.writeln('error: --rollout must be 0–100.');
      return 64;
    }
    cfg['rolloutPercent'] = rollout;
    if (channel != null) cfg['channel'] = channel;

    stdout.writeln('[release] activating → rollout $rollout%'
        '${channel != null && channel.isNotEmpty ? ', channel $channel' : ''}');
    try {
      await _postJson(Uri.parse('$base/api/config'), token, cfg);
    } catch (e) {
      stderr.writeln('error: activation failed — $e');
      return 70;
    }
    stdout.writeln('[release] live: $uploadVersion at $rollout% · $base/');
  } else {
    stdout.writeln('[release] uploaded but NOT live — make it live in the dashboard or re-run with --make-live.');
  }
  return 0;
}

Future<Map<String, dynamic>> _uploadPatch(
  Uri uri,
  String? token,
  List<int> zipBytes,
  List<int> manifestBytes,
) async {
  final boundary = '----fpRelease${DateTime.now().microsecondsSinceEpoch}';
  final body = BytesBuilder();
  void part(String field, String filename, String ctype, List<int> bytes) {
    body.add(utf8.encode('--$boundary\r\n'));
    body.add(utf8.encode('Content-Disposition: form-data; name="$field"; filename="$filename"\r\n'));
    body.add(utf8.encode('Content-Type: $ctype\r\n\r\n'));
    body.add(bytes);
    body.add(utf8.encode('\r\n'));
  }

  part('patchzip', 'patch.zip', 'application/zip', zipBytes);
  part('manifest', 'manifest.json', 'application/json', manifestBytes);
  body.add(utf8.encode('--$boundary--\r\n'));

  final client = HttpClient();
  try {
    final req = await client.postUrl(uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
    if (token != null && token.isNotEmpty) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.add(body.toBytes());
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode >= 400) throw _httpError(resp.statusCode, text);
    return jsonDecode(text) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _postJson(Uri uri, String? token, Map<String, dynamic> payload) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    if (token != null && token.isNotEmpty) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.add(utf8.encode(jsonEncode(payload)));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode >= 400) throw _httpError(resp.statusCode, text);
    return text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

String _httpError(int status, String text) {
  if (status == 401) return 'HTTP 401 — admin token required or wrong (pass --token).';
  try {
    final j = jsonDecode(text) as Map<String, dynamic>;
    if (j['error'] != null) return 'HTTP $status: ${j['error']}';
  } catch (_) {}
  return 'HTTP $status: $text';
}
