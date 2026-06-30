# Compatibility matrix

What flutter_patcher supports, and the known edges. "Covered" means exercised by the
plugin's logic and (where noted) verified on a device/emulator.

## Platforms

| | Supported | Notes |
|---|---|---|
| Android | ✅ | The only target. `minSdk` 24 (Android 7.0). |
| iOS | ❌ | Out of scope by design — see [ios-out-of-scope.md](ios-out-of-scope.md). |
| Desktop / web | ❌ | No `libapp.so` swap model applies. |

## Android API levels

| API | Code-push (load patched libapp.so) | Crash detection |
|---|---|---|
| 24–25 | ✅ | first-frame token + Dart error hook (within watchdog window) |
| 26–29 | ✅ | first-frame token + Dart error hook (within watchdog window) |
| 30+ | ✅ | full: `ApplicationExitInfo` classifies the previous death — native crash / ANR / init failure, **including after first frame** |

Crash-detection tail: on **API < 30**, a *native* crash or ANR that happens **after** the
watchdog window closes is not attributed to the patch (there's no `ApplicationExitInfo`).
Dart exceptions during the window are caught on all API levels. Use the kill switch as the
backstop for the pre-30 tail.

## ABIs

| ABI | Supported |
|---|---|
| arm64-v8a | ✅ |
| armeabi-v7a | ✅ |
| x86_64 | ✅ (emulators / Chromebooks) |
| x86 | packs if present; rarely shipped |

`pack` bundles every ABI found in the APK into one `patch.zip` (or a `--abi a,b` subset);
the device selects its own ABI at install time. Per-ABI base fingerprints are recorded
when `--base-apk` is given.

## What a patch can and cannot change

| Change | Supported |
|---|---|
| Dart code (business logic, UI) | ✅ — it's the AOT snapshot |
| Flutter assets (overlay) | ✅ since 0.1.3 |
| Native code (your own `.so`, plugins' native) | ❌ |
| Flutter **engine** version (libflutter.so) | ❌ — bind with `--base-apk`; ship via the store |
| `AndroidManifest`, permissions, app icon, versionCode | ❌ — store release only |

## Signing / verification

- Signature scheme: **Ed25519** (RFC 8032), verified on-device via BouncyCastle's
  lightweight API (works on every supported API level, independent of platform JCA
  providers).
- Signed/integrity hash: **SHA-256**. (Inner asset/lib entry hashes are MD5 — those are
  corruption checks of data already inside the SHA-256-signed zip, not security values.)
- Public key format accepted by `init`: raw 32-byte or X.509 SubjectPublicKeyInfo
  (44-byte) base64. `keygen` emits the X.509 form.
- Manifest versions: `flutter_patcher.manifest.v1` (version+patchNumber+targetVersionCode
  +sha256) and `v2` (adds rolloutPercent+channel). The device accepts both.

## Update-check protocol fields (`/check` response → `patch`)

| Field | Required | Meaning |
|---|---|---|
| `version` | yes | patch id, e.g. `1.0.1-h1` |
| `patchUrl` | yes | payload URL (https unless `requireHttps:false`) |
| `sha256` | for signed | SHA-256 of the payload |
| `signature` | for signed | Ed25519 over the canonical manifest |
| `patchNumber` | for signed | monotonic; downgrade protection |
| `targetVersionCode` | for signed | host APK versionCode the patch targets |
| `rolloutPercent` / `channel` | optional | staged rollout (v2 manifest) |

Top-level `rolledBack[]` + `rolledBackSignature` drive the kill switch.
