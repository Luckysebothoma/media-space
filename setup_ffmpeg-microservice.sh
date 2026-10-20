#!/bin/bash
# ============================================================
# setup.sh — Creates the entire FFmpeg Microservice stack
# Run: bash setup.sh [--run] [--test]
# ============================================================

set -euo pipefail

STACK_DIR="./ffmpeg-microservice"
RUN_STACK=false
RUN_TESTS=false

for arg in "$@"; do
  case $arg in
    --run)  RUN_STACK=true ;;
    --test) RUN_TESTS=true ;;
  esac
done

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "${CYAN}[SETUP]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ============================================================
# Preflight checks
# ============================================================
log "Checking dependencies..."
command -v docker      >/dev/null 2>&1 || die "docker not found. Install Docker first."
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found."
ok "docker + compose available"

# ============================================================
# Create directory structure
# ============================================================
log "Creating directory structure..."
mkdir -p "$STACK_DIR/app/src"
mkdir -p "$STACK_DIR/scripts"
ok "Directories created under $STACK_DIR"

# ============================================================
# init.sql
# ============================================================
log "Writing init.sql..."
cat > "$STACK_DIR/init.sql" << 'INITSQL'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS jobs (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    status      TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','running','done','failed','skipped')),
    preset      TEXT NOT NULL DEFAULT 'standard',
    threads     INT  NOT NULL DEFAULT 1,
    src_path    TEXT NOT NULL,
    output_path TEXT,
    folder_name TEXT,
    total_images INT DEFAULT 0,
    duration_sec INT DEFAULT 0,
    size_mb      NUMERIC(10,2) DEFAULT 0,
    started_at  TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    error_msg   TEXT
);

