import { serve } from '@hono/node-server';
import { Hono }  from 'hono';
import { logger } from 'hono/logger';
import { pool } from './db.js';
import routes from './routes.js';
import { PRESETS, presetsByCategory } from './utils.js';

const app = new Hono();
app.use('*', logger());

// ── GUI Manager ──────────────────────────────────────────────────────────────
app.get('/', (c) => {
  const DATA_ROOT = process.env.DATA_ROOT || '/data/media';

  // Build preset option groups for the <select>
  const cats = presetsByCategory();
  const optGroups = Object.entries(cats).map(([cat, list]) => {
    const opts = list.map(p =>
      `<option value="${p.key}">${p.key} — ${p.width}×${p.height} ${p.aspectLabel} (${p.description})</option>`
    ).join('');
    return `<optgroup label="${cat.toUpperCase()}">${opts}</optgroup>`;
  }).join('');

  // Build quick-fire sidebar buttons from all presets
  const qfButtons = Object.entries(PRESETS).map(([key, p]) => {
    const cls = `q-${key.replace(/[^a-z0-9]/g, '-')}`;
    return `<button class="quick-btn ${cls}" onclick="quickFire('${key}')">
      <span class="qname">${key.toUpperCase()}</span>
      <span class="qres">${p.width}×${p.height}</span>
      <span class="qsub">${p.aspectLabel} · CRF${p.crf} · ${p.bitrate}k</span>
    </button>`;
  }).join('');

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FFmpeg Manager v2</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=Bebas+Neue&family=Inter:wght@300;400;500;600&display=swap" rel="stylesheet">
<style>
  :root {
    --bg:#080810;--panel:#0f0f1a;--panel2:#141422;--border:#1e1e32;--border2:#2a2a42;
    --accent:#e84d1c;--accent2:#ff7a45;--blue:#1e90ff;--green:#00c97a;
    --yellow:#f5c400;--red:#ff3b3b;--purple:#a060ff;
    --muted:#4a4a6a;--text:#d8d8f0;--text2:#9090b8;
    --mono:'Space Mono',monospace;--sans:'Inter',sans-serif;--display:'Bebas Neue',sans-serif;
  }
  *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
  html{font-size:14px}
  body{background:var(--bg);color:var(--text);font-family:var(--sans);min-height:100vh;
    display:grid;grid-template-rows:auto 1fr auto;grid-template-columns:280px 1fr;
    grid-template-areas:"header header" "sidebar main" "footer footer"}

  /* HEADER */
  header{grid-area:header;background:var(--panel);border-bottom:1px solid var(--border2);
    padding:.65rem 1.25rem;display:flex;align-items:center;gap:1rem}
  .logo{font-family:var(--display);font-size:1.75rem;letter-spacing:.06em;color:var(--accent2);line-height:1}
  .logo span{color:var(--muted)}
  .logo sub{font-size:.7rem;vertical-align:super;color:var(--accent);letter-spacing:.02em}
  .header-stats{display:flex;gap:.5rem;margin-left:auto;flex-wrap:wrap}
  .stat-chip{display:flex;align-items:center;gap:.35rem;background:var(--panel2);
    border:1px solid var(--border2);border-radius:5px;padding:.25rem .6rem;
    font-family:var(--mono);font-size:.65rem}
  .dot{width:6px;height:6px;border-radius:50%;background:var(--muted);flex-shrink:0;transition:background .3s}
  .dot.running{background:var(--yellow);box-shadow:0 0 5px var(--yellow);animation:pulse 1.4s infinite}
  .dot.done{background:var(--green)}.dot.failed{background:var(--red)}
  .dot.db-ok{background:var(--green)}.dot.db-err{background:var(--red)}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.35}}
  .header-btn{background:none;border:1px solid var(--border2);color:var(--text2);
    padding:.25rem .7rem;border-radius:5px;cursor:pointer;font-size:.7rem;
    font-family:var(--mono);transition:all .15s}
  .header-btn:hover{border-color:var(--accent2);color:var(--accent2)}

  /* SIDEBAR */
  aside{grid-area:sidebar;background:var(--panel);border-right:1px solid var(--border);
    overflow-y:auto;padding:1rem .85rem;display:flex;flex-direction:column;gap:1.25rem}
  .sidebar-label{font-family:var(--mono);font-size:.6rem;color:var(--muted);
    text-transform:uppercase;letter-spacing:.12em;margin-bottom:.5rem;padding-left:.2rem}
  .nav-item{display:flex;align-items:center;gap:.55rem;padding:.45rem .65rem;
    border-radius:5px;cursor:pointer;font-size:.78rem;color:var(--text2);transition:all .15s;margin-bottom:.15rem}
  .nav-item:hover{background:var(--panel2);color:var(--text)}
  .nav-item.active{background:var(--panel2);color:var(--accent2);border-left:2px solid var(--accent2)}
  .nav-icon{font-size:.95rem;width:1.1rem;text-align:center}

  /* Quick fire buttons */
  .qf-grid{display:flex;flex-direction:column;gap:.3rem;max-height:340px;overflow-y:auto}
  .quick-btn{background:var(--panel2);border:1px solid var(--border2);border-radius:7px;
    padding:.55rem .7rem;cursor:pointer;text-align:left;transition:all .18s;position:relative}
  .quick-btn:hover{border-color:var(--accent2);background:#1a1028;transform:translateX(2px)}
  .quick-btn.loading{opacity:.5;pointer-events:none}
  .quick-btn .qname{display:block;font-family:var(--display);font-size:1rem;letter-spacing:.04em;color:var(--text)}
  .quick-btn .qres{display:block;font-family:var(--mono);font-size:.58rem;color:var(--accent2)}
  .quick-btn .qsub{display:block;font-family:var(--mono);font-size:.56rem;color:var(--muted)}
  #quick-toast{font-family:var(--mono);font-size:.72rem;margin-top:.4rem;padding:.4rem .6rem;
    border-radius:5px;display:none;word-break:break-all}
  #quick-toast.success{background:rgba(0,201,122,.1);border:1px solid rgba(0,201,122,.3);color:var(--green);display:block}
  #quick-toast.error{background:rgba(255,59,59,.1);border:1px solid rgba(255,59,59,.3);color:var(--red);display:block}

  /* MAIN */
  main{grid-area:main;overflow-y:auto;padding:1.25rem;display:flex;flex-direction:column;gap:1rem}
  .card{background:var(--panel);border:1px solid var(--border2);border-radius:10px;padding:1.1rem 1.25rem}
  .card-title{font-family:var(--display);font-size:1.4rem;letter-spacing:.05em;
    display:flex;align-items:center;gap:.5rem;margin-bottom:.9rem}
  .badge{font-family:var(--mono);font-size:.58rem;background:var(--accent);
    color:#fff;padding:.12rem .35rem;border-radius:3px;letter-spacing:.05em}

  /* Form fields */
  .field-row{display:grid;gap:.65rem;margin-bottom:.65rem}
  .field-row.col2{grid-template-columns:1fr 1fr}
  .field-row.col3{grid-template-columns:1fr 1fr 1fr}
  .field-row.col1{grid-template-columns:1fr}
  label{display:block;font-size:.65rem;font-family:var(--mono);color:var(--muted);
    margin-bottom:.25rem;text-transform:uppercase;letter-spacing:.08em}
  input[type=text],select{width:100%;background:var(--panel2);border:1px solid var(--border2);
    border-radius:5px;color:var(--text);font-family:var(--mono);font-size:.75rem;
    padding:.45rem .65rem;outline:none;transition:border-color .15s}
  input[type=text]:focus,select:focus{border-color:var(--accent2)}
  select option,select optgroup{background:var(--panel2)}
  .thread-row{display:flex;align-items:center;gap:.5rem}
  .thread-row input[type=range]{flex:1;accent-color:var(--accent2);height:2px}
  .thread-val{font-family:var(--mono);font-size:.72rem;color:var(--accent2);min-width:1.2rem;text-align:right}
  .mode-pills{display:flex;gap:.35rem}
  .pill{flex:1;text-align:center;padding:.4rem;border-radius:5px;border:1px solid var(--border2);
    background:var(--panel2);cursor:pointer;font-size:.7rem;font-family:var(--mono);
    color:var(--text2);transition:all .15s}
  .pill.active{border-color:var(--blue);background:rgba(30,144,255,.1);color:var(--blue)}
  .launch-btn{width:100%;padding:.7rem;border-radius:7px;border:none;
    background:linear-gradient(135deg,var(--accent),var(--accent2));color:#fff;
    font-family:var(--display);font-size:1.2rem;letter-spacing:.08em;cursor:pointer;
    transition:all .2s;margin-top:.65rem}
  .launch-btn:hover{transform:translateY(-1px);box-shadow:0 5px 20px rgba(232,77,28,.35)}
  .launch-btn:disabled{opacity:.45;cursor:not-allowed;transform:none;box-shadow:none}
  .toast{margin-top:.65rem;padding:.5rem .8rem;border-radius:5px;font-family:var(--mono);
    font-size:.72rem;display:none;word-break:break-all}
  .toast.success{background:rgba(0,201,122,.1);border:1px solid rgba(0,201,122,.3);color:var(--green);display:block}
  .toast.error{background:rgba(255,59,59,.1);border:1px solid rgba(255,59,59,.3);color:var(--red);display:block}

  /* Tables */
  .section-header{display:flex;align-items:center;justify-content:space-between;margin-bottom:.65rem}
  .section-title{font-family:var(--display);font-size:1.25rem;letter-spacing:.05em}
  .refresh-btn{background:none;border:1px solid var(--border2);color:var(--muted);
    padding:.2rem .55rem;border-radius:5px;cursor:pointer;font-size:.7rem;font-family:var(--mono);transition:all .15s}
  .refresh-btn:hover{border-color:var(--accent2);color:var(--accent2)}
  .filter-row{display:flex;gap:.35rem;margin-bottom:.65rem;flex-wrap:wrap}
  .filter-pill{padding:.2rem .6rem;border-radius:18px;border:1px solid var(--border2);
    background:none;color:var(--text2);cursor:pointer;font-size:.68rem;font-family:var(--mono);transition:all .15s}
  .filter-pill:hover{border-color:var(--text2)}
  .filter-pill.active{background:var(--panel2);border-color:var(--accent2);color:var(--accent2)}
  table{width:100%;border-collapse:collapse}
  thead th{font-family:var(--mono);font-size:.62rem;color:var(--muted);text-transform:uppercase;
    letter-spacing:.1em;padding:.45rem .65rem;text-align:left;border-bottom:1px solid var(--border)}
  tbody tr{border-bottom:1px solid var(--border);cursor:pointer;transition:background .1s}
  tbody tr:hover{background:var(--panel2)}
  tbody td{padding:.5rem .65rem;font-size:.74rem;font-family:var(--mono)}
  .status-badge{display:inline-flex;align-items:center;gap:.25rem;padding:.12rem .45rem;
    border-radius:18px;font-size:.62rem;font-weight:600}
  .status-badge.running{background:rgba(245,196,0,.1);color:var(--yellow);border:1px solid rgba(245,196,0,.3)}
  .status-badge.done{background:rgba(0,201,122,.1);color:var(--green);border:1px solid rgba(0,201,122,.3)}
  .status-badge.failed{background:rgba(255,59,59,.1);color:var(--red);border:1px solid rgba(255,59,59,.3)}
  .status-badge.skipped{background:rgba(74,74,106,.1);color:var(--muted);border:1px solid var(--border2)}
  .status-badge.pending{background:rgba(30,144,255,.1);color:var(--blue);border:1px solid rgba(30,144,255,.3)}
  .empty-state{text-align:center;padding:2.5rem;color:var(--muted);font-family:var(--mono);font-size:.78rem}

  /* Drawer */
  .drawer-overlay{position:fixed;inset:0;background:rgba(8,8,16,.7);backdrop-filter:blur(4px);
    z-index:100;display:none;align-items:stretch;justify-content:flex-end}
  .drawer-overlay.open{display:flex}
  .drawer{width:min(620px,95vw);background:var(--panel);border-left:1px solid var(--border2);
    overflow-y:auto;padding:1.25rem;animation:slideIn .2s ease}
  @keyframes slideIn{from{transform:translateX(35px);opacity:0}to{transform:none;opacity:1}}
  .drawer-close{float:right;background:none;border:1px solid var(--border2);color:var(--text2);
    padding:.25rem .6rem;border-radius:5px;cursor:pointer;font-family:var(--mono);font-size:.7rem;margin-bottom:.85rem}
  .drawer-close:hover{border-color:var(--red);color:var(--red)}
  .detail-grid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:.45rem;margin:.85rem 0}
  .detail-cell{background:var(--panel2);border:1px solid var(--border);border-radius:5px;padding:.55rem .7rem}
  .dc-label{font-size:.58rem;font-family:var(--mono);color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin-bottom:.15rem}
  .dc-val{font-family:var(--mono);font-size:.78rem;color:var(--text)}
  .log-list{max-height:260px;overflow-y:auto;margin-top:.4rem}
  .log-entry{display:flex;gap:.5rem;padding:.3rem 0;border-bottom:1px solid var(--border);
    font-family:var(--mono);font-size:.65rem;align-items:flex-start}
  .log-level{flex-shrink:0;padding:.08rem .3rem;border-radius:3px;font-size:.58rem;
    font-weight:700;min-width:34px;text-align:center}
  .log-level.info{background:rgba(30,144,255,.15);color:var(--blue)}
  .log-level.warn{background:rgba(245,196,0,.15);color:var(--yellow)}
  .log-level.error{background:rgba(255,59,59,.15);color:var(--red)}
  .log-level.debug{background:rgba(74,74,106,.15);color:var(--muted)}
  .log-msg{color:var(--text2);flex:1;word-break:break-word}
  .log-time{color:var(--muted);flex-shrink:0;font-size:.58rem}

  /* Footer */
  footer{grid-area:footer;background:var(--panel);border-top:1px solid var(--border);
    padding:.35rem 1.25rem;display:flex;align-items:center;gap:.85rem;
    font-size:.62rem;font-family:var(--mono);color:var(--muted)}
  .footer-spacer{flex:1}
  #auto-refresh-toggle{accent-color:var(--accent2);cursor:pointer}
  .scrollbar-thin::-webkit-scrollbar{width:3px}
  .scrollbar-thin::-webkit-scrollbar-track{background:transparent}
  .scrollbar-thin::-webkit-scrollbar-thumb{background:var(--border2);border-radius:2px}
