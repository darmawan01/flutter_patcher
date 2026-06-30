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
