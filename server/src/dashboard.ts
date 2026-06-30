export function dashboardHtml(): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>flutter_patcher · control room</title>
<style>
  :root {
    color-scheme: dark;
    --bg:#0e1015; --panel:#161a22; --panel2:#1b212c; --line:#262c39;
    --txt:#e7eaf0; --muted:#8b93a1; --accent:#3b82f6; --good:#22c55e;
    --warn:#f59e0b; --bad:#ef4444; --radius:12px;
  }
  * { box-sizing:border-box; }
  body { margin:0; font:14px/1.55 system-ui,-apple-system,sans-serif; background:var(--bg); color:var(--txt); }
  a { color:var(--accent); }
  code,pre { font-family:ui-monospace,"SF Mono",Menlo,monospace; }
  header {
    position:sticky; top:0; z-index:5; backdrop-filter:blur(8px);
    background:rgba(14,16,21,.82); border-bottom:1px solid var(--line);
    padding:14px 24px; display:flex; align-items:center; gap:16px; flex-wrap:wrap;
  }
  header h1 { font-size:16px; margin:0; font-weight:650; letter-spacing:.01em; }
  header h1 .dim { color:var(--muted); font-weight:400; }
  .dot { width:8px; height:8px; border-radius:50%; background:var(--good); box-shadow:0 0 0 3px rgba(34,197,94,.18); }
  .dot.off { background:var(--bad); box-shadow:0 0 0 3px rgba(239,68,68,.18); }
  .spacer { flex:1; }
  .hsum { display:flex; gap:18px; align-items:center; color:var(--muted); font-size:13px; flex-wrap:wrap; }
  .hsum b { color:var(--txt); font-weight:600; }
  main { max-width:1060px; margin:0 auto; padding:22px; display:grid; gap:18px; grid-template-columns:1fr 1fr; }
  .card { background:var(--panel); border:1px solid var(--line); border-radius:var(--radius); padding:18px 20px; }
  .card.wide { grid-column:1 / -1; }
  .card h2 { font-size:11px; text-transform:uppercase; letter-spacing:.08em; color:var(--muted); margin:0 0 14px; font-weight:650; }
  pre { background:#0a0c10; border:1px solid var(--line); border-radius:9px; padding:12px; overflow:auto; white-space:pre-wrap; word-break:break-all; margin:0; font-size:12.5px; }
  table { width:100%; border-collapse:collapse; }
  th,td { text-align:left; padding:9px 10px; border-bottom:1px solid var(--line); vertical-align:middle; }
  th { color:var(--muted); font-weight:600; font-size:11px; text-transform:uppercase; letter-spacing:.05em; }
  tr:last-child td { border-bottom:0; }
  .pill { display:inline-block; padding:2px 9px; border-radius:999px; font-size:11.5px; font-weight:600; background:var(--panel2); color:var(--muted); }
  .pill.live { background:rgba(34,197,94,.16); color:#7ee2a8; }
  .pill.killed { background:rgba(239,68,68,.16); color:#fca5a5; }
  .pill.idle { background:var(--panel2); color:var(--muted); }
  button { background:var(--accent); color:#fff; border:0; border-radius:8px; padding:8px 13px; cursor:pointer; font-size:13px; font-weight:550; transition:filter .12s; }
  button:hover { filter:brightness(1.12); }
  button:active { filter:brightness(.95); }
  button.ghost { background:var(--panel2); color:var(--txt); }
  button.danger { background:rgba(239,68,68,.16); color:#fca5a5; }
  button.danger:hover { background:var(--bad); color:#fff; }
  button.mini { padding:4px 9px; font-size:12px; }
  input[type=text],input[type=number],select { background:#0a0c10; border:1px solid var(--line); color:var(--txt); border-radius:8px; padding:7px 9px; font-size:13px; }
  select { min-width:200px; }
  label { display:inline-flex; align-items:center; gap:8px; color:var(--muted); }
  .row { display:flex; flex-wrap:wrap; gap:14px; align-items:center; }
  .keyrow { display:flex; gap:8px; align-items:center; }
  .keyrow code { flex:1; background:#0a0c10; border:1px solid var(--line); border-radius:8px; padding:9px 11px; font-size:12px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .slider-wrap { display:flex; align-items:center; gap:14px; width:100%; }
  input[type=range]{ flex:1; accent-color:var(--accent); }
  .big { font-size:26px; font-weight:700; font-variant-numeric:tabular-nums; min-width:84px; text-align:right; }
  .presets button { background:var(--panel2); color:var(--muted); }
  .presets button:hover { color:var(--txt); }
  .drop { border:1.5px dashed var(--line); border-radius:10px; padding:18px; text-align:center; color:var(--muted); transition:.15s; cursor:pointer; }
  .drop.over { border-color:var(--accent); background:rgba(59,130,246,.06); color:var(--txt); }
  .empty { color:var(--muted); text-align:center; padding:18px; }
  .toast { position:fixed; bottom:22px; right:22px; background:var(--panel2); border:1px solid var(--line); border-left:3px solid var(--accent); padding:11px 16px; border-radius:9px; box-shadow:0 8px 30px rgba(0,0,0,.4); opacity:0; transform:translateY(8px); transition:.2s; z-index:20; max-width:360px; }
  .toast.show { opacity:1; transform:none; }
  .toast.err { border-left-color:var(--bad); }
  .tele { font-size:12.5px; }
  .tele .t-type { display:inline-block; min-width:96px; }
  .chip { font-size:11px; padding:1px 7px; border-radius:6px; background:var(--panel2); color:var(--muted); }
  .chip.staged { background:rgba(34,197,94,.16); color:#7ee2a8; }
  .chip.applyFinished { background:rgba(59,130,246,.16); color:#93c5fd; }
  .chip.boot { background:rgba(245,158,11,.16); color:#fcd34d; }
  .refresh { font-size:12px; color:var(--muted); }
</style>
</head>
<body>
<header>
  <span class="dot" id="dot"></span>
  <h1>flutter_patcher <span class="dim">control room</span></h1>
  <div class="spacer"></div>
  <div class="hsum" id="hsum"></div>
  <span class="refresh" id="refresh"></span>
</header>
<main>
  <div class="card wide">
    <h2>Signing key — paste into the app</h2>
    <div class="keyrow">
      <code id="pubkey">…</code>
      <button class="ghost mini" onclick="copy(state.publicKey,'Public key copied')">Copy</button>
    </div>
    <div class="muted" style="margin-top:8px;font-size:12.5px">
      await FlutterPatcher.init(publicKeyBase64: '…');  then
      <code style="font-size:12px">checkAndStage('<span id="checkurl"></span>')</code>
      <button class="ghost mini" onclick="copy(location.origin+'/check','Check URL copied')">Copy URL</button>
    </div>
  </div>

  <div class="card">
    <h2>Rollout</h2>
    <div class="row" style="margin-bottom:14px">
      <label>Active patch <select id="active"></select></label>
      <label>Channel <input type="text" id="channel" placeholder="(stable)" size="9" /></label>
    </div>
    <div class="slider-wrap">
      <input type="range" id="rollout" min="0" max="100" value="100" />
      <span class="big"><span id="rollout-val">100</span><span style="font-size:15px">%</span></span>
    </div>
    <div class="row presets" style="margin-top:10px;justify-content:space-between">
      <span>
        <button class="mini" onclick="setRollout(1)">1%</button>
        <button class="mini" onclick="setRollout(10)">10%</button>
        <button class="mini" onclick="setRollout(50)">50%</button>
        <button class="mini" onclick="setRollout(100)">100%</button>
      </span>
      <button id="save-config">Apply</button>
    </div>
  </div>

  <div class="card">
    <h2>How to make a patch</h2>
    <ol style="margin:0;padding-left:18px;color:var(--muted);font-size:13px;line-height:1.9">
      <li>Edit your Dart, then <code>flutter build apk --release</code></li>
      <li>Pack (and optionally delta) it:
        <pre style="margin-top:6px">dart run flutter_patcher:pack \\
  --apk build/app/outputs/flutter-apk/app-release.apk \\
  --version 1.0.1-h1 --target-version-code &lt;vc&gt; --patch-number 1
# smaller delta vs your baseline:  --from-apk baseline.apk</pre>
      </li>
      <li>Upload <code>dist/patch.zip</code> + <code>dist/manifest.json</code> → make live → set rollout %.</li>
    </ol>
    <div class="muted" style="margin-top:8px;font-size:12.5px">First time? <code>dart run flutter_patcher:init --server <span id="self-url"></span> --public-key …</code> wires up your app.</div>
  </div>

  <div class="card">
    <h2>Upload a packed patch</h2>
    <div class="drop" id="drop">
      <div><b>Drop</b> patch.zip + manifest.json here</div>
      <div style="font-size:12px;margin-top:4px" id="drop-files">or click to choose · from <code>dart run flutter_patcher:pack</code></div>
    </div>
    <input type="file" id="files" accept=".zip,.json" multiple style="display:none" />
    <div class="row" style="margin-top:12px;justify-content:flex-end">
      <button id="upload" disabled>Upload</button>
    </div>
  </div>

  <div class="card wide">
    <h2>Patches</h2>
    <table>
      <thead><tr><th>version</th><th>#</th><th>targetVc</th><th>abis</th><th>sha256</th><th>state</th><th></th></tr></thead>
      <tbody id="patches"></tbody>
    </table>
  </div>

  <div class="card">
    <h2>What the device sees · /check</h2>
    <pre id="check">…</pre>
  </div>

  <div class="card">
    <h2>Telemetry · last 50</h2>
    <div id="telemetry"><div class="empty">No events yet.<br/>Wire <code>init(onEvent:)</code> → POST /api/telemetry.</div></div>
  </div>
</main>
<div class="toast" id="toast"></div>
<script>
const $ = (id) => document.getElementById(id);
let state = { publicKey:'', patches:[], config:{}, telemetry:[] };
let dirtyRollout = false; // don't stomp the slider while the user drags

async function api(path, opts) {
  const r = await fetch(path, opts);
  if (!r.ok && r.headers.get('content-type')?.includes('json')) { const j = await r.json(); throw new Error(j.error || r.statusText); }
  return r.headers.get('content-type')?.includes('json') ? r.json() : r.text();
}
function toast(msg, err) {
  const t = $('toast'); t.textContent = msg; t.className = 'toast show' + (err ? ' err' : '');
  clearTimeout(t._t); t._t = setTimeout(() => t.className = 'toast', 2600);
}
function copy(txt, msg) { navigator.clipboard.writeText(txt).then(() => toast(msg)); }
function rel(ts){ const s=(Date.now()-ts)/1000; if(s<60)return Math.floor(s)+'s ago'; if(s<3600)return Math.floor(s/60)+'m ago'; return Math.floor(s/3600)+'h ago'; }

async function refresh() {
  let s;
  try { s = await api('/api/state'); $('dot').className = 'dot'; }
  catch { $('dot').className = 'dot off'; $('refresh').textContent = 'offline'; return; }
  state = s;
  $('refresh').textContent = 'updated ' + new Date().toLocaleTimeString();
  $('pubkey').textContent = s.publicKey;
  $('checkurl').textContent = location.origin + '/check';
  const su = $('self-url'); if (su) su.textContent = location.origin;

  // header summary
  const active = s.patches.find(p => p.version === s.config.activeVersion);
  $('hsum').innerHTML =
    'active <b>' + (active ? active.version + ' · #' + active.patchNumber : '—') + '</b>' +
    '<span>rollout <b>' + s.config.rolloutPercent + '%</b>' + (s.config.channel ? ' · ' + s.config.channel : '') + '</span>' +
    '<span>killed <b>' + s.config.killed.length + '</b></span>' +
    '<span>patches <b>' + s.patches.length + '</b></span>';

  // active select
  const sel = $('active');
  sel.innerHTML = '<option value="">(none)</option>' +
    s.patches.map(p => '<option value="'+p.version+'">'+p.version+' (#'+p.patchNumber+')</option>').join('');
  sel.value = s.config.activeVersion || '';
  $('channel').value = s.config.channel || '';
  if (!dirtyRollout) { $('rollout').value = s.config.rolloutPercent; $('rollout-val').textContent = s.config.rolloutPercent; }

  // patches
  $('patches').innerHTML = s.patches.length ? s.patches.map(p => {
    const live = p.version === s.config.activeVersion;
    const killed = s.config.killed.includes(p.patchNumber);
    const st = killed ? '<span class="pill killed">killed</span>' : live ? '<span class="pill live">live</span>' : '<span class="pill idle">idle</span>';
    const kb = killed
      ? '<button class="ghost mini" onclick="unkill('+p.patchNumber+')">un-kill</button>'
      : '<button class="danger mini" onclick="kill('+p.patchNumber+',\\''+p.version+'\\')">kill</button>';
    const act = live ? '' : '<button class="ghost mini" onclick="activate(\\''+p.version+'\\')">make live</button> ';
    return '<tr><td><b>'+p.version+'</b></td><td>'+p.patchNumber+'</td><td>'+p.targetVersionCode+'</td><td>'+(p.abis||[]).join(', ')+'</td><td><code>'+p.sha256.slice(0,12)+'…</code></td><td>'+st+'</td><td style="text-align:right;white-space:nowrap">'+act+kb+'</td></tr>';
  }).join('') : '<tr><td colspan="7"><div class="empty">No patches yet — pack one and upload it below.</div></td></tr>';

  // telemetry
  $('telemetry').innerHTML = s.telemetry.length ? '<table class="tele"><tbody>' + s.telemetry.map(t => {
    const e = t.event || {}; const type = (e.type||'event').replace('PatchEventType.','');
    return '<tr><td style="white-space:nowrap;color:var(--muted)">'+rel(t.at)+'</td><td><span class="chip '+type+'">'+type+'</span></td><td><code style="font-size:11.5px">'+JSON.stringify(e).slice(0,90)+'</code></td></tr>';
  }).join('') + '</tbody></table>' : '<div class="empty">No events yet.<br/>Wire <code>init(onEvent:)</code> → POST /api/telemetry.</div>';

  try { $('check').textContent = JSON.stringify(await api('/check'), null, 2); } catch {}
}

function setRollout(v){ dirtyRollout=true; $('rollout').value=v; $('rollout-val').textContent=v; }
$('rollout').addEventListener('input', e => { dirtyRollout=true; $('rollout-val').textContent = e.target.value; });
$('save-config').onclick = async () => {
  try {
    await api('/api/config', { method:'POST', headers:{'content-type':'application/json'},
      body: JSON.stringify({ activeVersion: $('active').value || null, rolloutPercent: +$('rollout').value, channel: $('channel').value }) });
    dirtyRollout=false; toast('Rollout applied'); refresh();
  } catch(e){ toast(e.message, true); }
};
$('active').onchange = () => $('save-config').click();
window.activate = (v) => { $('active').value = v; $('save-config').click(); };
window.kill = async (n, v) => { if(!confirm('Kill '+v+' (#'+n+')? Devices revert to the built-in build on next check.')) return; await setKilled([...new Set([...state.config.killed, n])]); toast('Killed #'+n); };
window.unkill = async (n) => { await setKilled(state.config.killed.filter(x=>x!==n)); toast('Un-killed #'+n); };
async function setKilled(killed){ try { await api('/api/kill',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({killed})}); refresh(); } catch(e){ toast(e.message,true); } }

// upload (file picker + drag-drop)
const drop = $('drop'), filesInput = $('files');
let picked = [];
function showPicked(){ $('drop-files').innerHTML = picked.length ? picked.map(f=>'<code>'+f.name+'</code>').join(' + ') : 'or click to choose'; $('upload').disabled = picked.length < 2; }
drop.onclick = () => filesInput.click();
filesInput.onchange = () => { picked = [...filesInput.files]; showPicked(); };
['dragover','dragenter'].forEach(ev => drop.addEventListener(ev, e => { e.preventDefault(); drop.classList.add('over'); }));
['dragleave','drop'].forEach(ev => drop.addEventListener(ev, e => { e.preventDefault(); drop.classList.remove('over'); }));
drop.addEventListener('drop', e => { picked = [...e.dataTransfer.files]; showPicked(); });
$('upload').onclick = async () => {
  const zip = picked.find(f=>f.name.endsWith('.zip')); const man = picked.find(f=>f.name.endsWith('.json'));
  if(!zip||!man){ toast('Need a .zip and a .json', true); return; }
  const fd = new FormData(); fd.append('patchzip', zip); fd.append('manifest', man);
  try { const r = await api('/api/patches',{method:'POST',body:fd}); picked=[]; showPicked(); filesInput.value=''; toast('Uploaded '+r.patch.version); refresh(); }
  catch(e){ toast(e.message, true); }
};

refresh();
setInterval(() => { if(document.visibilityState==='visible') refresh(); }, 5000);
</script>
</body>
</html>`;
}