</style>
</head>
<body>

<header>
  <div class="logo">FFMPEG<span>MGR</span><sub>v2</sub></div>
  <div class="header-stats">
    <div class="stat-chip"><span class="dot db-ok" id="db-dot"></span><span id="db-label">DB</span></div>
    <div class="stat-chip"><span class="dot running" id="run-dot"></span><span id="running-count">0</span>&nbsp;running</div>
    <div class="stat-chip"><span class="dot done"></span><span id="done-count">0</span>&nbsp;done</div>
    <div class="stat-chip"><span class="dot failed"></span><span id="fail-count">0</span>&nbsp;failed</div>
    <div class="stat-chip" id="preset-chip" style="color:var(--accent2)">— presets</div>
  </div>
  <button class="header-btn" onclick="window.open('/doc','_blank')">API Docs ↗</button>
  <button class="header-btn" onclick="window.open('/presets','_blank')">Presets JSON ↗</button>
</header>

<aside class="scrollbar-thin">
  <div>
    <div class="sidebar-label">Quick Fire</div>
    <div class="qf-grid scrollbar-thin">${qfButtons}</div>
    <div id="quick-toast" class="toast"></div>
  </div>

  <div>
    <div class="sidebar-label">Navigate</div>
    <div class="nav-item active" id="nav-launch" onclick="showSection('launch')"><span class="nav-icon">⚡</span>Launch Job</div>
    <div class="nav-item" id="nav-jobs"   onclick="showSection('jobs')"><span class="nav-icon">📋</span>Job Queue</div>
    <div class="nav-item" id="nav-logs"   onclick="showSection('logs')"><span class="nav-icon">📜</span>Error Logs</div>
    <div class="nav-item" id="nav-media"  onclick="showSection('media')"><span class="nav-icon">🎬</span>Media</div>
  </div>
