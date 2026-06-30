import { timingSafeEqual } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import express from 'express';
import multer from 'multer';

import { evaluateHalt } from './autohalt.js';
import { Signer } from './signing.js';
import { PATCH_DIR, Store, sha256OfFile } from './store.js';
import type { HaltEvent } from './store.js';
import { dashboardHtml } from './dashboard.js';

const PORT = Number(process.env.PORT || 8090);
const SEED = process.env.FP_SIGNING_SEED;
if (!SEED) {
  console.error('error: set FP_SIGNING_SEED (run `npm run keygen` to make one).');
  process.exit(1);
}

const signer = new Signer(SEED);
const store = new Store();
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 200 * 1024 * 1024 } });

// In-memory telemetry ring (devices POST onEvent here if wired).
const telemetry: { at: number; event: any }[] = [];

// Last time auto-halt froze a rollout (in-memory; informational for the dashboard).
let lastHalt: HaltEvent | null = null;

// Watch the live patch's recent failure rate; freeze the rollout if it goes bad.
// Runs on every applyFinished telemetry event. Operates on the in-memory ring,
// so it resets with the process — fine for a reference server.
function evaluateAutoHalt(): void {
  const cfg = store.config;
  const active = store.activePatch();
  const d = evaluateHalt(
    cfg.autoHalt,
    cfg.rolloutPercent,
    active?.patchNumber ?? null,
    telemetry,
    Date.now(),
  );
  if (!d.halt || !active) return;

  store.setConfig({ rolloutPercent: 0 });
  lastHalt = { at: Date.now(), version: active.version, patchNumber: active.patchNumber, ok: d.ok, fail: d.fail, rate: d.rate };
  console.warn(
    `[auto-halt] froze rollout of ${active.version} #${active.patchNumber}: ` +
      `${d.fail}/${d.ok + d.fail} applies failed (${Math.round(d.rate * 100)}%)`,
  );
}

function clampInt(v: unknown, lo: number, hi: number, fallback: number): number {
  const n = Math.floor(Number(v));
  return Number.isFinite(n) ? Math.max(lo, Math.min(hi, n)) : fallback;
}

// Optional admin token. When set, it gates the dashboard/admin endpoints
// (device-facing /check, /payload, /api/telemetry stay open). When unset the
// admin surface is open — fine for local/dev, NOT for a public deployment.
const ADMIN_TOKEN = process.env.FP_ADMIN_TOKEN || '';

