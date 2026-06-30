import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

export interface PatchRecord {
  version: string;
  patchNumber: number;
  targetVersionCode: number;
  sha256: string; // of patch.zip, server-computed
  abis: string[];
  file: string; // absolute path to patch.zip
  uploadedAt: number;
}

export interface AutoHalt {
  enabled: boolean;
  windowMinutes: number; // look-back window for the failure-rate sample
  minSamples: number; // need at least this many applyFinished events before acting
  minFailures: number; // and at least this many of them failed
  failureRate: number; // and the failed/total ratio is >= this (0..1)
}

export interface HaltEvent {
  at: number;
  version: string;
  patchNumber: number;
  ok: number;
  fail: number;
  rate: number;
}

export interface ChannelState {
  activeVersion: string | null;
  rolloutPercent: number; // 0..100
}

export interface Config {
  // The default channel (served when /check is hit with no ?channel, or with the
  // default's name). Kept top-level for byte-compat with single-channel deploys.
  activeVersion: string | null;
  rolloutPercent: number; // 0..100
  channel: string; // the default channel's name (usually '')
  // Additional named channels (beta, staging, …), each with its own active patch
  // + rollout. The device selects one via /check?channel=<name>.
  channels: Record<string, ChannelState>;
  killed: number[]; // rolled-back patchNumbers (global)
  autoHalt: AutoHalt;
}

/** Resolved view of one channel, ready to sign + serve. */
export interface ResolvedChannel {
  channel: string;
  activeVersion: string | null;
  rolloutPercent: number;
}

interface Db {
  patches: PatchRecord[];
  config: Config;
}

export const DEFAULT_AUTO_HALT: AutoHalt = {
  enabled: false,
  windowMinutes: 30,
  minSamples: 10,
  minFailures: 3,
  failureRate: 0.2,
};

const DATA_DIR = process.env.FP_DATA_DIR || join(process.cwd(), 'data');
const DB_FILE = join(DATA_DIR, 'db.json');
export const PATCH_DIR = join(DATA_DIR, 'patches');

const DEFAULT_DB: Db = {
  patches: [],
  config: {
    activeVersion: null,
    rolloutPercent: 100,
    channel: '',
    channels: {},
    killed: [],
    autoHalt: { ...DEFAULT_AUTO_HALT },
  },
};

function ensureDir(p: string) {
  if (!existsSync(p)) mkdirSync(p, { recursive: true });
}

export class Store {
  private db: Db;

  constructor() {
    ensureDir(DATA_DIR);
    ensureDir(PATCH_DIR);
    this.db = structuredClone(DEFAULT_DB);
    if (existsSync(DB_FILE)) {
      try {
        const loaded = JSON.parse(readFileSync(DB_FILE, 'utf8'));
        const lc = loaded.config ?? {};
        this.db = {
          patches: Array.isArray(loaded.patches) ? loaded.patches : [],
          config: {
            ...DEFAULT_DB.config,
            ...lc,
            channels: lc.channels && typeof lc.channels === 'object' ? lc.channels : {},
            autoHalt: { ...DEFAULT_AUTO_HALT, ...(lc.autoHalt ?? {}) },
          },
        };
      } catch (e) {
        console.error(`[store] db.json is unreadable, starting from defaults: ${(e as Error).message}`);
      }
    }
  }

  private persist() {
    ensureDir(dirname(DB_FILE));
    writeFileSync(DB_FILE, JSON.stringify(this.db, null, 2));
  }

  state() {
    return { patches: this.db.patches, config: this.db.config };
  }

  patch(version: string): PatchRecord | undefined {
    return this.db.patches.find((p) => p.version === version);
  }

  activePatch(): PatchRecord | undefined {
    const v = this.db.config.activeVersion;
    return v ? this.patch(v) : undefined;
  }

  get config(): Config {
    return this.db.config;
  }

  /** Name of the default channel (served when no ?channel is given). */
  get defaultChannel(): string {
    return this.db.config.channel || '';
  }

  /** Every channel name with state, default first. */
  channelNames(): string[] {
    return [this.defaultChannel, ...Object.keys(this.db.config.channels)];
  }

  /** Resolve a requested channel to its active patch + rollout, or null if the
   *  channel exists but isn't configured. The default channel always resolves. */
  resolveChannel(requested: string): ResolvedChannel | null {
    const def = this.defaultChannel;
    if (!requested || requested === def) {
      return { channel: def, activeVersion: this.db.config.activeVersion, rolloutPercent: this.db.config.rolloutPercent };
    }
    const c = this.db.config.channels[requested];
    if (!c) return null;
    return { channel: requested, activeVersion: c.activeVersion, rolloutPercent: c.rolloutPercent };
  }

  /** Set a channel's active version / rollout. Empty name = the default channel. */
  setChannelState(name: string, partial: Partial<ChannelState>) {
    if (!name || name === this.defaultChannel) {
      this.setConfig(partial as Partial<Config>);
      return;
    }
    const cur = this.db.config.channels[name] ?? { activeVersion: null, rolloutPercent: 100 };
    this.db.config.channels[name] = { ...cur, ...partial };
    this.persist();
  }

  upsertPatch(rec: PatchRecord) {
    const i = this.db.patches.findIndex((p) => p.version === rec.version);
    if (i >= 0) this.db.patches[i] = rec;
    else this.db.patches.push(rec);
    this.db.patches.sort((a, b) => b.patchNumber - a.patchNumber);
    this.persist();
  }

  setConfig(partial: Partial<Config>) {
    this.db.config = { ...this.db.config, ...partial };
    this.persist();
  }
}

export function sha256OfFile(path: string): string {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}
