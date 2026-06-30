import type { AutoHalt } from './store.js';

export interface TelemetryEntry {
  at: number;
  event: unknown;
}

export interface HaltDecision {
  halt: boolean;
  ok: number;
  fail: number;
  rate: number;
}

/**
 * Pure auto-halt decision: given the config, the active patch number, the
 * telemetry ring and "now", decide whether the live rollout should be frozen.
 *
 * Kept side-effect-free (no store writes, no clock) so it can be unit-tested and
 * so the freeze action stays in one place in the server.
 */
export function evaluateHalt(
  ah: AutoHalt,
  rolloutPercent: number,
  activePatchNumber: number | null,
  telemetry: TelemetryEntry[],
  now: number,
): HaltDecision {
  if (!ah?.enabled || rolloutPercent <= 0 || activePatchNumber == null) {
    return { halt: false, ok: 0, fail: 0, rate: 0 };
  }
  const since = now - ah.windowMinutes * 60_000;
  let ok = 0;
  let fail = 0;
  for (const t of telemetry) {
    if (t.at < since) continue;
    const e = t.event as { type?: unknown; patchNumber?: unknown; ok?: unknown } | null;
    const type = String(e?.type ?? '').replace('PatchEventType.', '');
    if (type !== 'applyFinished' || e?.patchNumber !== activePatchNumber) continue;
    if (e?.ok === false) fail++;
    else if (e?.ok === true) ok++;
  }
  const total = ok + fail;
  const rate = total > 0 ? fail / total : 0;
  const halt = total >= ah.minSamples && fail >= ah.minFailures && rate >= ah.failureRate;
  return { halt, ok, fail, rate };
}
