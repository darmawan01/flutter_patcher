import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

/// `flutter_patcher status` — show what a patch server is actually serving.
///
///   dart run flutter_patcher:status --server https://you.up.railway.app
///
/// Reads the device-facing `/check` endpoint and prints the active patch,
/// rollout, channel and kill list — the fastest answer to "why isn't my
/// device getting the patch?". No admin token needed (/check is public).
Future<int> main(List<String> argv) async {
  return exitCode = await _run(argv);
}

Future<int> _run(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('server', abbr: 's', help: 'Server base URL (or a full /check URL).')
    ..addOption('timeout', defaultsTo: '10', help: 'Request timeout in seconds.')
    ..addFlag('json', negatable: false, help: 'Print the raw /check JSON instead.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help.');

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}\n${parser.usage}');
    return 64;
  }
  if (args['help'] as bool) {
    stdout.writeln('flutter_patcher status — what a server is serving\n\n${parser.usage}');
    return 0;
  }

  final server = (args['server'] as String?)?.trim();
  if (server == null || server.isEmpty) {
    stderr.writeln('error: --server is required (e.g. --server https://you.up.railway.app)');
    return 64;
  }
  final base = server.replaceAll(RegExp(r'/+$'), '');
  final checkUrl = base.endsWith('/check') ? base : '$base/check';
  final timeout = Duration(seconds: int.tryParse(args['timeout'] as String) ?? 10);

  final Map<String, dynamic> body;
  try {
    body = await _getJson(Uri.parse(checkUrl), timeout);
  } catch (e) {
    stderr.writeln('error: could not reach $checkUrl — $e');
    return 70;
  }

  if (args['json'] as bool) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(body));
    return 0;
  }

  stdout.writeln('[status] $checkUrl');
  final rolledBack = (body['rolledBack'] as List?) ?? const [];
  if (body['hasUpdate'] == true && body['patch'] is Map) {
    final p = body['patch'] as Map<String, dynamic>;
    final sha = (p['sha256'] as String?) ?? '';
    stdout.writeln('  active patch    ${p['version']}  #${p['patchNumber']}');
    stdout.writeln('  target vc       ${p['targetVersionCode']}');
    stdout.writeln('  rollout         ${p['rolloutPercent'] ?? 100}%'
        '${(p['channel'] as String?)?.isNotEmpty == true ? '  ·  channel ${p['channel']}' : ''}');
    stdout.writeln('  signed          ${(p['signature'] as String?)?.isNotEmpty == true ? 'yes' : 'no'}');
    stdout.writeln('  sha256          ${sha.isNotEmpty ? '${sha.substring(0, sha.length.clamp(0, 16))}…' : '—'}');
    stdout.writeln('  payload         ${p['patchUrl']}');
  } else {
    stdout.writeln('  active patch    none — server is offering no update');
  }
  stdout.writeln('  killed          ${rolledBack.isEmpty ? 'none' : rolledBack.join(', ')}');
  return 0;
}

Future<Map<String, dynamic>> _getJson(Uri uri, Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final resp = await req.close().timeout(timeout);
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode >= 400) {
      throw 'HTTP ${resp.statusCode}: ${text.isEmpty ? resp.reasonPhrase : text}';
    }
    return jsonDecode(text) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}
