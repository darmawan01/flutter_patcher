# flutter_patcher

**English** | [简体中文](README-zh.md)

[![Platform](https://img.shields.io/badge/platform-Android_only-brightgreen)](https://flutter.dev)
[![pub package](https://img.shields.io/pub/v/flutter_patcher.svg)](https://pub.dev/packages/flutter_patcher)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-beta-orange)]()

## TL;DR

flutter_patcher is an Android-only, self-hosted Flutter hot-update plugin.

It replaces Flutter's Dart AOT artifact `libapp.so` (and, since 0.1.3, Flutter assets) on the next cold start, with:

- self-hosted patch distribution
- versionCode binding
- MD5 / optional Ed25519 verification
- crash rollback and bad-patch blacklist

Best for: teams that need controlled Android hotfixes and can manage their own patch endpoint/CDN.
Not for: iOS, native code, Flutter Engine upgrades, or apps whose distribution channel forbids dynamic executable code.

> **Before you ship:** Google Play and some app stores restrict downloading executable `.so` files — check your channel's policy first. This package targets self-controlled, enterprise, or otherwise permissive distribution.
> The project is **beta**: validate it in internal testing and staged rollouts before depending on it in production.

If this project helps your Flutter release workflow, please star it.

---

## Features

- Hot updates for Dart code compiled into Android `libapp.so`
- Patches take effect on the next cold start; no in-process code swapping
- Self-hosted distribution; no third-party cloud lock-in
- Built-in integrity verification, crash rollback, and a bad-patch blacklist
- Includes a packaging CLI, runtime diagnostics, local mock server, and sample app

---

## Feature Demo

![Feature demo: apply a patch, cold restart, and rollback](doc/feature-presentation.gif)

---

## Table of contents

- [Is this plugin a fit for you?](#is-this-plugin-a-fit-for-you)
- [Requirements](#requirements)
- [5-minute walkthrough](#5-minute-walkthrough)
- [Local mock server](#local-mock-server)
- [Install](#install)
- [Quick start](#quick-start)
- [Patch lifecycle](#patch-lifecycle)
- [Crash protection](#crash-protection)
- [What can and cannot be patched](#what-can-and-cannot-be-patched)
- [Security](#security)
- [Production recommendations](#production-recommendations)
- [FAQ](#faq)
- [Documentation](#documentation)

---

## Is this plugin a fit for you?

`flutter_patcher` is a self-hosted Android-only hot-update SDK for Flutter.
Patches live on your own server, CDN, or object storage; nothing depends on a third-party cloud.

### Good fit

- Your project only needs Android hot updates; iOS can ship through normal store releases
- Your team can run its own patch distribution, and patch data must be self-hosted
- You want to roll out Dart-layer fixes to a small audience quickly

### Not a fit

- You need hot updates on both Android and iOS
- You don't want to maintain any patch-distribution infrastructure
- You need a commercial SLA, hosted console, audit trails, or dedicated support
- You need to update native code, Android `res/` resources, or the Flutter Engine
- App-store policy or regulatory rules forbid dynamic delivery of executable code

If you need cross-platform hot updates or a managed service, evaluate alternatives such as Shorebird.

---

## Requirements

| Item | Requirement |
|---|---|
| Platform | Android only |
| Dart SDK | `>=3.0.0 <4.0.0` |
| Flutter | `>=3.3.0`; loader hook verified on 3.19 ~ 3.38 |
| Android `minSdk` | 24 |
| Android `compileSdk` | 36 |
| ABI | `armeabi-v7a` / `arm64-v8a` / `x86_64` |
| NDK | 27.0.12077973+ |
| AGP | 8.11.1+ |
| Kotlin | 2.2.20+ |
| Java / JVM | 17 |

On iOS, macOS, Windows, Linux and Web, every API is safe to call but does nothing — the plugin logs a one-time "platform unsupported" warning and returns safe defaults.

---

## 5-minute walkthrough

You don't need any backend. Clone the repo and you can experience the full hot-update flow:

```bash
git clone https://github.com/xuelinger2333/flutter_patcher.git
cd flutter_patcher/example
flutter build apk --release
flutter install
```

Steps:

1. Launch the app — the button is **blue**
2. Tap **Apply patch**
3. Swipe the app away from recents and reopen it
4. The button is now **red** — the patch took effect
5. Tap **Rollback**
6. After another restart it is blue again

The example bundles a precompiled red-theme patch.
`Apply patch` reads the asset bytes and calls `applyPatchBytes`; the entire flow is offline.

---

## Local mock server

If you want to try the HTTP `checkUpdate -> applyPatch` flow without building a backend, run the bundled mock server.
It is for local development only, not production patch distribution.

```bash
# Rebuild the release APK after editing Dart code
flutter build apk --release

# Build the patch package
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version dev-1 \
  --target-version-code 100

# Serve dist/patch.zip and dist/manifest.json on 0.0.0.0:8080
dart run flutter_patcher:mock_server --dist dist
```

Then call it from a phone on the same Wi-Fi network:

```dart
final check = await FlutterPatcher.checkUpdate(
  'http://<your-computer-ip>:8080/check',
);

if (check.hasUpdate) {
  await FlutterPatcher.applyPatch(check.patch!);
}
```

---

## Install

```yaml
dependencies:
  flutter_patcher: ^0.1.3
```

Or as a Git dependency:

```yaml
dependencies:
  flutter_patcher:
    git:
      url: https://github.com/xuelinger2333/flutter_patcher.git
```

---

## Quick start

### 1. Build a patch

Rebuild the release APK (`flutter build apk --release`), then run `pack` against it.

**Dart code:**

```bash
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.0-h1 \
  --target-version-code 100
```

**Assets** (since 0.1.3) — append `--assets`:

```bash
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.1 \
  --target-version-code 100 \
  --assets assets/hero.png,assets/strings/zh.json
```

- `--version`: patch version (any string you choose).
- `--target-version-code`: `versionCode` of the **base APK installed on the user's device** — not the patch version, not the patch APK's version.
- `--assets`: comma-separated asset keys. Omit for Dart-only patches.

When you have many keys, point `--assets` at a text file with `@` — one key per line, `#` starts a comment, inline and `@file` can be mixed:

```bash
# patch-assets.txt
# core
assets/hero.png
assets/strings/zh.json
# fonts
assets/fonts/Inter-Bold.ttf
```

```bash
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.1 \
  --target-version-code 100 \
  --assets @patch-assets.txt,assets/last-minute.png
```

Output: `dist/patch.zip` + `dist/manifest.json`. Upload both to your CDN.

`patch.zip` layout and `manifest_patch.json` schema: [API Reference → Asset Patching](doc/api-reference.md#asset-patching). Server protocol, signing, disabling auto-init: [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html).

### 2. Apply a patch

#### 2.1 Initialize

Call before `runApp()`:

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FlutterPatcher.init();

  runApp(const MyApp());
}
```

The defaults are appropriate for most projects.

If you need to tune crash protection, pass parameters explicitly:

```dart
await FlutterPatcher.init(
  maxCrashCount: 1,
  verifyAfter: const Duration(seconds: 5),
);
```

#### 2.2 Apply a patch

The client only needs a `PatchInfo`; pass it to `applyPatch`. `PatchInfo` is normally produced from your own update endpoint:

```dart
final result = await FlutterPatcher.applyPatch(
  PatchInfo(
    version: 'fix-1',
    patchUrl: 'https://your-cdn.com/v100/patch.zip',
    md5: '0123456789abcdef0123456789abcdef',
    targetVersionCode: 100,
  ),
);

if (result.ok) {
  // The patch will take effect on the next cold start; show a restart hint if you want.
}
```

If you already have your own download logic, or the patch comes from an asset / isolate, use `applyPatchBytes`:

```dart
final bytes = await loadPatchFromYourSource();

final result = await FlutterPatcher.applyPatchBytes(
  bytes,
  version: '1.0.0-h1',
  targetVersionCode: 100,
);
```

`applyPatchBytes` automatically computes the MD5, manages the temporary file, and reuses the regular apply flow.

> The plugin also ships with an optional minimal check-update JSON protocol, intended for quick onboarding, the example, and local testing. In production, if you already have your own update / staging / auth protocol, parse the response yourself and construct `PatchInfo` directly. The protocol format and `checkUpdate` usage live in the [API reference](https://pub.dev/documentation/flutter_patcher/latest/topics/API-reference-topic.html) and [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html).

> **Skipping MD5**: `PatchInfo.md5` is now optional. If your server doesn't ship md5 (or you only want HTTPS-level integrity), leave it out:
> ```dart
> PatchInfo(version: 'fix-1', patchUrl: '...', targetVersionCode: 100); // md5 defaults to ''
> ```
> Download integrity checks are skipped; **note that signature verification is also skipped** in this case (the Ed25519 input is the md5 hex string — without md5 there is no message to sign over). To keep signature verification you must also ship md5.

#### 2.3 Roll back

```dart
await FlutterPatcher.rollback();
```

Rollback deletes the current patch. On the next cold start the app falls back to the version baked into the APK.

A manual `rollback()` does **not** add the patch to the blacklist.

---

## Patch lifecycle

```text
Download patch
  ↓
Verify MD5 / signature when provided, then versionCode
  ↓
Persist to local patch directory
  ↓
Wait for the next cold start
  ↓
Cold start loads the patched libapp.so
  ↓
Boot succeeds: keep using the patch
Boot fails:    auto-rollback
```

A successful `applyPatch` takes effect on the **next cold start**, never inside the current process.

If you need to nudge users to restart, show a prompt after `applyPatch` succeeds.

---

## Crash protection

`flutter_patcher` is fail-fast by default.
If a patch causes a boot failure, or a serious Dart-level error fires during early UI, the plugin rolls back to the APK's built-in version on the next cold start and adds the offending patch to a local blacklist, so the same bad patch is not loaded over and over.

Common settings:

| Parameter | Default | Description |
|---|---|---|
| `maxCrashCount` | `1` | Number of consecutive failures before the patch is tripped |
| `verifyAfter` | `5 seconds` | Window during which the post-first-frame Dart error hooks keep watching |

Android 11+ uses `ApplicationExitInfo` to distinguish crashes, ANRs, user dismissal, and system reclaim more accurately.
Android 10 and below have weaker signals; pair the SDK with your own crash monitoring and a server-side kill switch.

The full design, Android version differences, blacklist semantics, and diagnostic states live in the [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html) doc.

---

## What can and cannot be patched

A patch replaces the Dart AOT artifact `libapp.so` and Flutter assets declared in `pubspec.yaml`. Everything else — native code, the Flutter Engine, APK resources — must ship through a regular release.

### Hot-patchable

- Anything in `lib/` — widgets, business logic, state, routing, string constants
- Pure-Dart third-party packages, as long as the native side is unchanged
- Flutter assets declared in `pubspec.yaml` — images, JSON, font glyphs; anything reachable via `Image.asset(...)` or `rootBundle.load(...)`

### Not hot-patchable

- Native code: Kotlin / Java / C++, `AndroidManifest.xml`, APK `res/` resources, adding or modifying native plugins
- Flutter Engine upgrades (a patched `libapp.so` is tied to the engine version baked into the APK)

### Evaluate carefully

- **ProGuard / R8 changes**: a mismatched symbol map can make crash stacks unreadable
- **Multi-ABI / multi-flavor**: the server must shard by `ABI × flavor × versionCode`
- **Persisted state migrations** (Dart model serialization, DB schema, local cache format): both old and new code must read safely, since a rollback brings old code back against new-format data

---

## Security

`flutter_patcher` provides basic integrity checks plus an optional signature mechanism.

- MD5 verification is strongly recommended; leave `PatchInfo.md5` empty only for quick testing or protocols that intentionally rely on HTTPS-level integrity
- Optional Ed25519 signature verification is available on Android 13 / API 33+. On lower Android versions, signed patches are rejected by default (`strictSignature: true`); use `strictSignature: false` only if you accept the MD5 + HTTPS fallback
- Because the signed message is the md5 hex string, signatures are only checked when `md5` is present
- Keep the private key on the server or build environment only — never in the client repo
- A patch is strongly bound to the host APK's `versionCode`, so old patches expire after an APK upgrade
- Always download patches over HTTPS
- The server should record patch version, MD5/signature when used, target `versionCode`, and release time

For signature generation, `strictSignature` behavior, and the server protocol, see [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html).

---

## Production recommendations

### 1. Stage the rollout

Don't ship a patch to 100% on day one. A typical ramp:

```text
1% → 5% → 20% → 50% → 100%
```

Watch crash rate, boot failure rate, and the key business metrics at each stage.

### 2. Report boot diagnostics

Report `lastBootDiagnostic`:

```dart
final diag = await FlutterPatcher.lastBootDiagnostic;

if (diag != null && !diag.isHealthy) {
  // Replace with your analytics SDK: Firebase Analytics / Sentry / your own pipeline.
  analytics.report('patch_dropped', {
    'status': diag.status.name,
    'patch_version': diag.patchVersion,
    'crash_count': diag.crashCount,
    'message': diag.message,
  });
}
```

If the same patch triggers `droppedCircuitBreaker` repeatedly in a short window, the server should automatically stop delivering it.

### 3. Keep release records

Track each patch with at least:

- Patch version
- Target APK `versionCode`
- ABI
- Flavor
- MD5, if shipped
- Signature, if shipped
- Release time
- Rollout percentage
- Current state: ramping, full, or rolled back

### 4. Plan for emergency rollback

An emergency rollback only requires the update endpoint to stop returning the offending patch version.
Devices that already tripped crash protection have rolled back locally and will refuse to apply the same problematic patch again.

---

## FAQ

### Q: Must the patch and base APK use the same Flutter version?

A: Yes. `libapp.so` is tightly coupled to the Flutter Engine and Dart runtime. Different Flutter versions cannot safely load each other's `libapp.so`. After upgrading the Flutter SDK or Engine, you must ship a new release.

### Q: A user skipped intermediate patch versions and just got the latest one — what happens?

A: Each patch is a complete `libapp.so` and does not depend on previous patches. Users can jump straight from "no patch" or an old patch to the latest one.

### Q: How do I iterate quickly during development without uploading to a CDN?

A: For the offline flow, run the sample app from the [5-minute walkthrough](#5-minute-walkthrough). For HTTP testing, use the bundled mock server from [Local mock server](#local-mock-server):

```bash
dart run flutter_patcher:pack \
  --apk path/to/app-release.apk \
  --version dev-1 \
  --target-version-code 1

dart run flutter_patcher:mock_server --dist dist --port 8080
```

Then set the client `patchUrl` to:

```text
http://<your-machine-ip>:8080/patch.zip
```

### Q: How do I handle multiple ABIs?

A: The server must distribute a `patch.zip` per ABI (each patch embeds one `lib/<abi>/libapp.so`). The client can read the current device ABI via `FlutterPatcher.deviceAbi` and include it in your update request.

### Q: How do I handle multiple flavors?

A: The server should track patches by `flavor × ABI × versionCode`. Different flavors typically have different configs, package names, resources, and business logic — never share a patch across flavors.

### Q: Do I need to tweak ProGuard / R8 rules?

A: Usually no. The plugin's reflection targets non-obfuscated Flutter Engine classes and is unaffected by your business obfuscation.

### Q: Can a patch be revoked?

A: Yes. On the client, `FlutterPatcher.rollback()` deletes the current patch. On the server, simply stop returning that version from your update endpoint and new users will not download it.

### Q: Why doesn't a patch take effect immediately?

A: Once the current process has loaded `libapp.so`, it can't be safely swapped at runtime. To stay safe, the patch is written to disk and loaded on the next cold start.

### Q: Why does each patch need a `targetVersionCode`?

A: A patch is only valid against the base APK it was built for. Binding `targetVersionCode` prevents loading old patches after an APK upgrade and prevents the server from accidentally shipping a patch to incompatible builds.

---

## Documentation

- [API reference](https://pub.dev/documentation/flutter_patcher/latest/topics/API-reference-topic.html) — init, check-update, apply, rollback, diagnostics, error codes, and CLI flags
- [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html) — crash protection, auto-rollback, blacklist, Android version differences, and diagnostic states
- [Architecture](https://pub.dev/documentation/flutter_patcher/latest/topics/Architecture-topic.html) — internals, self-hosted server protocol, signing, and advanced configuration

中文文档：[README-zh.md](README-zh.md) · [doc/api-reference-zh.md](doc/api-reference-zh.md) · [doc/architecture-zh.md](doc/architecture-zh.md) · [doc/crash-protection-zh.md](doc/crash-protection-zh.md)

---

## Contributing

Issues and PRs are welcome.

Before submitting, please make sure:

- `flutter analyze` reports no warnings
- `flutter test` is fully green
- If you touched native code, you have run a real-device end-to-end patch / rollback flow

---

## License

MIT
