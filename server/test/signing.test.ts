import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, createPublicKey, verify } from 'node:crypto';

import { Signer, generateSeed } from '../src/signing.js';

// Independently verify a base64 Ed25519 signature against an SPKI public key —
// this is effectively what the Android/Dart verifiers do, so it pins the
// canonical message format byte-for-byte.
function verifySig(spkiB64: string, msg: string, sigB64: string): boolean {
  const pub = createPublicKey({ key: Buffer.from(spkiB64, 'base64'), format: 'der', type: 'spki' });
  return verify(null, Buffer.from(msg, 'utf8'), pub, Buffer.from(sigB64, 'base64'));
}

test('seed must be exactly 32 bytes', () => {
  assert.throws(() => new Signer(Buffer.alloc(16).toString('base64')));
  assert.throws(() => new Signer(Buffer.alloc(33).toString('base64')));
});

test('v1 manifest signs the documented canonical string (sha256 lowercased)', () => {
  const s = new Signer(generateSeed().seedBase64);
  const sig = s.signManifestV1({ version: '1.0.1-h1', patchNumber: 3, targetVersionCode: 42, sha256: 'ABCDEF' });
  const expected =
    'flutter_patcher.manifest.v1\nversion=1.0.1-h1\npatchNumber=3\ntargetVersionCode=42\nsha256=abcdef';
  assert.ok(verifySig(s.publicKeySpkiBase64, expected, sig));
});

test('v2 manifest binds rollout + channel', () => {
  const s = new Signer(generateSeed().seedBase64);
  const sig = s.signManifestV2({
    version: '1.0.1-h1',
    patchNumber: 3,
    targetVersionCode: 42,
    sha256: 'abc',
    rolloutPercent: 10,
    channel: 'beta',
  });
  const expected =
    'flutter_patcher.manifest.v2\nversion=1.0.1-h1\npatchNumber=3\ntargetVersionCode=42\nsha256=abc\nrolloutPercent=10\nchannel=beta';
  assert.ok(verifySig(s.publicKeySpkiBase64, expected, sig));
});

test('v3 manifest binds delivery + announcement (body by hash)', () => {
  const s = new Signer(generateSeed().seedBase64);
  const sig = s.signManifestV3({
    version: '1.0.1-h1',
    patchNumber: 3,
    targetVersionCode: 42,
    sha256: 'abc',
    rolloutPercent: 100,
    channel: '',
    delivery: 'notify',
    annTitle: 'Hi',
    annBody: 'a\nb',
    annSeverity: 'important',
    annUrl: 'https://x',
  });
  const bodySha = createHash('sha256').update('a\nb', 'utf8').digest('hex');
  const expected =
    'flutter_patcher.manifest.v3\nversion=1.0.1-h1\npatchNumber=3\ntargetVersionCode=42\nsha256=abc\n' +
    `rolloutPercent=100\nchannel=\ndelivery=notify\nannTitle=Hi\nannSeverity=important\nannUrl=https://x\nannBodySha256=${bodySha}`;
  assert.ok(verifySig(s.publicKeySpkiBase64, expected, sig));
});

test('v3 cross-language vector: fixed seed → fixed signature (matches Dart + native)', () => {
  const seedBase64 = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
  const s = new Signer(seedBase64);
  assert.equal(s.publicKeySpkiBase64, 'MCowBQYDK2VwAyEAA6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=');
  const sig = s.signManifestV3({
    version: '1.2.0+5',
    patchNumber: 5,
    targetVersionCode: 4,
    sha256: 'ab'.repeat(32),
    rolloutPercent: 100,
    channel: '',
    delivery: 'notify',
    annTitle: 'Hello',
    annBody: 'line1\nline2',
    annSeverity: 'important',
    annUrl: 'https://x',
  });
  assert.equal(sig, '9sXFYT8I03DD+I+IT9xi/TO97tzoqkwhLuoBeKJBozNWvFCy5q3HqnZzp5F+xdgf94RNSuiAJcqrOtP2MM+zDA==');
});

test('rollback list is sorted and de-duplicated', () => {
  const s = new Signer(generateSeed().seedBase64);
  const sig = s.signRollback([5, 1, 5, 3]);
  const expected = 'flutter_patcher.rollback.v1\npatchNumbers=1,3,5';
  assert.ok(verifySig(s.publicKeySpkiBase64, expected, sig));
});

test('Ed25519 signing is deterministic (same input → same signature)', () => {
  const s = new Signer(generateSeed().seedBase64);
  const p = { version: 'v', patchNumber: 1, targetVersionCode: 1, sha256: 'aa' };
  assert.equal(s.signManifestV1(p), s.signManifestV1(p));
});

test('generateSeed yields a 32-byte seed whose pubkey matches a Signer over it', () => {
  const { seedBase64, publicKeySpkiBase64 } = generateSeed();
  assert.equal(Buffer.from(seedBase64, 'base64').length, 32);
  assert.equal(new Signer(seedBase64).publicKeySpkiBase64, publicKeySpkiBase64);
});

test('a signature does NOT verify under a different key', () => {
  const s1 = new Signer(generateSeed().seedBase64);
  const s2 = new Signer(generateSeed().seedBase64);
  const msg = 'flutter_patcher.manifest.v1\nversion=v\npatchNumber=1\ntargetVersionCode=1\nsha256=aa';
  const sig = s1.signManifestV1({ version: 'v', patchNumber: 1, targetVersionCode: 1, sha256: 'aa' });
  assert.ok(verifySig(s1.publicKeySpkiBase64, msg, sig));
  assert.ok(!verifySig(s2.publicKeySpkiBase64, msg, sig));
});
