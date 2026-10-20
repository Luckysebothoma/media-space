import { Hono } from 'hono';
import { pool, dbLog } from './db.js';
import { processDirectory, processSingleFolder } from './processor.js';
import { PRESETS, DEFAULT_PRESET, DEFAULT_THREADS, resolvePreset, validPresetNames, presetsByCategory } from './utils.js';

const app = new Hono();
const DATA_ROOT = process.env.DATA_ROOT || '/data/media';

// ── /presets ─────────────────────────────────────────────────────────────────
app.get('/presets', (c) => {
  return c.json({
    presets: PRESETS,
    categories: presetsByCategory(),
    count: Object.keys(PRESETS).length,
  });
});

// ── /doc ─────────────────────────────────────────────────────────────────────
app.get('/doc', (c) => {
  const presetRows = Object.entries(PRESETS).map(([k, p]) =>
    `<tr><td>${k}</td><td>${p.aspectLabel}</td><td>${p.width}×${p.height}</td><td>${p.crf}</td><td>${p.bitrate}k / ${p.maxrate}k</td><td>${p.category}</td><td style="color:#6b6b80">${p.description}</td></tr>`
  ).join('');

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FFmpeg Microservice v2 — API Docs</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&family=Syne:wght@400;700;800&display=swap');
:root{--bg:#0a0a0f;--surface:#13131a;--border:#2a2a3a;--accent:#ff6b35;--accent2:#00d4ff;--text:#e8e8f0;--muted:#6b6b80}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:'JetBrains Mono',monospace;line-height:1.7;padding:2rem;max-width:1100px;margin:0 auto}
h1{font-family:'Syne',sans-serif;font-size:2.8rem;font-weight:800;color:var(--accent);margin-bottom:.25rem}
h2{font-family:'Syne',sans-serif;font-size:1.4rem;color:var(--accent2);margin:2.5rem 0 .75rem;border-bottom:1px solid var(--border);padding-bottom:.4rem}
h3{color:var(--accent);font-size:.9rem;margin:.75rem 0 .25rem}
.sub{color:var(--muted);font-size:.85rem;margin-bottom:2rem}
.endpoint{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:1.25rem;margin-bottom:1rem}
.method{display:inline-block;padding:.2rem .6rem;border-radius:4px;font-weight:700;font-size:.8rem;margin-right:.5rem}
.get{background:#0d3b2e;color:#00d4ff}.post{background:#3b1a0d;color:#ff6b35}
.path{font-size:1rem;font-weight:700}
pre{background:#0d0d14;border:1px solid var(--border);border-radius:6px;padding:1rem;overflow-x:auto;font-size:.82rem;margin:.5rem 0}
table{width:100%;border-collapse:collapse;font-size:.8rem;margin:.5rem 0}
th{text-align:left;color:var(--muted);border-bottom:1px solid var(--border);padding:.4rem .5rem;white-space:nowrap}
td{padding:.4rem .5rem;border-bottom:1px solid #1a1a24}
td:first-child{color:var(--accent2)}
.cat-desktop{color:#00d4ff}.cat-mobile{color:#a060ff}.cat-social{color:#ff6b35}
</style>
</head>
<body>
<h1>🎬 FFmpeg Microservice v2</h1>
<p class="sub">Image-to-video batch processor · Hono + PostgreSQL · Corruption-hardened · ${Object.keys(PRESETS).length} presets</p>

<h2>All Presets</h2>
<table>
<tr><th>Key</th><th>Aspect</th><th>Resolution</th><th>CRF</th><th>Bitrate / Maxrate</th><th>Category</th><th>Description</th></tr>
${presetRows}
</table>
<p style="margin-top:.5rem;font-size:.75rem;color:var(--muted)">Also accepts aliases: vertical, reel, reels, tiktok, shorts, portrait, landscape, square, instagram, feed, cinema, 1080p, 4k-high, 16-9, 9-16, 4-3, 1:1 …</p>

<h2>Endpoints</h2>

<div class="endpoint">
<span class="method get">GET</span><span class="path">/presets</span>
<p>Returns full preset registry grouped by category as JSON.</p>
</div>

<div class="endpoint">
<span class="method post">POST</span><span class="path">/process/quick</span>
<p>Process DATA_ROOT with default preset (standard). No body needed.</p>
</div>

<div class="endpoint">
<span class="method post">POST</span><span class="path">/process/quick/:preset</span>
<p>Process DATA_ROOT with any named preset or alias. No body needed.</p>
<pre>POST /process/quick/mobile-hd        # 9:16 portrait
POST /process/quick/reel              # alias → mobile-hd
POST /process/quick/square-hd         # 1:1
POST /process/quick/4k
POST /process/quick/cinematic
POST /process/quick/ultrawide</pre>
</div>

<div class="endpoint">
<span class="method post">POST</span><span class="path">/process</span>
<p>Full control — path, preset, threads, mode.</p>
<pre>{ "srcPath": "/data/media/album1", "preset": "mobile-hd", "threads": 2, "mode": "recursive" }</pre>
<p><code>mode</code>: <code>recursive</code> (default) or <code>single</code>.</p>
</div>

<div class="endpoint">
<span class="method post">POST</span><span class="path">/process/folder</span>
<p>Process one specific folder only.</p>
<pre>{ "folderPath": "/data/media/album1/set_a", "preset": "portrait-social", "threads": 1 }</pre>
</div>

<div class="endpoint">
<span class="method get">GET</span><span class="path">/jobs</span>
<p>List jobs. Params: <code>?status=running</code>, <code>?limit=20</code>, <code>?offset=0</code></p>
</div>

<div class="endpoint">
<span class="method get">GET</span><span class="path">/jobs/:id</span>
<p>Full job detail with events, media, and last 100 logs.</p>
</div>

<div class="endpoint">
<span class="method get">GET</span><span class="path">/logs</span>
<p>Paginated logs. Params: <code>?level=error</code>, <code>?job_id=uuid</code>, <code>?limit=50</code></p>
</div>

<div class="endpoint">
<span class="method get">GET</span><span class="path">/logs/error-global</span>
<p>All error-level logs joined with job metadata.</p>
</div>

<div class="endpoint">
<span class="method get">GET</span><span class="path">/media</span>
<p>List tracked media. Params: <code>?job_id=uuid</code>, <code>?type=video|image</code></p>
</div>

<div class="endpoint">
<span class="method get">GET</span><span class="path">/status</span>
<p>Health check — DB connectivity and job queue stats.</p>
</div>
</body>
</html>`;
  return c.html(html);
});

// ── /status ───────────────────────────────────────────────────────────────────
app.get('/status', async (c) => {
  try {
    const r = await pool.query(`SELECT
      (SELECT COUNT(*) FROM jobs WHERE status='running') AS running,
      (SELECT COUNT(*) FROM jobs WHERE status='done')    AS done,
      (SELECT COUNT(*) FROM jobs WHERE status='failed')  AS failed,
      (SELECT COUNT(*) FROM jobs)                        AS total`);
    return c.json({ ok: true, db: 'connected', stats: r.rows[0], presetsAvailable: Object.keys(PRESETS).length });
  } catch (err) {
    return c.json({ ok: false, db: 'error', error: err.message }, 503);
  }
});

// ── /process/quick ────────────────────────────────────────────────────────────
app.post('/process/quick', async (c) => {
  try {
    const jobId = await processDirectory({ srcPath: DATA_ROOT, preset: DEFAULT_PRESET, threads: DEFAULT_THREADS });
    return c.json({ jobId, srcPath: DATA_ROOT, preset: DEFAULT_PRESET, threads: DEFAULT_THREADS }, 202);
  } catch (err) {
    await dbLog('error', `/process/quick failed: ${err.message}`);
    return c.json({ error: err.message }, 500);
  }
});

// ── /process/quick/:preset ────────────────────────────────────────────────────
app.post('/process/quick/:preset', async (c) => {
  const raw    = c.req.param('preset');
  const preset = resolvePreset(raw);
  if (!preset) {
    return c.json({ error: `Unknown preset: "${raw}". Valid: ${validPresetNames()}` }, 400);
  }
  try {
    const jobId = await processDirectory({ srcPath: DATA_ROOT, preset, threads: DEFAULT_THREADS });
    return c.json({ jobId, srcPath: DATA_ROOT, preset, threads: DEFAULT_THREADS, resolvedFrom: raw !== preset ? raw : undefined }, 202);
  } catch (err) {
    await dbLog('error', `/process/quick/${raw} failed: ${err.message}`);
    return c.json({ error: err.message }, 500);
  }
});

// ── /process ──────────────────────────────────────────────────────────────────
app.post('/process', async (c) => {
  let body;
  try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON body' }, 400); }
  const srcPath = body.srcPath;
  if (!srcPath) return c.json({ error: 'srcPath is required' }, 400);
  const preset  = resolvePreset(body.preset) || DEFAULT_PRESET;
  const threads = parseInt(body.threads) || DEFAULT_THREADS;
  const mode    = body.mode || 'recursive';
  if (!PRESETS[preset]) return c.json({ error: `Unknown preset: ${body.preset}. Valid: ${validPresetNames()}` }, 400);
  try {
    const fn    = mode === 'single' ? processSingleFolder : processDirectory;
    const jobId = await fn({ srcPath, preset, threads });
    return c.json({ jobId, srcPath, preset, threads, mode }, 202);
  } catch (err) {
    await dbLog('error', `/process failed: ${err.message}`, null, { srcPath, preset });
    return c.json({ error: err.message }, 500);
  }
});

// ── /process/folder ───────────────────────────────────────────────────────────
app.post('/process/folder', async (c) => {
  let body;
  try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON body' }, 400); }
  const folderPath = body.folderPath || body.srcPath;
  if (!folderPath) return c.json({ error: 'folderPath is required' }, 400);
  const preset  = resolvePreset(body.preset) || DEFAULT_PRESET;
  const threads = parseInt(body.threads) || DEFAULT_THREADS;
  if (!PRESETS[preset]) return c.json({ error: `Unknown preset: ${body.preset}` }, 400);
  try {
    const jobId = await processSingleFolder({ srcPath: folderPath, preset, threads });
    return c.json({ jobId, folderPath, preset, threads }, 202);
  } catch (err) {
    await dbLog('error', `/process/folder failed: ${err.message}`, null, { folderPath });
    return c.json({ error: err.message }, 500);
  }
});

// ── /jobs ─────────────────────────────────────────────────────────────────────
app.get('/jobs', async (c) => {
  const status = c.req.query('status');
  const limit  = Math.min(parseInt(c.req.query('limit')  || '50'),  200);
  const offset = parseInt(c.req.query('offset') || '0');
  let query = `SELECT * FROM jobs`;
  const vals = [];
  if (status) { query += ` WHERE status=$1`; vals.push(status); }
  query += ` ORDER BY created_at DESC LIMIT ${limit} OFFSET ${offset}`;
  try {
    const r = await pool.query(query, vals);
    return c.json({ jobs: r.rows, count: r.rowCount });
  } catch (err) { return c.json({ error: err.message }, 500); }
});

app.get('/jobs/:id', async (c) => {
  const id = c.req.param('id');
  try {
    const job    = await pool.query(`SELECT * FROM jobs   WHERE id=$1`, [id]);
    if (!job.rows.length) return c.json({ error: 'Job not found' }, 404);
    const events = await pool.query(`SELECT * FROM events WHERE job_id=$1 ORDER BY created_at`, [id]);
    const media  = await pool.query(`SELECT * FROM media  WHERE job_id=$1 ORDER BY created_at`, [id]);
    const logs   = await pool.query(`SELECT * FROM logs   WHERE job_id=$1 ORDER BY created_at DESC LIMIT 100`, [id]);
    return c.json({ job: job.rows[0], events: events.rows, media: media.rows, logs: logs.rows });
  } catch (err) { return c.json({ error: err.message }, 500); }
});

// ── /logs ─────────────────────────────────────────────────────────────────────
app.get('/logs', async (c) => {
  const level  = c.req.query('level');
  const jobId  = c.req.query('job_id');
  const limit  = Math.min(parseInt(c.req.query('limit') || '100'), 500);
  const offset = parseInt(c.req.query('offset') || '0');
  const conditions = [], vals = [];
  if (level) { conditions.push(`level=$${vals.length+1}`);  vals.push(level); }
  if (jobId) { conditions.push(`job_id=$${vals.length+1}`); vals.push(jobId); }
  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
  try {
    const r = await pool.query(`SELECT * FROM logs ${where} ORDER BY created_at DESC LIMIT ${limit} OFFSET ${offset}`, vals);
    return c.json({ logs: r.rows, count: r.rowCount });
  } catch (err) { return c.json({ error: err.message }, 500); }
});

app.get('/logs/error-global', async (c) => {
  const limit  = Math.min(parseInt(c.req.query('limit') || '100'), 500);
  const offset = parseInt(c.req.query('offset') || '0');
  try {
    const r = await pool.query(`SELECT * FROM global_error_logs LIMIT $1 OFFSET $2`, [limit, offset]);
    return c.json({ errors: r.rows, count: r.rowCount });
  } catch (err) { return c.json({ error: err.message }, 500); }
});

// ── /media ────────────────────────────────────────────────────────────────────
app.get('/media', async (c) => {
  const jobId = c.req.query('job_id');
  const type  = c.req.query('type');
  const limit = Math.min(parseInt(c.req.query('limit') || '100'), 500);
  const conditions = [], vals = [];
  if (jobId) { conditions.push(`job_id=$${vals.length+1}`);    vals.push(jobId); }
  if (type)  { conditions.push(`media_type=$${vals.length+1}`); vals.push(type); }
  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
  try {
    const r = await pool.query(`SELECT * FROM media ${where} ORDER BY created_at DESC LIMIT ${limit}`, vals);
    return c.json({ media: r.rows, count: r.rowCount });
  } catch (err) { return c.json({ error: err.message }, 500); }
});

export default app;