</aside>

<main class="scrollbar-thin">

  <!-- LAUNCH -->
  <div id="section-launch">
    <div class="card">
      <div class="card-title">⚡ Launch Job <span class="badge">NEW</span></div>
      <div class="field-row col1">
        <div><label>Source Path</label>
          <input type="text" id="src-path" placeholder="/data/media" value="${DATA_ROOT}">
        </div>
      </div>
      <div class="field-row col2">
        <div><label>Preset</label>
          <select id="preset-select">${optGroups}</select>
        </div>
        <div><label>Threads — <span id="thread-display">1</span></label>
          <div class="thread-row">
            <input type="range" min="1" max="16" value="1" id="thread-range"
              oninput="document.getElementById('thread-display').textContent=this.value">
          </div>
        </div>
      </div>
      <div class="field-row col1">
        <div><label>Mode</label>
          <div class="mode-pills">
            <div class="pill active" id="pill-recursive" onclick="selectMode('recursive')">🔄 Recursive</div>
            <div class="pill" id="pill-single" onclick="selectMode('single')">📁 Single Folder</div>
          </div>
        </div>
      </div>
      <button class="launch-btn" id="launch-btn" onclick="launchJob()">▶ LAUNCH PROCESS</button>
      <div id="launch-toast" class="toast"></div>
    </div>
  </div>

  <!-- JOBS -->
  <div id="section-jobs" style="display:none">
    <div class="card">
      <div class="section-header">
        <div class="section-title">📋 Job Queue</div>
        <button class="refresh-btn" onclick="loadJobs()">↻ Refresh</button>
      </div>
      <div class="filter-row">
        <button class="filter-pill active" onclick="filterJobs('')"         id="filt-all">All</button>
        <button class="filter-pill"        onclick="filterJobs('running')"   id="filt-running">Running</button>
        <button class="filter-pill"        onclick="filterJobs('done')"      id="filt-done">Done</button>
        <button class="filter-pill"        onclick="filterJobs('failed')"    id="filt-failed">Failed</button>
        <button class="filter-pill"        onclick="filterJobs('skipped')"   id="filt-skipped">Skipped</button>
      </div>
      <div id="jobs-table-wrap"></div>
    </div>
  </div>

  <!-- LOGS -->
  <div id="section-logs" style="display:none">
    <div class="card">
      <div class="section-header">
        <div class="section-title">📜 Error Logs</div>
        <button class="refresh-btn" onclick="loadErrorLogs()">↻ Refresh</button>
      </div>
      <div id="error-logs-wrap"></div>
    </div>
  </div>

  <!-- MEDIA -->
  <div id="section-media" style="display:none">
    <div class="card">
      <div class="section-header">
        <div class="section-title">🎬 Media Files</div>
        <button class="refresh-btn" onclick="loadMedia()">↻ Refresh</button>
      </div>
      <div class="filter-row">
        <button class="filter-pill active" onclick="filterMedia('')"       id="mfilt-all">All</button>
        <button class="filter-pill"        onclick="filterMedia('video')"  id="mfilt-video">Video</button>
        <button class="filter-pill"        onclick="filterMedia('image')"  id="mfilt-image">Images</button>
      </div>
      <div id="media-wrap"></div>
    </div>
  </div>

