import { Hono } from 'hono';
import path from 'path';
import { pool, dbLog } from './db.js';
import { processDirectory, processDirectorySingles } from './processor.js';
import {
  PRESETS, DEFAULT_PRESET, DEFAULT_THREADS, SINGLE_DURATION,
  TRANSITIONS, MOTIONS, resolvePreset, validPresetNames, presetsByCategory,
} from './utils.js';
import {
  mountRemote, unmountRemote, storeSecret, deleteSecret, mountPointFor, countMounted,
} from './remotes.js';
import { register, remotesMountedGauge } from './metrics.js';
import { sanitiseName } from './utils.js';

const app = new Hono();
const DATA_ROOT   = process.env.DATA_ROOT   || '/data/media';
const MOUNT_ROOT  = process.env.MOUNT_ROOT  || '/data/remote';

// ── /presets ─────────────────────────────────────────────────────────────
app.get('/presets', (c) => {
  return c.json({
    presets: PRESETS,
    categories: presetsByCategory(),
    count: Object.keys(PRESETS).length,
    transitions: TRANSITIONS,
    motions: MOTIONS,
    singleDurationSec: SINGLE_DURATION,
  });
});

// ── /metrics (Prometheus) ───────────────────────────────────────────────
app.get('/metrics', async (c) => {
  const body = await register.metrics();
  return c.text(body, 200, { 'Content-Type': register.contentType });
});

// ── /status ──────────────────────────────────────────────────────────────
app.get('/status', async (c) => {
  try {
    const r = await pool.query(`SELECT
      (SELECT COUNT(*) FROM jobs WHERE status='running') AS running,
      (SELECT COUNT(*) FROM jobs WHERE status='done')    AS done,
      (SELECT COUNT(*) FROM jobs WHERE status='failed')  AS failed,
      (SELECT COUNT(*) FROM jobs)                        AS total,
      (SELECT COUNT(*) FROM remotes WHERE status='mounted') AS remotes_mounted`);
    return c.json({ ok: true, db: 'connected', stats: r.rows[0], presetsAvailable: Object.keys(PRESETS).length, singleDurationSec: SINGLE_DURATION });
  } catch (err) {
    return c.json({ ok: false, db: 'error', error: err.message }, 503);
  }
});

// ── /process — grouped (folder → 1 slideshow, transitions + motion) ──────
app.post('/process', async (c) => {
  let body;
  try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON body' }, 400); }
  const srcPath = body.srcPath || DATA_ROOT;
  const preset  = resolvePreset(body.ratio || body.preset);
  if (body.preset && !preset) return c.json({ error: `Unknown preset/ratio: ${body.preset}. Valid: ${validPresetNames()}` }, 400);
  try {
    const jobId = await processDirectory({ srcPath, body });
    return c.json({ jobId, srcPath, mode: 'grouped', ...body }, 202);
  } catch (err) {
    await dbLog('error', `/process failed: ${err.message}`, null, { srcPath });
    return c.json({ error: err.message }, 500);
  }
});

// ── /process/quick/:preset — grouped quick-fire against DATA_ROOT ────────
app.post('/process/quick/:preset', async (c) => {
  const raw    = c.req.param('preset');
  const preset = resolvePreset(raw);
  if (!preset) return c.json({ error: `Unknown preset: "${raw}". Valid: ${validPresetNames()}` }, 400);
  try {
    const jobId = await processDirectory({ srcPath: DATA_ROOT, body: { preset } });
    return c.json({ jobId, srcPath: DATA_ROOT, preset, mode: 'grouped' }, 202);
  } catch (err) {
    return c.json({ error: err.message }, 500);
  }
});

// ── /process/singles — one clip per image, recursive or single folder ────
app.post('/process/singles', async (c) => {
  let body;
  try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON body' }, 400); }
  const srcPath = body.srcPath || DATA_ROOT;
  const preset  = resolvePreset(body.ratio || body.preset);
  if (body.preset && !preset) return c.json({ error: `Unknown preset/ratio: ${body.preset}. Valid: ${validPresetNames()}` }, 400);
  const singleFolderOnly = body.mode === 'single';
  try {
    const jobId = await processDirectorySingles({ srcPath, body, singleFolderOnly });
    return c.json({ jobId, srcPath, mode: 'singles', scanMode: body.mode || 'recursive', durationSec: SINGLE_DURATION }, 202);
  } catch (err) {
    return c.json({ error: err.message }, 500);
  }
});

app.post('/process/singles/:preset', async (c) => {
  const raw    = c.req.param('preset');
  const preset = resolvePreset(raw);
  if (!preset) return c.json({ error: `Unknown preset: "${raw}". Valid: ${validPresetNames()}` }, 400);
  try {
    const jobId = await processDirectorySingles({ srcPath: DATA_ROOT, body: { preset } });
    return c.json({ jobId, srcPath: DATA_ROOT, preset, mode: 'singles', durationSec: SINGLE_DURATION }, 202);
  } catch (err) {
    return c.json({ error: err.message }, 500);
  }
});

// ── /remotes — SSH / SMB source configuration ─────────────────────────────
//
// POST body (ssh, key auth):
//   { "name":"nas-photos","protocol":"ssh","host":"192.168.1.50","port":22,
//     "username":"pi","authType":"key","privateKey":"-----BEGIN...","remotePath":"/export/photos" }
//
// POST body (ssh, password auth):
//   { "name":"laptop","protocol":"ssh","host":"10.0.0.5","username":"me",
//     "authType":"password","password":"...","remotePath":"/home/me/Pictures" }
//
// POST body (smb):
//   { "name":"synology","protocol":"smb","host":"192.168.1.20",
//     "username":"user","password":"...","domain":"WORKGROUP","remotePath":"photos" }

