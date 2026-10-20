import { Hono } from 'hono';
import { pool, dbLog } from './db.js';
import { organiseFiles, scanFiles } from './organiser.js';
import { processDirectory } from './processor.js';
import { renderWithRemotion } from './renderer.js';
import { FFMPEG_PRESETS, REMOTION_PRESETS, collectMedia, humanReadable } from './utils.js';
import fs from 'fs/promises';
import path from 'path';

const api = new Hono();
const DATA_ROOT   = process.env.DATA_ROOT  || '/data/media';
const AUDIO_BASE  = process.env.AUDIO_BASE || '/data/audio';
const RENDER_BASE = process.env.RENDER_BASE|| '/data/renders';
const REMOTION_URL = process.env.REMOTION_URL || 'http://remotion:3100';

// ── /status ──────────────────────────────────────────────────────────────────
api.get('/status', async (c) => {
  try {
    const r = await pool.query(`
      SELECT
        (SELECT COUNT(*) FROM jobs WHERE status='running') AS running,
        (SELECT COUNT(*) FROM jobs WHERE status='done')    AS done,
        (SELECT COUNT(*) FROM jobs WHERE status='failed')  AS failed,
        (SELECT COUNT(*) FROM jobs)                        AS total,
        (SELECT COUNT(*) FROM jobs WHERE job_type='render') AS renders,
        (SELECT COUNT(*) FROM jobs WHERE job_type='process') AS processes
    `);
    // Ping Remotion
    let remotionOk = false;
    try {
      const rr = await fetch(`${REMOTION_URL}/health`);
      remotionOk = rr.ok;
    } catch {}
    return c.json({ ok: true, db: 'connected', remotion: remotionOk ? 'connected' : 'offline', stats: r.rows[0] });
  } catch (err) {
    return c.json({ ok: false, db: 'error', error: err.message }, 503);
  }
});

// ── /audio — list available audio files ──────────────────────────────────────
api.get('/audio', async (c) => {
  try {
    await fs.mkdir(AUDIO_BASE, { recursive: true });
    const entries = await fs.readdir(AUDIO_BASE, { withFileTypes: true });
    const files = entries
      .filter(e => e.isFile() && /\.(mp3|wav|aac|ogg|m4a|flac)$/i.test(e.name))
      .map(e => ({ name: e.name, path: path.join(AUDIO_BASE, e.name) }));
    return c.json({ audio: files, count: files.length });
  } catch (err) { return c.json({ error: err.message }, 500); }
});

// ── /presets ──────────────────────────────────────────────────────────────────
api.get('/presets', (c) => c.json({
  ffmpeg: FFMPEG_PRESETS,
  remotion: REMOTION_PRESETS,
}));

// ══════════════════════════════════════════════════════════════
// ORGANISE endpoints
// ══════════════════════════════════════════════════════════════

api.post('/organise', async (c) => {
  let body; try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON' }, 400); }
  const { srcPath = DATA_ROOT, outputDir, mediaType = 'both', granularity = 'day', dryRun = false } = body;
  try {
    const result = await organiseFiles({ srcPath, outputDir, mediaType, granularity, dryRun });
    return c.json(result, 202);
  } catch (err) { return c.json({ error: err.message }, 500); }
});

api.post('/organise/scan', async (c) => {
  let body; try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON' }, 400); }
  const { srcPath = DATA_ROOT, mediaType = 'both' } = body;
  try {
    const result = await scanFiles({ srcPath, mediaType });
    return c.json(result);
  } catch (err) { return c.json({ error: err.message }, 500); }
});

// ══════════════════════════════════════════════════════════════
// PROCESS endpoints  (FFmpeg image→video)
// ══════════════════════════════════════════════════════════════

