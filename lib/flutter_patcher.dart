import 'dart:async';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show EventChannel;
import 'package:flutter/widgets.dart';

import 'src/blacklist.dart';
import 'src/boot_diagnostic.dart';
import 'src/io_stub.dart' if (dart.library.io) 'src/io.dart' as platform_io;
import 'src/patch_info.dart';
import 'src/patcher_channel.dart';

export 'src/blacklist.dart';
export 'src/boot_diagnostic.dart';
export 'src/patch_info.dart';

/// Android-only Flutter hot-update entrypoint.
///
/// `flutter_patcher` installs a patch payload and loads it on the next cold
/// start. The payload can be a legacy `libapp.so` or a v2 `patch.zip` that
/// contains `libapp.so` plus explicitly selected Flutter assets.
///
/// Main APIs:
///
/// - [init]: configure native startup, crash protection, and first-frame boot
///   verification.
/// - [checkUpdate]: optional helper for the built-in minimal update protocol.
/// - [applyPatch]: download, verify, and install a payload URL.
/// - [applyPatchBytes]: install an already downloaded payload byte array.
/// - [rollback]: delete the current patch.
///
/// Patches are never swapped into the current process. A successful apply takes
/// effect only after the next cold start.
///
/// {@category Architecture}
/// {@category API-reference}
/// {@category Crash-protection}
class FlutterPatcher {
  FlutterPatcher._();

  static bool _inited = false;
  static bool _firstFrameReported = false;
  static bool _bootReported = false;
  static bool _bootErrorReported = false;
  static bool _nonAndroidWarned = false;

  /// Whether Dart boot-error hooks can still report failures to native crash
  /// protection. The first frame clears native boot state immediately; this
  /// flag keeps Dart-side blank-screen detection alive for [init]'s
  /// `verifyAfter` window.
  static bool _dartHookActive = true;

  static bool _notAndroidGuard(String method) {
    if (platform_io.isAndroid) return false;
    if (!_nonAndroidWarned) {
      _nonAndroidWarned = true;
      debugPrint(
        '[FlutterPatcher] WARNING: $method called on ${platform_io.operatingSystem}. '
        'This plugin only supports Android; all calls are no-ops. '
        'See README > What Can Be Patched?',
      );
    }
    return true;
  }

  static const EventChannel _eventChannel = EventChannel(
    'flutter_patcher/events',
  );
  static Stream<PatchApplyProgress>? _progressStream;

  /// Broadcast progress stream for [applyPatch].
  ///
  /// Subscribe before calling [applyPatch] to receive `downloading`,
  /// `verifying`, and `finalizing` events. Non-Android platforms return an
  /// empty stream.
  static Stream<PatchApplyProgress> get applyProgress {
    if (_notAndroidGuard('applyProgress')) return const Stream.empty();
    return _progressStream ??= _eventChannel.receiveBroadcastStream().map(
          (raw) => PatchApplyProgress.fromNative(raw),
        );
  }

