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

export interface Config {
  activeVersion: string | null;
  rolloutPercent: number; // 0..100
  channel: string;
  killed: number[]; // rolled-back patchNumbers
}

interface Db {
  patches: PatchRecord[];
  config: Config;
}

const DATA_DIR = process.env.FP_DATA_DIR || join(process.cwd(), 'data');
const DB_FILE = join(DATA_DIR, 'db.json');
export const PATCH_DIR = join(DATA_DIR, 'patches');

const DEFAULT_DB: Db = {
  patches: [],
  config: { activeVersion: null, rolloutPercent: 100, channel: '', killed: [] },
};

function ensureDir(p: string) {
  if (!existsSync(p)) mkdirSync(p, { recursive: true });
}

export class Store {
  private db: Db;

  constructor() {
    ensureDir(DATA_DIR);
    ensureDir(PATCH_DIR);
    this.db = existsSync(DB_FILE)
      ? { ...DEFAULT_DB, ...JSON.parse(readFileSync(DB_FILE, 'utf8')) }
      : structuredClone(DEFAULT_DB);
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