api.post('/process', async (c) => {
  let body; try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON' }, 400); }
  const { srcPath = DATA_ROOT, preset = 'standard', threads = 2, audioPath = null, muted = false } = body;
  if (!FFMPEG_PRESETS[preset]) return c.json({ error: `Unknown preset. Valid: ${Object.keys(FFMPEG_PRESETS).join(', ')}` }, 400);
  try {
    const jobId = await processDirectory({ srcPath, preset, threads, audioPath, muted });
    return c.json({ jobId, srcPath, preset, threads, muted }, 202);
  } catch (err) { return c.json({ error: err.message }, 500); }
});

api.post('/process/quick/:preset', async (c) => {
  const preset = c.req.param('preset');
  if (!FFMPEG_PRESETS[preset]) return c.json({ error: `Unknown preset: ${preset}` }, 400);
  try {
    const jobId = await processDirectory({ srcPath: DATA_ROOT, preset, threads: 2 });
    return c.json({ jobId, preset, srcPath: DATA_ROOT }, 202);
  } catch (err) { return c.json({ error: err.message }, 500); }
});

// ══════════════════════════════════════════════════════════════
// RENDER endpoints  (Remotion — animated video with audio)
// ══════════════════════════════════════════════════════════════

api.post('/render', async (c) => {
  let body; try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON' }, 400); }
  const { srcPath = DATA_ROOT, preset = 'cineslide', audioPath = null, muted = false, options = {} } = body;
  if (!REMOTION_PRESETS[preset]) return c.json({ error: `Unknown render preset. Valid: ${Object.keys(REMOTION_PRESETS).join(', ')}` }, 400);
  try {
    const jobId = await renderWithRemotion({ srcPath, preset, audioPath, muted, customOpts: options });
    return c.json({ jobId, srcPath, preset, muted, audioPath: !!audioPath }, 202);
  } catch (err) { return c.json({ error: err.message }, 500); }
});

api.post('/render/quick/:preset', async (c) => {
  const preset = c.req.param('preset');
  if (!REMOTION_PRESETS[preset]) return c.json({ error: `Unknown render preset: ${preset}` }, 400);
  try {
    const jobId = await renderWithRemotion({ srcPath: DATA_ROOT, preset });
    return c.json({ jobId, preset, srcPath: DATA_ROOT }, 202);
  } catch (err) { return c.json({ error: err.message }, 500); }
});

// ── Full pipeline: organise → process → render ────────────────────────────
api.post('/pipeline', async (c) => {
  let body; try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON' }, 400); }
  const {
    srcPath = DATA_ROOT,
    granularity = 'day',
    ffmpegPreset = 'standard',
    remotionPreset = 'cineslide',
    audioPath = null,
    muted = false,
    dryRun = false,
    skipOrganise = false,
    skipProcess = false,
    skipRender = false,
  } = body;

  const pipeline = [];
  try {
    if (!skipOrganise) {
      const org = await organiseFiles({ srcPath, mediaType: 'both', granularity, dryRun });
      pipeline.push({ step: 'organise', jobId: org.jobId, groups: org.groups.length, files: org.movedCount });
    }
    if (!skipProcess) {
      const procJobId = await processDirectory({ srcPath, preset: ffmpegPreset, threads: 2, audioPath, muted });
      pipeline.push({ step: 'process', jobId: procJobId, preset: ffmpegPreset });
    }
    if (!skipRender) {
      const renderJobId = await renderWithRemotion({ srcPath, preset: remotionPreset, audioPath, muted });
      pipeline.push({ step: 'render', jobId: renderJobId, preset: remotionPreset });
    }
    return c.json({ ok: true, pipeline, dryRun }, 202);
  } catch (err) {
    return c.json({ error: err.message, pipeline }, 500);
  }
});

// ══════════════════════════════════════════════════════════════
// JOBS / LOGS / MEDIA
// ══════════════════════════════════════════════════════════════

