import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import express from 'express';
import multer from 'multer';

import { Signer } from './signing.js';
import { PATCH_DIR, Store, sha256OfFile } from './store.js';
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
const telemetry: unknown[] = [];

const app = express();
app.use(express.json());

function baseUrl(req: express.Request): string {
  return process.env.PUBLIC_URL || `${req.protocol}://${req.get('host')}`;
}

// ---- Device-facing endpoints -------------------------------------------------

// The OTA check. Signs a v2 manifest for the active patch with the current
// rollout/channel, and a signed kill list. The device enforces the rest.
app.get('/check', (req, res) => {
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
  res.type('application/octet-stream').sendFile(rec.file);
});

// Optional telemetry sink the app's onEvent can POST to.
app.post('/api/telemetry', (req, res) => {
  telemetry.unshift({ at: Date.now(), event: req.body });
  if (telemetry.length > 200) telemetry.length = 200;
  res.json({ ok: true });
});

// ---- Admin / dashboard endpoints --------------------------------------------

app.get('/api/state', (_req, res) => {
  res.json({
    ...store.state(),
    publicKey: signer.publicKeySpkiBase64,
    telemetry: telemetry.slice(0, 50),
  });
});

// Upload a packed dist: patch.zip + manifest.json (from `flutter_patcher:pack`).
app.post(
  '/api/patches',
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
    if (!version || !Number.isFinite(patchNumber) || !Number.isFinite(targetVersionCode)) {
      return res
        .status(400)
        .json({ error: 'manifest needs version, patchNumber, targetVersionCode' });
    }
    const dir = join(PATCH_DIR, version.replace(/[^A-Za-z0-9._-]/g, '_'));
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const file = join(dir, 'patch.zip');
    await writeFile(file, zip.buffer);
    const rec = {
      version,
      patchNumber,
      targetVersionCode,
      sha256: sha256OfFile(file),
      abis: Array.isArray(manifest.abis) ? manifest.abis : [],
      file,
      uploadedAt: Date.now(),
    };
    store.upsertPatch(rec);
    res.json({ ok: true, patch: rec });
  },
);

app.post('/api/config', (req, res) => {
  const { activeVersion, rolloutPercent, channel } = req.body ?? {};
  const patch: Record<string, unknown> = {};
  if (activeVersion !== undefined) patch.activeVersion = activeVersion;
  if (rolloutPercent !== undefined) {
    patch.rolloutPercent = Math.max(0, Math.min(100, Number(rolloutPercent)));
  }
  if (channel !== undefined) patch.channel = String(channel);
  store.setConfig(patch);
  res.json({ ok: true, config: store.config });
});

app.post('/api/kill', (req, res) => {
  const killed = Array.isArray(req.body?.killed)
    ? req.body.killed.map((n: unknown) => Number(n)).filter(Number.isFinite)
    : [];
  store.setConfig({ killed });
  res.json({ ok: true, config: store.config });
});

app.get('/', (_req, res) => res.type('html').send(dashboardHtml()));

app.listen(PORT, () => {
  console.log(`flutter_patcher server on http://localhost:${PORT}`);
  console.log(`  dashboard:   http://localhost:${PORT}/`);
  console.log(`  device check: http://localhost:${PORT}/check`);
  console.log(`  public key:  ${signer.publicKeySpkiBase64}`);
});
