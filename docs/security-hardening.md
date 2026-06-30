# Security hardening guide

flutter_patcher swaps your app's compiled Dart (`libapp.so`) at cold start. That is
exactly the capability an attacker wants to hijack, so the security of your update
pipeline matters as much as the app itself. This guide covers the threat model and
every knob you should turn on for a production deployment.

## Threat model

The patch travels: your build machine → signing → your server/CDN → the device → disk
→ loaded at next boot. Each hop is a place to defend.

| Threat | Mitigation | Knob |
|---|---|---|
| MITM swaps the payload in transit | HTTPS required; optional SPKI pinning | `requireHttps` (default on), `pinnedSpkiSha256` |
| Forged / unsigned patch | Ed25519 signature over a canonical manifest | `publicKeyBase64` / `publicKeysBase64` |
| Tampered metadata (version, target, sha256) | All bound into the **signed** manifest | automatic when signed |
| Replay of an old, validly-signed patch | Monotonic `patchNumber` downgrade protection | sign with increasing `patchNumber` |
| A leaked signing key | Trust multiple keys, rotate | `publicKeysBase64: [old, new]` |
| A bad patch already on devices | Server-driven, signed kill switch | `rolledBack[]` + signature in the check response |
| Patch that loads then crash-loops | Boot-token + watchdog circuit breaker | `maxCrashCount`, `verifyAfter` |
| Patch applied onto a drifted base binary | Per-ABI base `libapp.so` fingerprint | `pack --base-apk` |
| Collision-weak digest used as the signed value | SHA-256 is the signed/integrity hash | automatic |
| Blast radius of a bad patch | Staged percentage rollout + channels | `pack --rollout-percent / --channel` |
| On-disk tampering at rest | Boot-time integrity (+ signature for legacy) re-check | automatic |

The trust anchor is the **app binary itself** — the public key(s) you pass to `init`
ship via the store (Play), which patches cannot alter. A patch can never change the
set of keys the device trusts.

## Recommended production `init`

```dart
await FlutterPatcher.init(
  // Trust the current signing key; add the next one here before you rotate.
  publicKeysBase64: const [
    'MCowBQYDK2Vw...current...',
    // 'MCowBQYDK2Vw...next...',   // during a rotation window
  ],
  requireHttps: true,                 // default; reject plaintext http payloads
  pinnedSpkiSha256: const [           // optional: pin your server's leaf cert SPKI
    // 'base64-sha256-of-SPKI',
  ],
  maxCrashCount: 1,                   // trip the breaker on the first boot crash
);
```

Then drive updates with the safe default flow:

```dart
final r = await FlutterPatcher.checkAndStage('https://updates.example.com/check');
// r.outcome: upToDate | staged | failed. Staged patches apply on the NEXT cold start.
```

## Signing and key management

- Generate a key: `dart run flutter_patcher:keygen` → keep the seed secret, paste the
  printed X.509 public key into `init`.
- Sign while packing: `dart run flutter_patcher:pack --apk app.apk --version 1.0.1-h1
  --target-version-code 42 --patch-number 7 --key @patch_signing.seed`.
- Validate before shipping: `dart run flutter_patcher:doctor --dist dist --pubkey <b64>`.
- **Rotation:** ship an app release that trusts both the old and new key, switch the
  server to sign with the new key, then drop the old key in a later release. The device
  accepts a patch if *any* trusted key verifies it (any-of-N).
- **Downgrade protection:** always increase `patchNumber`. The device refuses any
  patchNumber at or below the highest it has applied.

## Emergency rollback (kill switch)

To pull a bad patch from the fleet, include a **signed** rollback list in the `/check`
response:

```json
{ "hasUpdate": false,
  "rolledBack": [7],
  "rolledBackSignature": "<Ed25519 over the canonical rollback string>" }
```

On the next check the device verifies the signature, deletes the listed patch (reverting
to the built-in build), and blacklists it so it can't reapply. An unsigned or
wrongly-signed list is ignored, so the lever can't be abused as a denial-of-service.

## Crash protection

The circuit breaker drops a patch that fails to boot. On API 30+ it uses
`ApplicationExitInfo` to classify the previous death (covering native crashes and ANRs
even after first frame); on all API levels a Dart error hook and a boot-success token
cover the first-frame window. The crash counter resets only after the app survives the
`verifyAfter` watchdog window, so a render-then-crash-loop patch accumulates failures and
trips rather than looping forever. Tune `maxCrashCount` (default 1) and `verifyAfter`.

## Residual risks (be honest with yourself)

- **Rooted devices**: an attacker with root can read/modify app-private storage. The
  boot-time signature + integrity checks raise the bar but a fully compromised device is
  out of scope.
- **API < 30 post-window native crashes**: a native crash that happens *after* the
  watchdog window closes isn't caught by the breaker on pre-30 devices (no
  `ApplicationExitInfo`). The kill switch is your remedy. See the compatibility matrix.
- **Engine compatibility**: a patch's `libapp.so` must match the installed Flutter
  engine. Bind it with `pack --base-apk` and never ship a patch built with a different
  Flutter version than the installed app.
