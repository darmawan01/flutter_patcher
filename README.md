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
- Ed25519-signed, SHA-256 manifests with downgrade protection and a signed kill switch
- HTTPS-required downloads with optional cert pinning; multi-key rotation
- Crash-loop circuit breaker, base-binary drift guard, multi-ABI packaging
- Staged percentage rollouts + channels; `checkAndStage` safe-default flow
- Signing CLI (`keygen` / `pack --key` / `doctor`), diagnostics, mock server, sample app
- Self-hosted reference server + control-room dashboard (rollout %, channels, kill switch, telemetry)

---

## Feature Demo

![Feature demo: apply a patch, cold restart, and rollback](doc/feature-presentation.gif)

---

## Quickstart

```bash
# 1. Stand up the server (locally, Railway, Fly, a VM) — see server/README.md
cd server && npm install && npm run keygen
FP_SIGNING_SEED=<seed> npm start          # dashboard at http://localhost:8090/

# 2. Wire up your app
dart run flutter_patcher:init --server <url> --public-key <key>
#    → call await setupPatcher(); in main(), before runApp()

# 3. Make a Dart change, then ship a patch in one step (pack + upload + make-live)
flutter build apk --release
dart run flutter_patcher:release \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --server <url> --token $FP_ADMIN_TOKEN \
  --version 1.0.1-h1 --target-version-code <vc> --patch-number 1 \
  --rollout 10 --make-live
#    (or `:pack` to only build dist/, then drag it into the dashboard)

# 4. See what the server is serving
dart run flutter_patcher:status --server <url>
```

Full walkthrough: **[docs/getting-started.md](docs/getting-started.md)**.

---

## Documentation

The full docs live in [`docs/`](docs/) and render as a site (docsify — GitHub
Pages → source `/docs`, or `npx docsify-cli serve docs`):

- **[Getting started](docs/getting-started.md)** — zero → your first patch
- **[Shipping from CI](docs/ci.md)** — release patches from GitHub Actions / any runner
- **[Compatibility](docs/compatibility.md)** — API levels, ABIs, what a patch can change
- **[Security hardening](docs/security-hardening.md)** — threat model + every knob
- **[iOS — out of scope](docs/ios-out-of-scope.md)**
- **[Reference server + dashboard](server/README.md)** — self-hosted endpoint + control room

CLI: `dart run flutter_patcher:<init|pack|release|status|keygen|doctor|mock_server> --help`.
中文：[README-zh.md](README-zh.md).

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
