import { generateSeed } from './signing.js';

// Generate a signing keypair for the server. Print the seed (set FP_SIGNING_SEED)
// and the public key to paste into FlutterPatcher.init(publicKeyBase64: ...).
const kp = generateSeed();
console.log('FP_SIGNING_SEED (keep secret, set as env for the server):');
console.log('  ' + kp.seedBase64);
console.log('');
console.log('Public key for the app (FlutterPatcher.init publicKeyBase64):');
console.log('  ' + kp.publicKeySpkiBase64);