  /// Initializes patch configuration and crash protection.
  ///
  /// Call this in `main()` before `runApp()`. The method is idempotent.
  ///
  /// [publicKeyBase64] is an optional X.509 SubjectPublicKeyInfo Ed25519 public
  /// key in base64. Empty disables signature verification. If [PatchInfo.sha256]
  /// is empty, signature verification is skipped as well because the signed
  /// message is the SHA-256 hex string.
  ///
  /// [publicKeysBase64] is the multi-key form: a set of **trusted** signing keys.
  /// A patch (or kill-switch) signature is accepted if **any** of them verifies
  /// it. This is how you rotate keys without bricking clients — ship a release
  /// that trusts both the old and new key, switch the server to sign with the
  /// new key, then drop the old key in a later release. [publicKeyBase64] is
  /// merged into this set, so passing either (or both) works.
  ///
  /// [maxCrashCount] defaults to `1` (fail-fast). Once a loaded patch causes an
  /// early boot failure, the SDK rolls it back and blacklists the same payload.
  ///
  /// [strictSignature] historically rejected signed patches on Android API < 33.
  /// Ed25519 now runs through the bundled BouncyCastle lightweight crypto API,
  /// so verification works on every supported API level; the flag is retained
  /// for source compatibility.
  ///
  /// [requireHttps] (default true) rejects patch payloads served over plaintext
  /// `http://`. `file://` (local staging via [applyPatchBytes]) is always
  /// allowed. Pass `false` only for trusted in-network testing.
  ///
  /// [pinnedSpkiSha256] optionally pins the download server's leaf-certificate
  /// SubjectPublicKeyInfo SHA-256, base64-encoded (the `sha256/…` value from
  /// OkHttp-style pinning, without the `sha256/` prefix). When non-empty, an
  /// HTTPS download whose leaf SPKI is not in this set is rejected. Empty
  /// disables pinning.
  ///
  /// [loaderFieldCandidates] and [loaderFallbackHeuristic] are advanced Flutter
  /// embedding compatibility controls. Keep defaults unless adapting a new
  /// Flutter version.
  ///
  /// [verifyAfter] is the post-first-frame Dart error watch window.
  static Future<void> init({
    String publicKeyBase64 = '',
    List<String> publicKeysBase64 = const [],
    int maxCrashCount = 1,
    bool strictSignature = true,
    bool requireHttps = true,
    List<String> pinnedSpkiSha256 = const [],
    List<String> loaderFieldCandidates = const ['flutterLoader'],
    bool loaderFallbackHeuristic = false,
    Duration verifyAfter = const Duration(seconds: 5),
  }) async {
    if (_notAndroidGuard('init')) return;
    if (_inited) return;
    _inited = true;
    _verifyAfter = verifyAfter;

    try {
      await PatcherChannel.markBooting();
    } catch (e, s) {
      _log('markBooting failed: $e', s);
    }

    _installBootErrorCatchers();

    try {
      final trustedKeys = <String>[
        ...publicKeysBase64,
        if (publicKeyBase64.isNotEmpty) publicKeyBase64,
      ].map((k) => k.trim()).where((k) => k.isNotEmpty).toSet().toList();
      await PatcherChannel.saveConfig(
        publicKeysBase64: trustedKeys,
        maxCrashCount: maxCrashCount,
        strictSignature: strictSignature,
        requireHttps: requireHttps,
        pinnedSpkiSha256: pinnedSpkiSha256,
        loaderFieldCandidates: loaderFieldCandidates,
        loaderFallbackHeuristic: loaderFallbackHeuristic,
      );
    } catch (e, s) {
      _log('saveConfig failed: $e', s);
    }

    _BootVerifier.start();
  }

  /// Clears the "crashed before first frame" signal once the UI renders.
  ///
  /// Does NOT yet declare the patch healthy — that happens after the watchdog
  /// window via [reportBootSuccess]. Called automatically by [init].
  static Future<void> reportFirstFrame() async {
    if (_notAndroidGuard('reportFirstFrame')) return;
    if (_firstFrameReported) return;
    _firstFrameReported = true;
    try {
      await PatcherChannel.reportFirstFrame();
    } catch (e, s) {
      _log('reportFirstFrame failed: $e', s);
    }
  }

  /// Declares the patched boot healthy and resets native crash protection.
  ///
  /// Called automatically by [init] only after the app survives the watchdog
  /// window (first frame + [verifyAfter] of healthy foreground time), so a
  /// render-then-crash-loop patch keeps accumulating crashes until it trips.
  static Future<void> reportBootSuccess() async {
    if (_notAndroidGuard('reportBootSuccess')) return;
    if (_bootReported) return;
    _bootReported = true;
    try {
      await PatcherChannel.reportBootSuccess();
    } catch (e, s) {
      _log('reportBootSuccess failed: $e', s);
    }
  }

