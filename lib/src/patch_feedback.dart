import 'package:flutter/material.dart';

import '../flutter_patcher.dart';

/// Sender for [PatchFeedback]. Returns `true` on success. Defaults to
/// [FlutterPatcher.reportFeedback]; override for tests or a custom transport.
typedef FeedbackSubmit = Future<bool> Function(PatchRating rating, String? comment);

/// State + actions handed to [PatchFeedback.builder] so a fully custom UI can
/// reuse the submit plumbing. Call [submit] from your own buttons; read
/// [submitting]/[done] to render progress and the thank-you state.
class PatchFeedbackScope {
  const PatchFeedbackScope({
    required this.submitting,
    required this.done,
    required this.submit,
  });

  final bool submitting;
  final bool done;

  /// Send a rating (with an optional comment). Drives [submitting]/[done] and
  /// the widget's `onDone` callback.
  final Future<void> Function(PatchRating rating, {String? comment}) submit;
}

/// Drop-in 👍/👎 prompt for the patch a user is running.
///
/// Zero required arguments: it calls [FlutterPatcher.reportFeedback], which fills
/// in `installId` + the current patch version and POSTs to the endpoint you set
/// via `FlutterPatcher.init(feedbackUrl: …)`. Show it after an update lands.
///
/// Three levels of customization:
/// - **Defaults** — `PatchFeedback()` renders a labelled thumbs up/down.
/// - **Tweak** — override `prompt`, `upLabel`/`downLabel`, `showComment`, etc.
/// - **Full control** — pass [builder] to render your own UI (stars, emojis,
///   a bottom sheet…) while reusing the submit/state logic via [PatchFeedbackScope].
///
/// ```dart
/// PatchFeedback(
///   builder: (context, s) => s.done
///       ? const Text('🙏')
///       : Row(children: [
///           for (final n in [1, 2, 3, 4, 5])
///             IconButton(
///               icon: const Icon(Icons.star),
///               onPressed: s.submitting
///                   ? null
///                   : () => s.submit(n >= 4 ? PatchRating.up : PatchRating.down,
///                       comment: '$n stars'),
///             ),
///         ]),
/// )
/// ```
class PatchFeedback extends StatefulWidget {
  const PatchFeedback({
    super.key,
    this.prompt = 'Enjoying this update?',
    this.thanksMessage = 'Thanks for the feedback!',
    this.showComment = false,
    this.commentHint = 'Anything we should know? (optional)',
    this.upLabel = 'Good',
    this.downLabel = 'Bad',
    this.onSubmit,
    this.onDone,
    this.version,
    this.builder,
  });

  final String prompt;
  final String thanksMessage;
  final bool showComment;
  final String commentHint;
  final String upLabel;
  final String downLabel;

  /// Override the sender (tests / custom transport). Defaults to
  /// [FlutterPatcher.reportFeedback] with the endpoint configured in `init`.
  final FeedbackSubmit? onSubmit;

  /// Called after a submit resolves, with the rating and whether it succeeded.
  final void Function(PatchRating rating, bool ok)? onDone;

  /// Pin the version being rated; defaults to the running patch.
  final String? version;

  /// Render a completely custom UI. When set, all the styling props above are
  /// ignored and you drive everything through the [PatchFeedbackScope].
  final Widget Function(BuildContext context, PatchFeedbackScope scope)? builder;

  @override
  State<PatchFeedback> createState() => _PatchFeedbackState();
}

class _PatchFeedbackState extends State<PatchFeedback> {
  final TextEditingController _comment = TextEditingController();
  bool _submitting = false;
  bool _done = false;

  Future<void> _send(PatchRating rating, {String? comment}) async {
    if (_submitting || _done) return;
    setState(() => _submitting = true);
    final FeedbackSubmit submit = widget.onSubmit ??
        (r, c) => FlutterPatcher.reportFeedback(rating: r, comment: c, version: widget.version);
    final resolvedComment = comment ?? (widget.showComment ? _comment.text : null);
    final ok = await submit(rating, resolvedComment);
    widget.onDone?.call(rating, ok);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _done = ok;
    });
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.builder != null) {
      return widget.builder!(
        context,
        PatchFeedbackScope(submitting: _submitting, done: _done, submit: _send),
      );
    }

    if (_done) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(widget.thanksMessage, style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.prompt, style: Theme.of(context).textTheme.titleSmall),
        if (widget.showComment) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _comment,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: widget.commentHint,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _submitting ? null : () => _send(PatchRating.up),
              icon: const Icon(Icons.thumb_up_alt_outlined, size: 18),
              label: Text(widget.upLabel),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _submitting ? null : () => _send(PatchRating.down),
              icon: const Icon(Icons.thumb_down_alt_outlined, size: 18),
              label: Text(widget.downLabel),
            ),
            if (_submitting) ...[
              const SizedBox(width: 12),
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ],
        ),
      ],
    );
  }
}
