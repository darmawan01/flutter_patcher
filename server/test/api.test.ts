import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { randomBytes } from 'node:crypto';
import type { Server } from 'node:http';

// store.ts reads FP_DATA_DIR at import — point it at a temp dir first.
process.env.FP_DATA_DIR = mkdtempSync(join(tmpdir(), 'fp-api-'));
const { createApp } = await import('../src/app.js');
const { Store } = await import('../src/store.js');
const { Signer } = await import('../src/signing.js');

const TOKEN = 'test-token';
const signer = new Signer(randomBytes(32).toString('base64'));
const store = new Store();
const app = createApp({ signer, store, adminToken: TOKEN });

let base = '';
let server: Server;
before(async () => {
  server = app.listen(0);
  await once(server, 'listening');
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
});
after(() => {
  server.close();
});

function auth(extra: Record<string, string> = {}) {
  return { Authorization: `Bearer ${TOKEN}`, ...extra };
}

function uploadPatch(manifest: unknown, token: string | null = TOKEN) {
  const fd = new FormData();
  fd.append('patchzip', new Blob(['PK-demo-payload']), 'patch.zip');
  fd.append('manifest', new Blob([JSON.stringify(manifest)]), 'manifest.json');
  const headers = token ? { Authorization: `Bearer ${token}` } : {};
  return fetch(`${base}/api/patches`, { method: 'POST', headers, body: fd });
}

const jsonHeaders = () => auth({ 'content-type': 'application/json' });

test('/health is public', async () => {
  const r = await fetch(`${base}/health`);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { ok: true });
});

test('/api/meta reports auth is on', async () => {
  assert.deepEqual(await (await fetch(`${base}/api/meta`)).json(), { authRequired: true });
});

test('admin endpoints require a valid token', async () => {
  assert.equal((await fetch(`${base}/api/state`)).status, 401);
  assert.equal((await fetch(`${base}/api/state`, { headers: { Authorization: 'Bearer wrong' } })).status, 401);
  assert.equal((await fetch(`${base}/api/state`, { headers: auth() })).status, 200);
});

test('device endpoints stay public', async () => {
  assert.equal((await fetch(`${base}/check`)).status, 200);
  const t = await fetch(`${base}/api/telemetry`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: '{}',
  });
  assert.equal(t.status, 200);
});

test('upload rejects bad inputs and missing token', async () => {
  assert.equal((await uploadPatch({ version: 'v', patchNumber: -1, targetVersionCode: 1 })).status, 400);
  assert.equal((await uploadPatch({ version: 'v', patchNumber: 1.5, targetVersionCode: 1 })).status, 400);
  assert.equal((await uploadPatch({ version: '///', patchNumber: 1, targetVersionCode: 1 })).status, 400);
  assert.equal((await uploadPatch({ version: 'ok', patchNumber: 1, targetVersionCode: 1 }, null)).status, 401);
});

test('upload + activate + /check round-trips, per channel', async () => {
  assert.equal((await uploadPatch({ version: '1.0.0', patchNumber: 1, targetVersionCode: 9, abis: ['arm64-v8a'] })).status, 200);
  await fetch(`${base}/api/config`, { method: 'POST', headers: jsonHeaders(), body: JSON.stringify({ activeVersion: '1.0.0', rolloutPercent: 100 }) });

  assert.equal((await uploadPatch({ version: '1.0.0-beta', patchNumber: 2, targetVersionCode: 9 })).status, 200);
  await fetch(`${base}/api/config`, { method: 'POST', headers: jsonHeaders(), body: JSON.stringify({ channel: 'beta', activeVersion: '1.0.0-beta', rolloutPercent: 25 }) });

  const def = await (await fetch(`${base}/check`)).json();
  assert.equal(def.hasUpdate, true);
  assert.equal(def.patch.version, '1.0.0');
  assert.equal(def.patch.rolloutPercent, 100);
  assert.ok(def.patch.signature.length > 0);

  const beta = await (await fetch(`${base}/check?channel=beta`)).json();
  assert.equal(beta.patch.version, '1.0.0-beta');
  assert.equal(beta.patch.channel, 'beta');
  assert.equal(beta.patch.rolloutPercent, 25);

  const ghost = await (await fetch(`${base}/check?channel=ghost`)).json();
  assert.equal(ghost.hasUpdate, false);
});

test('/check is no-cache and /payload supports range + caching', async () => {
  const chk = await fetch(`${base}/check`);
  assert.equal(chk.headers.get('cache-control'), 'no-cache');

  const pay = await fetch(`${base}/payload/1.0.0`);
  assert.equal(pay.status, 200);
  assert.equal(pay.headers.get('accept-ranges'), 'bytes');
  assert.match(pay.headers.get('cache-control') || '', /max-age/);

  const ranged = await fetch(`${base}/payload/1.0.0`, { headers: { Range: 'bytes=0-2' } });
  assert.equal(ranged.status, 206);
});

test('preview signs a manifest for the right channel', async () => {
  const p = await (await fetch(`${base}/api/patches/1.0.0-beta/preview`, { headers: auth() })).json();
  assert.equal(p.active, true);
  assert.equal(p.activeChannel, 'beta');
  assert.equal(p.signedManifest.channel, 'beta');
  assert.equal(p.signedManifest.rolloutPercent, 25);
});

test('kill switch hides the patch from /check', async () => {
  await fetch(`${base}/api/kill`, { method: 'POST', headers: jsonHeaders(), body: JSON.stringify({ killed: [1] }) });
  const def = await (await fetch(`${base}/check`)).json();
  assert.equal(def.hasUpdate, false);
  assert.deepEqual(def.rolledBack, [1]);
  assert.ok(def.rolledBackSignature.length > 0);
  await fetch(`${base}/api/kill`, { method: 'POST', headers: jsonHeaders(), body: JSON.stringify({ killed: [] }) });
});
