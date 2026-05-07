# API Reference

**English** | [简体中文](api-reference-zh.md)

Every public API in `flutter_patcher` is exposed as a static member on the `FlutterPatcher` class.

The plugin only executes patch logic on Android.
On iOS, Web, macOS, Windows, and Linux, calling these APIs is a no-op — they don't throw, they print a one-time warning on first call, and they return safe defaults.

---

## Initialization

Call before `runApp()`:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterPatcher.init();

  runApp(const MyApp());
}
```

Most projects need no parameters. `init()` prepares the patch loader, the crash-protection state machine, and the boot diagnostic recorder. Repeated calls are safe.

If you want to enable signature verification, change the circuit-breaker threshold, or work around an unusual Flutter build, override the defaults:

```dart
await FlutterPatcher.init(
  publicKeyBase64: 'MFkwEwYH...==',
  maxCrashCount: 1,
  strictSignature: true,
  loaderFieldCandidates: ['flutterLoader'],
  loaderFallbackHeuristic: false,
  verifyAfter: const Duration(seconds: 5),
);
```

| Parameter | Description |
| ---  | --- |
| `publicKeyBase64` | Ed25519 public key. When `PatchInfo.signature` is empty, signature verification is skipped. A patch that ships with a signature but is loaded on a client without a configured public key is rejected. |
| `maxCrashCount` | Number of consecutive crashes that trips the patch. Default `1`. |
| `strictSignature` | On API < 33 (no JDK Ed25519 support), reject signed patches instead of silently skipping verification. On API ≥ 33 the flag has no effect — native verification always runs. |
| `loaderFieldCandidates` | Candidate field names used to locate `FlutterLoader`. Rarely needs changing. |
| `loaderFallbackHeuristic` | If the candidates fail, use a heuristic last-resort scan. Off by default. |
| `verifyAfter` | Window after launch during which the patch is still considered "under verification". |

---

## Check for updates (optional)

> The plugin ships a minimal, optional check-update JSON protocol intended for quick onboarding, the example, and local debugging. In production you almost certainly already have your own update / staging / auth protocol — parse the response yourself, build a `PatchInfo`, and skip this section.

If you do want to use the built-in protocol, call `checkUpdate`:

```dart
try {
  final check = await FlutterPatcher.checkUpdate(
    'https://api.example.com/patch/check',
    headers: {'Authorization': 'Bearer $token'},
    timeout: const Duration(seconds: 10),
  );

  if (check.hasUpdate) {
    await FlutterPatcher.applyPatch(check.patch!);
  }
} on PatcherException catch (e) {
  log.warning('check update failed: ${e.message}');
}
```

`checkUpdate` returns a `PatchCheckResult`:

| Field | Type | Description |
| --- | --- | --- |
| `hasUpdate` | `bool` | Whether a patch is available. |
| `patch` | `PatchInfo?` | The patch info; `null` when no update is available. |

If your server already speaks its own update protocol, skip `checkUpdate` and build a `PatchInfo` directly before calling `applyPatch`.

---

## Apply a patch

There are two ways to apply a patch:

* `applyPatch`: pass a URL and let the plugin download and verify it (recommended for most apps).
* `applyPatchBytes`: pass the patch bytes directly — useful for custom downloaders, asset-bundled patches, or isolate-based loading.

A successful apply takes effect on the **next cold start**. The current process is never modified in place.

### Option 1: let the plugin download the patch

```dart
final result = await FlutterPatcher.applyPatch(
  PatchInfo(
    version: '1.0.0-h1',
    patchUrl: 'https://cdn.example.com/libapp.so',
    md5: '0123456789abcdef0123456789abcdef',
    targetVersionCode: 100,
  ),
  onProgress: (p) {
    print('${p.phase.name}: ${p.fraction ?? "..."}');
  },
);

if (result.ok) {
  showRestartHint();
}
```

`targetVersionCode` is the host APK `versionCode` the patch was built for — **not** the patch version. If your live APK is `versionCode = 100`, every patch built for that APK should set `targetVersionCode: 100`.

If multiple APK versions are live at the same time, build and ship a separate patch per `versionCode`.

### Option 2: apply patch bytes directly

```dart
final bytes = await loadPatchFromYourSource();