</main>

<footer>
  <span>FFmpeg Microservice v2</span>·<span id="footer-time"></span>
  <span class="footer-spacer"></span>
  <label style="display:flex;align-items:center;gap:.35rem;cursor:pointer;">
    <input type="checkbox" id="auto-refresh-toggle" checked> Auto-refresh
  </label>
</footer>

<!-- DRAWER -->
<div class="drawer-overlay" id="drawer-overlay" onclick="closeDrawer(event)">
  <div class="drawer scrollbar-thin" id="drawer">
    <button class="drawer-close" onclick="closeDrawerForce()">✕ Close</button>
    <div id="drawer-content"></div>
  </div>
</div>

<script>
let currentMode = 'recursive';
let currentJobFilter = '';
let currentMediaFilter = '';
let autoRefreshInterval = null;

function showSection(name) {
  ['launch','jobs','logs','media'].forEach(s => {
    document.getElementById('section-'+s).style.display = s===name?'':'none';
    const n = document.getElementById('nav-'+s);
    if(n) n.classList.toggle('active', s===name);
  });
  if(name==='jobs')  loadJobs();
  if(name==='logs')  loadErrorLogs();
  if(name==='media') loadMedia();
}

async function refreshStatus() {
  try {
    const d = await fetch('/status').then(r=>r.json());
    document.getElementById('db-dot').className = 'dot '+(d.ok?'db-ok':'db-err');
    document.getElementById('db-label').textContent = d.ok?'DB':'DB ERR';
    document.getElementById('running-count').textContent = d.stats?.running||0;
    document.getElementById('done-count').textContent    = d.stats?.done||0;
    document.getElementById('fail-count').textContent    = d.stats?.failed||0;
    document.getElementById('preset-chip').textContent   = (d.presetsAvailable||0)+' presets';
  } catch(e) {
    document.getElementById('db-dot').className = 'dot db-err';
  }
}

