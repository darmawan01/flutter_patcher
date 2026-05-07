# Architecture

**English** | [简体中文](architecture-zh.md)

This document covers how `flutter_patcher` works, the self-hosted server protocol, and a small number of advanced configuration options.

If you only want to integrate quickly, read the API reference first. This document is more useful when:

- You want to understand why a patch only takes effect on the next cold start
- You need to self-host the patch check / distribution service
- You need to evaluate security, compatibility, or app-store compliance
- Your Android project has an unusual startup, such as eagerly preheating `FlutterEngine`

Related docs:

- The public API, pack CLI flags, performance, and compatibility live in the [API reference](https://pub.dev/documentation/flutter_patcher/latest/topics/API-reference-topic.html)
- Crash protection, auto-rollback, and blacklist behavior live in [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html)

---

## How it works

### Overview

A `flutter_patcher` rollout involves three actors: the developer machine, the server, and the user device.

```text
  Dev machine                Server                   User device
─────────────              ─────────────              ─────────────
 Edit Dart code            Storage + delivery         Download + verify
      │                          │                           │
 flutter build apk           Upload patch                applyPatch()
      │                  libapp.so + manifest               │
 pack extracts patch              │                    Persist locally
      │                          │                           │
      └──────────────→     CDN / object store    ──────────→ Load on next cold start
                                                              │
                                                       Boot OK   → keep patch
                                                       Boot fail → auto-rollback
```

The basic flow:

1. Edit Dart code and rebuild the release APK.
2. Use `flutter_patcher:pack` to extract the patch file and metadata from the APK.
3. Upload the patch to a CDN or object storage.
4. The client checks for updates, then downloads and verifies the patch.
5. The patch is persisted to disk and takes effect on the next cold start.

The patch never replaces code in the current process. If you want users to restart sooner, prompt them after `applyPatch` succeeds.

---

### Patch lifecycle

On a user device a patch goes through:

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

On every cold start the plugin re-checks that the patch still applies to the current APK before loading it.
If the patch is invalid, corrupt, mismatched, or blacklisted, the plugin drops it and falls back to the APK's built-in version.

For the full crash-protection decision flow, Android-version differences, and blacklist behavior, see [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html).

---

### VersionCode binding

Each patch is bound to one host APK `versionCode`.

On cold start, if the current APK's `versionCode` does not match the patch's `targetVersionCode`, the plugin drops the patch.

This guards against:

- Loading an old patch after the user upgraded the APK
- Server-side mistakes that ship a patch built for an old APK to a newer build
- Sharing one patch between incompatible production versions

That's why building a patch must explicitly name the base APK's `versionCode`:

```bash
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.0-h1 \
  --target-version-code 100
```

`--target-version-code 100` means:

> This patch is only valid for the APK with `versionCode = 100` already installed on the user's device.

If multiple `versionCode`s are live at once, build and ship a separate patch for each base.

---

### Crash safety

`flutter_patcher` is fail-fast by default.
If a patch causes a boot failure, or a serious Dart-level error fires during early UI, the plugin rolls back to the APK's built-in version on the next cold start and prevents the same bad patch from being loaded again.

Production deployments should still combine this with server-side monitoring and staged rollouts.
For the full mechanism, see [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html).

---

## Self-hosting

`flutter_patcher` is not coupled to any particular backend. You can use your own server, CDN, or object storage to distribute patches.

The client only needs a `PatchInfo`; pass it to `applyPatch`.

---

### Check-update protocol (optional)

> The plugin ships a minimal, optional check-update JSON protocol, intended for quick onboarding, the example, and local testing. In production, if you already have your own update / staging / auth protocol, parse the response yourself and build a `PatchInfo` directly — you don't need to follow the format below. What follows is a reference implementation of the minimal protocol.

The client polls the server for new patches.

Sample request:

```http
GET /api/patch/check?app_version_code=100&abi=arm64-v8a&current_patch=1.0.0-h1
```

Recommended parameters:

| Parameter | Description |
| --- | --- |
| `app_version_code` | The current APK's `versionCode`. |
| `abi` | Current device ABI, e.g. `arm64-v8a`. |
| `current_patch` | Currently applied patch version; can be empty when no patch is installed. |

When no patch is available:

```json
{
  "has_update": false
}
```

When a patch is available:

```json
{
  "has_update": true,
  "version": "1.0.0-h2",
  "patch_url": "https://cdn.example.com/patches/arm64-v8a/libapp.so",
  "md5": "0123456789abcdef0123456789abcdef",
  "target_version_code": 100
}
```

If signature verification is enabled, also include `signature`:

```json
{
  "has_update": true,
  "version": "1.0.0-h2",
  "patch_url": "https://cdn.example.com/patches/arm64-v8a/libapp.so",
  "md5": "0123456789abcdef0123456789abcdef",
  "target_version_code": 100,
  "signature": "BASE64_SIGNATURE"
}
```

---

### Hosting the patch file

Any HTTP `GET`-able location works.

Common choices:

- A CDN
- Object storage
- An nginx static directory
- Your own file server

Use HTTPS, and make sure the server returns the correct content and a sensible cache policy.

---

### ABI routing

`libapp.so` is not portable across ABIs.

The server must distribute the right binary per ABI:

```text
patches/
├── arm64-v8a/
│   └── libapp.so
├── armeabi-v7a/
│   └── libapp.so
└── x86_64/
    └── libapp.so
```

The client can read the current device ABI:

```dart
final abi = await FlutterPatcher.deviceAbi;
```

Pass it in the check-update request and have the server return the matching URL.

---

### Patch signing

`flutter_patcher` supports Ed25519 signature verification.

Signing provides extra integrity protection beyond HTTPS, in case the CDN or an intermediate hop ever returns a tampered file.

The basic workflow:

1. The client configures the public key in `FlutterPatcher.init()`.
2. The server holds the private key.
3. For every release with signature verification enabled, the server signs the patch MD5.
4. The client verifies MD5 first, then the signature. If `md5` is omitted, both checks are skipped by design.

Configure the public key:

```dart
await FlutterPatcher.init(
  publicKeyBase64: 'MCowBQYDK2VwAyEA...',
);
```

Generate a key pair:

```bash
openssl genpkey -algorithm ed25519 -out patch_sk.pem
openssl pkey -in patch_sk.pem -pubout -outform DER | base64 -w0
```

Where:

- `patch_sk.pem` is the private key — keep it on the server or build environment only
- The Base64 string from the second command is the public key — embed that in the client

Sign the patch MD5:

```bash
printf "%s" "0123456789abcdef0123456789abcdef" | \
  openssl pkeyutl -sign -inkey patch_sk.pem -rawin | base64 -w0
```

Put the resulting signature in the `signature` field of the check-update response.

---

### strictSignature

`strictSignature` defaults to `true`.

On Android API < 33 (no JDK Ed25519), if the device receives a signed patch, the plugin **rejects** it instead of silently skipping verification. On API ≥ 33 the flag has no effect — native verification always runs.

This avoids the false sense of security where "we configured signing but some devices don't actually verify".

```dart
await FlutterPatcher.init(
  publicKeyBase64: 'MCowBQYDK2VwAyEA...',
  strictSignature: true,
);
```

If you explicitly accept that older devices fall back to MD5 + HTTPS only, set:

```dart
await FlutterPatcher.init(
  publicKeyBase64: 'MCowBQYDK2VwAyEA...',
  strictSignature: false,
);
```

#### Skipping MD5 entirely (optional)

If your server protocol does not ship `md5` (relying on HTTPS for integrity), leave `PatchInfo.md5` empty:

```dart
PatchInfo(version: 'fix-1', patchUrl: 'https://...', targetVersionCode: 100);
```

In that case **both download integrity and signature verification are skipped** (the Ed25519 input is the md5 hex string — without md5 there is no message to sign over). To keep signature verification, you must ship md5. The native side still computes the actual md5 after download and writes it to `meta.effectiveMd5`, so runtime checks (boot validation and the blacklist) keep a stable key.

---

### Recommended backend practices

#### 1. Stage the rollout

A typical ramp:

```text
1% → 5% → 20% → 50% → 100%
```

Watch the crash rate, boot-failure rate, and key business metrics before continuing each step.

#### 2. Wire crash reporting to the SDK

The client should report the abnormal `lastBootDiagnostic` states.
What each auto-rollback / circuit-breaker event means is documented in [Crash protection](https://pub.dev/documentation/flutter_patcher/latest/topics/Crash-protection-topic.html).

If the same patch causes multiple rollbacks in a short window, the server should automatically stop delivering it.

#### 3. Emergency rollback

Emergency rollback does **not** require deleting any local file.
As long as the server stops returning the patch from the check-update endpoint, new users will not download it, and devices that already tripped crash protection will roll back locally and refuse to load the same problematic patch again.

#### 4. Keep release records

The server should record per patch:

- Patch version
- Target APK `versionCode`
- ABI
- MD5, if shipped
- Signature, if shipped
- Release time
- Rollout percentage
- Current state: ramping, full, rolled back

This makes incident triage much easier.

---

### Local mock server

The repository ships `example/tools/mock_server.dart` for local end-to-end testing.

It depends on the `crypto` `dev_dependency` declared in `example/pubspec.yaml`, so it must be run inside the `example/` workspace (`cd example && flutter pub get` first). It is never bundled into a release APK and should never be used in production.

A typical workflow is to validate the full flow against the mock server, then plug your own backend in.

---

## Advanced configuration

Most projects don't need anything in this section.
Read on only when your project has an unusual startup, you want to optimize patch size, or you hit a Flutter version compatibility issue.

---

### Manual Android initialization

By default the plugin uses Android's auto-init mechanism to install the patch loader as early as possible.

If your app preheats `FlutterEngine` inside `Application.attachBaseContext`, auto-init may run *after* the engine has been created, which is too late for the patch to take effect. In that case, disable auto-init and call the entry point manually.

Remove the auto-init provider from `AndroidManifest.xml`:

```xml
<provider
    android:name="com.flutter_patcher.flutter_patcher.FlutterPatcherAutoInitProvider"
    android:authorities="${applicationId}.flutter_patcher.autoinit"
    tools:node="remove" />
```

Initialize manually inside your custom `Application`:

```kotlin
class MyApp : FlutterApplication() {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        FlutterPatcherApplication.attachPatcher(base)
    }
}
```

Only do this when you know the project creates a `FlutterEngine` ahead of time.

---

### Flutter compatibility

`flutter_patcher` needs to influence Flutter Engine's loader during early Android startup.

The current `pubspec` allows Flutter `>=3.3.0`; the loader hook is verified on Flutter `3.19 ~ 3.38`. If a future Flutter release changes the loader internals, you may temporarily override the field name without upgrading the plugin:

```dart
await FlutterPatcher.init(
  loaderFieldCandidates: ['newFieldName', 'flutterLoader'],
);
```

After upgrading Flutter, check the `FlutterPatcher/Hook` tag in logcat to confirm injection succeeded.

---

## Limitations

### Android only

`flutter_patcher` only supports Android.

iOS does not allow shipping executable code dynamically. On Web, macOS, Windows and Linux every API is a no-op — patch logic never runs.

---

### APK or Flutter Engine upgrades invalidate old patches

Patches are tightly bound to the host APK `versionCode`.
After an APK upgrade, old patches are dropped automatically.

If you upgrade the Flutter Engine, Flutter SDK, or build configuration, regenerate the patch — do not reuse one built for an older toolchain.

---

### Reliance on Flutter internals

The plugin reaches into Flutter's Android embedding to influence how `libapp.so` is loaded during early startup.

When Flutter overhauls its loader architecture in a major release, the plugin may need to adapt.
After upgrading Flutter, validate on a real device that patches still load, roll back, and report diagnostics correctly.

---

### App-store policies and compliance

Dynamic delivery of executable code may be restricted in some app stores or business categories.

Before integrating, evaluate the policies that apply to:

- Apps targeting minors
- Highly regulated verticals such as finance, healthcare, and government
- App stores that explicitly restrict dynamic code updates

`flutter_patcher` provides the technical capability — it doesn't substitute for your own compliance review.
