# flutter_patcher example

The smallest end-to-end asset-replacement demo. The screen renders
`Image.asset('assets/patch_demo.png')`; the bundled patch swaps the image
under the same asset key on the next cold start.

## Run

```bash
flutter build apk --debug
flutter install
```

Tap **Apply patch** → force-stop → reopen → image changes.
Tap **Rollback** → cold-start → image reverts to the APK version.

For payload layout, `manifest_patch.json` schema, and pack CLI flags, see
[API Reference → Asset Patching](../doc/api-reference.md#asset-patching).
The bundled `assets/asset_patch_preload.zip` was produced by the same flow.

## Mock server flow

For a real over-HTTP flow, build a patched APK and pack it, then run the
mock server:

```bash
dart run flutter_patcher:pack \
  --apk path/to/patched-app-release.apk \
  --version dev-asset-1 \
  --target-version-code 1 \
  --assets assets/patch_demo.png

dart run flutter_patcher:mock_server --dist dist
```

The mock server reads `dist/manifest.json` and serves the payload named by
`manifest.payload`, exposing `GET /check` plus the payload URL.
