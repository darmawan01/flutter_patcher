import { createApp } from './app.js';
import { Signer } from './signing.js';
import { Store } from './store.js';

const PORT = Number(process.env.PORT || 8090);
const SEED = process.env.FP_SIGNING_SEED;
if (!SEED) {
  console.error('error: set FP_SIGNING_SEED (run `npm run keygen` to make one).');
  process.exit(1);
}

const adminToken = process.env.FP_ADMIN_TOKEN || '';
const signer = new Signer(SEED);
const store = new Store();
const app = createApp({ signer, store, adminToken });

app.listen(PORT, () => {
  console.log(`flutter_patcher server on http://localhost:${PORT}`);
  console.log(`  dashboard:   http://localhost:${PORT}/`);
  console.log(`  device check: http://localhost:${PORT}/check`);
  console.log(`  public key:  ${signer.publicKeySpkiBase64}`);
  console.log(
    adminToken
      ? '  admin auth:  ON (dashboard requires FP_ADMIN_TOKEN)'
      : '  admin auth:  OFF — set FP_ADMIN_TOKEN to lock down the dashboard for a public deploy',
  );
});