final result = await FlutterPatcher.applyPatchBytes(
  bytes,
  version: '1.0.0-h1',
  targetVersionCode: 100,
  onProgress: (p) => print(p.phase.name),
);
```

`applyPatchBytes` automatically computes the MD5, manages the temporary file, and reuses the same flow as `applyPatch`.

---

## Handle the result

Both `applyPatch` and `applyPatchBytes` return a `PatchApplyResult`:

```dart
if (result.ok) {
  // Patch persisted; takes effect on the next cold start.
  showRestartHint();
} else {
  switch (result.error!) {
    case PatchApplyError.blacklisted:
      // This patch previously caused a crash; stop delivering it.
      break;

    case PatchApplyError.network:
    case PatchApplyError.ioError:
      // Transient — retry later.
      break;

    case PatchApplyError.md5Mismatch:
      // CDN content or server-side md5 may be inconsistent.
      break;

    case PatchApplyError.signatureInvalid:
      // Treat as a security event.
      break;

    default:
      log.warning('patch failed: ${result.error?.name} / ${result.message}');
  }
}
```

`result.message` is for developers — don't surface it to end users.

Re-applying the same patch is safe; if it is already installed, the call returns `ok = true`.

---

## Error codes

| Code | Meaning | Suggested handling |
| --- | --- | --- |
| `invalidArgs` | Missing or malformed arguments | Inspect the server response |
| `blacklisted` | Patch hit the local blacklist | Stop delivering this patch |
| `network` | Download failed | Retry later |
| `md5Mismatch` | Downloaded MD5 does not match (only triggered when md5 is provided) | Check CDN / server-side md5 |
| `signatureInvalid` | Signature verification failed | Treat as a security event; do not retry |
| `ioError` | Disk write, rename, or permission failure | Retry later |
| `unknown` | Unclassified error | Inspect `result.message` |

---

## Listening to progress

Besides `onProgress`, you can subscribe to the global broadcast stream:

```dart
FlutterPatcher.applyProgress.listen((p) {
  print('${p.phase.name}: ${p.fraction}');
});
```

| Field | Description |
| --- | --- |
| `phase` | Current phase: `downloading`, `verifying`, `finalizing`. |
| `bytesReceived` | Bytes received so far; only meaningful while downloading. |
| `totalBytes` | Total bytes; `-1` when the server omits `Content-Length`. |
| `fraction` | Download progress in `0.0 ~ 1.0`; `null` when unknown. |

---

## Roll back

```dart
await FlutterPatcher.rollback();
```

Rollback deletes the current patch. On the next cold start the app falls back to the version baked into the APK.

A manual rollback does **not** add the patch to the blacklist.

---

## Manually report a successful boot

```dart
await FlutterPatcher.reportBootSuccess();
```

You usually don't need to call this. `init()` automatically reports a successful boot once the first frame has rendered.

Call it explicitly only when you want to confirm the patch is healthy with custom logic before the first frame:

```dart
await runLightweightSelfCheck();
await FlutterPatcher.reportBootSuccess();
```

Once the first frame has rendered, additional calls are no-ops.

---

## Query state

```dart
final int? code = await FlutterPatcher.appVersionCode;
final String? version = await FlutterPatcher.currentVersion;
final String abi = await FlutterPatcher.deviceAbi;
```

| API | Description |
| --- | --- |
| `appVersionCode` | The current APK's `versionCode`. Uses `longVersionCode` on API 28+. |
| `currentVersion` | The patch version currently on disk (read from `meta.json`). Becomes readable immediately after a successful `applyPatch`, but the Flutter Engine only loads it on the next cold start. `null` when there is no patch. |
| `deviceAbi` | The current device ABI; useful for check-update requests. |

---

## Boot diagnostics

After every cold start the native side records a single patch-load result. Read it via `lastBootDiagnostic` and report it:

```dart
final diag = await FlutterPatcher.lastBootDiagnostic;

if (diag != null && !diag.isHealthy) {
  analytics.report('patch_dropped', {
    'status': diag.status.name,
    'patch_version': diag.patchVersion,
    'crash_count': diag.crashCount,
    'message': diag.message,
  });
}
```

`PatchBootDiagnostic` fields:

| Field | Type | Description |
| --- | --- | --- |
| `status` | `PatchBootStatus` | The boot result. |
| `recordedAt` | `DateTime` | When the diagnostic was recorded. |
| `patchVersion` | `String?` | The patch version involved. |
| `patchTargetVersionCode` | `int?` | The `versionCode` the patch was built for. |
| `appVersionCode` | `int?` | The current APK's `versionCode`. |
| `crashCount` | `int?` | Cumulative crash count. |
| `attemptedLoaderFields` | `List<String>?` | Field names tried when the loader hook failed. |
| `message` | `String?` | Developer-facing diagnostic text. |
| `isHealthy` | `bool` | `true` when the status is `patched` or `noPatch`. |

`PatchBootStatus` values:

| Value | Meaning | Suggested handling |
| --- | --- | --- |
| `patched` | Patch loaded successfully | Normal |
| `noPatch` | No patch; running APK built-in version | Normal |
| `droppedVersionCodeMismatch` | APK was upgraded; the old patch is no longer valid | Usually no alert needed |
| `droppedCircuitBreaker` | Patch caused repeated crashes and was tripped | Strong alert; stop delivering |
| `droppedSignatureInvalid` | Signature verification failed | Alert; investigate the source |
| `droppedMd5Mismatch` | Local file MD5 does not match the recorded MD5 | Report and investigate |
| `droppedMetaCorrupted` | Patch metadata is corrupt | Report and investigate |
| `hookInstallFailed` | FlutterLoader hook failed to install | Check Flutter version / `loaderFieldCandidates` |
| `unknown` | Unclassified error | Inspect `message` |

For interactive debugging, see `example/lib/diag_card.dart` — it renders the diagnostic on-device.

---

## Blacklist

When a patch causes a boot crash or a verification failure, the plugin adds it to a local blacklist so the same bad patch is not retried.

```dart
final entries = await FlutterPatcher.blacklist;