function safeEq(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

function requireAdmin(req: express.Request, res: express.Response, next: express.NextFunction): void {
  if (!ADMIN_TOKEN) return next();
  const auth = req.get('authorization') || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : req.get('x-admin-token') || '';
  if (token && safeEq(token, ADMIN_TOKEN)) return next();
  res.status(401).json({ error: 'admin token required' });
}

const app = express();
// Behind a TLS-terminating proxy (Railway/Fly/Heroku/nginx), honor
// X-Forwarded-Proto so req.protocol is 'https' and patchUrl is built as https.
app.set('trust proxy', true);
app.use(express.json());

// Lets the dashboard know whether to show a login prompt (no secret leaked).
app.get('/api/meta', (_req, res) => res.json({ authRequired: !!ADMIN_TOKEN }));

// Health check (for Railway / load balancers).
app.get('/health', (_req, res) => res.json({ ok: true }));

function baseUrl(req: express.Request): string {
  return process.env.PUBLIC_URL || `${req.protocol}://${req.get('host')}`;
}

// ---- Device-facing endpoints -------------------------------------------------

// The OTA check. Signs a v2 manifest for the active patch with the current
// rollout/channel, and a signed kill list. The device enforces the rest.
app.get('/check', (req, res) => {
  // The signed response is deterministic for a given config, so Express's ETag
  // + this header let CDNs/clients revalidate cheaply (304) without serving a
  // stale rollout. Cuts bandwidth when nothing changed between launches.
  res.set('Cache-Control', 'no-cache');
  const cfg = store.config;
  const killed = cfg.killed;
  const rolledBackSignature = killed.length ? signer.signRollback(killed) : '';

  const active = store.activePatch();
  // Don't offer a killed patch; still send the kill list so devices remove it.
  if (!active || killed.includes(active.patchNumber)) {
    return res.json({ hasUpdate: false, rolledBack: killed, rolledBackSignature });
  }

  const signature = signer.signManifestV2({
    version: active.version,
    patchNumber: active.patchNumber,
    targetVersionCode: active.targetVersionCode,
    sha256: active.sha256,
    rolloutPercent: cfg.rolloutPercent,
    channel: cfg.channel,
  });

  res.json({
    hasUpdate: true,
    patch: {
      version: active.version,
      patchNumber: active.patchNumber,
      targetVersionCode: active.targetVersionCode,
      sha256: active.sha256,
      signature,
      rolloutPercent: cfg.rolloutPercent,
      channel: cfg.channel,
      patchUrl: `${baseUrl(req)}/payload/${encodeURIComponent(active.version)}`,
    },
    rolledBack: killed,
    rolledBackSignature,
  });
});

app.get('/payload/:version', (req, res) => {
  const rec = store.patch(req.params.version);
  if (!rec || !existsSync(rec.file)) return res.status(404).send('not found');
  // sendFile already supports Range (resumable downloads) + ETag/Last-Modified
  // (conditional GET). Add a cache window so a CDN/proxy can offload repeat
  // downloads; the device still integrity-checks every payload against the
  // freshly-signed sha256 from /check, so a stale edge copy can't be applied.
  res.type('application/octet-stream');
  res.sendFile(rec.file, { maxAge: '1h', lastModified: true, acceptRanges: true });
});

// Optional telemetry sink the app's onEvent can POST to.
app.post('/api/telemetry', (req, res) => {
  telemetry.unshift({ at: Date.now(), event: req.body });
  if (telemetry.length > 200) telemetry.length = 200;
  evaluateAutoHalt();
  res.json({ ok: true });
});

// ---- Admin / dashboard endpoints --------------------------------------------

app.get('/api/state', requireAdmin, (_req, res) => {
  res.json({
    ...store.state(),
    publicKey: signer.publicKeySpkiBase64,
    telemetry: telemetry.slice(0, 50),
    lastHalt,
  });
});

// Upload a packed dist: patch.zip + manifest.json (from `flutter_patcher:pack`).
app.post(
  '/api/patches',
  requireAdmin,
  upload.fields([
    { name: 'patchzip', maxCount: 1 },
    { name: 'manifest', maxCount: 1 },
  ]),
  async (req, res) => {
    const files = req.files as Record<string, Express.Multer.File[]> | undefined;
    const zip = files?.patchzip?.[0];
    const manifestFile = files?.manifest?.[0];
    if (!zip || !manifestFile) {
      return res.status(400).json({ error: 'need patchzip + manifest files' });
    }
    let manifest: any;
    try {
      manifest = JSON.parse(manifestFile.buffer.toString('utf8'));
    } catch {
      return res.status(400).json({ error: 'manifest.json is not valid JSON' });
    }
    const version = String(manifest.version || '');
    const patchNumber = Number(manifest.patchNumber);
    const targetVersionCode = Number(manifest.targetVersionCode);
    const isNonNegInt = (n: number) => Number.isInteger(n) && n >= 0;
    if (!version) {
      return res.status(400).json({ error: 'manifest needs a version' });
    }
    if (version.length > 256) {
      return res.status(400).json({ error: 'version is too long (max 256 chars)' });
    }
    if (!isNonNegInt(patchNumber) || !isNonNegInt(targetVersionCode)) {
      return res.status(400).json({
        error: 'patchNumber and targetVersionCode must be non-negative integers',
      });
    }
    // Sanitized name must not collapse to empty (e.g. a version of only "/../").
    const safeName = version.replace(/[^A-Za-z0-9._-]/g, '_');
    if (!safeName.replace(/[._-]/g, '')) {
      return res.status(400).json({ error: 'version has no usable filename characters' });
    }
    const abis = Array.isArray(manifest.abis)
      ? manifest.abis.filter((a: unknown): a is string => typeof a === 'string')
      : [];
    const dir = join(PATCH_DIR, safeName);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const file = join(dir, 'patch.zip');
    await writeFile(file, zip.buffer);
    const rec = {
      version,
      patchNumber,
      targetVersionCode,
      sha256: sha256OfFile(file),
      abis,
      file,
      uploadedAt: Date.now(),
    };
    store.upsertPatch(rec);
    res.json({ ok: true, patch: rec });
  },
);

app.post('/api/config', requireAdmin, (req, res) => {
  const { activeVersion, rolloutPercent, channel, autoHalt } = req.body ?? {};
  const patch: Record<string, unknown> = {};
  if (activeVersion !== undefined) patch.activeVersion = activeVersion;
  if (rolloutPercent !== undefined) {
    patch.rolloutPercent = Math.max(0, Math.min(100, Number(rolloutPercent)));
  }
  if (channel !== undefined) patch.channel = String(channel);
  if (autoHalt !== undefined && autoHalt !== null) {
    const cur = store.config.autoHalt;
    const rate = Number(autoHalt.failureRate);
    patch.autoHalt = {
      enabled: typeof autoHalt.enabled === 'boolean' ? autoHalt.enabled : cur.enabled,
      windowMinutes: clampInt(autoHalt.windowMinutes, 1, 1440, cur.windowMinutes),
      minSamples: clampInt(autoHalt.minSamples, 1, 100000, cur.minSamples),
      minFailures: clampInt(autoHalt.minFailures, 1, 100000, cur.minFailures),
      failureRate: Number.isFinite(rate) ? Math.max(0, Math.min(1, rate)) : cur.failureRate,
    };
  }
  store.setConfig(patch);
  res.json({ ok: true, config: store.config });
});

app.post('/api/kill', requireAdmin, (req, res) => {
  const killed = Array.isArray(req.body?.killed)
    ? req.body.killed.map((n: unknown) => Number(n)).filter(Number.isFinite)
    : [];
  store.setConfig({ killed });
  res.json({ ok: true, config: store.config });
});

// Preview the signed manifest a device would receive for ANY stored patch
// (not just the active one) — powers the dashboard's per-patch detail drawer.
app.get('/api/patches/:version/preview', requireAdmin, (req, res) => {
  const rec = store.patch(req.params.version);
  if (!rec) return res.status(404).json({ error: 'unknown version' });
  const cfg = store.config;
  const killed = cfg.killed.includes(rec.patchNumber);
  const signature = signer.signManifestV2({
    version: rec.version,
    patchNumber: rec.patchNumber,
    targetVersionCode: rec.targetVersionCode,
    sha256: rec.sha256,
    rolloutPercent: cfg.rolloutPercent,
    channel: cfg.channel,
  });
  res.json({
    version: rec.version,
    patchNumber: rec.patchNumber,
    targetVersionCode: rec.targetVersionCode,
    sha256: rec.sha256,
    abis: rec.abis,
    uploadedAt: rec.uploadedAt,
    active: cfg.activeVersion === rec.version,
    killed,
    signedManifest: {
      version: rec.version,
      patchNumber: rec.patchNumber,
      targetVersionCode: rec.targetVersionCode,
      sha256: rec.sha256,
      rolloutPercent: cfg.rolloutPercent,
      channel: cfg.channel,
      signature,
      patchUrl: `${baseUrl(req)}/payload/${encodeURIComponent(rec.version)}`,
    },
  });
});

app.get('/', (_req, res) => res.type('html').send(dashboardHtml()));

app.listen(PORT, () => {
  console.log(`flutter_patcher server on http://localhost:${PORT}`);
  console.log(`  dashboard:   http://localhost:${PORT}/`);
  console.log(`  device check: http://localhost:${PORT}/check`);
  console.log(`  public key:  ${signer.publicKeySpkiBase64}`);
  console.log(
    ADMIN_TOKEN
      ? '  admin auth:  ON (dashboard requires FP_ADMIN_TOKEN)'
      : '  admin auth:  OFF — set FP_ADMIN_TOKEN to lock down the dashboard for a public deploy',
  );
});
