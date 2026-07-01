import 'package:flutter/material.dart';

import 'patch_info.dart';

/// What the user chose on a [PatchUpdatePrompt].
enum PatchUpdateAction { update, later }

/// State + actions handed to [PatchUpdatePrompt.builder] so a fully custom UI can
/// reuse the dismiss/callback plumbing.
class PatchUpdateScope {
  const PatchUpdateScope({
    required this.announcement,
    required this.deliveryMode,
    required this.dismissed,
    required this.update,
    required this.later,
    required this.openUrl,
  });

  final PatchAnnouncement announcement;
  final String? deliveryMode;
  final bool dismissed;

  /// Fire the "update now" path (invokes `onUpdate`, then dismisses).
  final VoidCallback update;

  /// Fire the "later" path (invokes `onLater`, then dismisses).
  final VoidCallback later;

  /// Invoke `onLearnMore` with the announcement url (no-op if there's no url or
  /// no handler — the SDK stays free of a url_launcher dependency).
  final VoidCallback openUrl;
}

/// Prebuilt "update available" prompt bound to a patch [PatchAnnouncement].
///
/// This is the UI half of the `notify` delivery mode. When `checkAndStage` stages
/// a patch whose `deliveryMode` is `notify`, show this to tell the user what
/// changed and let them act. Patches apply on the next cold start, so "Update
/// now" is app-defined (e.g. prompt a restart) via [onUpdate].
///
/// Three customization levels, mirroring `PatchFeedback`:
/// - **Defaults** — `PatchUpdatePrompt(announcement: a)` renders a severity-styled banner.
/// - **Tweak** — override `updateLabel`, `laterLabel`, `showLater`, `learnMoreLabel`, …
/// - **Full control** — pass [builder] and drive everything via [PatchUpdateScope].
///
/// A dialog variant is available via [PatchUpdatePrompt.showAsDialog].
class PatchUpdatePrompt extends StatefulWidget {
  const PatchUpdatePrompt({
    super.key,
    required this.announcement,
    this.deliveryMode,
    this.onUpdate,
    this.onLater,
    this.onLearnMore,
    this.updateLabel = 'Update now',
    this.laterLabel = 'Later',
    this.learnMoreLabel = 'Learn more',
    this.showLater = true,
    this.dismissOnAction = true,
    this.builder,
  });

  final PatchAnnouncement announcement;
  final String? deliveryMode;

  /// Called when the user taps update. Apply happens on cold start, so this is
  /// typically where you prompt a restart (or call your own restart helper).
  final VoidCallback? onUpdate;

  /// Called when the user defers.
  final VoidCallback? onLater;

  /// Called with the announcement url when the user taps "Learn more". Kept as a
  /// callback so the SDK doesn't depend on url_launcher.
  final void Function(String url)? onLearnMore;

  final String updateLabel;
  final String laterLabel;
  final String learnMoreLabel;
  final bool showLater;

  /// Hide the prompt after an action (default true).
  final bool dismissOnAction;

  /// Render a completely custom UI via a [PatchUpdateScope].
  final Widget Function(BuildContext context, PatchUpdateScope scope)? builder;

  /// Severity accent color for the default UI.
  static Color severityColor(String severity) {
    switch (severity) {
      case 'critical':
        return const Color(0xFFef4444);
      case 'important':
        return const Color(0xFFf59e0b);
      default:
        return const Color(0xFF5b8cff);
    }
  }

  /// Show the announcement as a modal dialog. Resolves to the chosen action (or
  /// null if dismissed by tapping outside). "Learn more" calls [onLearnMore].
  static Future<PatchUpdateAction?> showAsDialog(
    BuildContext context, {
    required PatchAnnouncement announcement,
    String? deliveryMode,
    String updateLabel = 'Update now',
    String laterLabel = 'Later',
    String learnMoreLabel = 'Learn more',
    bool showLater = true,
    void Function(String url)? onLearnMore,
  }) {
    final accent = severityColor(announcement.severity);
    return showDialog<PatchUpdateAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.system_update_alt, color: accent, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(announcement.title)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (announcement.body.isNotEmpty) Text(announcement.body),
            if (announcement.url != null && announcement.url!.isNotEmpty)
              TextButton(
                onPressed: () => onLearnMore?.call(announcement.url!),
                child: Text(learnMoreLabel),
              ),
          ],
        ),
        actions: [
          if (showLater)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(PatchUpdateAction.later),
              child: Text(laterLabel),
            ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(PatchUpdateAction.update),
            child: Text(updateLabel),
          ),
        ],
      ),
    );
  }

  @override
  State<PatchUpdatePrompt> createState() => _PatchUpdatePromptState();
}

class _PatchUpdatePromptState extends State<PatchUpdatePrompt> {
  bool _dismissed = false;

  void _act(VoidCallback? cb) {
    cb?.call();
    if (widget.dismissOnAction && mounted) setState(() => _dismissed = true);
  }

  void _openUrl() {
    final url = widget.announcement.url;
    if (url != null && url.isNotEmpty) widget.onLearnMore?.call(url);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.builder != null) {
      return widget.builder!(
        context,
        PatchUpdateScope(
          announcement: widget.announcement,
          deliveryMode: widget.deliveryMode,
          dismissed: _dismissed,
          update: () => _act(widget.onUpdate),
          later: () => _act(widget.onLater),
          openUrl: _openUrl,
        ),
      );
    }

    if (_dismissed) return const SizedBox.shrink();

    final a = widget.announcement;
    final accent = PatchUpdatePrompt.severityColor(a.severity);
    final hasUrl = a.url != null && a.url!.isNotEmpty;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(width: 4, color: accent),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.system_update_alt, size: 18, color: accent),
                      const SizedBox(width: 8),
                      Expanded(child: Text(a.title, style: Theme.of(context).textTheme.titleSmall)),
                    ],
                  ),
                  if (a.body.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(a.body, style: Theme.of(context).textTheme.bodyMedium),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (hasUrl)
                        TextButton(onPressed: _openUrl, child: Text(widget.learnMoreLabel)),
                      const Spacer(),
                      if (widget.showLater)
                        TextButton(onPressed: () => _act(widget.onLater), child: Text(widget.laterLabel)),
                      const SizedBox(width: 4),
                      FilledButton(onPressed: () => _act(widget.onUpdate), child: Text(widget.updateLabel)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
