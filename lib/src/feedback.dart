/// User sentiment on the patch a device is running.
enum PatchRating { up, down }

extension PatchRatingWire on PatchRating {
  String get wire => this == PatchRating.up ? 'up' : 'down';
}

/// Pure builder for the `/api/feedback` JSON body. Kept side-effect-free so it's
/// unit-testable; the SDK fills [installId] + [version] from what it already
/// knows. Null/empty fields are omitted so the server sees a clean payload.
Map<String, dynamic> buildFeedbackPayload({
  required PatchRating rating,
  String? installId,
  String? version,
  String? comment,
}) {
  return <String, dynamic>{
    'rating': rating.wire,
    if (version != null && version.isNotEmpty) 'version': version,
    if (installId != null && installId.isNotEmpty) 'installId': installId,
    if (comment != null && comment.trim().isNotEmpty) 'comment': comment.trim(),
  };
}
