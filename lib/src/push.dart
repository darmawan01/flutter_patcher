/// Pure builder for the `/api/v1/push-token` body. Side-effect-free for testing;
/// the SDK fills [installId] from what it already knows.
Map<String, dynamic> buildPushTokenPayload({
  required String installId,
  required String token,
  String platform = 'android',
}) {
  return <String, dynamic>{
    'installId': installId,
    'token': token,
    'platform': platform,
  };
}

/// Append `iid` (installId) and `pkg` (applicationId) to a `/check` URL so the
/// server can validate the app identifier and correlate the device. Existing
/// params are preserved; a param already present is not overwritten. Pure.
String augmentCheckUrl(String url, {String? installId, String? applicationId}) {
  final u = Uri.parse(url);
  final qp = Map<String, String>.from(u.queryParameters);
  if (installId != null && installId.isNotEmpty && !qp.containsKey('iid')) {
    qp['iid'] = installId;
  }
  if (applicationId != null && applicationId.isNotEmpty && !qp.containsKey('pkg')) {
    qp['pkg'] = applicationId;
  }
  return u.replace(queryParameters: qp).toString();
}