function selectMode(m) {
  currentMode = m;
  document.getElementById('pill-recursive').classList.toggle('active', m==='recursive');
  document.getElementById('pill-single').classList.toggle('active',    m==='single');
}

async function launchJob() {
  const srcPath = document.getElementById('src-path').value.trim();
  const preset  = document.getElementById('preset-select').value;
  const threads = parseInt(document.getElementById('thread-range').value);
  const toast   = document.getElementById('launch-toast');
  const btn     = document.getElementById('launch-btn');
  if(!srcPath){ showToast(toast,'error','Source path is required'); return; }
  btn.disabled=true; btn.textContent='⏳ LAUNCHING…';
  toast.className='toast';
  try {
    const d = await fetch('/process',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({srcPath,preset,threads,mode:currentMode})}).then(r=>r.json());
    if(d.jobId){ showToast(toast,'success','✓ Job started — '+d.jobId); refreshStatus(); }
    else        showToast(toast,'error','✗ '+(d.error||'Unknown error'));
  } catch(e){ showToast(toast,'error','✗ '+e.message); }
  finally{ btn.disabled=false; btn.textContent='▶ LAUNCH PROCESS'; }
}

async function quickFire(preset) {
  const toast = document.getElementById('quick-toast');
  const btn   = document.querySelector('.q-'+preset.replace(/[^a-z0-9]/g,'-'));
  if(btn){ btn.classList.add('loading'); btn.querySelector('.qsub').textContent='launching…'; }
  toast.className='toast';
  try {
    const d = await fetch('/process/quick/'+encodeURIComponent(preset),{method:'POST'}).then(r=>r.json());
    if(d.jobId){ showToast(toast,'success','✓ '+preset.toUpperCase()+' → '+d.jobId.slice(0,8)+'…'); refreshStatus(); }
    else         showToast(toast,'error','✗ '+(d.error||'Error'));
  } catch(e){ showToast(toast,'error','✗ '+e.message); }
  finally {
    if(btn){ btn.classList.remove('loading'); /* restore sub text from preset data */ }
  }
}

