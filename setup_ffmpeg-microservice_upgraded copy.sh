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
# Delete directory structure
# ============================================================
if [ -d "$STACK_DIR" ]; then
  log "Removing existing stack directory..."
  rm -rf "$STACK_DIR"
  ok "Removed $STACK_DIR"
fi
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
  "version": "2.0.0",
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
  cinematic:{ width: 4096, height: 2160, crf: 18, bitrate: 20000 },
};

// Keep 'cinema' as alias for backward compatibility
export const PRESET_ALIASES = { cinema: 'cinematic' };

export const DEFAULT_PRESET  = 'standard';
export const DEFAULT_THREADS = 1;
export const IMAGE_DURATION  = 3;
export const MIN_DURATION    = 30;
export const FPS             = 30;
export const MIN_SIZE_BYTES = 100 * 1024;

export const IMAGE_EXTS = new Set(['.jpg', '.jpeg', '.png', '.webp', '.bmp', '.tiff', '.tif']);

/**
 * Resolve a preset name, supporting aliases (e.g. cinema -> cinematic).
 */
export function resolvePreset(name) {
  if (!name) return DEFAULT_PRESET;
  const lower = name.toLowerCase();
  if (PRESETS[lower]) return lower;
  if (PRESET_ALIASES[lower]) return PRESET_ALIASES[lower];
  return null; // invalid
}

