import { test } from 'node:test';
import assert from 'node:assert/strict';

import { evaluateHalt } from '../src/autohalt.js';
import { DEFAULT_AUTO_HALT } from '../src/store.js';

const NOW = 1_000_000_000_000;
const cfg = { ...DEFAULT_AUTO_HALT, enabled: true, minSamples: 5, minFailures: 3, failureRate: 0.2, windowMinutes: 30 };

function ev(ok: boolean, patchNumber = 100, at = NOW) {
  return { at, event: { type: 'applyFinished', patchNumber, ok } };
}

test('disabled never halts', () => {
  const tel = [ev(false), ev(false), ev(false), ev(false), ev(false)];
  assert.equal(evaluateHalt({ ...cfg, enabled: false }, 50, 100, tel, NOW).halt, false);
});

test('an already-frozen rollout (0%) never re-halts', () => {
  const tel = [ev(false), ev(false), ev(false), ev(false), ev(false)];
  assert.equal(evaluateHalt(cfg, 0, 100, tel, NOW).halt, false);
});

test('halts when failures cross the rate + count thresholds', () => {
  const tel = [ev(true), ev(true), ev(false), ev(false), ev(false)]; // 3/5 = 60%
  const d = evaluateHalt(cfg, 50, 100, tel, NOW);
  assert.equal(d.halt, true);
  assert.equal(d.ok, 2);
  assert.equal(d.fail, 3);
});

test('does not halt below minSamples', () => {
  const tel = [ev(false), ev(false), ev(false)]; // 3 fails but only 3 samples
  assert.equal(evaluateHalt(cfg, 50, 100, tel, NOW).halt, false);
});

test('does not halt below minFailures even at a high rate', () => {
  const tel = [ev(true), ev(true), ev(true), ev(false), ev(false)]; // 2 fails (40%) < minFailures 3
  assert.equal(evaluateHalt(cfg, 50, 100, tel, NOW).halt, false);
});

test('ignores events outside the time window', () => {
  const old = NOW - 60 * 60_000; // 60m ago, window is 30m
  const tel = Array.from({ length: 5 }, () => ev(false, 100, old));
  assert.equal(evaluateHalt(cfg, 50, 100, tel, NOW).halt, false);
});

test('ignores telemetry for other patch numbers', () => {
  const tel = Array.from({ length: 5 }, () => ev(false, 999));
  assert.equal(evaluateHalt(cfg, 50, 100, tel, NOW).halt, false);
});

test('only counts applyFinished events', () => {
  const tel = [
    { at: NOW, event: { type: 'staged', patchNumber: 100 } },
    { at: NOW, event: { type: 'boot', patchNumber: 100 } },
    ev(false), ev(false), ev(false), ev(false), ev(false),
  ];
  const d = evaluateHalt(cfg, 50, 100, tel, NOW);
  assert.equal(d.fail, 5);
  assert.equal(d.halt, true);
});

test('handles PatchEventType-prefixed event types', () => {
  const tel = Array.from({ length: 5 }, () => ({
    at: NOW,
    event: { type: 'PatchEventType.applyFinished', patchNumber: 100, ok: false },
  }));
  assert.equal(evaluateHalt(cfg, 50, 100, tel, NOW).halt, true);
});

test('no active patch → no halt', () => {
  const tel = Array.from({ length: 5 }, () => ev(false));
  assert.equal(evaluateHalt(cfg, 50, null, tel, NOW).halt, false);
});
