# Why iOS is out of scope

flutter_patcher is Android-only, on purpose. This isn't a missing feature — it's a
platform and policy boundary.

## Technical reasons

- **No runtime code loading.** flutter_patcher works by replacing the Dart AOT artifact
  `libapp.so` on the next cold start. On iOS there is no equivalent swap: iOS forbids
  loading executable code that wasn't signed by Apple and shipped through the App Store.
  `dlopen` of a downloaded binary, JIT, and self-modifying executable pages are
  unavailable to App Store apps.
- **Code signing.** Every executable page on iOS must be covered by Apple's code
  signature. A downloaded `libapp` could never satisfy that, so the OS would refuse to
  map it.
- **Flutter on iOS.** Release Flutter builds compile Dart to a signed `App.framework`.
  Patching it would break the app's signature.

## Policy reasons

- **App Store Review Guideline 2.5.2** prohibits apps that download, install, or execute
  code which changes features or functionality. Even where a technical hack exists, it is
  grounds for rejection or removal.

## What to do instead on iOS

- Ship fixes through the App Store. Use **TestFlight** for fast internal/beta
  distribution and phased releases for production ramp.
- Move changeable behavior server-side (feature flags, remote config, server-rendered
  content) so a fix doesn't require new executable code.
- If you need true code push across both platforms and can accept a hosted dependency,
  Shorebird supports iOS via its own interpreter/linker machinery — a different trade-off
  (not self-hostable).

## Scope summary

flutter_patcher targets **self-controlled Android distribution** (enterprise/MDM,
sideload, or otherwise permissive channels) where you own the update endpoint. For
iOS, and for anything that changes native code, the engine, or the app manifest, ship a
normal store release.
