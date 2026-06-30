import 'package:flutter/foundation.dart';

import 'boot_diagnostic.dart';
import 'patch_info.dart';

/// Kind of [PatchEvent] emitted to `FlutterPatcher.init(onEvent:)`.
enum PatchEventType {
  /// The previous cold start's patch decision, read from the native boot
  /// diagnostic at startup. Crash attribution lives here: a
  /// [PatchBootStatus.droppedCircuitBreaker] event carries the patch version and
  /// crash count that tripped the breaker — forward it to your crash reporter.
  boot,

  /// `applyPatch` began downloading/verifying a patch.
  applyStarted,

  /// `applyPatch` finished — see [PatchEvent.ok] / [PatchEvent.error].
  applyFinished,

  /// `checkAndStage` staged a patch for the next cold start.
  staged,
}

/// A patch-lifecycle telemetry event.
///
/// Register a single sink via `FlutterPatcher.init(onEvent: ...)` and forward
/// these to Sentry/Crashlytics/your own backend. The callback must not throw;
/// exceptions from it are swallowed so telemetry can never break patching.
@immutable
class PatchEvent {
  final PatchEventType type;

  /// Patch version, when known.
  final String? version;

  /// Monotonic patch number, when known. Use this to attribute crashes/metrics
  /// to a specific patch.
  final int? patchNumber;

  /// For [PatchEventType.applyFinished]: whether the apply succeeded.
  final bool? ok;

  /// For [PatchEventType.applyFinished]: the failure category, if any.
  final PatchApplyError? error;

  /// For [PatchEventType.boot]: the full native boot diagnostic.
  final PatchBootDiagnostic? boot;

  /// Developer-facing detail. Not for end users.
  final String? message;

  const PatchEvent({
    required this.type,
    this.version,
    this.patchNumber,
    this.ok,
    this.error,
    this.boot,
    this.message,
  });

  @override
  String toString() {
    switch (type) {
      case PatchEventType.boot:
        return 'PatchEvent(boot: ${boot ?? 'none'})';
      case PatchEventType.applyStarted:
        return 'PatchEvent(applyStarted v=$version#$patchNumber)';
      case PatchEventType.applyFinished:
        return 'PatchEvent(applyFinished v=$version#$patchNumber '
            'ok=$ok${error != null ? ' error=${error!.name}' : ''})';
      case PatchEventType.staged:
        return 'PatchEvent(staged v=$version#$patchNumber)';
    }
  }
}
