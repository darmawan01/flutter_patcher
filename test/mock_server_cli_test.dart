import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

import '../bin/mock_server.dart' as mock_server;

void main() {
  group('mock_server CLI helpers', () {
    test('dist mode reads libapp.so and manifest.json', () async {
      final temp = await Directory.systemTemp.createTemp(
        'flutter_patcher_mock_dist_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final dist = Directory('${temp.path}/dist')..createSync();
      final bytes = utf8.encode('dist patch bytes');
      await File('${dist.path}/libapp.so').writeAsBytes(bytes);
      await File('${dist.path}/manifest.json').writeAsString(
        jsonEncode({
          'version': '1.0.0-h1',
          'md5': crypto.md5.convert(bytes).toString(),
          'targetVersionCode': 100,
        }),
      );

      final patch = await mock_server.loadMockPatch(dist: dist.path);
      expect(patch.version, '1.0.0-h1');
      expect(patch.md5, crypto.md5.convert(bytes).toString());
      expect(patch.targetVersionCode, 100);

      final server = await mock_server.startMockPatchServer(
        mock_server.MockPatchServerConfig(
          patch: patch,
          host: '127.0.0.1',
          port: 0,
        ),
      );
      addTearDown(() => server.close(force: true));

      final check = await _getJson('http://127.0.0.1:${server.port}/check');
      expect(check['hasUpdate'], isTrue);
      final patchJson = check['patch'] as Map<String, dynamic>;
      expect(patchJson['version'], '1.0.0-h1');
      expect(patchJson['md5'], crypto.md5.convert(bytes).toString());
      expect(patchJson['targetVersionCode'], 100);
      expect(
        patchJson['patchUrl'],
        'http://127.0.0.1:${server.port}/libapp.so',
      );

      final patchResponse = await _getBytes(
        'http://127.0.0.1:${server.port}/libapp.so',
      );
      expect(patchResponse.bytes, bytes);
      expect(
        patchResponse.contentType?.mimeType,
        'application/octet-stream',
      );
    });

    test('patch mode computes md5 and uses explicit metadata', () async {
      final temp = await Directory.systemTemp.createTemp(
        'flutter_patcher_mock_patch_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final bytes = utf8.encode('standalone patch bytes');
      final soFile = File('${temp.path}/libapp.so');
      await soFile.writeAsBytes(bytes);

      final patch = await mock_server.loadMockPatch(
        patch: soFile.path,
        version: 'dev-1',
        targetVersionCode: 42,
      );
      expect(patch.version, 'dev-1');
      expect(patch.md5, crypto.md5.convert(bytes).toString());
      expect(patch.targetVersionCode, 42);

      final server = await mock_server.startMockPatchServer(
        mock_server.MockPatchServerConfig(
          patch: patch,
          host: '127.0.0.1',
          port: 0,
        ),
      );
      addTearDown(() => server.close(force: true));

      final check = await _getJson('http://127.0.0.1:${server.port}/check');
      final patchJson = check['patch'] as Map<String, dynamic>;
      expect(patchJson['version'], 'dev-1');
      expect(patchJson['md5'], crypto.md5.convert(bytes).toString());
      expect(patchJson['targetVersionCode'], 42);
    });

    test('missing input and missing patch report usage-style errors', () async {
      await expectLater(
        mock_server.loadMockPatch(),
        throwsA(
          isA<mock_server.MockServerUsageException>()
              .having((e) => e.exitCode, 'exitCode', 64),
        ),
      );

      await expectLater(
        mock_server.loadMockPatch(patch: 'missing/libapp.so'),
        throwsA(
          isA<mock_server.MockServerUsageException>()
              .having((e) => e.exitCode, 'exitCode', 66),
        ),
      );
    });

    test('root endpoint describes available URLs', () async {
      final temp = await Directory.systemTemp.createTemp(
        'flutter_patcher_mock_root_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final soFile = File('${temp.path}/libapp.so');
      await soFile.writeAsBytes(utf8.encode('bytes'));
      final patch = await mock_server.loadMockPatch(patch: soFile.path);
      final server = await mock_server.startMockPatchServer(
        mock_server.MockPatchServerConfig(
          patch: patch,
          host: '127.0.0.1',
          port: 0,
        ),
      );
      addTearDown(() => server.close(force: true));

      final body = await _getText('http://127.0.0.1:${server.port}/');
      expect(body, contains('GET http://127.0.0.1:${server.port}/check'));
      expect(body, contains('FlutterPatcher.checkUpdate'));
    });
  });
}

Future<Map<String, dynamic>> _getJson(String url) async {
  final response = await _openUrl(url);
  final body = await utf8.decodeStream(response);
  expect(response.statusCode, HttpStatus.ok);
  return jsonDecode(body) as Map<String, dynamic>;
}

Future<String> _getText(String url) async {
  final response = await _openUrl(url);
  expect(response.statusCode, HttpStatus.ok);
  return utf8.decodeStream(response);
}

Future<_BytesResponse> _getBytes(String url) async {
  final response = await _openUrl(url);
  expect(response.statusCode, HttpStatus.ok);
  final chunks = await response.toList();
  return _BytesResponse(
    chunks.expand((chunk) => chunk).toList(),
    response.headers.contentType,
  );
}

Future<HttpClientResponse> _openUrl(String url) async {
  final client = HttpClient();
  addTearDown(client.close);
  final request = await client.getUrl(Uri.parse(url));
  return request.close();
}

class _BytesResponse {
  _BytesResponse(this.bytes, this.contentType);

  final List<int> bytes;
  final ContentType? contentType;
}