for (final e in entries) {
  print('${e.version} / ${e.md5} / ${e.reason} / ${e.blacklistedAt}');
}
```

To clear the blacklist (debug only):

```dart
await FlutterPatcher.clearBlacklist();
```

`BlacklistEntry` fields:

| Field | Type | Description |
| --- | --- | --- |
| `version` | `String` | Patch version. |
| `md5` | `String` | Patch file MD5. |
| `reason` | `String` | Why the patch was blacklisted. |
| `blacklistedAt` | `DateTime` | When the entry was recorded. |

Common `reason` values:

| Value | Description |
| --- | --- |
| `BOOT_CRASH` | Patch caused a boot crash. |
| `MD5_MISMATCH` | MD5 verification failed. |
| `SIGNATURE_INVALID` | Signature verification failed. |

---

## PatchInfo

`PatchInfo` describes a patch ready to apply.

```dart
final patch = PatchInfo(
  version: '1.0.0-h1',
  patchUrl: 'https://cdn.example.com/libapp.so',
  md5: '0123456789abcdef0123456789abcdef',
  targetVersionCode: 100,
);
```

You can also build it from a server response:

```dart
final patch = PatchInfo.fromJson(json);
final map = patch.toJson();
```

`fromJson` accepts both camelCase and snake_case field names; unknown fields are kept in `raw`.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `version` | `String` | Yes | Patch identifier, an arbitrary string. |
| `patchUrl` | `String` | Yes | Patch download URL. |
| `md5` | `String` | No | Patch MD5 (lower-case 32-hex). An empty string skips MD5 verification (and signature verification along with it). |
| `signature` | `String` | No | Ed25519 signature, base64. Empty disables signature verification. Only effective when `md5` is non-empty. |
| `targetVersionCode` | `int?` | Recommended | Host APK `versionCode` the patch is built for. |
| `raw` | `Map<String, dynamic>` | No | Original fields preserved by `fromJson`. |

---

## Exception behavior

Only `checkUpdate` throws `PatcherException`, typically for network failures or unparsable JSON.

Every other API reports outcomes through return values rather than exceptions.

```dart
try {
  final check = await FlutterPatcher.checkUpdate(url);
} on PatcherException catch (e) {
  log.warning(e.message);
}
```

---

## pack CLI

`flutter_patcher:pack` extracts `libapp.so` from a release APK and emits the patch metadata.

```bash
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.0-h1 \
  --target-version-code 100
```

| Flag | Description |
| --- | --- |
| `--apk <path>` | Required. Path to the release APK. |
| `--version <string>` | Required. Patch identifier. |
| `--target-version-code <int>` | Required. Host APK `versionCode` the patch targets. |
| `--abi <string>` | Optional. Defaults to the first match among `arm64-v8a`, `armeabi-v7a`, `x86_64`. |
| `--out <dir>` | Optional. Output directory; defaults to `dist/`. |

`--target-version-code` binds the patch to a specific base APK already installed on the user's device. For example:

* The live APK is `versionCode = 100`
* You are publishing patch `1.0.0-h1` for that APK
* `--target-version-code` should be `100`

If the APK is upgraded to a new `versionCode`, old patches expire automatically.
If multiple `versionCode`s are live at the same time, build and ship a separate patch per base.

Output:

```text
dist/
├── libapp.so
└── manifest.json
```

Upload `libapp.so` and `manifest.json` to your CDN, then return them from your update endpoint.

---

## Performance and supported range

### Performance impact

| Metric | Impact |
| --- | --- |
| APK size delta | ~80–120 KB |
| Cold-start delta | ~5–15 ms |
| Runtime memory | No additional resident footprint after patch load |
| Patch file size | Typically 5–15 MB |

> Numbers measured on Pixel 6 / Flutter 3.24. Real-world results vary with device, Flutter version, and build configuration.

### Supported range

| Dimension | Requirement |
| --- | --- |
| Platform | Android |
| Android `minSdk` | 24 |
| Flutter | `>=3.3.0`; loader hook verified on 3.19 ~ 3.38 |
| ABI | `armeabi-v7a` / `arm64-v8a` / `x86_64` |
| NDK | 27.0.12077973+ |
| AGP | 8.11.1+ |
| Kotlin | 2.2.20+ |
| Java / JVM | 17 |

On non-Android platforms every API is a no-op: a one-time warning is logged and safe defaults are returned. No exceptions are thrown.

---

## Version compatibility

* During the `0.x` series the API may still change; pin a version in `pubspec.yaml`.
* `PatchBootStatus` and blacklist `reason` values are forward-compatible: new values are mapped to `unknown` by older SDKs.
* `PatchInfo.fromJson` accepts both camelCase and snake_case names; unknown fields are preserved in `raw` and don't break parsing.
