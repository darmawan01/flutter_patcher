# flutter_patcher reference server + control room

A small self-hostable OTA server and dashboard for `flutter_patcher`. It is the
control plane for the device-side features: it signs the update manifest on the
fly (so you can change rollout % / channel without re-packing), drives the
signed **kill switch**, and collects telemetry.

> Reference implementation — Node + TypeScript, a JSON file store, no database.
> Put it behind HTTPS in production (see ../docs/security-hardening.md).

## Run it

```bash
cd server
npm install
npm run keygen          # prints FP_SIGNING_SEED + the public key for the app
FP_SIGNING_SEED=<seed> npm start
# dashboard:    http://localhost:8090/
# device check: http://localhost:8090/check
```

Paste the printed public key into the app:

```dart
await FlutterPatcher.init(publicKeyBase64: '<public key>');
// drive updates:
await FlutterPatcher.checkAndStage('https://your-host/check');
```

## Workflow

1. Build + pack a patch with the CLI (no `--key` needed — the server signs):
   `dart run flutter_patcher:pack --apk app.apk --version 1.0.1-h1 --target-version-code 42 --patch-number 7 --abi x86_64,arm64-v8a`
   (add `--from-apk <base>` for a delta).
2. In the dashboard, **upload** `dist/patch.zip` + `dist/manifest.json`.
3. Set it **active**, pick a **rollout %** and **channel**.
4. To pull a bad patch: hit **kill** — the device reverts to the built-in build
   on its next check.

## Endpoints

Device-facing:
- `GET /check` — signed manifest for the active patch (honors rollout/channel) + signed kill list.
- `GET /payload/:version` — the patch.zip.
- `POST /api/telemetry` — optional sink for `FlutterPatcher.init(onEvent:)`.

Admin (used by the dashboard):
- `GET /api/state` · `POST /api/patches` (upload) · `POST /api/config` (active/rollout/channel) · `POST /api/kill`.

## Config

- `FP_SIGNING_SEED` (required) — Ed25519 seed; its public key is what the app trusts.
- `PORT` (default 8090) · `FP_DATA_DIR` (default `./data`) · `PUBLIC_URL` (override the payload base URL behind a proxy).

## Not included (intentionally)

Auth on the admin API, TLS, and a database — add these for real deployments.
Rollout **auto-halt** (watching telemetry crash-rate to pause a rollout) is the
obvious next step now that telemetry lands here.