app.get('/remotes', async (c) => {
  const r = await pool.query(`SELECT id,name,protocol,host,port,username,auth_type,remote_path,domain,mount_point,status,last_error,created_at,updated_at FROM remotes ORDER BY created_at DESC`);
  return c.json({ remotes: r.rows, count: r.rowCount });
});

app.post('/remotes', async (c) => {
  let body;
  try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON body' }, 400); }
  const { name, protocol, host, remotePath } = body;
  if (!name || !protocol || !host || !remotePath) {
    return c.json({ error: 'name, protocol, host, remotePath are required' }, 400);
  }
  if (!['ssh', 'smb'].includes(protocol)) return c.json({ error: 'protocol must be ssh or smb' }, 400);

  const port      = parseInt(body.port) || (protocol === 'ssh' ? 22 : 445);
  const authType  = protocol === 'ssh' ? (body.authType || 'key') : 'password';
  const mountPoint = mountPointFor(name);

  try {
    const secretRef = await storeSecret({
      protocol, name, authType,
      password: body.password, privateKey: body.privateKey,
      domain: body.domain, username: body.username,
    });

    const r = await pool.query(
      `INSERT INTO remotes (name, protocol, host, port, username, auth_type, secret_ref, remote_path, domain, mount_point)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING id, name, protocol, host, port, mount_point, status`,
      [name, protocol, host, port, body.username || null, authType, secretRef, remotePath, body.domain || null, mountPoint]
    );
    return c.json({ remote: r.rows[0] }, 201);
  } catch (err) {
    if (err.code === '23505') return c.json({ error: `Remote "${name}" already exists` }, 409);
    return c.json({ error: err.message }, 500);
  }
});

app.post('/remotes/:id/mount', async (c) => {
  const id = c.req.param('id');
  const r = await pool.query(`SELECT * FROM remotes WHERE id=$1`, [id]);
  if (!r.rows.length) return c.json({ error: 'Remote not found' }, 404);
  const remote = r.rows[0];

  const result = await mountRemote(remote);
  if (result.ok) {
    await pool.query(`UPDATE remotes SET status='mounted', last_error=NULL, updated_at=NOW() WHERE id=$1`, [id]);
    remotesMountedGauge.set(await countMounted());
    return c.json({ ok: true, mountPoint: remote.mount_point });
  }
  await pool.query(`UPDATE remotes SET status='error', last_error=$1, updated_at=NOW() WHERE id=$2`, [result.error, id]);
  return c.json({ ok: false, error: result.error }, 502);
});

app.post('/remotes/:id/unmount', async (c) => {
  const id = c.req.param('id');
  const r = await pool.query(`SELECT * FROM remotes WHERE id=$1`, [id]);
  if (!r.rows.length) return c.json({ error: 'Remote not found' }, 404);
  const remote = r.rows[0];

  const result = await unmountRemote(remote);
  await pool.query(`UPDATE remotes SET status='unmounted', last_error=$1, updated_at=NOW() WHERE id=$2`, [result.ok ? null : result.error, id]);
  remotesMountedGauge.set(await countMounted());
  return c.json(result);
});

app.delete('/remotes/:id', async (c) => {
  const id = c.req.param('id');
  const r = await pool.query(`SELECT * FROM remotes WHERE id=$1`, [id]);
  if (!r.rows.length) return c.json({ error: 'Remote not found' }, 404);
  const remote = r.rows[0];
  if (remote.status === 'mounted') await unmountRemote(remote);
  await deleteSecret({ protocol: remote.protocol, secretRef: remote.secret_ref });
  await pool.query(`DELETE FROM remotes WHERE id=$1`, [id]);
  remotesMountedGauge.set(await countMounted());
  return c.json({ ok: true, deleted: id });
});

// Convenience: process a mounted remote directly by name (grouped or singles)
app.post('/remotes/:id/process', async (c) => {
  const id = c.req.param('id');
  let body = {};
  try { body = await c.req.json(); } catch {}
  const r = await pool.query(`SELECT * FROM remotes WHERE id=$1`, [id]);
  if (!r.rows.length) return c.json({ error: 'Remote not found' }, 404);
  const remote = r.rows[0];
  if (remote.status !== 'mounted') return c.json({ error: 'Remote is not mounted — POST /remotes/:id/mount first' }, 409);

  const srcPath = body.subPath ? path.join(remote.mount_point, body.subPath) : remote.mount_point;
  const singles = body.singles === true;
  try {
    const jobId = singles
      ? await processDirectorySingles({ srcPath, body, remoteId: id, singleFolderOnly: body.mode === 'single' })
      : await processDirectory({ srcPath, body, remoteId: id });
    return c.json({ jobId, srcPath, remoteId: id, mode: singles ? 'singles' : 'grouped' }, 202);
  } catch (err) {
    return c.json({ error: err.message }, 500);
  }
});

// ── /jobs ────────────────────────────────────────────────────────────────
app.get('/jobs', async (c) => {
  const status = c.req.query('status');
  const mode   = c.req.query('mode');
  const limit  = Math.min(parseInt(c.req.query('limit')  || '50'),  200);
  const offset = parseInt(c.req.query('offset') || '0');
  const conditions = [], vals = [];
  if (status) { conditions.push(`status=$${vals.length+1}`); vals.push(status); }
  if (mode)   { conditions.push(`mode=$${vals.length+1}`);   vals.push(mode); }
  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
  const query = `SELECT * FROM jobs ${where} ORDER BY created_at DESC LIMIT ${limit} OFFSET ${offset}`;
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

// ── /logs ────────────────────────────────────────────────────────────────
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

// ── /media ───────────────────────────────────────────────────────────────
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
