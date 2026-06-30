import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// store.ts reads FP_DATA_DIR at import time, so point it at a temp dir first.
const dir = mkdtempSync(join(tmpdir(), 'fp-store-'));
process.env.FP_DATA_DIR = dir;
const { Store, DEFAULT_AUTO_HALT } = await import('../src/store.js');
const DB = join(dir, 'db.json');

beforeEach(() => {
  if (existsSync(DB)) rmSync(DB);
});

function rec(version: string, patchNumber: number) {
  return { version, patchNumber, targetVersionCode: 1, sha256: 'x', abis: [], file: '/x', uploadedAt: patchNumber };
}

test('a fresh store has defaults including autoHalt', () => {
  const s = new Store();
  assert.equal(s.config.rolloutPercent, 100);
  assert.equal(s.config.activeVersion, null);
  assert.deepEqual(s.config.killed, []);
  assert.deepEqual(s.config.autoHalt, DEFAULT_AUTO_HALT);
});

test('upsertPatch sorts by patchNumber desc and replaces same version in place', () => {
  const s = new Store();
  s.upsertPatch(rec('a', 1));
  s.upsertPatch(rec('b', 3));
  s.upsertPatch(rec('a', 2)); // replaces version a
  const ps = s.state().patches;
  assert.deepEqual(ps.map((p) => p.version), ['b', 'a']); // 3 then 2
  assert.equal(ps.find((p) => p.version === 'a')!.patchNumber, 2);
});

test('setConfig merges and leaves untouched fields alone', () => {
  const s = new Store();
  s.setConfig({ rolloutPercent: 25 });
  assert.equal(s.config.rolloutPercent, 25);
  assert.equal(s.config.channel, '');
});

test('a corrupt db.json falls back to defaults instead of crashing', () => {
  writeFileSync(DB, '{ this is not valid json');
  let s: InstanceType<typeof Store> | undefined;
  assert.doesNotThrow(() => {
    s = new Store();
  });
  assert.equal(s!.config.rolloutPercent, 100);
  assert.deepEqual(s!.config.autoHalt, DEFAULT_AUTO_HALT);
});

test('an older db.json without autoHalt is backfilled, keeping its other config', () => {
  writeFileSync(
    DB,
    JSON.stringify({
      patches: [],
      config: { activeVersion: 'v1', rolloutPercent: 50, channel: 'beta', killed: [9] },
    }),
  );
  const s = new Store();
  assert.equal(s.config.activeVersion, 'v1');
  assert.equal(s.config.rolloutPercent, 50);
  assert.equal(s.config.channel, 'beta');
  assert.deepEqual(s.config.killed, [9]);
  assert.deepEqual(s.config.autoHalt, DEFAULT_AUTO_HALT);
});

test('a non-array patches field is coerced to []', () => {
  writeFileSync(DB, JSON.stringify({ patches: 'nope', config: {} }));
  const s = new Store();
  assert.deepEqual(s.state().patches, []);
});

test('fresh store has an empty channels map and resolves the default channel', () => {
  const s = new Store();
  assert.deepEqual(s.config.channels, {});
  const def = s.resolveChannel('');
  assert.deepEqual(def, { channel: '', activeVersion: null, rolloutPercent: 100 });
});

test('setChannelState writes named channels; default routes to top-level', () => {
  const s = new Store();
  s.setChannelState('', { activeVersion: 'd1', rolloutPercent: 90 }); // default
  s.setChannelState('beta', { activeVersion: 'b1', rolloutPercent: 10 });
  assert.equal(s.config.activeVersion, 'd1');
  assert.equal(s.config.rolloutPercent, 90);
  assert.deepEqual(s.config.channels.beta, { activeVersion: 'b1', rolloutPercent: 10 });
  assert.deepEqual(s.resolveChannel('beta'), { channel: 'beta', activeVersion: 'b1', rolloutPercent: 10 });
});

test('resolveChannel returns null for an unknown channel', () => {
  const s = new Store();
  assert.equal(s.resolveChannel('does-not-exist'), null);
});

test('channelNames lists the default first', () => {
  const s = new Store();
  s.setChannelState('beta', { activeVersion: 'b1', rolloutPercent: 5 });
  assert.deepEqual(s.channelNames(), ['', 'beta']);
});

test('an old db.json without channels is backfilled to {}', () => {
  writeFileSync(
    DB,
    JSON.stringify({ patches: [], config: { activeVersion: 'v', rolloutPercent: 100, channel: '', killed: [] } }),
  );
  const s = new Store();
  assert.deepEqual(s.config.channels, {});
});
