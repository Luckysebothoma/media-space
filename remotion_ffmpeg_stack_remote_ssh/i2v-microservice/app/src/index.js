import { serve } from '@hono/node-server';
import { Hono }  from 'hono';
import { logger } from 'hono/logger';
import { pool } from './db.js';
import routes from './routes.js';
import { PRESETS, TRANSITIONS, MOTIONS, SINGLE_DURATION } from './utils.js';

const app = new Hono();
app.use('*', logger());

// ── Minimal landing page — full API surface documented at /doc ──────────
app.get('/', (c) => {
  const presetRows = Object.entries(PRESETS).map(([k, p]) =>
    `<tr><td>${k}</td><td>${p.aspectLabel}</td><td>${p.width}×${p.height}</td><td>${p.category}</td></tr>`
  ).join('');
  const html = `<!DOCTYPE html><html><head><meta charset="UTF-8">
<title>i2v-microservice v4</title>
<style>
body{background:#0a0a0f;color:#e8e8f0;font-family:ui-monospace,monospace;padding:2rem;max-width:900px;margin:0 auto}
h1{color:#ff6b35} a{color:#00d4ff} table{width:100%;border-collapse:collapse;margin:1rem 0}
th,td{padding:.4rem .6rem;border-bottom:1px solid #2a2a3a;text-align:left;font-size:.85rem}
.card{background:#13131a;border:1px solid #2a2a3a;border-radius:8px;padding:1rem;margin:1rem 0}
code{color:#ff7a45}
</style></head><body>
<h1>🎬 i2v-microservice v4</h1>
<p>Folder or single-image → video, with SSH/SMB remote sources and Prometheus metrics.</p>
<div class="card">
<b>Key endpoints</b><br>
<a href="/doc">/doc</a> — full API reference<br>
<a href="/presets">/presets</a> — resolutions, ratios, transitions, motions<br>
<a href="/metrics">/metrics</a> — Prometheus scrape target<br>
<a href="/status">/status</a> — health<br>
POST <code>/process</code> — grouped (folder → 1 video, transitions + motion)<br>
POST <code>/process/singles</code> — one clip per image<br>
POST <code>/remotes</code> — register an SSH or SMB source<br>
POST <code>/remotes/:id/mount</code> — mount it, then <code>/remotes/:id/process</code>
</div>
<div class="card"><b>Presets</b><table><tr><th>Key</th><th>Aspect</th><th>Resolution</th><th>Category</th></tr>${presetRows}</table></div>
<div class="card"><b>Transitions</b>: ${TRANSITIONS.join(', ')} &nbsp; <b>Motions</b>: ${MOTIONS.join(', ')} &nbsp; <b>Singles duration</b>: ${SINGLE_DURATION}s</div>
</body></html>`;
  return c.html(html);
});

