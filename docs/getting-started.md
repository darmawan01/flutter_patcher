# Getting started — from zero to your first patch

This walks you from nothing to a live Dart hot-patch landing on a device. ~15 min.

> Android only. A patch can change your **Dart code** (and Flutter assets), not native
> code, the Flutter engine, or the app manifest. See [compatibility](compatibility.md).

## 0. The pieces

| Piece | What it is |
|---|---|
| **Plugin** (`flutter_patcher`) | in your app — checks, verifies, stages, and loads patches |
| **CLI** (`pack`, `keygen`, `doctor`, `init`) | build + sign patches on your machine / CI |
| **Server** (`server/`) | self-hosted endpoint + dashboard that signs and serves patches |

## 1. Stand up the server

Run it anywhere (locally, Railway, Fly, a VM). See [deploy](../server/README.md) for
the Railway one-click-ish flow. Quick local version:

```bash
cd server
npm install
npm run keygen          # prints FP_SIGNING_SEED + a PUBLIC KEY
FP_SIGNING_SEED=<seed> npm start
# dashboard: http://localhost:8090/   ·   device check: http://localhost:8090/check
```

Keep two values: the **seed** (server secret) and the **public key** (goes in the app).

## 2. Wire up your app

In an existing Flutter app (or after `flutter create`):

```bash
dart run flutter_patcher:init \
  --server https://your-server.example.com \
  --public-key <PUBLIC_KEY_FROM_STEP_1>
flutter pub get
```

`init` adds the dependency and writes `lib/patcher_bootstrap.dart`. Call it in `main()`:

```dart
import 'patcher_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await setupPatcher();   // check + stage; takes effect on the NEXT cold start
  runApp(const MyApp());
}
```

Then ship this build to your devices (store / MDM / sideload) **as your baseline** —
patches upgrade *from* it.

## 3. Make a change and pack a patch

Edit some Dart, then:

```bash
flutter build apk --release
dart run flutter_patcher:pack \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --version 1.0.1-h1 \
  --target-version-code <your app's versionCode> \
  --patch-number 1
```

This writes `dist/patch.zip` + `dist/manifest.json`. Useful flags:

- `--abi arm64-v8a,armeabi-v7a` — limit ABIs (default: all in the APK).
- `--from-apk <baseline.apk>` — ship a **binary delta** against the baseline (much smaller).
- `--patch-number N` — monotonic; the device refuses anything ≤ the last applied.

Sanity-check it: `dart run flutter_patcher:doctor --dist dist`.

## 4. Upload + make it live

**One command (CI-friendly)** — pack, upload, and activate in one step (replaces
step 3 + this step):

```bash
dart run flutter_patcher:release \
  --apk build/app/outputs/flutter-apk/app-release.apk \
  --server https://your-server.example.com --token $FP_ADMIN_TOKEN \
  --version 1.0.1-h1 --target-version-code <vc> --patch-number 1 \
  --rollout 10 --make-live
```

Then `dart run flutter_patcher:status --server <url>` shows exactly what the server
is serving. Or do it by hand in the dashboard:

Open the dashboard (`/`), drop `dist/patch.zip` + `dist/manifest.json`, then:

- **Make live** the patch,
- set a **rollout %** (start at 10%, watch, then 100%),
- pick a **channel** if you use them.

The server signs the manifest on the fly — no re-packing when you change rollout.

## 5. Land it on the device

Your app calls `setupPatcher()` at launch → it checks the server, verifies the
signature, downloads + stages the patch, and **applies it on the next cold start**.
Force-stop and relaunch to see the change.

## When something's wrong

- **Pull a bad patch:** hit **kill** in the dashboard — devices revert to the
  built-in build on their next check.
- **A patch that crashes on boot** is auto-rolled-back and blacklisted by the device.
- Watch outcomes in the dashboard **telemetry** (wire `onEvent` to POST `/api/telemetry`).

Next: [security hardening](security-hardening.md) · [compatibility](compatibility.md).
