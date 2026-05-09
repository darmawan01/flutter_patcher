# flutter_patcher example

This example demonstrates the local hot-patch flow without a server.

## Run

```bash
flutter build apk --release
flutter install
```

Open the app, tap **Apply patch**, then cold-start the app again. The bundled
`assets/libapp_preload.so` is installed through `FlutterPatcher.applyPatchBytes`
and takes effect on the next cold start.

Tap **Rollback** and cold-start again to return to the APK-bundled `libapp.so`.

## Mock server

The package includes a formal local mock server CLI for testing
`checkUpdate -> applyPatch` from your own app, without depending on this
example directory:

```bash
dart run flutter_patcher:pack \
  --apk path/to/app-release.apk \
  --version dev-1 \
  --target-version-code 1

dart run flutter_patcher:mock_server --dist dist
```

The mock server reads `dist/libapp.so` and `dist/manifest.json`, then exposes
`GET /check` and `GET /libapp.so` on `0.0.0.0:8080` so a phone on the same
Wi-Fi can access it.