  /// Optional HTTP update checker for the built-in minimal JSON protocol.
  ///
  /// Production apps can skip this method, parse their own update response, and
  /// construct [PatchInfo] directly before calling [applyPatch].
  ///
  /// The returned `patchUrl` is a payload URL: `libapp.so` for lib-only patches
  /// or `patch.zip` for asset patches.
  static Future<PatchCheckResult> checkUpdate(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_notAndroidGuard('checkUpdate')) {
      return PatchCheckResult.none();
    }

    try {
      final decoded = await platform_io.getJson(
        url,
        headers: headers,
        timeout: timeout,
      );
      final check = PatchCheckResult.fromJson(decoded);
      // Server kill switch: if the response carries a signed rollback list, let
      // native verify it and drop the installed patch before we return. This
      // runs on every check, including when there is no new update to offer.
      if (check.rolledBack.isNotEmpty) {
        try {
          final killed = await PatcherChannel.enforceRollback(
            check.rolledBack,
            check.rolledBackSignature,
          );
          if (killed) _log('server rolled back the installed patch');
        } catch (e, s) {
          _log('enforceRollback failed: $e', s);
        }
      }
      return check;
    } on PatcherException {
      rethrow;
    } catch (e, s) {
      _log('checkUpdate failed: $e', s);
      throw PatcherException(e.toString());
    }
  }

  /// Recommended default update flow: check, then **stage** any new patch for the
  /// next cold start. Call this once at startup (e.g. right after `runApp`).
  ///
  /// This is the safe pattern for a long-running or safety-critical app: the
  /// download and verification happen off the UI isolate (native worker thread),
  /// the kill switch is enforced transparently during the check, and a new patch
  /// only takes effect on the **next launch** — the running isolate is never
  /// hot-swapped mid-session. To force it sooner, prompt the user to restart;
  /// don't kill the process from under them.
  ///
  /// Never throws — network/parse failures come back as
  /// [PatchStageOutcome.failed]. [onProgress] streams download progress.
  static Future<PatchStageResult> checkAndStage(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
    void Function(PatchApplyProgress)? onProgress,
  }) async {
    if (_notAndroidGuard('checkAndStage')) return PatchStageResult.upToDate();
    try {
      final check = await checkUpdate(url, headers: headers, timeout: timeout);
      final patch = check.patch;
      if (!check.hasUpdate || patch == null) return PatchStageResult.upToDate();
      final res = await applyPatch(patch, onProgress: onProgress);
      if (res.ok) return PatchStageResult.stagedPatch(patch);
      return PatchStageResult.failure(
        res.error ?? PatchApplyError.unknown,
        res.message,
      );
    } catch (e, s) {
      _log('checkAndStage failed: $e', s);
      return PatchStageResult.failure(PatchApplyError.network, e.toString());
    }
  }

  /// Downloads, verifies, and installs [patchInfo]'s payload.
  ///
  /// The payload can be either a complete `libapp.so` or a v2 `patch.zip`.
  /// Native code detects ZIP payloads automatically.
  ///
  /// Flow:
  ///
  /// 1. Download with retry.
  /// 2. Verify payload md5/signature when provided.
  /// 3. Install legacy lib-only payload, or parse and install v2 package.
  /// 4. Commit patch files transactionally for the next cold start.
  ///
  /// Returns a [PatchApplyResult]. `ok=true` means the patch is installed and
  /// will take effect on the next cold start.
  static Future<PatchApplyResult> applyPatch(
    PatchInfo patchInfo, {
    void Function(PatchApplyProgress)? onProgress,
  }) async {
    if (_notAndroidGuard('applyPatch')) {
      return PatchApplyResult.failure(
        PatchApplyError.unknown,
        'not supported on ${platform_io.operatingSystem}',
      );
    }
    StreamSubscription<PatchApplyProgress>? sub;
    if (onProgress != null) {
      sub = applyProgress.listen(onProgress);
    }
    try {
      final native = await PatcherChannel.applyPatch(patchInfo.toJson());
      return PatchApplyResult.fromNative(native);
    } catch (e, s) {
      _log('applyPatch failed: $e', s);
      return PatchApplyResult.failure(PatchApplyError.unknown, e.toString());
    } finally {
      await sub?.cancel();
    }
  }

  static String? _cachedStagingDir;

  /// Installs an already downloaded patch payload.
  ///
  /// Useful for bundled example patches, custom downloaders, or isolate-based
  /// loading. The bytes can be either `libapp.so` or `patch.zip`.
  ///
  /// This helper writes bytes to native cache, computes the SHA-256, then
  /// reuses [applyPatch] through a `file://` URL.
  static Future<PatchApplyResult> applyPatchBytes(
    Uint8List bytes, {
    required String version,
    String signature = '',
    int? targetVersionCode,
    void Function(PatchApplyProgress)? onProgress,
  }) async {
    if (_notAndroidGuard('applyPatchBytes')) {
      return PatchApplyResult.failure(
        PatchApplyError.unknown,
        'not supported on ${platform_io.operatingSystem}',
      );
    }
    final dir = _cachedStagingDir ??= (await PatcherChannel.cacheDir()) ?? '';
    if (dir.isEmpty) {
      return PatchApplyResult.failure(
        PatchApplyError.ioError,
        'native cacheDir unavailable',
      );
    }
    String? stagedPath;
    try {
      stagedPath = await platform_io.stagePatchBytes(dir, bytes);
      final sha256Hex = crypto.sha256.convert(bytes).toString();
      return await applyPatch(
        PatchInfo(
          version: version,
          patchUrl: 'file://$stagedPath',
          sha256: sha256Hex,
          signature: signature,
          targetVersionCode: targetVersionCode,
        ),
        onProgress: onProgress,
      );
    } catch (e, s) {
      _log('applyPatchBytes failed: $e', s);
      return PatchApplyResult.failure(PatchApplyError.unknown, e.toString());
    } finally {
      try {
        if (stagedPath != null) {
          await platform_io.deleteFileIfExists(stagedPath);
        }
      } catch (_) {
        // Staging cleanup must not block the apply result.
      }
    }
  }

  /// Deletes the current patch. The next cold start uses the APK built-in
  /// version. Manual rollback does not blacklist the patch.
  static Future<void> rollback() async {
    if (_notAndroidGuard('rollback')) return;
    try {
      await PatcherChannel.rollback();
    } catch (e, s) {
      _log('rollback failed: $e', s);
    }
  }

  /// Current host APK versionCode. Returns null on failure/non-Android.
  static Future<int?> get appVersionCode async {
    if (_notAndroidGuard('appVersionCode')) return null;
    try {
      return await PatcherChannel.appVersionCode();
    } catch (_) {
      return null;
    }
  }

  /// Current device ABI. Useful when your backend routes patches per ABI.
  static Future<String> get deviceAbi async {
    if (_notAndroidGuard('deviceAbi')) return '';
    try {
      return await PatcherChannel.deviceAbi() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Patch version currently installed on disk.
  ///
  /// A successful `applyPatch` updates this immediately, but the patch is only
  /// loaded by Flutter after the next cold start. Returns null when no patch is
  /// installed.
  static Future<String?> get currentVersion async {
    if (_notAndroidGuard('currentVersion')) return null;
    try {
      final v = await PatcherChannel.currentVersion();
      if (v == null || v.isEmpty) return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  /// Local bad-patch blacklist, ordered from oldest to newest.
  ///
  /// Automatic blacklist triggers include early boot failures, cold-start md5
  /// mismatches, and cold-start signature failures. For asset patches, the md5
  /// is the `patch.zip` payload md5.
  static Future<List<BlacklistEntry>> get blacklist async {
    if (_notAndroidGuard('blacklist')) return const [];
    try {
      final raw = await PatcherChannel.blacklist();
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((m) => BlacklistEntry.fromNative(m))
          .toList(growable: false);
    } catch (e, s) {
      _log('blacklist failed: $e', s);
      return const [];
    }
  }

  /// Clears the local bad-patch blacklist.
  ///
  /// Intended for tests, local debugging, or deliberate operational recovery.
  static Future<void> clearBlacklist() async {
    if (_notAndroidGuard('clearBlacklist')) return;
    try {
      await PatcherChannel.clearBlacklist();
    } catch (e, s) {
      _log('clearBlacklist failed: $e', s);
    }
  }

  /// Last cold-start patch loading diagnostic.
  ///
  /// `applyPatch` reports install-time failures. This getter reports what
  /// happened on the next cold start: version mismatch, md5/signature failure,
  /// crash rollback, loader hook failure, or successful patch load.
  static Future<PatchBootDiagnostic?> get lastBootDiagnostic async {
    if (_notAndroidGuard('lastBootDiagnostic')) return null;
    try {
      final raw = await PatcherChannel.lastBootDiagnostic();
      if (raw == null) return null;
      return PatchBootDiagnostic.fromNative(raw);
    } catch (e, s) {
      _log('lastBootDiagnostic failed: $e', s);
      return null;
    }
  }

  static Duration _verifyAfter = const Duration(seconds: 5);

  static void _installBootErrorCatchers() {
    final priorPlatformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _maybeReportBootError(error, stack);
      return priorPlatformHandler?.call(error, stack) ?? false;
    };

    final priorFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      _maybeReportBootError(details.exception, details.stack);
      (priorFlutterHandler ?? FlutterError.presentError).call(details);
    };
  }

  static void _maybeReportBootError(Object error, StackTrace? stack) {
    if (!_dartHookActive) return;
    if (_bootErrorReported) return;
    _bootErrorReported = true;
    final msg = error.toString();
    _log('boot-phase Dart error captured: $msg', stack);
    PatcherChannel.reportDartBootError(msg).catchError((e) {
      _log('reportDartBootError channel call failed: $e');
    });
  }

  static void _log(String msg, [StackTrace? stack]) {
    if (kDebugMode) {
      debugPrint('[FlutterPatcher] $msg');
    }
  }
}

/// Plugin-wide exception. Wraps network/parsing errors from [FlutterPatcher.checkUpdate].
class PatcherException implements Exception {
  final String message;
  PatcherException(this.message);
  @override
  String toString() => 'PatcherException: $message';
}

class _BootVerifier with WidgetsBindingObserver {
  static _BootVerifier? _instance;

  Duration _foregroundElapsed = Duration.zero;
  DateTime? _resumedAt;
  Timer? _timer;
  bool _windowClosed = false;

  static void start() {
    if (_instance != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _instance ??= _BootVerifier().._begin();
    });
  }

  void _begin() {
    // First frame rendered: clear the pre-frame crash signal, but do NOT yet
    // declare the patch healthy — that waits for the watchdog window to elapse.
    FlutterPatcher.reportFirstFrame();

    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    final state = binding.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) {
      _resumedAt = DateTime.now();
      _scheduleCheck();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_windowClosed) return;
    if (state == AppLifecycleState.resumed) {
      _resumedAt = DateTime.now();
      _scheduleCheck();
    } else {
      if (_resumedAt != null) {
        _foregroundElapsed += DateTime.now().difference(_resumedAt!);
        _resumedAt = null;
      }
      _timer?.cancel();
    }
  }

  void _scheduleCheck() {
    final remaining = FlutterPatcher._verifyAfter - _foregroundElapsed;
    _timer?.cancel();
    if (remaining <= Duration.zero) {
      _closeHookWindow();
      return;
    }
    _timer = Timer(remaining, _closeHookWindow);
  }

  void _closeHookWindow() {
    if (_windowClosed) return;
    _windowClosed = true;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    // Survived the watchdog window with no boot crash → the patch is healthy.
    FlutterPatcher.reportBootSuccess();
    FlutterPatcher._dartHookActive = false;
  }
}
