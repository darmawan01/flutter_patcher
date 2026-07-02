import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

void main() {
  group('buildPushTokenPayload', () {
    test('carries installId/token/platform', () {
      final p = buildPushTokenPayload(installId: 'dev-1', token: 'tok', platform: 'ios');
      expect(p, {'installId': 'dev-1', 'token': 'tok', 'platform': 'ios'});
    });
    test('defaults platform to android', () {
      expect(buildPushTokenPayload(installId: 'd', token: 't')['platform'], 'android');
    });
  });

  group('augmentCheckUrl', () {
    test('appends iid and pkg, preserving existing params', () {
      final out = augmentCheckUrl('https://ota.example/check?app=com.acme.app&channel=',
          installId: 'iid-9', applicationId: 'com.acme.app');
      final u = Uri.parse(out);
      expect(u.queryParameters['app'], 'com.acme.app');
      expect(u.queryParameters['channel'], '');
      expect(u.queryParameters['iid'], 'iid-9');
      expect(u.queryParameters['pkg'], 'com.acme.app');
    });

    test('does not overwrite params already present', () {
      final out = augmentCheckUrl('https://ota.example/check?app=a&pkg=already',
          installId: 'iid', applicationId: 'com.new');
      expect(Uri.parse(out).queryParameters['pkg'], 'already');
    });

    test('omits empty/null values', () {
      final out = augmentCheckUrl('https://ota.example/check?app=a', installId: '', applicationId: null);
      expect(Uri.parse(out).queryParameters.containsKey('iid'), isFalse);
      expect(Uri.parse(out).queryParameters.containsKey('pkg'), isFalse);
    });
  });

  group('PatchDeviceInfo.applicationId', () {
    test('parses applicationId from the native map', () {
      final d = PatchDeviceInfo.fromNative({
        'model': 'Pixel',
        'manufacturer': 'Google',
        'os': 'Android 14',
        'abi': 'arm64-v8a',
        'versionCode': 7,
        'applicationId': 'com.acme.app',
      });
      expect(d.applicationId, 'com.acme.app');
      expect(d.toJson()['applicationId'], 'com.acme.app');
    });

    test('applicationId defaults to empty when absent', () {
      final d = PatchDeviceInfo.fromNative({'model': 'X'});
      expect(d.applicationId, '');
      expect(d.toJson().containsKey('applicationId'), isFalse);
    });
  });
}
