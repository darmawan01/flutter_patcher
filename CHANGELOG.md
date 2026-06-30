> Chinese version: [CHANGELOG-zh.md](CHANGELOG-zh.md)

## 0.2.0

Hardening + self-hosted server/console fork. Verified end-to-end against a live
deployment (apply, staged rollout, kill-switch rollback) on an emulator.

### Security & integrity

- Ed25519 signature verification via BouncyCastle on device, byte-compatible with
  the Dart CLI and Node server (RFC 8032). Fixes the API 33/35 provider issue.
- SHA-256 signed manifests with a TUF-style canonical format (v1/v2) shared across
  all three languages; monotonic `patchNumber` downgrade protection.
- Signed kill switch (server-issued, signature-verified rollback list) that reverts
  a device to its built-in build on the next check.
- Any-of-N trusted keys for rotation; HTTPS-required downloads with optional SPKI
  pinning; strict public-key length checks.

### Resilience

- Crash-loop circuit breaker (boot token + watchdog) that auto-rolls-back and
  blacklists a patch that crashes on boot.
- Base-binary drift guard so a patch won't apply onto a different same-versionCode base.

### Distribution

- Multi-ABI packaging; rsync-style **binary delta** patches (`pack --from-apk`),
  self-verified and sha256-checked on device.
- Staged percentage rollouts (deterministic per-install bucketing) and **channels**
  (stable/beta/staging), each with its own active patch + rollout.

### Observability

- `PatchEvent` telemetry hook with `toJson()` and an opt-in per-install `installId`
  (shared with rollout bucketing) for distinct-device adoption.

### Tooling (CLI)

- `init` now auto-wires `setupPatcher()` into `main()`; `pack`, `keygen`, `doctor`
  (+ `doctor --project` to validate app wiring), and a `mock_server`.
- New `release` (pack + upload + make-live in one command) and `status` (what the
  server is serving). All CLIs exit non-zero on failure.

### Reference server + console (`server/`)

- Self-hosted Node/TypeScript server that signs manifests on the fly and serves
  patches with CDN-friendly caching + range support.
- Embedded control-room dashboard: per-channel rollout, signed kill switch,
  per-patch detail (signed `/check` preview), applies-over-time, distinct-device
  adoption, **rollout auto-halt** (freezes a rollout when the failure rate spikes),
  and optional admin auth (`FP_ADMIN_TOKEN`).

### Tests & CI

- Server test suite (signing, store, auto-halt, endpoint integration) and CI that
  runs the Dart, server, and Android suites on every push.

## 0.1.3

### Added

- Added Android cold-start Flutter asset hot updates. Assets (images,
  fonts, JSON, anything reachable via `Image.asset(...)` or
  `rootBundle.load(...)`) can be patched together with Dart code through
  the same `patch.zip` payload.
- Added `--assets` to `dart run flutter_patcher:pack`. Pass paths inline
  (`--assets a,b`) or read them from a UTF-8 text file with the `@` prefix
  (`--assets @patch-assets.txt`, one path per line, `#` starts a comment);
  inline paths and `@file` references can be mixed in the same flag.
  Each path must already be registered under `assets:` in the new APK's
  `pubspec.yaml`; `--assets` only tells `pack` which of those assets to
  ship inside `patch.zip`. The runtime overlays them on top of the APK's
  Flutter asset bundle at install time.

### Changed

- `dart run flutter_patcher:pack` now always emits `dist/patch.zip` +
  `dist/manifest.json` (outer `schemaVersion: 2`, `payload: patch.zip`),
  whether or not `--assets` is passed. A Dart-only `patch.zip` contains
  just `manifest.json` + `lib/<abi>/libapp.so`; its inner manifest omits
  the `assets` block. The previous bare-`.so` output mode is gone.
- Android runtime detects ZIP payloads, installs overlay asset packages,
  builds a private `flutter_assets.apk`, and starts Flutter through a
  patched `FlutterJNI` AssetManager when assets are present. Dart-only
  `patch.zip` payloads short-circuit the asset overlay pipeline and
  behave like code-only patches at install time.
- `mock_server --dist` reads `manifest.payload` and serves the declared
  file.

### Compatibility

