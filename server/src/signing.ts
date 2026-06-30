import {
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  sign as edSign,
  type KeyObject,
} from 'node:crypto';

// PKCS#8 prefix for an Ed25519 private key (16 bytes) + 32-byte seed = 48-byte DER.
const PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');

/**
 * Ed25519 signing for the reference server. The canonical strings here MUST match
 * the device verifier (SignatureVerifier canonical manifest / rollback builders)
 * in the Android plugin and the Dart PatchSigning helper, byte-for-byte.
 */
export class Signer {
  private readonly key: KeyObject;
  readonly publicKeySpkiBase64: string;

  constructor(seedBase64: string) {
    const seed = Buffer.from(seedBase64.trim(), 'base64');
    if (seed.length !== 32) {
      throw new Error(`signing seed must be 32 bytes (got ${seed.length})`);
    }
    this.key = createPrivateKey({
      key: Buffer.concat([PKCS8_PREFIX, seed]),
      format: 'der',
      type: 'pkcs8',
    });
    this.publicKeySpkiBase64 = createPublicKey(this.key)
      .export({ type: 'spki', format: 'der' })
      .toString('base64');
  }

  sign(message: string): string {
    return edSign(null, Buffer.from(message, 'utf8'), this.key).toString('base64');
  }

  /** v1 manifest — used when no rollout is configured. */
  signManifestV1(p: {
    version: string;
    patchNumber: number;
    targetVersionCode: number;
    sha256: string;
  }): string {
    return this.sign(
      'flutter_patcher.manifest.v1\n' +
        `version=${p.version}\n` +
        `patchNumber=${p.patchNumber}\n` +
        `targetVersionCode=${p.targetVersionCode}\n` +
        `sha256=${p.sha256.toLowerCase()}`,
    );
  }

  /** v2 manifest — binds the staged-rollout fields too. */
  signManifestV2(p: {
    version: string;
    patchNumber: number;
    targetVersionCode: number;
    sha256: string;
    rolloutPercent: number;
    channel: string;
  }): string {
    return this.sign(
      'flutter_patcher.manifest.v2\n' +
        `version=${p.version}\n` +
        `patchNumber=${p.patchNumber}\n` +
        `targetVersionCode=${p.targetVersionCode}\n` +
        `sha256=${p.sha256.toLowerCase()}\n` +
        `rolloutPercent=${p.rolloutPercent}\n` +
        `channel=${p.channel}`,
    );
  }

  /** Signed kill-switch list. */
  signRollback(patchNumbers: number[]): string {
    const sorted = [...new Set(patchNumbers)].sort((a, b) => a - b);
    return this.sign(`flutter_patcher.rollback.v1\npatchNumbers=${sorted.join(',')}`);
  }
}

/** Generate a fresh seed + its X.509 public key (for `keygen`). */
export function generateSeed(): { seedBase64: string; publicKeySpkiBase64: string } {
  const { privateKey } = generateKeyPairSync('ed25519');
  const pkcs8 = privateKey.export({ type: 'pkcs8', format: 'der' });
  const seed = pkcs8.subarray(pkcs8.length - 32); // last 32 bytes = the raw seed
  return {
    seedBase64: Buffer.from(seed).toString('base64'),
    publicKeySpkiBase64: createPublicKey(privateKey)
      .export({ type: 'spki', format: 'der' })
      .toString('base64'),
  };
}
