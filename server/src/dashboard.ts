export function dashboardHtml(): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>flutter_patcher · control room</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 14px/1.5 system-ui, sans-serif; background: #0f1115; color: #e6e8eb; }
  header { padding: 16px 24px; border-bottom: 1px solid #232733; display: flex; align-items: baseline; gap: 12px; }
  h1 { font-size: 18px; margin: 0; }
  .muted { color: #8b93a1; }
  main { max-width: 1000px; margin: 0 auto; padding: 24px; display: grid; gap: 20px; }
  .card { background: #161a22; border: 1px solid #232733; border-radius: 10px; padding: 16px 20px; }
  .card h2 { font-size: 14px; text-transform: uppercase; letter-spacing: .04em; color: #8b93a1; margin: 0 0 12px; }
  code, pre { font-family: ui-monospace, monospace; }
  pre { background: #0b0d11; border: 1px solid #232733; border-radius: 8px; padding: 12px; overflow:auto; white-space: pre-wrap; word-break: break-all; }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #232733; }
  th { color: #8b93a1; font-weight: 600; font-size: 12px; }
  .pill { display:inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; background:#232733; }
  .pill.live { background:#1f6f43; color:#d9f7e6; }
  .pill.killed { background:#7a2230; color:#ffd9df; }
  button { background:#2b6cb0; color:#fff; border:0; border-radius:7px; padding:7px 12px; cursor:pointer; font-size:13px; }
  button.ghost { background:#232733; }
  button.danger { background:#7a2230; }
  button:hover { filter: brightness(1.1); }
  input[type=text], input[type=number] { background:#0b0d11; border:1px solid #232733; color:#e6e8eb; border-radius:7px; padding:6px 8px; }
  label { display:inline-flex; align-items:center; gap:8px; margin-right:16px; }
  .row { display:flex; flex-wrap:wrap; gap:12px; align-items:center; }
  .slider-val { min-width:48px; text-align:right; font-variant-numeric: tabular-nums; }
</style>
</head>
<body>
<header>
  <h1>flutter_patcher <span class="muted">control room</span></h1>
  <span class="muted" id="pubkey-hint"></span>
</header>
<main>
  <div class="card">
    <h2>Signing key (paste into the app)</h2>
    <pre id="pubkey">…</pre>
    <div class="muted">await FlutterPatcher.init(publicKeyBase64: '<span id="pubkey-inline">…</span>');</div>
  </div>

  <div class="card">
    <h2>Rollout control</h2>
    <div class="row">
      <label>Active patch
        <select id="active"></select>
      </label>
      <label>Channel <input type="text" id="channel" placeholder="(stable)" size="10" /></label>
    </div>
    <div class="row" style="margin-top:12px">
      <input type="range" id="rollout" min="0" max="100" value="100" style="flex:1" />
      <span class="slider-val"><span id="rollout-val">100</span>%</span>
      <button id="save-config">Apply rollout</button>
    </div>
  </div>

  <div class="card">
    <h2>Patches</h2>
    <table>
      <thead><tr><th>version</th><th>#</th><th>targetVc</th><th>abis</th><th>sha256</th><th>state</th><th></th></tr></thead>
      <tbody id="patches"></tbody>
    </table>
  </div>

  <div class="card">
    <h2>Upload a packed patch</h2>
    <div class="muted">Run <code>dart run flutter_patcher:pack …</code>, then upload its <code>dist/patch.zip</code> + <code>dist/manifest.json</code>.</div>
    <div class="row" style="margin-top:12px">
      <label>patch.zip <input type="file" id="f-zip" accept=".zip" /></label>
      <label>manifest.json <input type="file" id="f-manifest" accept=".json" /></label>
      <button id="upload">Upload</button>
    </div>
  </div>

  <div class="card">
    <h2>Live /check response</h2>
    <pre id="check">…</pre>
  </div>

  <div class="card">
    <h2>Telemetry (last 50)</h2>
    <pre id="telemetry">(none yet — wire FlutterPatcher.init(onEvent:) to POST /api/telemetry)</pre>
  </div>
</main>
<script>
const $ = (id) => document.getElementById(id);
async function api(path, opts) { const r = await fetch(path, opts); return r.json(); }

async function refresh() {
  const s = await api('/api/state');
  $('pubkey').textContent = s.publicKey;
  $('pubkey-inline').textContent = s.publicKey;

  // active select
  const sel = $('active');
  sel.innerHTML = '<option value="">(none)</option>' +
    s.patches.map(p => '<option value="'+p.version+'">'+p.version+' (#'+p.patchNumber+')</option>').join('');
  sel.value = s.config.activeVersion || '';
  $('channel').value = s.config.channel || '';
  $('rollout').value = s.config.rolloutPercent;
  $('rollout-val').textContent = s.config.rolloutPercent;

  // patches table
  $('patches').innerHTML = s.patches.map(p => {
    const live = p.version === s.config.activeVersion;
    const killed = s.config.killed.includes(p.patchNumber);
    const state = killed ? '<span class="pill killed">killed</span>'
      : live ? '<span class="pill live">live</span>' : '<span class="pill">idle</span>';
    const killBtn = killed
      ? '<button class="ghost" onclick="unkill('+p.patchNumber+')">un-kill</button>'
      : '<button class="danger" onclick="kill('+p.patchNumber+')">kill</button>';
    return '<tr><td>'+p.version+'</td><td>'+p.patchNumber+'</td><td>'+p.targetVersionCode+'</td>'
      + '<td>'+(p.abis||[]).join(', ')+'</td><td><code>'+p.sha256.slice(0,12)+'…</code></td>'
      + '<td>'+state+'</td><td>'+killBtn+'</td></tr>';
  }).join('') || '<tr><td colspan="7" class="muted">no patches uploaded yet</td></tr>';

  $('telemetry').textContent = s.telemetry.length
    ? s.telemetry.map(t => new Date(t.at).toLocaleTimeString()+'  '+JSON.stringify(t.event)).join('\\n')
    : '(none yet — wire FlutterPatcher.init(onEvent:) to POST /api/telemetry)';

  const chk = await api('/check');
  $('check').textContent = JSON.stringify(chk, null, 2);
}

$('rollout').addEventListener('input', e => $('rollout-val').textContent = e.target.value);
$('save-config').onclick = async () => {
  await api('/api/config', { method:'POST', headers:{'content-type':'application/json'},
    body: JSON.stringify({ activeVersion: $('active').value || null, rolloutPercent: Number($('rollout').value), channel: $('channel').value }) });
  refresh();
};
$('active').onchange = () => $('save-config').click();
window.kill = async (n) => { const s = await api('/api/state'); const k = [...new Set([...s.config.killed, n])]; await api('/api/kill', {method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({killed:k})}); refresh(); };
window.unkill = async (n) => { const s = await api('/api/state'); const k = s.config.killed.filter(x=>x!==n); await api('/api/kill', {method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({killed:k})}); refresh(); };
$('upload').onclick = async () => {
  const zip = $('f-zip').files[0], man = $('f-manifest').files[0];
  if (!zip || !man) { alert('pick patch.zip + manifest.json'); return; }
  const fd = new FormData(); fd.append('patchzip', zip); fd.append('manifest', man);
  const r = await api('/api/patches', { method:'POST', body: fd });
  if (r.error) alert(r.error); else refresh();
};
refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>`;
}