- Bare-`.so` patches produced by 0.1.0–0.1.2 still install on 0.1.3
  devices (the runtime keeps a quiet legacy install path); the producer
  CLI no longer emits that format. Server operators should ship
  `patch.zip` for any new patch built against a 0.1.3+ host APK.

## 0.1.2

### Added

- Added `dart run flutter_patcher:mock_server` for local
  `checkUpdate -> applyPatch` testing without maintaining an example-only
  helper script.

### Changed

- Improved README onboarding with a TL;DR, clearer fit / non-fit guidance,
  store policy warning, and local mock server instructions.
- Updated pub.dev package description and topics for better discoverability.
- Added a GitHub social preview image under `doc/social-preview.png`.

## 0.1.1+1

### Fixed

- Corrected the README install snippet version pin to `^0.1.1`
  (docs-only, no code change).
- Translated CHANGELOG to English so pub.dev's pana check no longer
  flags it for non-ASCII content. Chinese version preserved as
  `CHANGELOG-zh.md`.

## 0.1.1

### Changed

- **`PatchInfo.md5` is now optional.** An empty string means the caller
  explicitly opts out of download integrity verification and relies on
  HTTPS only. When `md5` is empty the Ed25519 signature check is also
  skipped (the signature input is the md5 hex, so no md5 means no
  signature input). `toJson` omits the `md5` key when it is empty.
- **`validatePatchArgs`**: blank `md5` is now accepted; non-blank `md5`
  is still required to be 32 lowercase hex chars.
- **Blacklist**: when the caller does not provide `md5`, the download
  pre-check falls back to version-only matching via the new
  `BlacklistStore.containsByVersion`. Blacklist entries are still
  recorded with the actual md5 computed after download.
- **`meta.json`**: `effectiveMd5` now always stores the md5 computed
  after download (previously it stored the server-declared md5). Boot
  checks and blacklist entries key on this stable hash.
- **Dependency constraints relaxed**: Dart SDK constraint changed from
  `^3.10.7` to `>=3.0.0 <4.0.0`; runtime dependencies switched to a
  lower bound plus an open upper bound; `archive` now supports both
  3.x and 4.x to reduce host-project conflicts.

## 0.1.0

First public release (Android-only beta).

### Core features

- **Cold-start hot updates**: replaces `FlutterLoader.findAppBundlePath`
  via reflection inside `Application.attachBaseContext`, before the
  Dart engine starts, enabling whole-file `libapp.so` replacement.
- **Signature verification**: built-in Ed25519 (X.509 SubjectPublicKey
  Info) plus MD5 dual verification, with `strictSignature` mode that
  prevents downgrade bypass on older devices.
- **Crash circuit breaker / auto rollback**: counts `REASON_CRASH`
  events from `ApplicationExitInfo` and hooks
  `PlatformDispatcher.onError` on the Dart side. Once `maxCrashCount`
  (default 1, fail-fast) is reached, the patch is deleted, added to
  the blacklist, and the host falls back to the bundled APK version.
- **First-frame verify clears the breaker**: after the patch loads,
  the app must stay alive in the foreground for `verifyAfter`
  (default 5s) before being marked verified, which resets the crash
  counter.
- **Local blacklist**: auto-blacklisted patches will never be
  reinstalled, preventing crash loops. Inspect or clear via
  `FlutterPatcher.blacklist` / `clearBlacklist`.
- **Progress event stream**: `FlutterPatcher.applyProgress` exposes
  `downloading` / `verifying` / `finalizing` phase events.
- **CLI packaging tool**: `dart run flutter_patcher:pack` extracts
  `libapp.so` from a release APK and produces the patch manifest.

### Known limitations

- **Android only**. On iOS / Web / desktop, all APIs are no-ops (the
  first call prints a warning).
- **Strict Ed25519 mode requires Android API 33+**. Below API 33 with
  `strictSignature: true` (the default), signed patches are rejected.
- **Only full-mode patches are supported**. Differential patching is
  not shipped in 0.1.0 to avoid exposing an unverified path.
- This initial release shipped the legacy lib-only payload path. Asset
  payloads were added later in 0.1.3.

### Documentation

- Repository README: use cases, 5-minute demo, integration steps.
- `doc/architecture.md`: native + Dart layered architecture and
  startup sequence.
- `doc/api-reference.md`: full API reference.
- `doc/crash-protection.md`: breaker and rollback strategy.