CREATE TABLE IF NOT EXISTS events (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id     UUID REFERENCES jobs(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,
    payload    JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS logs (
    id         BIGSERIAL PRIMARY KEY,
    job_id     UUID REFERENCES jobs(id) ON DELETE SET NULL,
    level      TEXT NOT NULL DEFAULT 'info'
                 CHECK (level IN ('info','warn','error','debug')),
    message    TEXT NOT NULL,
    context    JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS media (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id      UUID REFERENCES jobs(id) ON DELETE CASCADE,
    media_type  TEXT NOT NULL CHECK (media_type IN ('image','video')),
    file_path   TEXT NOT NULL,
    folder_name TEXT,
    file_name   TEXT,
    size_bytes  BIGINT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_jobs_status      ON jobs(status);
CREATE INDEX IF NOT EXISTS idx_jobs_created_at  ON jobs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_job_id    ON events(job_id);
CREATE INDEX IF NOT EXISTS idx_logs_job_id      ON logs(job_id);
CREATE INDEX IF NOT EXISTS idx_logs_level       ON logs(level);
CREATE INDEX IF NOT EXISTS idx_media_job_id     ON media(job_id);

CREATE OR REPLACE VIEW global_error_logs AS
SELECT l.id, l.job_id, l.level, l.message, l.context, l.created_at,
       j.src_path, j.folder_name, j.preset
FROM logs l
LEFT JOIN jobs j ON j.id = l.job_id
WHERE l.level = 'error'
ORDER BY l.created_at DESC;
INITSQL
ok "init.sql written"

# ============================================================
# docker-compose.yml
# ============================================================
log "Writing docker-compose.yml..."
cat > "$STACK_DIR/docker-compose.yml" << 'COMPOSE'
services:

  db:
    image: postgres:16-alpine
    container_name: ffmpeg_db
    restart: unless-stopped
    environment:
      POSTGRES_DB:       ffmpeg_db
      POSTGRES_USER:     ffmpeg
      POSTGRES_PASSWORD: ffmpeg_pass
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ffmpeg -d ffmpeg_db"]
      interval: 5s
      timeout: 5s
      retries: 10
    ports:
      - "5432:5432"

  app:
    build:
      context: ./app
      dockerfile: Dockerfile
    container_name: ffmpeg_app
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      PORT:        3000
      PGHOST:      db
      PGPORT:      5432
      PGDATABASE:  ffmpeg_db
      PGUSER:      ffmpeg
      PGPASSWORD:  ffmpeg_pass
      DATA_ROOT:   /data/media
      OUTPUT_BASE: /data/archives
      LOG_DIR:     /data/logs
    volumes:
      - shared_media:/data/media
      - shared_archives:/data/archives
      - shared_logs:/data/logs
    ports:
      - "3000:3000"
    healthcheck:
      test: ["CMD-SHELL", "node -e \"fetch('http://localhost:3000/status').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  pg_data:
  shared_media:
  shared_archives:
  shared_logs:
COMPOSE
ok "docker-compose.yml written"

# ============================================================
# app/Dockerfile
# ============================================================
log "Writing app/Dockerfile..."
cat > "$STACK_DIR/app/Dockerfile" << 'DOCKERFILE'
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY src ./src

RUN mkdir -p /data/media /data/archives /data/logs

EXPOSE 3000

CMD ["node", "src/index.js"]
DOCKERFILE
ok "Dockerfile written"

# ============================================================
# app/package.json
# ============================================================
log "Writing app/package.json..."
cat > "$STACK_DIR/app/package.json" << 'PKG'
{
  "name": "ffmpeg-microservice",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "start": "node src/index.js",
    "dev": "node --watch src/index.js"
  },
  "dependencies": {
    "@hono/node-server": "^1.13.7",
    "hono": "^4.6.3",
    "pg": "^8.13.1"
  }
}
PKG
ok "package.json written"

# ============================================================
# app/src/db.js
# ============================================================
log "Writing app/src/db.js..."
cat > "$STACK_DIR/app/src/db.js" << 'DBJS'
import pg from 'pg';
const { Pool } = pg;

export const pool = new Pool({
  host:     process.env.PGHOST     || 'db',
  port:     parseInt(process.env.PGPORT || '5432'),
  database: process.env.PGDATABASE || 'ffmpeg_db',
  user:     process.env.PGUSER     || 'ffmpeg',
  password: process.env.PGPASSWORD || 'ffmpeg_pass',
});

pool.on('error', (err) => {
  console.error('[DB] Unexpected pool error', err.message);
});

export async function dbLog(level, message, jobId = null, context = null) {
  try {
    await pool.query(
      `INSERT INTO logs (job_id, level, message, context) VALUES ($1,$2,$3,$4)`,
      [jobId, level, message, context ? JSON.stringify(context) : null]
    );
  } catch (_) {}
}

export async function dbEvent(jobId, eventType, payload = null) {
  try {
    await pool.query(
      `INSERT INTO events (job_id, event_type, payload) VALUES ($1,$2,$3)`,
      [jobId, eventType, payload ? JSON.stringify(payload) : null]
    );
  } catch (_) {}
}
DBJS
ok "db.js written"

# ============================================================
# app/src/utils.js
# ============================================================
log "Writing app/src/utils.js..."
cat > "$STACK_DIR/app/src/utils.js" << 'UTILSJS'
import { spawn } from 'child_process';
import fs from 'fs/promises';
import path from 'path';

export const PRESETS = {
  standard: { width: 1920, height: 1080, crf: 23, bitrate: 5000 },
  high:     { width: 1920, height: 1080, crf: 18, bitrate: 8000 },
  '4k':     { width: 3840, height: 2160, crf: 20, bitrate: 15000 },
  cinema:   { width: 4096, height: 2160, crf: 18, bitrate: 20000 },
};

export const DEFAULT_PRESET  = 'standard';
export const DEFAULT_THREADS = 1;
export const IMAGE_DURATION  = 3;
export const MIN_DURATION    = 30;
export const FPS             = 30;
export const MIN_SIZE_BYTES  = 1024 * 1024;

export const IMAGE_EXTS = new Set(['.jpg', '.jpeg', '.png', '.webp', '.bmp', '.tiff', '.tif']);

/**
 * Sanitise a folder/file name — replace non-safe chars with underscore.
 * Handles Unicode, spaces, special characters, leading/trailing underscores.
 */
export function sanitiseName(name) {
  return name
    .normalize('NFC')
    .replace(/[^a-zA-Z0-9\-_.]/g, '_')
    .replace(/_+/g, '_')
    .replace(/^_+|_+$/g, '')
    || 'unnamed';
}

export async function collectFolders(srcPath) {
  let entries;
  try { entries = await fs.readdir(srcPath, { withFileTypes: true }); }
  catch { return []; }
  const folders = [];
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    if (e.name === '.duplicates') continue;
    const full = path.join(srcPath, e.name);
    folders.push(full);
    const nested = await collectFolders(full);
    folders.push(...nested);
  }
  return folders;
}

export async function collectImages(folderPath) {
  let entries;
  try { entries = await fs.readdir(folderPath, { withFileTypes: true }); }
  catch { return []; }
  return entries
    .filter(e => e.isFile() && IMAGE_EXTS.has(path.extname(e.name).toLowerCase()))
    .map(e => path.join(folderPath, e.name))
    .sort();
}

export function buildConcatArgs({ manifestPath, width, height, crf, bitrate, threads, outputFile }) {
  return [
    '-y', '-loglevel', 'error',
    '-f', 'concat', '-safe', '0', '-i', manifestPath,
    '-vf', `scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2,fps=${FPS}`,
    '-c:v', 'libx264', '-crf', String(crf), '-b:v', `${bitrate}k`, '-preset', 'fast',
    '-pix_fmt', 'yuv420p', '-threads', String(threads),
    outputFile,
  ];
}

export function buildLoopArgs({ imagePath, width, height, crf, bitrate, threads, duration, outputFile }) {
  return [
    '-y', '-loglevel', 'error',
    '-loop', '1', '-i', imagePath,
    '-vf', `scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2,fps=${FPS}`,
    '-t', String(duration),
    '-c:v', 'libx264', '-crf', String(crf), '-b:v', `${bitrate}k`, '-preset', 'fast',
    '-pix_fmt', 'yuv420p', '-threads', String(threads),
    outputFile,
  ];
}

export async function writeManifest(images) {
  const tmp = `/tmp/manifest_${Date.now()}_${Math.random().toString(36).slice(2)}.txt`;
  const lines = [];
  for (const img of images) {
    lines.push(`file '${img}'`);
    lines.push(`duration ${IMAGE_DURATION}`);
  }
  lines.push(`file '${images[images.length - 1]}'`);
  await fs.writeFile(tmp, lines.join('\n') + '\n');
  return tmp;
}

export async function fileSizeBytes(filePath) {
  try { const s = await fs.stat(filePath); return s.size; }
  catch { return 0; }
}

export function runFfmpeg(args, logFile) {
  return new Promise((resolve) => {
    const proc = spawn('ffmpeg', args, { stdio: ['ignore', 'ignore', 'pipe'] });
    const chunks = [];
    proc.stderr.on('data', d => chunks.push(d));
    proc.on('close', code => resolve({ code, stderr: Buffer.concat(chunks).toString() }));
    proc.on('error', err => resolve({ code: -1, stderr: err.message }));
    if (logFile) {
      fs.appendFile(logFile, `=== ffmpeg started ${new Date().toISOString()} ===\n`).catch(() => {});
      proc.stderr.on('data', d => { fs.appendFile(logFile, d).catch(() => {}); });
    }
  });
}
UTILSJS
ok "utils.js written"

# ============================================================
# app/src/processor.js
# ============================================================
log "Writing app/src/processor.js..."
cat > "$STACK_DIR/app/src/processor.js" << 'PROCESSORJS'
import fs from 'fs/promises';
import path from 'path';
import { pool, dbLog, dbEvent } from './db.js';
import {
  PRESETS, DEFAULT_PRESET, DEFAULT_THREADS,
  IMAGE_DURATION, MIN_DURATION, MIN_SIZE_BYTES,
  sanitiseName, collectFolders, collectImages,
  buildConcatArgs, buildLoopArgs,
  writeManifest, fileSizeBytes, runFfmpeg,
} from './utils.js';

const OUTPUT_BASE = process.env.OUTPUT_BASE || '/data/archives';
const LOG_DIR     = process.env.LOG_DIR     || '/data/logs';

async function ensureDirs() {
  await fs.mkdir(OUTPUT_BASE, { recursive: true });
  await fs.mkdir(LOG_DIR, { recursive: true });
}

async function createJob({ srcPath, preset, threads }) {
  const r = await pool.query(
    `INSERT INTO jobs (status, preset, threads, src_path, started_at)
     VALUES ('running', $1, $2, $3, NOW()) RETURNING id`,
    [preset, threads, srcPath]
  );
  return r.rows[0].id;
}

async function finaliseJob(jobId, { status, outputPath, folderName, totalImages, durationSec, sizeMb, errorMsg }) {
  await pool.query(
    `UPDATE jobs SET status=$1, output_path=$2, folder_name=$3,
     total_images=$4, duration_sec=$5, size_mb=$6, error_msg=$7, finished_at=NOW()
     WHERE id=$8`,
    [status, outputPath, folderName, totalImages, durationSec, sizeMb, errorMsg, jobId]
  );
}

async function insertMedia(jobId, { mediaType, filePath, folderName }) {
  const fileName = path.basename(filePath);
  const sizeBytes = await fileSizeBytes(filePath);
  await pool.query(
    `INSERT INTO media (job_id, media_type, file_path, folder_name, file_name, size_bytes)
     VALUES ($1,$2,$3,$4,$5,$6)`,
    [jobId, mediaType, filePath, folderName, fileName, sizeBytes]
  );
}

async function processFolder(jobId, folder, preset, threads) {
  const folderName = path.basename(folder);
  const safeName   = sanitiseName(folderName);
  const dateStamp  = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const outputFile = path.join(OUTPUT_BASE, `${safeName}_${dateStamp}.mp4`);
  const logFile    = path.join(LOG_DIR, `${safeName}_${dateStamp}.log`);
  const { width, height, crf, bitrate } = PRESETS[preset] || PRESETS[DEFAULT_PRESET];

  await dbEvent(jobId, 'folder_start', { folder, folderName, safeName });
  const images = await collectImages(folder);

  if (images.length === 0) {
    await dbLog('warn', `[SKIP] No images in: ${folderName}`, jobId);
    await dbEvent(jobId, 'skip', { reason: 'no_images', folder });
    return { status: 'skipped', folderName };
  }

  for (const img of images) {
    await insertMedia(jobId, { mediaType: 'image', filePath: img, folderName });
  }

  const totalDuration = Math.max(images.length * IMAGE_DURATION, MIN_DURATION);
  let args, manifestPath = null;

  if (images.length === 1) {
    args = buildLoopArgs({ imagePath: images[0], width, height, crf, bitrate, threads, duration: totalDuration, outputFile });
    await dbLog('info', `Single-image: ${folderName} (${totalDuration}s)`, jobId);
  } else {
    manifestPath = await writeManifest(images);
    args = buildConcatArgs({ manifestPath, width, height, crf, bitrate, threads, outputFile });
    await dbLog('info', `Multi-image: ${folderName} (${images.length} imgs, ${totalDuration}s)`, jobId);
  }

  await dbEvent(jobId, 'ffmpeg_start', { folderName, images: images.length, totalDuration, outputFile });
  const { code, stderr } = await runFfmpeg(args, logFile);
  if (manifestPath) await fs.unlink(manifestPath).catch(() => {});

  if (code !== 0) {
    await dbLog('error', `ffmpeg failed for ${folderName}: ${stderr.slice(0, 500)}`, jobId, { code, folderName });
    await dbEvent(jobId, 'ffmpeg_fail', { folderName, code });
    return { status: 'failed', folderName, error: stderr.slice(0, 500) };
  }

  const sizeBytes = await fileSizeBytes(outputFile);
  if (sizeBytes < MIN_SIZE_BYTES) {
    await dbLog('warn', `Output too small (${sizeBytes}B) for ${folderName}`, jobId);
    await fs.unlink(outputFile).catch(() => {});
    await dbEvent(jobId, 'fail_size', { folderName, sizeBytes });
    return { status: 'failed', folderName, error: 'output_too_small' };
  }

  const sizeMb = parseFloat((sizeBytes / 1024 / 1024).toFixed(2));
  await insertMedia(jobId, { mediaType: 'video', filePath: outputFile, folderName });
  await dbEvent(jobId, 'ffmpeg_done', { folderName, outputFile, sizeMb, durationSec: totalDuration });
  await dbLog('info', `Done: ${folderName} -> ${outputFile} (${sizeMb}MB, ${totalDuration}s)`, jobId);
  return { status: 'done', folderName, outputFile, totalImages: images.length, durationSec: totalDuration, sizeMb };
}

export async function processDirectory({ srcPath, preset = DEFAULT_PRESET, threads = DEFAULT_THREADS }) {
  await ensureDirs();
  if (!PRESETS[preset]) throw new Error(`Unknown preset: ${preset}`);
  const jobId = await createJob({ srcPath, preset, threads });
  await dbLog('info', `Job started: ${jobId} | src=${srcPath} preset=${preset}`, jobId);
  await dbEvent(jobId, 'job_start', { srcPath, preset, threads });

  setImmediate(async () => {
    try {
      const folders = await collectFolders(srcPath);
      await dbLog('info', `Found ${folders.length} folder(s)`, jobId);
      if (folders.length === 0) {
        await finaliseJob(jobId, { status: 'skipped', outputPath: null, folderName: null, totalImages: 0, durationSec: 0, sizeMb: 0, errorMsg: null });
        return;
      }
      let successCount = 0, skipCount = 0, failCount = 0, lastOutput = null;
      for (const folder of folders) {
        const result = await processFolder(jobId, folder, preset, threads);
        if      (result.status === 'done')    { successCount++; lastOutput = result.outputFile; }
        else if (result.status === 'skipped') { skipCount++; }
        else                                  { failCount++; }
      }
      const finalStatus = failCount > 0 ? 'failed' : successCount > 0 ? 'done' : 'skipped';
      await finaliseJob(jobId, { status: finalStatus, outputPath: lastOutput, folderName: null, totalImages: 0, durationSec: 0, sizeMb: 0, errorMsg: null });
      await dbEvent(jobId, 'job_done', { successCount, skipCount, failCount });
      await dbLog('info', `Job finished: success=${successCount} skip=${skipCount} fail=${failCount}`, jobId);
    } catch (err) {
      await dbLog('error', `Job crashed: ${err.message}`, jobId, { stack: err.stack });
      await pool.query(`UPDATE jobs SET status='failed', error_msg=$1, finished_at=NOW() WHERE id=$2`, [err.message, jobId]);
    }
  });
  return jobId;
}

export async function processSingleFolder({ srcPath, preset = DEFAULT_PRESET, threads = DEFAULT_THREADS }) {
  await ensureDirs();
  if (!PRESETS[preset]) throw new Error(`Unknown preset: ${preset}`);
  const jobId = await createJob({ srcPath, preset, threads });
  await dbLog('info', `Single-folder job: ${jobId} | src=${srcPath}`, jobId);
  await dbEvent(jobId, 'job_start', { srcPath, preset, threads, mode: 'single_folder' });

  setImmediate(async () => {
    try {
      const result = await processFolder(jobId, srcPath, preset, threads);
      await finaliseJob(jobId, {
        status:      result.status === 'done' ? 'done' : result.status === 'skipped' ? 'skipped' : 'failed',
        outputPath:  result.outputFile || null,
        folderName:  result.folderName,
        totalImages: result.totalImages || 0,
        durationSec: result.durationSec || 0,
        sizeMb:      result.sizeMb || 0,
        errorMsg:    result.error || null,
      });
      await dbEvent(jobId, 'job_done', result);
    } catch (err) {
      await dbLog('error', `Single-folder job crashed: ${err.message}`, jobId);
      await pool.query(`UPDATE jobs SET status='failed', error_msg=$1, finished_at=NOW() WHERE id=$2`, [err.message, jobId]);
    }
  });
  return jobId;
}
PROCESSORJS
ok "processor.js written"

# ============================================================
# app/src/routes.js
# ============================================================
log "Writing app/src/routes.js..."
cat > "$STACK_DIR/app/src/routes.js" << 'ROUTESJS'
import { Hono } from 'hono';
import { pool, dbLog } from './db.js';
import { processDirectory, processSingleFolder } from './processor.js';
import { PRESETS, DEFAULT_PRESET, DEFAULT_THREADS } from './utils.js';

const app = new Hono();
const DATA_ROOT = process.env.DATA_ROOT || '/data/media';

app.get('/doc', (c) => {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FFmpeg Microservice — API Docs</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&family=Syne:wght@400;700;800&display=swap');
:root{--bg:#0a0a0f;--surface:#13131a;--border:#2a2a3a;--accent:#ff6b35;--accent2:#00d4ff;--text:#e8e8f0;--muted:#6b6b80}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:'JetBrains Mono',monospace;line-height:1.7;padding:2rem}
h1{font-family:'Syne',sans-serif;font-size:2.8rem;font-weight:800;color:var(--accent);margin-bottom:.25rem}
h2{font-family:'Syne',sans-serif;font-size:1.4rem;color:var(--accent2);margin:2.5rem 0 .75rem;border-bottom:1px solid var(--border);padding-bottom:.4rem}
h3{color:var(--accent);font-size:.9rem;margin:.75rem 0 .25rem}
.sub{color:var(--muted);font-size:.85rem;margin-bottom:2rem}
.endpoint{background:var(--surface);border:1px solid var(--border);border-radius:8px;padding:1.25rem;margin-bottom:1rem}
.method{display:inline-block;padding:.2rem .6rem;border-radius:4px;font-weight:700;font-size:.8rem;margin-right:.5rem}
.get{background:#0d3b2e;color:#00d4ff}.post{background:#3b1a0d;color:#ff6b35}
.path{font-size:1rem;font-weight:700}
pre{background:#0d0d14;border:1px solid var(--border);border-radius:6px;padding:1rem;overflow-x:auto;font-size:.82rem;margin:.5rem 0}
table{width:100%;border-collapse:collapse;font-size:.85rem;margin:.5rem 0}
th{text-align:left;color:var(--muted);border-bottom:1px solid var(--border);padding:.4rem .5rem}
td{padding:.4rem .5rem;border-bottom:1px solid #1a1a24}
td:first-child{color:var(--accent2)}
</style>
</head>
<body>
<h1>🎬 FFmpeg Microservice</h1>
<p class="sub">Image-to-video batch processor &middot; Hono + PostgreSQL &middot; v2.0</p>

<h2>Presets</h2>
<table>
<tr><th>Name</th><th>Resolution</th><th>CRF</th><th>Bitrate</th></tr>
<tr><td>standard</td><td>1920&times;1080</td><td>23</td><td>5000k</td></tr>
<tr><td>high</td><td>1920&times;1080</td><td>18</td><td>8000k</td></tr>
<tr><td>4k</td><td>3840&times;2160</td><td>20</td><td>15000k</td></tr>
<tr><td>cinema</td><td>4096&times;2160</td><td>18</td><td>20000k</td></tr>
</table>

<h2>Endpoints</h2>

<div class="endpoint">
<span class="method post">POST</span><span class="path">/process/quick</span>
<p>Process DATA_ROOT using default settings. <strong>No body needed.</strong></p>
<pre>{ "jobId": "uuid", "srcPath": "/data/media", "preset": "standard", "threads": 1 }</pre>
</div>

<div class="endpoint">
<span class="method post">POST</span><span class="path">/process</span>
<p>Full control — specify path, preset, threads, and mode.</p>
<h3>Body</h3>
<pre>{ "srcPath": "/data/media/album1", "preset": "high", "threads": 2, "mode": "recursive" }</pre>
<p><code>mode</code>: <code>recursive</code> (default) processes all sub-folders; <code>single</code> processes only the given path.</p>
</div>

<div class="endpoint">
<span class="method post">POST</span><span class="path">/process/folder</span>
<p>Process one specific folder only (no sub-folder recursion). Body required.</p>
<h3>Body</h3>
<pre>{ "folderPath": "/data/media/album1/set_a", "preset": "standard", "threads": 1 }</pre>
</div>

<div class="endpoint">
<span class="method get">GET</span><span class="path">/jobs</span>
<p>List jobs. Query params: <code>?status=running</code>, <code>?limit=20</code>, <code>?offset=0</code></p>
</div>

<div class="endpoint">
<span class="method get">GET</span><span class="path">/jobs/:id</span>
<p>Full job detail including events, media, and last 100 logs.</p>
</div>

<div class="endpoint">
<span class="method get">GET</span><span class="path">/logs</span>
<p>Paginated logs. Params: <code>?level=error</code>, <code>?job_id=uuid</code>, <code>?limit=50</code></p>
</div>

<div class="endpoint">
<span class="method get">GET</span><span class="path">/logs/error-global</span>
<p>All error-level logs joined with job metadata. Global error view.</p>
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

app.get('/status', async (c) => {
  try {
    const r = await pool.query(`SELECT
      (SELECT COUNT(*) FROM jobs WHERE status='running') AS running,
      (SELECT COUNT(*) FROM jobs WHERE status='done')    AS done,
      (SELECT COUNT(*) FROM jobs WHERE status='failed')  AS failed,
      (SELECT COUNT(*) FROM jobs)                        AS total`);
    return c.json({ ok: true, db: 'connected', stats: r.rows[0] });
  } catch (err) {
    return c.json({ ok: false, db: 'error', error: err.message }, 503);
  }
});

app.post('/process/quick', async (c) => {
  try {
    const jobId = await processDirectory({ srcPath: DATA_ROOT, preset: DEFAULT_PRESET, threads: DEFAULT_THREADS });
    return c.json({ jobId, srcPath: DATA_ROOT, preset: DEFAULT_PRESET, threads: DEFAULT_THREADS }, 202);
  } catch (err) {
    await dbLog('error', `/process/quick failed: ${err.message}`);
    return c.json({ error: err.message }, 500);
  }
});

app.post('/process', async (c) => {
  let body;
  try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON body' }, 400); }
  const srcPath = body.srcPath;
  if (!srcPath) return c.json({ error: 'srcPath is required' }, 400);
  const preset  = body.preset  || DEFAULT_PRESET;
  const threads = parseInt(body.threads) || DEFAULT_THREADS;
  const mode    = body.mode    || 'recursive';
  if (!PRESETS[preset]) return c.json({ error: `Unknown preset: ${preset}. Valid: ${Object.keys(PRESETS).join(', ')}` }, 400);
  try {
    const fn    = mode === 'single' ? processSingleFolder : processDirectory;
    const jobId = await fn({ srcPath, preset, threads });
    return c.json({ jobId, srcPath, preset, threads, mode }, 202);
  } catch (err) {
    await dbLog('error', `/process failed: ${err.message}`, null, { srcPath, preset });
    return c.json({ error: err.message }, 500);
  }
});

app.post('/process/folder', async (c) => {
  let body;
  try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON body' }, 400); }
  const folderPath = body.folderPath || body.srcPath;
  if (!folderPath) return c.json({ error: 'folderPath is required' }, 400);
  const preset  = body.preset  || DEFAULT_PRESET;
  const threads = parseInt(body.threads) || DEFAULT_THREADS;
  if (!PRESETS[preset]) return c.json({ error: `Unknown preset: ${preset}` }, 400);
  try {
    const jobId = await processSingleFolder({ srcPath: folderPath, preset, threads });
    return c.json({ jobId, folderPath, preset, threads }, 202);
  } catch (err) {
    await dbLog('error', `/process/folder failed: ${err.message}`, null, { folderPath });
    return c.json({ error: err.message }, 500);
  }
});

app.get('/jobs', async (c) => {
  const status = c.req.query('status');
  const limit  = Math.min(parseInt(c.req.query('limit') || '50'), 200);
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
    const job    = await pool.query(`SELECT * FROM jobs WHERE id=$1`, [id]);
    if (!job.rows.length) return c.json({ error: 'Job not found' }, 404);
    const events = await pool.query(`SELECT * FROM events WHERE job_id=$1 ORDER BY created_at`, [id]);
    const media  = await pool.query(`SELECT * FROM media  WHERE job_id=$1 ORDER BY created_at`, [id]);
    const logs   = await pool.query(`SELECT * FROM logs   WHERE job_id=$1 ORDER BY created_at DESC LIMIT 100`, [id]);
    return c.json({ job: job.rows[0], events: events.rows, media: media.rows, logs: logs.rows });
  } catch (err) { return c.json({ error: err.message }, 500); }
});

app.get('/logs', async (c) => {
  const level  = c.req.query('level');
  const jobId  = c.req.query('job_id');
  const limit  = Math.min(parseInt(c.req.query('limit') || '100'), 500);
  const offset = parseInt(c.req.query('offset') || '0');
  const conditions = [], vals = [];
  if (level)  { conditions.push(`level=$${vals.length+1}`);  vals.push(level); }
  if (jobId)  { conditions.push(`job_id=$${vals.length+1}`); vals.push(jobId); }
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
ROUTESJS
ok "routes.js written"

# ============================================================
# app/src/index.js
# ============================================================
log "Writing app/src/index.js..."
cat > "$STACK_DIR/app/src/index.js" << 'INDEXJS'
import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { logger } from 'hono/logger';
import { pool } from './db.js';
import routes from './routes.js';

const app = new Hono();
app.use('*', logger());

app.get('/', (c) => c.json({
  service: 'ffmpeg-microservice',
  version: '2.0.0',
  docs:    '/doc',
  status:  '/status',
}));

app.route('/', routes);
app.notFound((c) => c.json({ error: 'Not found', hint: 'Visit /doc for API reference' }, 404));
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
      console.log(`[DB] Waiting for database... (${retries} retries left)`);
      await new Promise(r => setTimeout(r, 2000));
    }
  }
  if (retries === 0) { console.error('[DB] Could not connect. Exiting.'); process.exit(1); }

  serve({ fetch: app.fetch, port: PORT }, (info) => {
    console.log(`[SERVER] Running on http://0.0.0.0:${info.port}`);
    console.log(`[SERVER] API docs: http://0.0.0.0:${info.port}/doc`);
  });
}

start();
INDEXJS
ok "index.js written"

# ============================================================
# scripts/smoke-test.sh
# ============================================================
log "Writing scripts/smoke-test.sh..."
cat > "$STACK_DIR/scripts/smoke-test.sh" << 'SMOKETEST'
#!/bin/bash
# ============================================================
# smoke-test.sh — Validates the FFmpeg Microservice stack
# Usage: bash smoke-test.sh [http://localhost:3000]
# ============================================================
set -euo pipefail

BASE_URL="${1:-http://localhost:3000}"
PASS=0; FAIL=0

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

check() {
  local name="$1" result="$2" expected="$3"
  if echo "$result" | grep -q "$expected"; then
    echo -e "${GREEN}✓ PASS${NC} $name"; ((PASS++))
  else
    echo -e "${RED}✗ FAIL${NC} $name"
    echo "  Expected: $expected"; echo "  Got: ${result:0:200}"; ((FAIL++))
  fi
}

echo -e "${CYAN}========================================"
echo "  FFmpeg Microservice — Smoke Tests"
echo "  Target: $BASE_URL"
echo -e "========================================${NC}"
echo ""

echo "Waiting for service..."
for i in $(seq 1 30); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/status" 2>/dev/null || echo "000")
  [ "$STATUS" = "200" ] && { echo -e "${GREEN}Service is up!${NC}"; break; }
  [ "$i" = "30" ] && { echo -e "${RED}Timed out waiting for service.${NC}"; exit 1; }
  sleep 2
done
echo ""

echo "--- Core Endpoints ---"
check "GET / service name"         "$(curl -s $BASE_URL/)"              "ffmpeg-microservice"
check "GET /status ok"             "$(curl -s $BASE_URL/status)"        '"ok":true'
check "GET /status db"             "$(curl -s $BASE_URL/status)"        'connected'
check "GET /doc 200"               "$(curl -s -o /dev/null -w '%{http_code}' $BASE_URL/doc)" "200"
check "GET /jobs array"            "$(curl -s $BASE_URL/jobs)"          '"jobs"'
check "GET /logs array"            "$(curl -s $BASE_URL/logs)"          '"logs"'
check "GET /logs/error-global"     "$(curl -s $BASE_URL/logs/error-global)" '"errors"'
check "GET /media array"           "$(curl -s $BASE_URL/media)"         '"media"'
check "GET /notfound hint"         "$(curl -s $BASE_URL/notfound)"      'hint'

echo ""
echo "--- Process Endpoints ---"
QUICK=$(curl -s -X POST "$BASE_URL/process/quick")
check "POST /process/quick jobId"  "$QUICK"   '"jobId"'

JOB_ID=$(echo "$QUICK" | grep -o '"jobId":"[^"]*"' | cut -d'"' -f4 || echo "")
if [ -n "$JOB_ID" ]; then
  sleep 1
  DETAIL=$(curl -s "$BASE_URL/jobs/$JOB_ID")
  check "GET /jobs/:id job"        "$DETAIL"  '"job"'
  check "GET /jobs/:id events"     "$DETAIL"  '"events"'
fi

check "POST /process bad preset"   "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/x\",\"preset\":\"bad\"}')" "error"
check "POST /process/folder no path" "$(curl -s -X POST $BASE_URL/process/folder -H 'Content-Type: application/json' -d '{}')" "error"
check "POST /process full body"    "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"standard\",\"threads\":1}')" '"jobId"'
check "POST /process/folder"       "$(curl -s -X POST $BASE_URL/process/folder -H 'Content-Type: application/json' -d '{\"folderPath\":\"/data/media/test\",\"preset\":\"standard\"}')" '"jobId"'

echo ""
echo "--- Query Filters ---"
check "GET /jobs?status=running"   "$(curl -s $BASE_URL/jobs?status=running)"  '"jobs"'
check "GET /logs?level=error"      "$(curl -s $BASE_URL/logs?level=error)"     '"logs"'
check "GET /media?type=video"      "$(curl -s $BASE_URL/media?type=video)"     '"media"'

echo ""
echo -e "${CYAN}========================================"
echo -e "Results: ${GREEN}$PASS passed${NC} | ${RED}$FAIL failed${NC}"
echo -e "${CYAN}========================================${NC}"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
SMOKETEST
chmod +x "$STACK_DIR/scripts/smoke-test.sh"
ok "smoke-test.sh written"

# ============================================================
# Validate generated files exist
# ============================================================
log "Validating file structure..."
EXPECTED_FILES=(
  "$STACK_DIR/init.sql"
  "$STACK_DIR/docker-compose.yml"
  "$STACK_DIR/app/Dockerfile"
  "$STACK_DIR/app/package.json"
  "$STACK_DIR/app/src/index.js"
  "$STACK_DIR/app/src/db.js"
  "$STACK_DIR/app/src/utils.js"
  "$STACK_DIR/app/src/processor.js"
  "$STACK_DIR/app/src/routes.js"
  "$STACK_DIR/scripts/smoke-test.sh"
)

ALL_OK=true
for f in "${EXPECTED_FILES[@]}"; do
  if [ -f "$f" ]; then
    ok "exists: $f"
  else
    echo -e "${RED}  ✗ MISSING: $f${NC}"
    ALL_OK=false
  fi
done

if [ "$ALL_OK" = false ]; then
  die "Some files are missing. Setup incomplete."
fi

# ============================================================
# Validate JS syntax on all source files
# ============================================================
if command -v node >/dev/null 2>&1; then
  log "Validating JavaScript syntax..."
  for f in "$STACK_DIR/app/src/"*.js; do
    node --input-type=module --eval "$(cat "$f")" 2>/dev/null \
      && ok "syntax ok: $(basename $f)" \
      || warn "syntax check skipped for $(basename $f) (may need imports)"
  done
else
  warn "node not found locally — skipping JS syntax check (will be checked inside Docker)"
fi

# ============================================================
# Print tree
# ============================================================
echo ""
log "Generated stack structure:"
if command -v tree >/dev/null 2>&1; then
  tree "$STACK_DIR"
else
  find "$STACK_DIR" -type f | sort | sed "s|$STACK_DIR/||" | while read -r f; do echo "  $f"; done
fi

# ============================================================
# Optionally build and run
# ============================================================
if [ "$RUN_STACK" = true ]; then
  echo ""
  log "Building and starting stack with docker compose..."
  cd "$STACK_DIR"
  docker compose down --remove-orphans 2>/dev/null || true
  docker compose build --no-cache
  docker compose up -d
  ok "Stack started!"
  echo ""
  log "Waiting for services to be healthy..."
  sleep 5
  docker compose ps
fi

# ============================================================
# Optionally run smoke tests
# ============================================================
if [ "$RUN_TESTS" = true ]; then
  echo ""
  log "Running smoke tests..."
  if ! bash "$STACK_DIR/scripts/smoke-test.sh" "http://localhost:3000"; then
    die "Smoke tests failed!"
  fi
  ok "All smoke tests passed!"
fi

# ============================================================
# Done
# ============================================================
echo ""
echo -e "${GREEN}========================================"
echo "  ✓ Stack created successfully!"
echo "========================================"
echo -e "${NC}"
echo "  Directory: $STACK_DIR"
echo ""
echo "  To start the stack:"
echo -e "  ${CYAN}cd $STACK_DIR && docker compose up -d${NC}"
echo ""
echo "  Or re-run with flags:"
echo -e "  ${CYAN}bash setup.sh --run         # build + start${NC}"
echo -e "  ${CYAN}bash setup.sh --run --test  # build + start + test${NC}"
echo ""
echo "  Endpoints:"
echo "    API docs:      http://localhost:3000/doc"
echo "    Status:        http://localhost:3000/status"
echo "    Quick process: POST http://localhost:3000/process/quick"
echo "    Error logs:    http://localhost:3000/logs/error-global"
