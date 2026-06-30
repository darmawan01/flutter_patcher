# Wire protocol

This is the **contract** between a flutter_patcher device SDK and a patch server.
Anything that speaks it works together — the open-source SDK, the reference
server, a private dashboard, or a future SDK for another runtime (React Native).

> **Versioning.** The protocol is versioned by the **canonical manifest string**
> (`...v1`, `...v2`, …). A server may serve older manifest versions to older
> clients. Endpoints are additive; clients ignore unknown JSON fields.

## Roles

- **SDK (device):** calls `/check`, verifies signatures, downloads + verifies the
  payload, applies it on the next cold start, enforces the kill switch.
- **Server:** holds patches, signs manifests on the fly with its private key,
  serves payloads, accepts telemetry. Framework-agnostic — it signs metadata and
  serves bytes; it does not parse the payload.
- **Trust anchor:** the server's **Ed25519 public key** (X.509 SPKI, base64) is
  compiled into the app. The device applies only what that key (or one of a
  configured set, for rotation) signed.

## Endpoints

### `GET /check`

Query params (all optional): `channel` (default channel when absent), and —
reserved for multi-app — `app`.

Caching: response is `Cache-Control: no-cache`; servers SHOULD send a (weak) ETag
so clients can revalidate (304). The signed body is deterministic for a given
config.

**Response — update available:**

```json
{
  "hasUpdate": true,
  "patch": {
    "version": "1.0.1-h1",
    "patchNumber": 7,
    "targetVersionCode": 42,
    "sha256": "<lowercase hex of the payload>",
    "signature": "<base64 Ed25519 over the canonical manifest>",
    "rolloutPercent": 10,
    "channel": "",
    "patchUrl": "https://server/payload/1.0.1-h1"
  },
  "rolledBack": [],
  "rolledBackSignature": ""
}
```

**Response — no update (or the active patch is killed):**

```json
{ "hasUpdate": false, "rolledBack": [99], "rolledBackSignature": "<base64 or ''>" }
```