function showToast(el,type,msg){ el.className='toast '+type; el.textContent=msg; }

async function loadJobs() {
  const wrap = document.getElementById('jobs-table-wrap');
  wrap.innerHTML='<div class="empty-state">Loading…</div>';
  try {
    const url='/jobs?limit=100'+(currentJobFilter?'&status='+currentJobFilter:'');
    const d = await fetch(url).then(r=>r.json());
    if(!d.jobs?.length){ wrap.innerHTML='<div class="empty-state">No jobs found</div>'; return; }
    const rows=d.jobs.map(j=>{
      const started=j.started_at?new Date(j.started_at).toLocaleTimeString():'—';
      const dur=j.finished_at&&j.started_at?Math.round((new Date(j.finished_at)-new Date(j.started_at))/1000)+'s':'—';
      return \`<tr onclick="openJobDetail('\${j.id}')">
        <td>\${j.id.slice(0,8)}…</td>
        <td><span class="status-badge \${j.status}">\${j.status}</span></td>
        <td style="color:var(--accent2)">\${j.preset}</td>
        <td style="max-width:160px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--text2)">\${j.src_path}</td>
        <td>\${j.total_images||0}</td><td>\${j.size_mb||0} MB</td>
        <td>\${started}</td><td>\${dur}</td>
      </tr>\`;
    }).join('');
    wrap.innerHTML=\`<table><thead><tr>
      <th>ID</th><th>Status</th><th>Preset</th><th>Path</th><th>Images</th><th>Size</th><th>Started</th><th>Duration</th>
    </tr></thead><tbody>\${rows}</tbody></table>\`;
  } catch(e){ wrap.innerHTML='<div class="empty-state" style="color:var(--red)">'+e.message+'</div>'; }
}

function filterJobs(s){
  currentJobFilter=s;
  ['all','running','done','failed','skipped'].forEach(x=>
    document.getElementById('filt-'+x)?.classList.toggle('active',(x==='all'&&!s)||(x===s)));
  loadJobs();
}

async function openJobDetail(id) {
  document.getElementById('drawer-overlay').classList.add('open');
  const content=document.getElementById('drawer-content');
  content.innerHTML='<div class="empty-state">Loading…</div>';
  try {
    const d=await fetch('/jobs/'+id).then(r=>r.json());
    const j=d.job;
    const dur=j.finished_at&&j.started_at?Math.round((new Date(j.finished_at)-new Date(j.started_at))/1000)+'s':'In progress';
    const logs=(d.logs||[]).map(l=>\`<div class="log-entry">
      <span class="log-level \${l.level}">\${l.level}</span>
      <span class="log-msg">\${l.message}</span>
      <span class="log-time">\${new Date(l.created_at).toLocaleTimeString()}</span>
    </div>\`).join('');
    content.innerHTML=\`
      <div style="font-family:var(--mono);font-size:.62rem;color:var(--muted);margin-bottom:.2rem">\${j.id}</div>
      <div style="display:flex;align-items:center;gap:.65rem;margin-bottom:.7rem">
        <div style="font-family:var(--display);font-size:1.5rem">\${j.folder_name||j.src_path}</div>
        <span class="status-badge \${j.status}">\${j.status}</span>
      </div>
      <div class="detail-grid">
        <div class="detail-cell"><div class="dc-label">Preset</div><div class="dc-val">\${j.preset}</div></div>
        <div class="detail-cell"><div class="dc-label">Threads</div><div class="dc-val">\${j.threads}</div></div>
        <div class="detail-cell"><div class="dc-label">Duration</div><div class="dc-val">\${dur}</div></div>
        <div class="detail-cell"><div class="dc-label">Images</div><div class="dc-val">\${j.total_images||0}</div></div>
        <div class="detail-cell"><div class="dc-label">Size</div><div class="dc-val">\${j.size_mb||0} MB</div></div>
        <div class="detail-cell"><div class="dc-label">Video Sec</div><div class="dc-val">\${j.duration_sec||0}s</div></div>
      </div>
      \${j.output_path?\`<div style="background:var(--panel2);border:1px solid var(--border2);border-radius:5px;padding:.5rem .7rem;font-family:var(--mono);font-size:.68rem;margin-bottom:.7rem;color:var(--green)">📦 \${j.output_path}</div>\`:''}
      \${j.error_msg?\`<div style="background:rgba(255,59,59,.07);border:1px solid rgba(255,59,59,.2);border-radius:5px;padding:.5rem .7rem;font-family:var(--mono);font-size:.68rem;margin-bottom:.7rem;color:var(--red)">✗ \${j.error_msg}</div>\`:''}
      <div style="font-family:var(--mono);font-size:.6rem;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin-bottom:.35rem">Logs (\${d.logs?.length||0})</div>
      <div class="log-list scrollbar-thin">\${logs||'<div style="padding:.85rem;text-align:center;color:var(--muted);font-size:.72rem">No logs</div>'}</div>
      <div style="font-family:var(--mono);font-size:.6rem;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin:.7rem 0 .35rem">Events (\${d.events?.length||0})</div>
      <div class="log-list scrollbar-thin">
        \${(d.events||[]).map(e=>\`<div class="log-entry">
          <span class="log-level info">\${e.event_type.replace(/_/g,' ')}</span>
          <span class="log-msg">\${e.payload?JSON.stringify(e.payload).slice(0,120):''}</span>
          <span class="log-time">\${new Date(e.created_at).toLocaleTimeString()}</span>
        </div>\`).join('')||'<div style="padding:.85rem;text-align:center;color:var(--muted);font-size:.72rem">No events</div>'}
      </div>\`;
  } catch(e){ content.innerHTML='<div class="empty-state" style="color:var(--red)">'+e.message+'</div>'; }
}
function closeDrawer(e){ if(e.target===document.getElementById('drawer-overlay')) closeDrawerForce(); }
function closeDrawerForce(){ document.getElementById('drawer-overlay').classList.remove('open'); }

async function loadErrorLogs() {
  const wrap=document.getElementById('error-logs-wrap');
  wrap.innerHTML='<div class="empty-state">Loading…</div>';
  try {
    const d=await fetch('/logs/error-global?limit=100').then(r=>r.json());
    if(!d.errors?.length){ wrap.innerHTML='<div class="empty-state" style="color:var(--green)">✓ No errors logged</div>'; return; }
    const rows=d.errors.map(e=>\`<tr>
      <td style="color:var(--muted)">\${new Date(e.created_at).toLocaleString()}</td>
      <td style="color:var(--text2)">\${e.job_id?.slice(0,8)||'—'}…</td>
      <td>\${e.folder_name||e.src_path||'—'}</td>
      <td style="color:var(--accent)">\${e.preset||'—'}</td>
      <td style="color:var(--red);max-width:240px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">\${e.message}</td>
    </tr>\`).join('');
    wrap.innerHTML=\`<table><thead><tr><th>Time</th><th>Job ID</th><th>Folder</th><th>Preset</th><th>Message</th></tr></thead><tbody>\${rows}</tbody></table>\`;
  } catch(e){ wrap.innerHTML='<div class="empty-state" style="color:var(--red)">'+e.message+'</div>'; }
}

async function loadMedia() {
  const wrap=document.getElementById('media-wrap');
  wrap.innerHTML='<div class="empty-state">Loading…</div>';
  try {
    const url='/media?limit=200'+(currentMediaFilter?'&type='+currentMediaFilter:'');
    const d=await fetch(url).then(r=>r.json());
    if(!d.media?.length){ wrap.innerHTML='<div class="empty-state">No media tracked yet</div>'; return; }
    const rows=d.media.map(m=>\`<tr>
      <td><span class="status-badge \${m.media_type==='video'?'done':'running'}">\${m.media_type}</span></td>
      <td style="max-width:190px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">\${m.file_name||'—'}</td>
      <td>\${m.folder_name||'—'}</td>
      <td>\${m.size_bytes?(m.size_bytes/1024/1024).toFixed(2)+' MB':'—'}</td>
      <td style="color:var(--muted)">\${new Date(m.created_at).toLocaleString()}</td>
    </tr>\`).join('');
    wrap.innerHTML=\`<table><thead><tr><th>Type</th><th>File</th><th>Folder</th><th>Size</th><th>Created</th></tr></thead><tbody>\${rows}</tbody></table>\`;
  } catch(e){ wrap.innerHTML='<div class="empty-state" style="color:var(--red)">'+e.message+'</div>'; }
}
function filterMedia(t){
  currentMediaFilter=t;
  ['all','video','image'].forEach(s=>document.getElementById('mfilt-'+s)?.classList.toggle('active',(s==='all'&&!t)||(s===t)));
  loadMedia();
}

setInterval(()=>document.getElementById('footer-time').textContent=new Date().toLocaleTimeString(),1000);
document.getElementById('footer-time').textContent=new Date().toLocaleTimeString();
document.getElementById('auto-refresh-toggle').addEventListener('change',function(){
  if(this.checked) autoRefreshInterval=setInterval(()=>{refreshStatus();if(document.getElementById('section-jobs').style.display!=='none')loadJobs();},5000);
  else clearInterval(autoRefreshInterval);
});
refreshStatus();
autoRefreshInterval=setInterval(()=>{refreshStatus();if(document.getElementById('section-jobs').style.display!=='none')loadJobs();},5000);
</script>
</body>
</html>`;
  return c.html(html);
});

app.route('/', routes);
app.notFound((c) => c.json({ error: 'Not found', hint: 'Visit /doc for API docs or / for the GUI' }, 404));
app.onError((err, c) => {
  console.error('[UNHANDLED]', err);
  return c.json({ error: 'Internal server error', message: err.message }, 500);
});

const PORT = parseInt(process.env.PORT || '3000');

async function start() {
  let retries = 15;
  while (retries > 0) {
    try {
      await pool.query('SELECT 1');
      console.log('[DB] Connected');
      break;
    } catch {
      retries--;
      console.log(`[DB] Waiting for database… (${retries} retries left)`);
      await new Promise(r => setTimeout(r, 2000));
    }
  }
  if (retries === 0) { console.error('[DB] Could not connect. Exiting.'); process.exit(1); }

  serve({ fetch: app.fetch, port: PORT }, (info) => {
    console.log(`[SERVER] Running on http://0.0.0.0:${info.port}`);
    console.log(`[SERVER] GUI:      http://0.0.0.0:${info.port}/`);
    console.log(`[SERVER] API Docs: http://0.0.0.0:${info.port}/doc`);
    console.log(`[SERVER] Presets:  http://0.0.0.0:${info.port}/presets`);
  });
}

start();