app.get('/doc', (c) => {
  const html = `<!DOCTYPE html><html><head><meta charset="UTF-8"><title>i2v API Docs</title>
<style>body{background:#0a0a0f;color:#e8e8f0;font-family:ui-monospace,monospace;padding:2rem;max-width:900px;margin:0 auto;line-height:1.6}
.ep{background:#13131a;border:1px solid #2a2a3a;border-radius:8px;padding:1rem;margin-bottom:.85rem}
.m{display:inline-block;padding:.15rem .5rem;border-radius:4px;font-weight:700;font-size:.75rem;margin-right:.5rem}
.get{background:#0d3b2e;color:#00d4ff}.post{background:#3b1a0d;color:#ff6b35}.del{background:#3b0d0d;color:#ff6363}
pre{background:#0d0d14;border:1px solid #2a2a3a;border-radius:6px;padding:.75rem;overflow-x:auto;font-size:.78rem}
h1{color:#ff6b35}</style></head><body>
<h1>i2v-microservice v4 — API</h1>

<div class="ep"><span class="m get">GET</span><b>/presets</b><p>Preset/ratio table, transitions, motions.</p></div>
<div class="ep"><span class="m get">GET</span><b>/metrics</b><p>Prometheus exposition format.</p></div>
<div class="ep"><span class="m get">GET</span><b>/status</b><p>DB + job-queue health.</p></div>

<div class="ep"><span class="m post">POST</span><b>/process</b><p>Grouped mode — every folder under <code>srcPath</code> becomes one slideshow video, with crossfade transitions and per-image motion.</p>
<pre>{
  "srcPath": "/data/media/album1",
  "ratio": "9:16",            // or "preset": "mobile-hd"
  "transition": "fade",       // fade | zoom | slide | random | none
  "transitionDuration": 1.0,
  "motion": "kenburns",       // kenburns | zoom | pan | random | none
  "fps": 30,
  "threads": 2
}</pre></div>

<div class="ep"><span class="m post">POST</span><b>/process/quick/:preset</b><p>Grouped quick-fire against DATA_ROOT, e.g. <code>/process/quick/mobile-hd</code>.</p></div>

<div class="ep"><span class="m post">POST</span><b>/process/singles</b><p>One clip per image (no folder/date bucketing). Body same shape as <code>/process</code>; add <code>"mode":"single"</code> to scan one folder only (default: recursive).</p></div>

<div class="ep"><span class="m post">POST</span><b>/process/singles/:preset</b><p>Singles quick-fire against DATA_ROOT.</p></div>

<div class="ep"><span class="m get">GET</span><b>/remotes</b><p>List configured remote sources.</p></div>
<div class="ep"><span class="m post">POST</span><b>/remotes</b><p>Register an SSH or SMB source. Secrets are written to disk (0600), never stored in Postgres.</p>
<pre>// SSH, key auth (recommended)
{ "name":"nas-photos", "protocol":"ssh", "host":"192.168.1.50", "port":22,
  "username":"pi", "authType":"key", "privateKey":"-----BEGIN OPENSSH PRIVATE KEY-----...",
  "remotePath":"/export/photos" }

// SSH, password auth
{ "name":"laptop", "protocol":"ssh", "host":"10.0.0.5", "username":"me",
  "authType":"password", "password":"...", "remotePath":"/home/me/Pictures" }

// SMB
{ "name":"synology", "protocol":"smb", "host":"192.168.1.20",
  "username":"user", "password":"...", "domain":"WORKGROUP", "remotePath":"photos" }</pre></div>

<div class="ep"><span class="m post">POST</span><b>/remotes/:id/mount</b><p>Mounts via sshfs (SSH) or mount.cifs (SMB) under MOUNT_ROOT.</p></div>
<div class="ep"><span class="m post">POST</span><b>/remotes/:id/unmount</b><p>Unmounts.</p></div>
<div class="ep"><span class="m del">DELETE</span><b>/remotes/:id</b><p>Unmounts if needed, deletes the on-disk secret, deletes the row.</p></div>
<div class="ep"><span class="m post">POST</span><b>/remotes/:id/process</b><p>Convert a mounted remote directly.</p>
<pre>{ "subPath": "2026/vacation", "singles": false, "ratio": "16:9", "transition": "slide" }</pre></div>

<div class="ep"><span class="m get">GET</span><b>/jobs</b> · <b>/jobs/:id</b><p>Filter with <code>?status=</code>, <code>?mode=grouped|singles</code>.</p></div>
<div class="ep"><span class="m get">GET</span><b>/logs</b> · <b>/logs/error-global</b> · <b>/media</b></div>
</body></html>`;
  return c.html(html);
});

app.route('/', routes);
app.notFound((c) => c.json({ error: 'Not found', hint: 'Visit /doc for API docs or / for overview' }, 404));
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
    console.log(`[SERVER] Overview:     http://0.0.0.0:${info.port}/`);
    console.log(`[SERVER] API Docs:     http://0.0.0.0:${info.port}/doc`);
    console.log(`[SERVER] Metrics:      http://0.0.0.0:${info.port}/metrics`);
    console.log(`[SERVER] Grouped mode: POST /process (transitions + motion, per i2v.sh)`);
    console.log(`[SERVER] Singles mode: POST /process/singles (one ${SINGLE_DURATION}s clip per image)`);
    console.log(`[SERVER] Remotes:      POST /remotes → /remotes/:id/mount → /remotes/:id/process`);
  });
}

start();