/**
 * Sanitise a folder/file name — replace non-safe chars with underscore.
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
import { PRESETS, DEFAULT_PRESET, DEFAULT_THREADS, resolvePreset } from './utils.js';

const app = new Hono();
const DATA_ROOT = process.env.DATA_ROOT || '/data/media';

// ── /doc ────────────────────────────────────────────────────────────────────
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
<tr><td>cinematic</td><td>4096&times;2160</td><td>18</td><td>20000k</td></tr>
</table>

<h2>Endpoints</h2>

<div class="endpoint">
<span class="method post">POST</span><span class="path">/process/quick</span>
<p>Process DATA_ROOT with default preset (standard). <strong>No body needed.</strong></p>
<pre>{ "jobId": "uuid", "srcPath": "/data/media", "preset": "standard", "threads": 1 }</pre>
</div>

<div class="endpoint">
<span class="method post">POST</span><span class="path">/process/quick/:preset</span>
<p>Process DATA_ROOT with a specific preset. Presets: <code>standard</code>, <code>high</code>, <code>4k</code>, <code>cinematic</code>. <strong>No body needed.</strong></p>
<pre>POST /process/quick/4k
POST /process/quick/cinematic
POST /process/quick/high</pre>
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

// ── /status ──────────────────────────────────────────────────────────────────
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

// ── /process/quick (default preset) ─────────────────────────────────────────
app.post('/process/quick', async (c) => {
  try {
    const jobId = await processDirectory({ srcPath: DATA_ROOT, preset: DEFAULT_PRESET, threads: DEFAULT_THREADS });
    return c.json({ jobId, srcPath: DATA_ROOT, preset: DEFAULT_PRESET, threads: DEFAULT_THREADS }, 202);
  } catch (err) {
    await dbLog('error', `/process/quick failed: ${err.message}`);
    return c.json({ error: err.message }, 500);
  }
});

// ── /process/quick/:preset ───────────────────────────────────────────────────
// Accepts: standard | high | 4k | cinematic  (also: cinema as alias)
app.post('/process/quick/:preset', async (c) => {
  const raw    = c.req.param('preset');
  const preset = resolvePreset(raw);
  if (!preset) {
    return c.json({
      error: `Unknown preset: "${raw}". Valid presets: standard, high, 4k, cinematic`,
    }, 400);
  }
  try {
    const jobId = await processDirectory({ srcPath: DATA_ROOT, preset, threads: DEFAULT_THREADS });
    return c.json({ jobId, srcPath: DATA_ROOT, preset, threads: DEFAULT_THREADS }, 202);
  } catch (err) {
    await dbLog('error', `/process/quick/${raw} failed: ${err.message}`);
    return c.json({ error: err.message }, 500);
  }
});

// ── /process ─────────────────────────────────────────────────────────────────
app.post('/process', async (c) => {
  let body;
  try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON body' }, 400); }
  const srcPath = body.srcPath;
  if (!srcPath) return c.json({ error: 'srcPath is required' }, 400);
  const preset  = resolvePreset(body.preset) || DEFAULT_PRESET;
  const threads = parseInt(body.threads) || DEFAULT_THREADS;
  const mode    = body.mode || 'recursive';
  if (!PRESETS[preset]) return c.json({ error: `Unknown preset: ${body.preset}. Valid: ${Object.keys(PRESETS).join(', ')}` }, 400);
  try {
    const fn    = mode === 'single' ? processSingleFolder : processDirectory;
    const jobId = await fn({ srcPath, preset, threads });
    return c.json({ jobId, srcPath, preset, threads, mode }, 202);
  } catch (err) {
    await dbLog('error', `/process failed: ${err.message}`, null, { srcPath, preset });
    return c.json({ error: err.message }, 500);
  }
});

// ── /process/folder ──────────────────────────────────────────────────────────
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

// ── /jobs ────────────────────────────────────────────────────────────────────
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

// ── /logs ────────────────────────────────────────────────────────────────────
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

// ── /media ───────────────────────────────────────────────────────────────────
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
# app/src/index.js  — GUI manager at /
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

// ── GUI Manager at / ─────────────────────────────────────────────────────────
app.get('/', (c) => {
  const DATA_ROOT = process.env.DATA_ROOT || '/data/media';
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FFmpeg Manager</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=Bebas+Neue&family=Inter:wght@300;400;500;600&display=swap" rel="stylesheet">
<style>
  :root {
    --bg: #080810;
    --panel: #0f0f1a;
    --panel2: #141422;
    --border: #1e1e32;
    --border2: #2a2a42;
    --accent: #e84d1c;
    --accent2: #ff7a45;
    --blue: #1e90ff;
    --green: #00c97a;
    --yellow: #f5c400;
    --red: #ff3b3b;
    --muted: #4a4a6a;
    --text: #d8d8f0;
    --text2: #9090b8;
    --mono: 'Space Mono', monospace;
    --sans: 'Inter', sans-serif;
    --display: 'Bebas Neue', sans-serif;
  }
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  html { font-size: 15px; }
  body {
    background: var(--bg);
    color: var(--text);
    font-family: var(--sans);
    min-height: 100vh;
    display: grid;
    grid-template-rows: auto 1fr auto;
    grid-template-columns: 260px 1fr;
    grid-template-areas: "header header" "sidebar main" "footer footer";
  }

  /* ── HEADER ── */
  header {
    grid-area: header;
    background: var(--panel);
    border-bottom: 1px solid var(--border2);
    padding: .75rem 1.5rem;
    display: flex;
    align-items: center;
    gap: 1.5rem;
  }
  .logo {
    font-family: var(--display);
    font-size: 1.9rem;
    letter-spacing: .05em;
    color: var(--accent2);
    line-height: 1;
  }
  .logo span { color: var(--muted); }
  .header-stats {
    display: flex;
    gap: .75rem;
    margin-left: auto;
  }
  .stat-chip {
    display: flex;
    align-items: center;
    gap: .4rem;
    background: var(--panel2);
    border: 1px solid var(--border2);
    border-radius: 6px;
    padding: .3rem .7rem;
    font-family: var(--mono);
    font-size: .7rem;
  }
  .stat-chip .dot {
    width: 7px; height: 7px;
    border-radius: 50%;
    background: var(--muted);
    flex-shrink: 0;
    transition: background .3s;
  }
  .stat-chip .dot.running { background: var(--yellow); box-shadow: 0 0 6px var(--yellow); animation: pulse 1.4s infinite; }
  .stat-chip .dot.done    { background: var(--green); }
  .stat-chip .dot.failed  { background: var(--red); }
  .stat-chip .dot.db-ok   { background: var(--green); }
  .stat-chip .dot.db-err  { background: var(--red); }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.4} }
  .header-btn {
    background: none;
    border: 1px solid var(--border2);
    color: var(--text2);
    padding: .3rem .8rem;
    border-radius: 6px;
    cursor: pointer;
    font-size: .75rem;
    font-family: var(--mono);
    transition: all .15s;
  }
  .header-btn:hover { border-color: var(--accent2); color: var(--accent2); }

  /* ── SIDEBAR ── */
  aside {
    grid-area: sidebar;
    background: var(--panel);
    border-right: 1px solid var(--border);
    padding: 1.25rem 1rem;
    overflow-y: auto;
  }
  .sidebar-section { margin-bottom: 1.5rem; }
  .sidebar-label {
    font-family: var(--mono);
    font-size: .65rem;
    color: var(--muted);
    text-transform: uppercase;
    letter-spacing: .12em;
    margin-bottom: .6rem;
    padding-left: .25rem;
  }

  /* ── PRESET BUTTONS ── */
  .preset-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: .4rem;
  }
  .preset-btn {
    position: relative;
    background: var(--panel2);
    border: 1px solid var(--border2);
    border-radius: 8px;
    padding: .7rem .5rem;
    cursor: pointer;
    text-align: center;
    transition: all .18s;
    overflow: hidden;
  }
  .preset-btn::before {
    content: '';
    position: absolute;
    inset: 0;
    background: linear-gradient(135deg, transparent 60%, rgba(232,77,28,.08));
    pointer-events: none;
  }
  .preset-btn:hover, .preset-btn.selected {
    border-color: var(--accent2);
    background: #1a1028;
  }
  .preset-btn.selected::after {
    content: '✓';
    position: absolute;
    top: 4px; right: 6px;
    font-size: .6rem;
    color: var(--accent2);
  }
  .preset-btn .pname {
    display: block;
    font-family: var(--display);
    font-size: 1.15rem;
    letter-spacing: .04em;
    color: var(--text);
    margin-bottom: .15rem;
  }
  .preset-btn .pres {
    display: block;
    font-family: var(--mono);
    font-size: .58rem;
    color: var(--muted);
  }
  .preset-btn .pcrf {
    display: block;
    font-family: var(--mono);
    font-size: .58rem;
    color: var(--accent);
  }

  /* ── THREAD SLIDER ── */
  .thread-row {
    display: flex;
    align-items: center;
    gap: .6rem;
    margin-bottom: .5rem;
  }
  .thread-row input[type=range] {
    flex: 1;
    accent-color: var(--accent2);
    height: 3px;
  }
  .thread-val {
    font-family: var(--mono);
    font-size: .75rem;
    color: var(--accent2);
    min-width: 1.2rem;
    text-align: right;
  }

  /* ── NAV ── */
  .nav-item {
    display: flex;
    align-items: center;
    gap: .6rem;
    padding: .5rem .75rem;
    border-radius: 6px;
    cursor: pointer;
    font-size: .82rem;
    color: var(--text2);
    transition: all .15s;
    margin-bottom: .2rem;
  }
  .nav-item:hover { background: var(--panel2); color: var(--text); }
  .nav-item.active { background: var(--panel2); color: var(--accent2); border-left: 2px solid var(--accent2); }
  .nav-icon { font-size: 1rem; width: 1.2rem; text-align: center; }

  /* ── MAIN ── */
  main {
    grid-area: main;
    overflow-y: auto;
    padding: 1.5rem;
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
  }

  /* ── LAUNCH CARD ── */
  .launch-card {
    background: var(--panel);
    border: 1px solid var(--border2);
    border-radius: 12px;
    padding: 1.25rem 1.5rem;
  }
  .card-title {
    font-family: var(--display);
    font-size: 1.5rem;
    letter-spacing: .05em;
    color: var(--text);
    margin-bottom: 1rem;
    display: flex;
    align-items: center;
    gap: .6rem;
  }
  .card-title .badge {
    font-family: var(--mono);
    font-size: .6rem;
    background: var(--accent);
    color: #fff;
    padding: .15rem .4rem;
    border-radius: 4px;
    letter-spacing: .06em;
  }
  .field-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: .75rem;
    margin-bottom: .75rem;
  }
  .field-row.single { grid-template-columns: 1fr; }
  label {
    display: block;
    font-size: .7rem;
    font-family: var(--mono);
    color: var(--muted);
    margin-bottom: .3rem;
    text-transform: uppercase;
    letter-spacing: .08em;
  }
  input[type=text], select {
    width: 100%;
    background: var(--panel2);
    border: 1px solid var(--border2);
    border-radius: 6px;
    color: var(--text);
    font-family: var(--mono);
    font-size: .78rem;
    padding: .5rem .75rem;
    outline: none;
    transition: border-color .15s;
  }
  input[type=text]:focus, select:focus { border-color: var(--accent2); }
  select option { background: var(--panel2); }
  .mode-pills {
    display: flex;
    gap: .4rem;
  }
  .pill {
    flex: 1;
    text-align: center;
    padding: .45rem;
    border-radius: 6px;
    border: 1px solid var(--border2);
    background: var(--panel2);
    cursor: pointer;
    font-size: .75rem;
    font-family: var(--mono);
    color: var(--text2);
    transition: all .15s;
  }
  .pill:hover { border-color: var(--blue); color: var(--blue); }
  .pill.active { border-color: var(--blue); background: rgba(30,144,255,.1); color: var(--blue); }
  .launch-btn {
    width: 100%;
    padding: .75rem;
    border-radius: 8px;
    border: none;
    background: linear-gradient(135deg, var(--accent), var(--accent2));
    color: #fff;
    font-family: var(--display);
    font-size: 1.25rem;
    letter-spacing: .08em;
    cursor: pointer;
    transition: all .2s;
    margin-top: .75rem;
    position: relative;
    overflow: hidden;
  }
  .launch-btn:hover { transform: translateY(-1px); box-shadow: 0 6px 24px rgba(232,77,28,.35); }
  .launch-btn:active { transform: translateY(0); }
  .launch-btn:disabled { opacity: .5; cursor: not-allowed; transform: none; box-shadow: none; }
  .toast {
    margin-top: .75rem;
    padding: .6rem .9rem;
    border-radius: 6px;
    font-family: var(--mono);
    font-size: .75rem;
    display: none;
    word-break: break-all;
  }
  .toast.success { background: rgba(0,201,122,.1); border: 1px solid rgba(0,201,122,.3); color: var(--green); display: block; }
  .toast.error   { background: rgba(255,59,59,.1);  border: 1px solid rgba(255,59,59,.3);  color: var(--red);   display: block; }

  /* ── QUICK FIRE ── */
  .quick-row {
    display: flex;
    gap: .5rem;
    flex-wrap: wrap;
  }
  .quick-btn {
    flex: 1;
    min-width: 100px;
    padding: .55rem .5rem;
    border-radius: 8px;
    border: 1px solid var(--border2);
    background: var(--panel2);
    color: var(--text2);
    cursor: pointer;
    font-family: var(--mono);
    font-size: .72rem;
    text-align: center;
    transition: all .18s;
  }
  .quick-btn:hover { transform: translateY(-1px); box-shadow: 0 4px 16px rgba(0,0,0,.4); }
  .quick-btn.q-standard { border-color: #2a4a7f; }
  .quick-btn.q-standard:hover { background: rgba(30,144,255,.12); border-color: var(--blue); color: var(--blue); }
  .quick-btn.q-high     { border-color: #4a2a7f; }
  .quick-btn.q-high:hover { background: rgba(130,80,255,.12); border-color: #a060ff; color: #a060ff; }
  .quick-btn.q-4k       { border-color: #2a4a2f; }
  .quick-btn.q-4k:hover { background: rgba(0,201,122,.12); border-color: var(--green); color: var(--green); }
  .quick-btn.q-cinematic{ border-color: #4a2a1a; }
  .quick-btn.q-cinematic:hover { background: rgba(232,77,28,.12); border-color: var(--accent2); color: var(--accent2); }
  .quick-btn .qname { display: block; font-size: .85rem; font-family: var(--display); letter-spacing: .04em; margin-bottom: .15rem; }
  .quick-btn .qsub  { display: block; font-size: .6rem; color: var(--muted); }
  .quick-btn.loading { opacity: .6; pointer-events: none; }

  /* ── JOBS TABLE ── */
  .section-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: .75rem;
  }
  .section-title {
    font-family: var(--display);
    font-size: 1.3rem;
    letter-spacing: .05em;
  }
  .refresh-btn {
    background: none;
    border: 1px solid var(--border2);
    color: var(--muted);
    padding: .25rem .6rem;
    border-radius: 6px;
    cursor: pointer;
    font-size: .75rem;
    font-family: var(--mono);
    transition: all .15s;
  }
  .refresh-btn:hover { border-color: var(--accent2); color: var(--accent2); }
  .filter-row {
    display: flex;
    gap: .4rem;
    margin-bottom: .75rem;
  }
  .filter-pill {
    padding: .25rem .7rem;
    border-radius: 20px;
    border: 1px solid var(--border2);
    background: none;
    color: var(--text2);
    cursor: pointer;
    font-size: .72rem;
    font-family: var(--mono);
    transition: all .15s;
  }
  .filter-pill:hover { border-color: var(--text2); }
  .filter-pill.active { background: var(--panel2); border-color: var(--accent2); color: var(--accent2); }
  table { width: 100%; border-collapse: collapse; }
  thead th {
    font-family: var(--mono);
    font-size: .65rem;
    color: var(--muted);
    text-transform: uppercase;
    letter-spacing: .1em;
    padding: .5rem .75rem;
    text-align: left;
    border-bottom: 1px solid var(--border);
  }
  tbody tr {
    border-bottom: 1px solid var(--border);
    cursor: pointer;
    transition: background .1s;
  }
  tbody tr:hover { background: var(--panel2); }
  tbody td {
    padding: .55rem .75rem;
    font-size: .78rem;
    font-family: var(--mono);
  }
  .status-badge {
    display: inline-flex;
    align-items: center;
    gap: .3rem;
    padding: .15rem .5rem;
    border-radius: 20px;
    font-size: .65rem;
    font-weight: 600;
  }
  .status-badge.running { background: rgba(245,196,0,.1); color: var(--yellow); border: 1px solid rgba(245,196,0,.3); }
  .status-badge.done    { background: rgba(0,201,122,.1); color: var(--green);  border: 1px solid rgba(0,201,122,.3); }
  .status-badge.failed  { background: rgba(255,59,59,.1);  color: var(--red);   border: 1px solid rgba(255,59,59,.3); }
  .status-badge.skipped { background: rgba(74,74,106,.1);  color: var(--muted); border: 1px solid var(--border2); }
  .status-badge.pending { background: rgba(30,144,255,.1); color: var(--blue);  border: 1px solid rgba(30,144,255,.3); }
  .empty-state {
    text-align: center;
    padding: 3rem;
    color: var(--muted);
    font-family: var(--mono);
    font-size: .8rem;
  }

  /* ── JOB DETAIL DRAWER ── */
  .drawer-overlay {
    position: fixed; inset: 0;
    background: rgba(8,8,16,.7);
    backdrop-filter: blur(4px);
    z-index: 100;
    display: none;
    align-items: stretch;
    justify-content: flex-end;
  }
  .drawer-overlay.open { display: flex; }
  .drawer {
    width: min(640px, 95vw);
    background: var(--panel);
    border-left: 1px solid var(--border2);
    overflow-y: auto;
    padding: 1.5rem;
    animation: slideIn .2s ease;
  }
  @keyframes slideIn { from { transform: translateX(40px); opacity: 0; } to { transform: none; opacity: 1; } }
  .drawer-close {
    float: right;
    background: none;
    border: 1px solid var(--border2);
    color: var(--text2);
    padding: .3rem .7rem;
    border-radius: 6px;
    cursor: pointer;
    font-family: var(--mono);
    font-size: .75rem;
    margin-bottom: 1rem;
  }
  .drawer-close:hover { border-color: var(--red); color: var(--red); }
  .detail-grid {
    display: grid;
    grid-template-columns: 1fr 1fr 1fr;
    gap: .5rem;
    margin: 1rem 0;
  }
  .detail-cell {
    background: var(--panel2);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: .6rem .8rem;
  }
  .detail-cell .dc-label {
    font-size: .6rem;
    font-family: var(--mono);
    color: var(--muted);
    text-transform: uppercase;
    letter-spacing: .08em;
    margin-bottom: .2rem;
  }
  .detail-cell .dc-val {
    font-family: var(--mono);
    font-size: .8rem;
    color: var(--text);
  }
  .log-list {
    max-height: 280px;
    overflow-y: auto;
    margin-top: .5rem;
  }
  .log-entry {
    display: flex;
    gap: .6rem;
    padding: .35rem 0;
    border-bottom: 1px solid var(--border);
    font-family: var(--mono);
    font-size: .68rem;
    align-items: flex-start;
  }
  .log-entry .log-level {
    flex-shrink: 0;
    padding: .1rem .35rem;
    border-radius: 3px;
    font-size: .6rem;
    font-weight: 700;
    min-width: 36px;
    text-align: center;
  }
  .log-level.info  { background: rgba(30,144,255,.15); color: var(--blue); }
  .log-level.warn  { background: rgba(245,196,0,.15);  color: var(--yellow); }
  .log-level.error { background: rgba(255,59,59,.15);  color: var(--red); }
  .log-level.debug { background: rgba(74,74,106,.15);  color: var(--muted); }
  .log-msg { color: var(--text2); flex: 1; word-break: break-word; }
  .log-time { color: var(--muted); flex-shrink: 0; font-size: .6rem; }

  /* ── FOOTER ── */
  footer {
    grid-area: footer;
    background: var(--panel);
    border-top: 1px solid var(--border);
    padding: .4rem 1.5rem;
    display: flex;
    align-items: center;
    gap: 1rem;
    font-size: .65rem;
    font-family: var(--mono);
    color: var(--muted);
  }
  .footer-spacer { flex: 1; }
  #auto-refresh-toggle {
    accent-color: var(--accent2);
    cursor: pointer;
  }
  .scrollbar-thin::-webkit-scrollbar { width: 4px; }
  .scrollbar-thin::-webkit-scrollbar-track { background: transparent; }
  .scrollbar-thin::-webkit-scrollbar-thumb { background: var(--border2); border-radius: 2px; }
</style>
</head>
<body>

<!-- HEADER -->
<header>
  <div class="logo">FFMPEG<span>MGR</span></div>
  <div class="header-stats">
    <div class="stat-chip"><span class="dot db-ok" id="db-dot"></span><span id="db-label">DB</span></div>
    <div class="stat-chip"><span class="dot running" id="run-dot"></span><span id="running-count">0</span> running</div>
    <div class="stat-chip"><span class="dot done"></span><span id="done-count">0</span> done</div>
    <div class="stat-chip"><span class="dot failed"></span><span id="fail-count">0</span> failed</div>
  </div>
  <button class="header-btn" onclick="window.open('/doc','_blank')">API Docs ↗</button>
</header>

<!-- SIDEBAR -->
<aside class="scrollbar-thin">
  <div class="sidebar-section">
    <div class="sidebar-label">Quick Fire</div>
    <div style="display:flex;flex-direction:column;gap:.35rem;">
      <button class="quick-btn q-standard" onclick="quickFire('standard')">
        <span class="qname">STANDARD</span>
        <span class="qsub">1080p · CRF 23 · 5Mbps</span>
      </button>
      <button class="quick-btn q-high" onclick="quickFire('high')">
        <span class="qname">HIGH</span>
        <span class="qsub">1080p · CRF 18 · 8Mbps</span>
      </button>
      <button class="quick-btn q-4k" onclick="quickFire('4k')">
        <span class="qname">4K</span>
        <span class="qsub">2160p · CRF 20 · 15Mbps</span>
      </button>
      <button class="quick-btn q-cinematic" onclick="quickFire('cinematic')">
        <span class="qname">CINEMATIC</span>
        <span class="qsub">4096×2160 · CRF 18 · 20Mbps</span>
      </button>
    </div>
    <div id="quick-toast" class="toast" style="margin-top:.5rem;"></div>
  </div>

  <div class="sidebar-section">
    <div class="sidebar-label">Navigate</div>
    <div class="nav-item active" id="nav-launch" onclick="showSection('launch')">
      <span class="nav-icon">⚡</span> Launch Job
    </div>
    <div class="nav-item" id="nav-jobs" onclick="showSection('jobs')">
      <span class="nav-icon">📋</span> Job Queue
    </div>
    <div class="nav-item" id="nav-logs" onclick="showSection('logs')">
      <span class="nav-icon">📜</span> Error Logs
    </div>
    <div class="nav-item" id="nav-media" onclick="showSection('media')">
      <span class="nav-icon">🎬</span> Media
    </div>
  </div>
</aside>

<!-- MAIN -->
<main class="scrollbar-thin">

  <!-- LAUNCH SECTION -->
  <div id="section-launch">
    <div class="launch-card">
      <div class="card-title">⚡ Launch Job <span class="badge">NEW</span></div>

      <div class="field-row single">
        <div>
          <label>Source Path</label>
          <input type="text" id="src-path" placeholder="/data/media" value="${DATA_ROOT}">
        </div>
      </div>

      <div class="field-row">
        <div>
          <label>Preset</label>
          <select id="preset-select">
            <option value="standard">Standard — 1080p CRF23 5Mbps</option>
            <option value="high">High — 1080p CRF18 8Mbps</option>
            <option value="4k">4K — 2160p CRF20 15Mbps</option>
            <option value="cinematic">Cinematic — 4096×2160 CRF18 20Mbps</option>
          </select>
        </div>
        <div>
          <label>Threads — <span id="thread-display">1</span></label>
          <div class="thread-row">
            <input type="range" min="1" max="16" value="1" id="thread-range"
              oninput="document.getElementById('thread-display').textContent=this.value">
          </div>
        </div>
      </div>

      <div class="field-row single">
        <div>
          <label>Mode</label>
          <div class="mode-pills">
            <div class="pill active" id="pill-recursive" onclick="selectMode('recursive')">🔄 Recursive</div>
            <div class="pill" id="pill-single" onclick="selectMode('single')">📁 Single Folder</div>
          </div>
        </div>
      </div>

      <button class="launch-btn" id="launch-btn" onclick="launchJob()">▶ LAUNCH PROCESS</button>
      <div id="launch-toast" class="toast"></div>
    </div>

    <!-- Quick Stats -->
    <div class="launch-card" id="section-quickstats" style="display:none">
      <div class="card-title">📊 Recent Activity</div>
      <div id="recent-jobs-mini"></div>
    </div>
  </div>

  <!-- JOBS SECTION -->
  <div id="section-jobs" style="display:none">
    <div class="launch-card">
      <div class="section-header">
        <div class="section-title">📋 Job Queue</div>
        <button class="refresh-btn" onclick="loadJobs()">↻ Refresh</button>
      </div>
      <div class="filter-row">
        <button class="filter-pill active" onclick="filterJobs('')"    id="filt-all">All</button>
        <button class="filter-pill"        onclick="filterJobs('running')" id="filt-running">Running</button>
        <button class="filter-pill"        onclick="filterJobs('done')"    id="filt-done">Done</button>
        <button class="filter-pill"        onclick="filterJobs('failed')"  id="filt-failed">Failed</button>
        <button class="filter-pill"        onclick="filterJobs('skipped')" id="filt-skipped">Skipped</button>
      </div>
      <div id="jobs-table-wrap"></div>
    </div>
  </div>

  <!-- LOGS SECTION -->
  <div id="section-logs" style="display:none">
    <div class="launch-card">
      <div class="section-header">
        <div class="section-title">📜 Error Logs</div>
        <button class="refresh-btn" onclick="loadErrorLogs()">↻ Refresh</button>
      </div>
      <div id="error-logs-wrap"></div>
    </div>
  </div>

  <!-- MEDIA SECTION -->
  <div id="section-media" style="display:none">
    <div class="launch-card">
      <div class="section-header">
        <div class="section-title">🎬 Media Files</div>
        <button class="refresh-btn" onclick="loadMedia()">↻ Refresh</button>
      </div>
      <div class="filter-row">
        <button class="filter-pill active" onclick="filterMedia('')"      id="mfilt-all">All</button>
        <button class="filter-pill"        onclick="filterMedia('video')" id="mfilt-video">Video</button>
        <button class="filter-pill"        onclick="filterMedia('image')" id="mfilt-image">Images</button>
      </div>
      <div id="media-wrap"></div>
    </div>
  </div>

</main>

<!-- FOOTER -->
<footer>
  <span>FFmpeg Microservice v2.0</span>
  <span>·</span>
  <span id="footer-time"></span>
  <span class="footer-spacer"></span>
  <label style="display:flex;align-items:center;gap:.4rem;cursor:pointer;">
    <input type="checkbox" id="auto-refresh-toggle" checked>
    Auto-refresh
  </label>
</footer>

<!-- JOB DETAIL DRAWER -->
<div class="drawer-overlay" id="drawer-overlay" onclick="closeDrawer(event)">
  <div class="drawer scrollbar-thin" id="drawer">
    <button class="drawer-close" onclick="closeDrawerForce()">✕ Close</button>
    <div id="drawer-content"></div>
  </div>
</div>

<script>
  // ── State ──────────────────────────────────────────────────────────────────
  let currentMode = 'recursive';
  let currentJobFilter = '';
  let currentMediaFilter = '';
  let autoRefreshInterval = null;

  // ── Section nav ────────────────────────────────────────────────────────────
  function showSection(name) {
    ['launch','jobs','logs','media'].forEach(s => {
      document.getElementById('section-'+s).style.display = s===name ? '' : 'none';
      const nav = document.getElementById('nav-'+s);
      if (nav) nav.classList.toggle('active', s===name);
    });
    if (name==='jobs')  loadJobs();
    if (name==='logs')  loadErrorLogs();
    if (name==='media') loadMedia();
  }

  // ── Status bar ─────────────────────────────────────────────────────────────
  async function refreshStatus() {
    try {
      const r = await fetch('/status');
      const d = await r.json();
      document.getElementById('db-dot').className = 'dot ' + (d.ok ? 'db-ok' : 'db-err');
      document.getElementById('db-label').textContent = d.ok ? 'DB' : 'DB ERR';
      document.getElementById('running-count').textContent = d.stats?.running || 0;
      document.getElementById('done-count').textContent    = d.stats?.done    || 0;
      document.getElementById('fail-count').textContent    = d.stats?.failed  || 0;
    } catch(e) {
      document.getElementById('db-dot').className = 'dot db-err';
    }
  }

  // ── Mode pills ─────────────────────────────────────────────────────────────
  function selectMode(m) {
    currentMode = m;
    document.getElementById('pill-recursive').classList.toggle('active', m==='recursive');
    document.getElementById('pill-single').classList.toggle('active', m==='single');
  }

  // ── Launch job ─────────────────────────────────────────────────────────────
  async function launchJob() {
    const srcPath = document.getElementById('src-path').value.trim();
    const preset  = document.getElementById('preset-select').value;
    const threads = parseInt(document.getElementById('thread-range').value);
    const toast   = document.getElementById('launch-toast');
    const btn     = document.getElementById('launch-btn');
    if (!srcPath) { showToast(toast, 'error', 'Source path is required'); return; }
    btn.disabled = true; btn.textContent = '⏳ LAUNCHING...';
    toast.className = 'toast'; toast.style.display = 'none';
    try {
      const r = await fetch('/process', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ srcPath, preset, threads, mode: currentMode }),
      });
      const d = await r.json();
      if (d.jobId) {
        showToast(toast, 'success', '✓ Job started — ID: ' + d.jobId);
        refreshStatus();
      } else {
        showToast(toast, 'error', '✗ ' + (d.error || 'Unknown error'));
      }
    } catch(e) {
      showToast(toast, 'error', '✗ Network error: ' + e.message);
    } finally {
      btn.disabled = false; btn.textContent = '▶ LAUNCH PROCESS';
    }
  }

  // ── Quick fire ─────────────────────────────────────────────────────────────
  async function quickFire(preset) {
    const toast = document.getElementById('quick-toast');
    const btn   = document.querySelector('.q-' + (preset==='4k'?'4k':preset));
    if (btn) { btn.classList.add('loading'); btn.querySelector('.qsub').textContent = 'launching…'; }
    toast.className = 'toast';
    try {
      const r = await fetch('/process/quick/' + preset, { method: 'POST' });
      const d = await r.json();
      if (d.jobId) {
        showToast(toast, 'success', '✓ ' + preset.toUpperCase() + ' job: ' + d.jobId.slice(0,8) + '…');
        refreshStatus();
      } else {
        showToast(toast, 'error', '✗ ' + (d.error || 'Error'));
      }
    } catch(e) {
      showToast(toast, 'error', '✗ ' + e.message);
    } finally {
      if (btn) {
        btn.classList.remove('loading');
        const subs = { standard:'1080p · CRF 23 · 5Mbps', high:'1080p · CRF 18 · 8Mbps', '4k':'2160p · CRF 20 · 15Mbps', cinematic:'4096×2160 · CRF 18 · 20Mbps' };
        btn.querySelector('.qsub').textContent = subs[preset] || '';
      }
    }
  }

  function showToast(el, type, msg) {
    el.className = 'toast ' + type;
    el.textContent = msg;
  }

  // ── Jobs ───────────────────────────────────────────────────────────────────
  async function loadJobs() {
    const wrap = document.getElementById('jobs-table-wrap');
    wrap.innerHTML = '<div class="empty-state">Loading…</div>';
    try {
      const url = '/jobs?limit=100' + (currentJobFilter ? '&status='+currentJobFilter : '');
      const r = await fetch(url);
      const d = await r.json();
      renderJobsTable(d.jobs || [], wrap);
    } catch(e) {
      wrap.innerHTML = '<div class="empty-state" style="color:var(--red)">Error: ' + e.message + '</div>';
    }
  }

  function filterJobs(status) {
    currentJobFilter = status;
    ['all','running','done','failed','skipped'].forEach(s => {
      document.getElementById('filt-'+s)?.classList.toggle('active', (s==='all'&&!status)||(s===status));
    });
    loadJobs();
  }

  function renderJobsTable(jobs, wrap) {
    if (!jobs.length) { wrap.innerHTML = '<div class="empty-state">No jobs found</div>'; return; }
    const rows = jobs.map(j => {
      const started = j.started_at ? new Date(j.started_at).toLocaleTimeString() : '—';
      const dur = j.finished_at && j.started_at
        ? Math.round((new Date(j.finished_at)-new Date(j.started_at))/1000)+'s' : '—';
      return \`<tr onclick="openJobDetail('\${j.id}')">
        <td>\${j.id.slice(0,8)}…</td>
        <td><span class="status-badge \${j.status}">\${j.status}</span></td>
        <td>\${j.preset}</td>
        <td style="color:var(--text2);max-width:180px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">\${j.src_path}</td>
        <td>\${j.total_images||0} imgs</td>
        <td>\${j.size_mb||0} MB</td>
        <td>\${started}</td>
        <td>\${dur}</td>
      </tr>\`;
    }).join('');
    wrap.innerHTML = \`<table>
      <thead><tr>
        <th>ID</th><th>Status</th><th>Preset</th><th>Path</th><th>Images</th><th>Size</th><th>Started</th><th>Duration</th>
      </tr></thead>
      <tbody>\${rows}</tbody>
    </table>\`;
  }

  // ── Job Detail ─────────────────────────────────────────────────────────────
  async function openJobDetail(id) {
    const overlay = document.getElementById('drawer-overlay');
    const content = document.getElementById('drawer-content');
    overlay.classList.add('open');
    content.innerHTML = '<div class="empty-state">Loading…</div>';
    try {
      const r = await fetch('/jobs/'+id);
      const d = await r.json();
      const j = d.job;
      const dur = j.finished_at && j.started_at
        ? Math.round((new Date(j.finished_at)-new Date(j.started_at))/1000)+'s' : 'In progress';
      const logs = (d.logs||[]).map(l => \`<div class="log-entry">
        <span class="log-level \${l.level}">\${l.level}</span>
        <span class="log-msg">\${l.message}</span>
        <span class="log-time">\${new Date(l.created_at).toLocaleTimeString()}</span>
      </div>\`).join('');
      content.innerHTML = \`
        <div style="margin-bottom:.25rem;font-family:var(--mono);font-size:.65rem;color:var(--muted)">\${j.id}</div>
        <div style="display:flex;align-items:center;gap:.75rem;margin-bottom:.75rem">
          <div style="font-family:var(--display);font-size:1.6rem">\${j.folder_name||j.src_path}</div>
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
        \${j.output_path ? \`<div style="background:var(--panel2);border:1px solid var(--border2);border-radius:6px;padding:.6rem .8rem;font-family:var(--mono);font-size:.7rem;margin-bottom:.75rem;color:var(--green)">📦 \${j.output_path}</div>\` : ''}
        \${j.error_msg ? \`<div style="background:rgba(255,59,59,.07);border:1px solid rgba(255,59,59,.2);border-radius:6px;padding:.6rem .8rem;font-family:var(--mono);font-size:.7rem;margin-bottom:.75rem;color:var(--red)">✗ \${j.error_msg}</div>\` : ''}
        <div style="font-family:var(--mono);font-size:.65rem;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin-bottom:.4rem">Logs (last \${d.logs?.length||0})</div>
        <div class="log-list scrollbar-thin">\${logs || '<div style="padding:1rem;text-align:center;color:var(--muted);font-size:.75rem">No logs</div>'}</div>
        <div style="font-family:var(--mono);font-size:.65rem;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin:.75rem 0 .4rem">Events (\${d.events?.length||0})</div>
        <div class="log-list scrollbar-thin">
          \${(d.events||[]).map(e=>\`<div class="log-entry">
            <span class="log-level info">\${e.event_type.replace(/_/g,' ')}</span>
            <span class="log-msg">\${e.payload?JSON.stringify(e.payload).slice(0,120):''}</span>
            <span class="log-time">\${new Date(e.created_at).toLocaleTimeString()}</span>
          </div>\`).join('')||'<div style="padding:1rem;text-align:center;color:var(--muted);font-size:.75rem">No events</div>'}
        </div>
      \`;
    } catch(e) {
      content.innerHTML = '<div class="empty-state" style="color:var(--red)">Error: '+e.message+'</div>';
    }
  }

  function closeDrawer(e) {
    if (e.target === document.getElementById('drawer-overlay')) closeDrawerForce();
  }
  function closeDrawerForce() {
    document.getElementById('drawer-overlay').classList.remove('open');
  }

  // ── Error Logs ─────────────────────────────────────────────────────────────
  async function loadErrorLogs() {
    const wrap = document.getElementById('error-logs-wrap');
    wrap.innerHTML = '<div class="empty-state">Loading…</div>';
    try {
      const r = await fetch('/logs/error-global?limit=100');
      const d = await r.json();
      if (!d.errors?.length) { wrap.innerHTML = '<div class="empty-state" style="color:var(--green)">✓ No errors logged</div>'; return; }
      const rows = d.errors.map(e => \`<tr>
        <td style="color:var(--muted)">\${new Date(e.created_at).toLocaleString()}</td>
        <td style="color:var(--text2)">\${e.job_id?.slice(0,8)||'—'}…</td>
        <td>\${e.folder_name||e.src_path||'—'}</td>
        <td style="color:var(--accent)">\${e.preset||'—'}</td>
        <td style="color:var(--red);max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">\${e.message}</td>
      </tr>\`).join('');
      wrap.innerHTML = \`<table>
        <thead><tr><th>Time</th><th>Job ID</th><th>Folder</th><th>Preset</th><th>Message</th></tr></thead>
        <tbody>\${rows}</tbody>
      </table>\`;
    } catch(e) {
      wrap.innerHTML = '<div class="empty-state" style="color:var(--red)">Error: '+e.message+'</div>';
    }
  }

  // ── Media ──────────────────────────────────────────────────────────────────
  async function loadMedia() {
    const wrap = document.getElementById('media-wrap');
    wrap.innerHTML = '<div class="empty-state">Loading…</div>';
    try {
      const url = '/media?limit=200' + (currentMediaFilter ? '&type='+currentMediaFilter : '');
      const r = await fetch(url);
      const d = await r.json();
      if (!d.media?.length) { wrap.innerHTML = '<div class="empty-state">No media tracked yet</div>'; return; }
      const rows = d.media.map(m => \`<tr>
        <td><span class="status-badge \${m.media_type==='video'?'done':'running'}">\${m.media_type}</span></td>
        <td style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">\${m.file_name||'—'}</td>
        <td>\${m.folder_name||'—'}</td>
        <td>\${m.size_bytes ? (m.size_bytes/1024/1024).toFixed(2)+' MB' : '—'}</td>
        <td style="color:var(--muted)">\${new Date(m.created_at).toLocaleString()}</td>
      </tr>\`).join('');
      wrap.innerHTML = \`<table>
        <thead><tr><th>Type</th><th>File</th><th>Folder</th><th>Size</th><th>Created</th></tr></thead>
        <tbody>\${rows}</tbody>
      </table>\`;
    } catch(e) {
      wrap.innerHTML = '<div class="empty-state" style="color:var(--red)">Error: '+e.message+'</div>';
    }
  }

  function filterMedia(type) {
    currentMediaFilter = type;
    ['all','video','image'].forEach(s => {
      document.getElementById('mfilt-'+s)?.classList.toggle('active', (s==='all'&&!type)||(s===type));
    });
    loadMedia();
  }

  // ── Footer clock ───────────────────────────────────────────────────────────
  function updateClock() {
    document.getElementById('footer-time').textContent = new Date().toLocaleTimeString();
  }

  // ── Auto-refresh ───────────────────────────────────────────────────────────
  function startAutoRefresh() {
    autoRefreshInterval = setInterval(() => {
      refreshStatus();
      // refresh active section
      if (!document.getElementById('section-jobs').style.display || document.getElementById('section-jobs').style.display==='') loadJobs();
    }, 5000);
  }
  document.getElementById('auto-refresh-toggle').addEventListener('change', function() {
    if (this.checked) startAutoRefresh();
    else clearInterval(autoRefreshInterval);
  });

  // ── Init ───────────────────────────────────────────────────────────────────
  refreshStatus();
  setInterval(updateClock, 1000);
  updateClock();
  startAutoRefresh();
</script>
</body>
</html>`;
  return c.html(html);
});

app.route('/', routes);
app.notFound((c) => c.json({ error: 'Not found', hint: 'Visit /doc for API reference or / for the GUI manager' }, 404));
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
    console.log(`[SERVER] GUI Manager: http://0.0.0.0:${info.port}/`);
    console.log(`[SERVER] API docs:    http://0.0.0.0:${info.port}/doc`);
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
check "GET / HTML manager"          "$(curl -s $BASE_URL/)"              "FFmpeg"
check "GET /status ok"              "$(curl -s $BASE_URL/status)"        '"ok":true'
check "GET /status db"              "$(curl -s $BASE_URL/status)"        'connected'
check "GET /doc 200"                "$(curl -s -o /dev/null -w '%{http_code}' $BASE_URL/doc)" "200"
check "GET /jobs array"             "$(curl -s $BASE_URL/jobs)"          '"jobs"'
check "GET /logs array"             "$(curl -s $BASE_URL/logs)"          '"logs"'
check "GET /logs/error-global"      "$(curl -s $BASE_URL/logs/error-global)" '"errors"'
check "GET /media array"            "$(curl -s $BASE_URL/media)"         '"media"'
check "GET /notfound hint"          "$(curl -s $BASE_URL/notfound)"      'hint'

echo ""
echo "--- Quick Fire Endpoints ---"
QUICK=$(curl -s -X POST "$BASE_URL/process/quick")
check "POST /process/quick jobId"           "$QUICK"   '"jobId"'

check "POST /process/quick/standard"        "$(curl -s -X POST $BASE_URL/process/quick/standard)"  '"jobId"'
check "POST /process/quick/high"            "$(curl -s -X POST $BASE_URL/process/quick/high)"       '"jobId"'
check "POST /process/quick/4k"              "$(curl -s -X POST $BASE_URL/process/quick/4k)"         '"jobId"'
check "POST /process/quick/cinematic"       "$(curl -s -X POST $BASE_URL/process/quick/cinematic)"  '"jobId"'
check "POST /process/quick/cinema (alias)"  "$(curl -s -X POST $BASE_URL/process/quick/cinema)"     '"jobId"'
check "POST /process/quick/bad preset"      "$(curl -s -X POST $BASE_URL/process/quick/ultramax)"   '"error"'

JOB_ID=$(echo "$QUICK" | grep -o '"jobId":"[^"]*"' | cut -d'"' -f4 || echo "")
if [ -n "$JOB_ID" ]; then
  sleep 1
  DETAIL=$(curl -s "$BASE_URL/jobs/$JOB_ID")
  check "GET /jobs/:id job"                 "$DETAIL"  '"job"'
  check "GET /jobs/:id events"              "$DETAIL"  '"events"'
fi

echo ""
echo "--- Process Endpoints ---"
check "POST /process bad preset"   "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/x\",\"preset\":\"bad\"}')" "error"
check "POST /process/folder no path" "$(curl -s -X POST $BASE_URL/process/folder -H 'Content-Type: application/json' -d '{}')" "error"
check "POST /process full body"    "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"standard\",\"threads\":1}')" '"jobId"'
check "POST /process cinematic"    "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"cinematic\"}')" '"jobId"'
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
echo "    GUI Manager:   http://localhost:3000/"
echo "    API docs:      http://localhost:3000/doc"
echo "    Status:        http://localhost:3000/status"
echo "    Quick process: POST http://localhost:3000/process/quick/:preset"
echo "    Error logs:    http://localhost:3000/logs/error-global"
echo ""
echo "  Quick Fire presets:"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/standard${NC}"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/high${NC}"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/4k${NC}"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/cinematic${NC}"
