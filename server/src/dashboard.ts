export function dashboardHtml(): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>flutter_patcher · console</title>
<style>
  :root {
    color-scheme: dark;
    --bg:#0b0d12; --panel:#14181f; --panel2:#1a1f29; --line:#242b38;
    --txt:#e8ebf1; --muted:#8a93a3; --faint:#5c6473;
    --accent:#5b8cff; --accent2:#7aa2ff; --good:#22c55e; --warn:#f59e0b; --bad:#ef4444;
    --radius:14px; --nav:218px;
  }
  * { box-sizing:border-box; }
  html,body { height:100%; }
  body { margin:0; font:14px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif; background:var(--bg); color:var(--txt); }
  a { color:var(--accent2); text-decoration:none; }
  a:hover { text-decoration:underline; }
  code,pre { font-family:ui-monospace,"SF Mono",Menlo,monospace; }
  .layout { display:grid; grid-template-columns:var(--nav) 1fr; min-height:100vh; }

  /* sidebar */
  aside { background:#0d1016; border-right:1px solid var(--line); padding:18px 14px; display:flex; flex-direction:column; gap:6px; position:sticky; top:0; height:100vh; }
  .brand { display:flex; align-items:center; gap:10px; padding:6px 8px 16px; }
  .brand svg { flex:0 0 auto; }
  .brand .bt { font-weight:680; font-size:15px; letter-spacing:.01em; line-height:1.1; }
  .brand .bs { font-size:11px; color:var(--muted); }
  nav { display:flex; flex-direction:column; gap:2px; }
  .navi { display:flex; align-items:center; gap:11px; padding:9px 11px; border-radius:9px; color:var(--muted); cursor:pointer; font-weight:550; font-size:13.5px; border:1px solid transparent; user-select:none; }
  .navi:hover { background:var(--panel); color:var(--txt); }
  .navi.on { background:rgba(91,140,255,.12); color:var(--accent2); border-color:rgba(91,140,255,.25); }
  .navi svg { opacity:.85; }
  .navi .cnt { margin-left:auto; font-size:11px; color:var(--faint); background:var(--panel2); border-radius:999px; padding:1px 7px; }
  aside .foot { margin-top:auto; padding:10px 8px 2px; border-top:1px solid var(--line); color:var(--faint); font-size:11.5px; display:flex; align-items:center; gap:8px; }
  .dot { width:8px; height:8px; border-radius:50%; background:var(--good); box-shadow:0 0 0 3px rgba(34,197,94,.16); flex:0 0 auto; }
  .dot.off { background:var(--bad); box-shadow:0 0 0 3px rgba(239,68,68,.16); }

  /* main */
  main { padding:26px 30px 40px; max-width:1100px; }
  .page-h { display:flex; align-items:flex-end; gap:14px; margin-bottom:22px; flex-wrap:wrap; }
  .page-h h1 { font-size:21px; font-weight:670; margin:0; letter-spacing:-.01em; }
  .page-h .sub { color:var(--muted); font-size:13px; padding-bottom:2px; }
  .page-h .spacer { flex:1; }
  .topchip { display:flex; align-items:center; gap:8px; background:var(--panel); border:1px solid var(--line); border-radius:999px; padding:5px 12px; font-size:12.5px; color:var(--muted); }
  .topchip b { color:var(--txt); font-weight:620; }

  .view { display:none; }
  .view.on { display:block; }

  /* cards & grid */
  .grid { display:grid; gap:16px; }
  .metrics { grid-template-columns:repeat(auto-fill,minmax(168px,1fr)); }
  .cols2 { grid-template-columns:1fr 1fr; }
  @media (max-width:820px){ .cols2 { grid-template-columns:1fr; } .layout { grid-template-columns:1fr; } aside { position:static; height:auto; flex-direction:row; flex-wrap:wrap; } aside .foot { margin:0; border:0; } nav { flex-direction:row; flex-wrap:wrap; } }
  .card { background:var(--panel); border:1px solid var(--line); border-radius:var(--radius); padding:18px 20px; }
  .card h2 { font-size:11px; text-transform:uppercase; letter-spacing:.08em; color:var(--muted); margin:0 0 14px; font-weight:680; }
  .metric { background:var(--panel); border:1px solid var(--line); border-radius:var(--radius); padding:15px 17px; }
  .metric .k { font-size:11px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); font-weight:650; }
  .metric .v { font-size:27px; font-weight:730; margin-top:7px; font-variant-numeric:tabular-nums; letter-spacing:-.01em; }
  .metric .v small { font-size:14px; color:var(--muted); font-weight:600; }
  .metric .d { font-size:12px; color:var(--faint); margin-top:3px; }
  .metric.accent .v { color:var(--accent2); }
  .metric.good .v { color:#5fd68a; }
  .metric.bad .v { color:#f08c8c; }

  pre { background:#070a0e; border:1px solid var(--line); border-radius:10px; padding:13px; overflow:auto; white-space:pre-wrap; word-break:break-all; margin:0; font-size:12.5px; color:#cdd5e2; }
  table { width:100%; border-collapse:collapse; }
  th,td { text-align:left; padding:10px 11px; border-bottom:1px solid var(--line); vertical-align:middle; }
  th { color:var(--muted); font-weight:620; font-size:11px; text-transform:uppercase; letter-spacing:.05em; }
  tbody tr:hover { background:rgba(255,255,255,.015); }
  tr:last-child td { border-bottom:0; }
  .pill { display:inline-block; padding:2px 9px; border-radius:999px; font-size:11.5px; font-weight:620; background:var(--panel2); color:var(--muted); }
  .pill.live { background:rgba(34,197,94,.16); color:#7ee2a8; }
  .pill.killed { background:rgba(239,68,68,.16); color:#fca5a5; }
  .pill.idle { background:var(--panel2); color:var(--muted); }
  button { background:var(--accent); color:#fff; border:0; border-radius:9px; padding:8px 14px; cursor:pointer; font-size:13px; font-weight:580; transition:filter .12s; }
  button:hover { filter:brightness(1.12); }
  button:active { filter:brightness(.95); }
  button:disabled { opacity:.5; cursor:not-allowed; filter:none; }
  button.ghost { background:var(--panel2); color:var(--txt); border:1px solid var(--line); }
  button.danger { background:rgba(239,68,68,.14); color:#fca5a5; }
  button.danger:hover { background:var(--bad); color:#fff; }
  button.mini { padding:4px 10px; font-size:12px; }
  input[type=text],input[type=number],select { background:#070a0e; border:1px solid var(--line); color:var(--txt); border-radius:8px; padding:8px 10px; font-size:13px; }
  select { min-width:210px; }
  label { display:inline-flex; align-items:center; gap:8px; color:var(--muted); }
  .row { display:flex; flex-wrap:wrap; gap:14px; align-items:center; }
  .keyrow { display:flex; gap:8px; align-items:center; }
  .keyrow code { flex:1; background:#070a0e; border:1px solid var(--line); border-radius:8px; padding:9px 11px; font-size:12px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .slider-wrap { display:flex; align-items:center; gap:16px; width:100%; }
  input[type=range]{ flex:1; accent-color:var(--accent); }
  .big { font-size:30px; font-weight:740; font-variant-numeric:tabular-nums; min-width:96px; text-align:right; }
  .big small { font-size:16px; }
  .presets button { background:var(--panel2); color:var(--muted); border:1px solid var(--line); }
  .presets button:hover { color:var(--txt); }
  .bar { height:8px; border-radius:999px; background:var(--panel2); overflow:hidden; margin-top:12px; }
  .bar > i { display:block; height:100%; background:linear-gradient(90deg,var(--accent),var(--accent2)); }
  .drop { border:1.5px dashed var(--line); border-radius:11px; padding:22px; text-align:center; color:var(--muted); transition:.15s; cursor:pointer; }
  .drop.over { border-color:var(--accent); background:rgba(91,140,255,.06); color:var(--txt); }
  .empty { color:var(--muted); text-align:center; padding:22px; }
  .toast { position:fixed; bottom:22px; right:22px; background:var(--panel2); border:1px solid var(--line); border-left:3px solid var(--accent); padding:11px 16px; border-radius:10px; box-shadow:0 10px 36px rgba(0,0,0,.45); opacity:0; transform:translateY(8px); transition:.2s; z-index:30; max-width:380px; }
  .toast.show { opacity:1; transform:none; }
  .toast.err { border-left-color:var(--bad); }
  .feed { display:flex; flex-direction:column; gap:0; }
  .feed .ev { display:flex; align-items:center; gap:11px; padding:9px 2px; border-bottom:1px solid var(--line); font-size:13px; }
  .feed .ev:last-child { border-bottom:0; }
  .feed .ev .t { color:var(--faint); font-size:11.5px; white-space:nowrap; min-width:62px; }
  .chip { font-size:11px; padding:2px 8px; border-radius:7px; background:var(--panel2); color:var(--muted); font-weight:580; white-space:nowrap; }
  .chip.staged { background:rgba(34,197,94,.16); color:#7ee2a8; }
  .chip.applyFinished { background:rgba(91,140,255,.16); color:#a9c2ff; }
  .chip.applyStarted { background:rgba(91,140,255,.10); color:#8aa6e8; }
  .chip.boot { background:rgba(245,158,11,.16); color:#fcd34d; }
  .chip.fail { background:rgba(239,68,68,.16); color:#fca5a5; }
  .filters { display:flex; gap:6px; flex-wrap:wrap; margin-bottom:12px; }
  .filters .f { font-size:12px; padding:5px 11px; border-radius:999px; background:var(--panel2); border:1px solid var(--line); color:var(--muted); cursor:pointer; }
  .filters .f.on { background:rgba(91,140,255,.14); color:var(--accent2); border-color:rgba(91,140,255,.3); }
  .muted { color:var(--muted); }
  .adopt { display:flex; align-items:center; gap:8px; min-width:120px; }
  .adopt .ab { height:6px; flex:1; border-radius:999px; background:var(--panel2); overflow:hidden; }
  .adopt .ab > i { display:block; height:100%; background:var(--accent); }
  .adopt .an { font-variant-numeric:tabular-nums; color:var(--muted); font-size:12px; min-width:26px; text-align:right; }
  ol.steps { margin:0; padding-left:18px; color:var(--muted); font-size:13px; line-height:1.95; }
  ol.steps code { color:var(--txt); }
</style>
</head>
<body>
<div class="layout">
  <aside>
    <div class="brand">
      <svg width="26" height="26" viewBox="0 0 24 24" fill="none"><path d="M12 2l8.66 5v10L12 22l-8.66-5V7L12 2z" stroke="#5b8cff" stroke-width="1.6" stroke-linejoin="round"/><path d="M12 7l4.33 2.5v5L12 17l-4.33-2.5v-5L12 7z" fill="#5b8cff" fill-opacity=".25" stroke="#7aa2ff" stroke-width="1.2" stroke-linejoin="round"/></svg>
      <div><div class="bt">flutter_patcher</div><div class="bs">console</div></div>
    </div>
    <nav>
      <div class="navi on" data-view="overview" onclick="go('overview')">${icon('grid')}<span>Overview</span></div>
      <div class="navi" data-view="patches" onclick="go('patches')">${icon('layers')}<span>Patches</span><span class="cnt" id="nav-patches">0</span></div>
      <div class="navi" data-view="telemetry" onclick="go('telemetry')">${icon('activity')}<span>Telemetry</span><span class="cnt" id="nav-tele">0</span></div>
      <div class="navi" data-view="settings" onclick="go('settings')">${icon('cog')}<span>Settings</span></div>
    </nav>
    <div class="foot"><span class="dot" id="dot"></span><span id="status">connecting…</span></div>
  </aside>

  <main>
    <!-- OVERVIEW -->
    <section class="view on" id="view-overview">
      <div class="page-h">
        <h1>Overview</h1>
        <div class="sub">live rollout &amp; device activity</div>
        <div class="spacer"></div>
        <div class="topchip">active <b id="chip-active">—</b></div>
      </div>

      <div class="grid metrics" id="metrics" style="margin-bottom:16px"></div>

      <div class="grid cols2">
        <div class="card">
          <h2>Live rollout</h2>
          <div class="row" style="margin-bottom:14px">
            <label>Patch <select id="active"></select></label>
            <label>Channel <input type="text" id="channel" placeholder="(stable)" size="9" /></label>
          </div>
          <div class="slider-wrap">
            <input type="range" id="rollout" min="0" max="100" value="100" />
            <span class="big"><span id="rollout-val">100</span><small>%</small></span>
          </div>
          <div class="row presets" style="margin-top:12px;justify-content:space-between">
            <span>
              <button class="mini" onclick="setRollout(1)">1%</button>
              <button class="mini" onclick="setRollout(10)">10%</button>
              <button class="mini" onclick="setRollout(50)">50%</button>
              <button class="mini" onclick="setRollout(100)">100%</button>
            </span>
            <button id="save-config">Apply rollout</button>
          </div>
        </div>

        <div class="card">
          <h2>Recent activity</h2>
          <div class="feed" id="feed"><div class="empty">No device events yet.</div></div>
        </div>
      </div>
    </section>

    <!-- PATCHES -->
    <section class="view" id="view-patches">
      <div class="page-h"><h1>Patches</h1><div class="sub">upload, stage, roll back</div></div>

      <div class="card" style="margin-bottom:16px">
        <h2>Upload a packed patch</h2>
        <div class="drop" id="drop">
          <div><b>Drop</b> patch.zip + manifest.json here</div>
          <div style="font-size:12px;margin-top:5px" id="drop-files">or click to choose · from <code>dart run flutter_patcher:pack</code></div>
        </div>
        <input type="file" id="files" accept=".zip,.json" multiple style="display:none" />
        <div class="row" style="margin-top:12px;justify-content:space-between">
          <span class="muted" style="font-size:12.5px">First time? <code>dart run flutter_patcher:init --server <span id="self-url"></span> --public-key …</code></span>
          <button id="upload" disabled>Upload</button>
        </div>
      </div>

      <div class="card">
        <h2>All patches</h2>
        <table>
          <thead><tr><th>version</th><th>#</th><th>target vc</th><th>abis</th><th>applies</th><th>uploaded</th><th>state</th><th></th></tr></thead>
          <tbody id="patches"></tbody>
        </table>
      </div>
    </section>

    <!-- TELEMETRY -->
    <section class="view" id="view-telemetry">
      <div class="page-h"><h1>Telemetry</h1><div class="sub">last 50 events the devices reported</div></div>
      <div class="card">
        <div class="filters" id="filters"></div>
        <div id="telemetry"><div class="empty">No events yet.<br/>Wire <code>init(onEvent:)</code> → POST /api/telemetry.</div></div>
      </div>
    </section>

    <!-- SETTINGS -->
    <section class="view" id="view-settings">
      <div class="page-h"><h1>Settings</h1><div class="sub">keys, endpoints, kill switch</div></div>

      <div class="card" style="margin-bottom:16px">
        <h2>Signing key — paste into the app</h2>
        <div class="keyrow">
          <code id="pubkey">…</code>
          <button class="ghost mini" onclick="copy(state.publicKey,'Public key copied')">Copy</button>
        </div>
        <div class="muted" style="margin-top:10px;font-size:12.5px">
          <code>FlutterPatcher.init(publicKeyBase64: '…')</code> then
          <code>checkAndStage('<span id="checkurl"></span>')</code>
          <button class="ghost mini" onclick="copy(location.origin+'/check','Check URL copied')">Copy URL</button>
        </div>
      </div>

      <div class="grid cols2">
        <div class="card">
          <h2>Make a patch</h2>
          <ol class="steps">
            <li>Edit Dart, then <code>flutter build apk --release</code></li>
            <li>Pack it:
              <pre style="margin-top:6px">dart run flutter_patcher:pack \\
  --apk build/app/outputs/flutter-apk/app-release.apk \\
  --version 1.0.1-h1 --target-version-code &lt;vc&gt; --patch-number 1
# smaller delta vs baseline:  --from-apk baseline.apk</pre>
            </li>
            <li>Upload on the <b>Patches</b> tab → make live → set rollout %.</li>
          </ol>
        </div>

        <div class="card">
          <h2>Kill switch</h2>
          <div class="muted" style="font-size:12.5px;margin-bottom:12px">Killed patches are removed from <code>/check</code> and signed into the rollback list. Devices revert to the built-in build on their next check.</div>
          <div id="killed"><div class="empty">Nothing killed.</div></div>
        </div>
      </div>
    </section>
  </main>
</div>
<div class="toast" id="toast"></div>
<script>
const $ = (id) => document.getElementById(id);
let state = { publicKey:'', patches:[], config:{ killed:[] }, telemetry:[] };
let dirtyRollout = false;      // don't stomp the slider while the user drags
let teleFilter = 'all';
const DAY = 86400000;

async function api(path, opts) {
  const r = await fetch(path, opts);
  const isJson = (r.headers.get('content-type')||'').indexOf('json') >= 0;
  if (!r.ok && isJson) { const j = await r.json(); throw new Error(j.error || r.statusText); }
  return isJson ? r.json() : r.text();
}
function toast(msg, err) {
  const t = $('toast'); t.textContent = msg; t.className = 'toast show' + (err ? ' err' : '');
  clearTimeout(t._t); t._t = setTimeout(function(){ t.className = 'toast'; }, 2600);
}
function copy(txt, msg) { navigator.clipboard.writeText(txt).then(function(){ toast(msg); }); }
function esc(s){ return String(s).replace(/[&<>"]/g, function(c){ return ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'})[c]; }); }
function rel(ts){ const s=(Date.now()-ts)/1000; if(s<60)return Math.floor(s)+'s ago'; if(s<3600)return Math.floor(s/60)+'m ago'; if(s<DAY/1000)return Math.floor(s/3600)+'h ago'; return Math.floor(s/3600/24)+'d ago'; }
function etype(e){ return String((e&&e.type)||'event').replace('PatchEventType.',''); }

function go(v){
  document.querySelectorAll('.navi').forEach(function(n){ n.classList.toggle('on', n.dataset.view===v); });
  document.querySelectorAll('.view').forEach(function(s){ s.classList.toggle('on', s.id==='view-'+v); });
  location.hash = v;
}
window.go = go;

// applies (ok applyFinished) per patchNumber, from telemetry
function adoption(tel){
  const m = {};
  tel.forEach(function(t){ const e=t.event||{}; if(etype(e)==='applyFinished' && e.ok && e.patchNumber!=null){ m[e.patchNumber]=(m[e.patchNumber]||0)+1; } });
  return m;
}

function renderMetrics(s){
  const active = s.patches.find(function(p){ return p.version === s.config.activeVersion; });
  const since = Date.now() - DAY;
  let ap24=0, fail24=0, staged24=0;
  s.telemetry.forEach(function(t){ if(t.at<since) return; const e=t.event||{}; const ty=etype(e);
    if(ty==='applyFinished'){ if(e.ok) ap24++; else fail24++; } if(ty==='staged') staged24++; });
  $('chip-active').textContent = active ? active.version + ' · #' + active.patchNumber : 'none';
  const cards = [
    ['Active patch', active ? esc(active.version) : '—', active ? '#'+active.patchNumber+' · vc '+active.targetVersionCode : 'nothing live', 'accent'],
    ['Rollout', s.config.rolloutPercent + '<small>%</small>', s.config.channel ? 'channel '+esc(s.config.channel) : 'all devices', ''],
    ['Patches', String(s.patches.length), s.config.killed.length+' killed', ''],
    ['Applies 24h', String(ap24), staged24+' staged', 'good'],
    ['Failures 24h', String(fail24), fail24 ? 'check telemetry' : 'all clear', fail24 ? 'bad' : ''],
  ];
  $('metrics').innerHTML = cards.map(function(c){
    return '<div class="metric '+c[3]+'"><div class="k">'+c[0]+'</div><div class="v">'+c[1]+'</div><div class="d">'+c[2]+'</div></div>';
  }).join('');
}

function renderFeed(s){
  const items = s.telemetry.slice(0, 8);
  $('feed').innerHTML = items.length ? items.map(function(t){
    const e=t.event||{}; const ty=etype(e); const cls = (ty==='applyFinished' && e.ok===false) ? 'fail' : ty;
    const label = (ty==='applyFinished' && e.ok===false) ? 'apply failed' : ty;
    const detail = (e.version ? esc(e.version) : '') + (e.patchNumber!=null ? ' #'+e.patchNumber : '') + (e.error ? ' · '+esc(e.error) : '');
    return '<div class="ev"><span class="t">'+rel(t.at)+'</span><span class="chip '+cls+'">'+label+'</span><span class="muted">'+(detail||'—')+'</span></div>';
  }).join('') : '<div class="empty">No device events yet.</div>';
}

function renderPatches(s){
  const adopt = adoption(s.telemetry);
  const maxA = Math.max(1, ...Object.values(adopt));
  $('nav-patches').textContent = s.patches.length;
  $('patches').innerHTML = s.patches.length ? s.patches.map(function(p){
    const live = p.version === s.config.activeVersion;
    const killed = s.config.killed.indexOf(p.patchNumber) >= 0;
    const st = killed ? '<span class="pill killed">killed</span>' : live ? '<span class="pill live">live</span>' : '<span class="pill idle">idle</span>';
    const kb = killed
      ? '<button class="ghost mini" onclick="unkill('+p.patchNumber+')">un-kill</button>'
      : '<button class="danger mini" onclick="kill('+p.patchNumber+',\\''+esc(p.version)+'\\')">kill</button>';
    const act = live ? '' : '<button class="ghost mini" onclick="activate(\\''+esc(p.version)+'\\')">make live</button> ';
    const dl = '<a class="muted" href="/payload/'+encodeURIComponent(p.version)+'" title="download patch.zip">↓</a> ';
    const a = adopt[p.patchNumber]||0;
    const ad = '<div class="adopt"><span class="ab"><i style="width:'+Math.round(a/maxA*100)+'%"></i></span><span class="an">'+a+'</span></div>';
    return '<tr><td><b>'+esc(p.version)+'</b></td><td>'+p.patchNumber+'</td><td>'+p.targetVersionCode+'</td><td class="muted">'+(p.abis||[]).join(', ')+'</td><td>'+ad+'</td><td class="muted">'+(p.uploadedAt?rel(p.uploadedAt):'—')+'</td><td>'+st+'</td><td style="text-align:right;white-space:nowrap">'+dl+act+kb+'</td></tr>';
  }).join('') : '<tr><td colspan="8"><div class="empty">No patches yet — pack one and upload it above.</div></td></tr>';
}

function renderTelemetry(s){
  $('nav-tele').textContent = s.telemetry.length;
  const types = ['all','applyFinished','staged','boot','applyStarted'];
  $('filters').innerHTML = types.map(function(f){
    const n = f==='all' ? s.telemetry.length : s.telemetry.filter(function(t){ return etype(t.event)===f; }).length;
    return '<span class="f '+(teleFilter===f?'on':'')+'" onclick="setFilter(\\''+f+'\\')">'+f+' ('+n+')</span>';
  }).join('');
  const rows = s.telemetry.filter(function(t){ return teleFilter==='all' || etype(t.event)===teleFilter; });
  $('telemetry').innerHTML = rows.length ? '<table><tbody>' + rows.map(function(t){
    const e=t.event||{}; const ty=etype(e); const cls=(ty==='applyFinished'&&e.ok===false)?'fail':ty;
    return '<tr><td style="white-space:nowrap;color:var(--faint);width:80px">'+rel(t.at)+'</td><td style="width:120px"><span class="chip '+cls+'">'+ty+'</span></td><td><code style="font-size:11.5px;color:#cdd5e2">'+esc(JSON.stringify(e).slice(0,120))+'</code></td></tr>';
  }).join('') + '</tbody></table>' : '<div class="empty">No matching events.</div>';
}
window.setFilter = function(f){ teleFilter=f; renderTelemetry(state); };

function renderSettings(s){
  $('pubkey').textContent = s.publicKey;
  $('checkurl').textContent = location.origin + '/check';
  const su = $('self-url'); if (su) su.textContent = location.origin;
  $('killed').innerHTML = s.config.killed.length ? s.config.killed.slice().sort(function(a,b){return a-b;}).map(function(n){
    return '<div class="row" style="justify-content:space-between;border-bottom:1px solid var(--line);padding:8px 0"><span>patch <b>#'+n+'</b></span><button class="ghost mini" onclick="unkill('+n+')">un-kill</button></div>';
  }).join('') : '<div class="empty">Nothing killed.</div>';
}

async function refresh() {
  let s;
  try { s = await api('/api/state'); $('dot').className='dot'; $('status').textContent='online · '+new Date().toLocaleTimeString(); }
  catch { $('dot').className='dot off'; $('status').textContent='offline'; return; }
  if (!s.config) s.config = { killed:[] };
  if (!s.config.killed) s.config.killed = [];
  state = s;

  // rollout controls
  const sel = $('active');
  sel.innerHTML = '<option value="">(none)</option>' + s.patches.map(function(p){ return '<option value="'+esc(p.version)+'">'+esc(p.version)+' (#'+p.patchNumber+')</option>'; }).join('');
  sel.value = s.config.activeVersion || '';
  $('channel').value = s.config.channel || '';
  if (!dirtyRollout) { $('rollout').value = s.config.rolloutPercent; $('rollout-val').textContent = s.config.rolloutPercent; }

  renderMetrics(s); renderFeed(s); renderPatches(s); renderTelemetry(s); renderSettings(s);
}

function setRollout(v){ dirtyRollout=true; $('rollout').value=v; $('rollout-val').textContent=v; }
window.setRollout = setRollout;
$('rollout').addEventListener('input', function(e){ dirtyRollout=true; $('rollout-val').textContent = e.target.value; });
$('save-config').onclick = async function(){
  try {
    await api('/api/config', { method:'POST', headers:{'content-type':'application/json'},
      body: JSON.stringify({ activeVersion: $('active').value || null, rolloutPercent: +$('rollout').value, channel: $('channel').value }) });
    dirtyRollout=false; toast('Rollout applied'); refresh();
  } catch(e){ toast(e.message, true); }
};
$('active').onchange = function(){ $('save-config').click(); };
window.activate = function(v){ $('active').value = v; $('save-config').click(); };
window.kill = async function(n, v){ if(!confirm('Kill '+v+' (#'+n+')? Devices revert to the built-in build on next check.')) return; await setKilled([...new Set([...state.config.killed, n])]); toast('Killed #'+n); };
window.unkill = async function(n){ await setKilled(state.config.killed.filter(function(x){return x!==n;})); toast('Un-killed #'+n); };
async function setKilled(killed){ try { await api('/api/kill',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({killed:killed})}); refresh(); } catch(e){ toast(e.message,true); } }

// upload (file picker + drag-drop)
const drop = $('drop'), filesInput = $('files');
let picked = [];
function showPicked(){ $('drop-files').innerHTML = picked.length ? picked.map(function(f){return '<code>'+esc(f.name)+'</code>';}).join(' + ') : 'or click to choose'; $('upload').disabled = picked.length < 2; }
drop.onclick = function(){ filesInput.click(); };
filesInput.onchange = function(){ picked = [...filesInput.files]; showPicked(); };
['dragover','dragenter'].forEach(function(ev){ drop.addEventListener(ev, function(e){ e.preventDefault(); drop.classList.add('over'); }); });
['dragleave','drop'].forEach(function(ev){ drop.addEventListener(ev, function(e){ e.preventDefault(); drop.classList.remove('over'); }); });
drop.addEventListener('drop', function(e){ picked = [...e.dataTransfer.files]; showPicked(); });
$('upload').onclick = async function(){
  const zip = picked.find(function(f){return f.name.endsWith('.zip');}); const man = picked.find(function(f){return f.name.endsWith('.json');});
  if(!zip||!man){ toast('Need a .zip and a .json', true); return; }
  const fd = new FormData(); fd.append('patchzip', zip); fd.append('manifest', man);
  try { const r = await api('/api/patches',{method:'POST',body:fd}); picked=[]; showPicked(); filesInput.value=''; toast('Uploaded '+r.patch.version); refresh(); }
  catch(e){ toast(e.message, true); }
};

if (location.hash) go(location.hash.slice(1));
refresh();
setInterval(function(){ if(document.visibilityState==='visible') refresh(); }, 5000);
</script>
</body>
</html>`;
}

function icon(name: string): string {
  const p: Record<string, string> = {
    grid: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
    layers: '<path d="M12 3l9 5-9 5-9-5 9-5z"/><path d="M3 13l9 5 9-5"/>',
    activity: '<path d="M3 12h4l3 8 4-16 3 8h4"/>',
    cog: '<circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1l2-1.6-2-3.4-2.3 1a7 7 0 0 0-1.7-1l-.3-2.5h-4l-.3 2.5a7 7 0 0 0-1.7 1l-2.3-1-2 3.4 2 1.6a7 7 0 0 0 0 2l-2 1.6 2 3.4 2.3-1a7 7 0 0 0 1.7 1l.3 2.5h4l.3-2.5a7 7 0 0 0 1.7-1l2.3 1 2-3.4-2-1.6a7 7 0 0 0 .1-1z"/>',
  };
  return '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">' + (p[name] || '') + '</svg>';
}