api.get('/jobs', async (c) => {
  const status  = c.req.query('status');
  const type    = c.req.query('type');
  const limit   = Math.min(parseInt(c.req.query('limit') || '50'), 200);
  const offset  = parseInt(c.req.query('offset') || '0');
  const where = [], vals = [];
  if (status) { where.push(`status=$${vals.length+1}`); vals.push(status); }
  if (type)   { where.push(`job_type=$${vals.length+1}`); vals.push(type); }
  const clause = where.length ? `WHERE ${where.join(' AND ')}` : '';
  try {
    const r = await pool.query(`SELECT * FROM jobs ${clause} ORDER BY created_at DESC LIMIT ${limit} OFFSET ${offset}`, vals);
    return c.json({ jobs: r.rows, count: r.rowCount });
  } catch (err) { return c.json({ error: err.message }, 500); }
});

api.get('/jobs/:id', async (c) => {
  const id = c.req.param('id');
  try {
    const job    = await pool.query(`SELECT * FROM jobs WHERE id=$1`, [id]);
    if (!job.rows.length) return c.json({ error: 'Not found' }, 404);
    const events = await pool.query(`SELECT * FROM events WHERE job_id=$1 ORDER BY created_at`, [id]);
    const media  = await pool.query(`SELECT * FROM media  WHERE job_id=$1 ORDER BY created_at`, [id]);
    const logs   = await pool.query(`SELECT * FROM logs   WHERE job_id=$1 ORDER BY created_at DESC LIMIT 100`, [id]);
    return c.json({ job: job.rows[0], events: events.rows, media: media.rows, logs: logs.rows });
  } catch (err) { return c.json({ error: err.message }, 500); }
});

api.get('/logs', async (c) => {
  const level  = c.req.query('level');
  const jobId  = c.req.query('job_id');
  const limit  = Math.min(parseInt(c.req.query('limit') || '100'), 500);
  const where = [], vals = [];
  if (level) { where.push(`level=$${vals.length+1}`); vals.push(level); }
  if (jobId) { where.push(`job_id=$${vals.length+1}`); vals.push(jobId); }
  const clause = where.length ? `WHERE ${where.join(' AND ')}` : '';
  try {
    const r = await pool.query(`SELECT * FROM logs ${clause} ORDER BY created_at DESC LIMIT ${limit}`, vals);
    return c.json({ logs: r.rows, count: r.rowCount });
  } catch (err) { return c.json({ error: err.message }, 500); }
});

api.get('/logs/errors', async (c) => {
  const limit = Math.min(parseInt(c.req.query('limit') || '100'), 500);
  try {
    const r = await pool.query(`SELECT * FROM global_error_logs LIMIT $1`, [limit]);
    return c.json({ errors: r.rows, count: r.rowCount });
  } catch (err) { return c.json({ error: err.message }, 500); }
});

api.get('/media', async (c) => {
  const jobId = c.req.query('job_id');
  const type  = c.req.query('type');
  const limit = Math.min(parseInt(c.req.query('limit') || '100'), 500);
  const where = [], vals = [];
  if (jobId) { where.push(`job_id=$${vals.length+1}`); vals.push(jobId); }
  if (type)  { where.push(`media_type=$${vals.length+1}`); vals.push(type); }
  const clause = where.length ? `WHERE ${where.join(' AND ')}` : '';
  try {
    const r = await pool.query(`SELECT * FROM media ${clause} ORDER BY created_at DESC LIMIT ${limit}`, vals);
    return c.json({ media: r.rows, count: r.rowCount });
  } catch (err) { return c.json({ error: err.message }, 500); }
});

api.get('/summary', async (c) => {
  try {
    const r = await pool.query(`SELECT * FROM job_summary`);
    const m = await pool.query(`SELECT media_type, COUNT(*) as count, SUM(size_bytes) as bytes FROM media GROUP BY media_type`);
    return c.json({ jobs: r.rows, media: m.rows });
  } catch (err) { return c.json({ error: err.message }, 500); }
});

export default api;
