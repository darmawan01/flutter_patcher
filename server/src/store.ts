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

export interface Config {
  activeVersion: string | null;
  rolloutPercent: number; // 0..100
  channel: string;
  killed: number[]; // rolled-back patchNumbers
  autoHalt: AutoHalt;
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
        this.db = {
          patches: Array.isArray(loaded.patches) ? loaded.patches : [],
          config: { ...DEFAULT_DB.config, ...(loaded.config ?? {}), autoHalt: { ...DEFAULT_AUTO_HALT, ...(loaded.config?.autoHalt ?? {}) } },
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