`rolledBack` is the signed kill list (see [Kill switch](#kill-switch)); it is sent
on **every** response, including `hasUpdate:false`, so a device always learns it
must revert.

### `GET /payload/:version`

Returns the patch payload as `application/octet-stream`. MUST support HTTP **Range**
(resumable downloads) and SHOULD send `ETag`/`Last-Modified` + a `Cache-Control`
window (payloads are integrity-checked against the signed `sha256`, so an edge
cache can't poison them).

### `POST /api/telemetry`

Optional sink for [telemetry events](#telemetry). Body is a single event object.
Public (no auth). Servers MAY ignore it.

### `POST /api/feedback` *(reserved)*

Future per-patch user-feedback sink (see issue #10). Same shape conventions.

## Signing

Ed25519 (RFC 8032). The public key is X.509 **SPKI** DER, base64 (44 bytes
decoded: a 12-byte Ed25519 prefix + the 32-byte key). A raw 32-byte key is also
accepted.

The signature in `/check.patch.signature` is over a **canonical manifest string**,
built **exactly** as below (LF newlines, `sha256` lowercased, no trailing newline):

**v1** — no rollout configured:

```
flutter_patcher.manifest.v1
version=<version>
patchNumber=<patchNumber>
targetVersionCode=<targetVersionCode>
sha256=<lowercase hex>
```

**v2** — binds the staged-rollout fields (used when a rollout/channel is set):

```
flutter_patcher.manifest.v2
version=<version>
patchNumber=<patchNumber>
targetVersionCode=<targetVersionCode>
sha256=<lowercase hex>
rolloutPercent=<0..100>
channel=<channel string, may be empty>
```

These strings are byte-identical across the Kotlin verifier, the Dart CLI, and the
Node server — a new server/SDK MUST reproduce them exactly.

### Kill switch

`rolledBack` is a list of `patchNumber`s the server has revoked. It is signed
separately so a device can trust it even with `hasUpdate:false`:

```
flutter_patcher.rollback.v1
patchNumbers=<ascending, de-duplicated, comma-separated>
```

`rolledBackSignature` is the base64 Ed25519 signature over that string (empty when
the list is empty). On receipt, if the device's **installed** `patchNumber` is in
the (signature-verified) list, it deletes the patch + blacklists it and reverts to
the built-in build on the next cold start.

## Device algorithm

On `checkAndStage(url)` (or your own check):

1. `GET /check`. Verify+apply the **kill list** first (always).
2. If `hasUpdate:false` → done.
3. **Rollout gate:** compute `bucket = crc32("<installId>:<patchNumber>") % 100`
   (CRC-32 over UTF-8). Apply only if `bucket < rolloutPercent`. `installId` is a
   stable random per-install id (also used to tag telemetry). The bucket is patch-
   stable, so widening 10%→50% is a superset (no churn).
4. **Downgrade protection:** reject `patchNumber <=` the last applied number.
5. Verify the **signature** over the canonical manifest (v2 if `rolloutPercent`
   present, else v1) against the trusted key(s).
6. Download `patchUrl`; verify its **sha256** equals the manifest `sha256`.
7. Stage it. It takes effect on the **next cold start** (never hot-swapped mid-run).

A crash-loop circuit breaker (boot token + watchdog) auto-rolls-back a patch that
crashes on boot, independent of the server.

## Payload format (Flutter)

`patch.zip` (a `GET /payload` body for Flutter) contains an inner `manifest.json`:

```json
{
  "schemaVersion": 2,
  "version": "1.0.1-h1",
  "targetVersionCode": 42,
  "lib": {
    "arm64-v8a": { "path": "lib/arm64-v8a/libapp.so", "md5": "<hex>" },
    "x86_64":    { "path": "lib/x86_64/libapp.so.delta", "format": "delta",
                   "baseSha256": "<hex>", "sha256": "<reconstructed .so sha256>", "size": 1234 }
  },
  "assets": { "mode": "overlay", "...": "optional Flutter asset overlay" }
}
```

- A **full** lib entry ships `libapp.so` (verified by `md5`, plus an optional
  `baseSha256` drift guard).
- A **delta** entry ships `libapp.so.delta` and the device reconstructs the full
  `.so` from the installed base, then verifies the result against `sha256`.

**Binary delta format** — magic `FPD1` (`0x46 0x50 0x44 0x31`), then a stream of
ops using unsigned **LEB128** varints:

```
0x00 COPY:   varint baseOffset, varint length   (copy from the base .so)
0x01 INSERT: varint length, <length> literal bytes
```

The device picks the entry matching its ABI; an RN payload would define its own
inner format (e.g. a JS bundle) under the same outer signing/check rules.

## Telemetry

Events POSTed to `/api/telemetry` (opt-in). One event per request:

```json
{
  "type": "applyFinished",          // boot | applyStarted | applyFinished | staged
  "version": "1.0.1-h1",
  "patchNumber": 7,
  "ok": true,                        // applyFinished only
  "error": "downgradeRejected",      // applyFinished failures only
  "installId": "<stable per-install id>",
  "message": "optional"
}
```

`installId` lets a server count **distinct devices** (not just events). Device
metadata (model/OS/ABI) on events is a planned addition (issue #9).

## Cross-runtime (React Native, future)

The server and everything above the payload are runtime-agnostic. To support
another runtime:

- Add a `runtime` tag (`flutter` | `rn`) — carried in the (multi-app) manifest /
  `appId` — so a server can serve the right payload type.
- Define that runtime's **payload format** (Flutter: `libapp.so` / `patch.zip`;
  RN: a JS bundle) and its **apply** step.
- Reuse `/check`, signing, rollout bucketing, channels, the kill switch, and
  telemetry **unchanged**.
