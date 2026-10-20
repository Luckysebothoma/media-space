#!/bin/bash
# ============================================================
# setup_ffmpeg_v2.sh — FFmpeg Microservice v2 — Full Stack
# Features: corruption fixes, mobile presets, 16:9/9:16/1:1/4:3
# Run: bash setup_ffmpeg_v2.sh [--run] [--test]
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
# Delete + recreate directory structure
# ============================================================
if [ -d "$STACK_DIR" ]; then
  log "Removing existing stack directory..."
  rm -rf "$STACK_DIR"
  ok "Removed $STACK_DIR"
fi

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
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    status       TEXT NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending','running','done','failed','skipped')),
    preset       TEXT NOT NULL DEFAULT 'standard',
    threads      INT  NOT NULL DEFAULT 1,
    src_path     TEXT NOT NULL,
    output_path  TEXT,
    folder_name  TEXT,
    total_images INT  DEFAULT 0,
    duration_sec INT  DEFAULT 0,
    size_mb      NUMERIC(10,2) DEFAULT 0,
    started_at   TIMESTAMPTZ,
    finished_at  TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    error_msg    TEXT
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
      - /mnt/blue_442gb/comfyui/088888888888888888888062026uPLOADEDTOmULAVISHI:/data/media
      - /mnt/blue_442gb/comfyui/generated_i2v/mlavish:/data/archives
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
    "dev":   "node --watch src/index.js"
  },
  "dependencies": {
    "@hono/node-server": "^1.13.7",
    "hono":              "^4.6.3",
    "pg":                "^8.13.1"
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
# app/src/utils.js  — CORRUPTION FIXES + MOBILE PRESETS
# ============================================================
log "Writing app/src/utils.js..."
cat > "$STACK_DIR/app/src/utils.js" << 'UTILSJS'
import { spawn } from 'child_process';
import fs from 'fs/promises';
import path from 'path';

// ── Preset registry ────────────────────────────────────────────────────────
//
// Each preset defines:
//   width/height  - output resolution (px)
//   crf           - constant rate factor (lower = better quality, bigger file)
//   bitrate       - target average bitrate (kbps)
//   maxrate       - peak bitrate cap (kbps) — prevents VBV overflow / corrupt frames
//   bufsize       - VBV buffer size (kbps) — keep at ~2× maxrate
//   aspectLabel   - human-readable aspect ratio tag
//   category      - 'desktop' | 'mobile' | 'social'
//
// CORRUPTION FIX: maxrate + bufsize are mandatory.
// Without VBV constraints the encoder can spike far above target bitrate,
// overflowing the decoder buffer and producing distorted / green-frame artifacts.

export const PRESETS = {

  // ── Desktop / TV ──────────────────────────────────────────────────────────
  standard: {
    width: 1920, height: 1080,
    crf: 23, bitrate: 5000, maxrate: 7500,  bufsize: 15000,
    aspectLabel: '16:9', category: 'desktop',
    description: 'Full HD 1080p — balanced quality/size',
  },
  high: {
    width: 1920, height: 1080,
    crf: 18, bitrate: 8000, maxrate: 12000, bufsize: 24000,
    aspectLabel: '16:9', category: 'desktop',
    description: 'Full HD 1080p — high quality',
  },
  '4k': {
    width: 3840, height: 2160,
    crf: 20, bitrate: 15000, maxrate: 22500, bufsize: 45000,
    aspectLabel: '16:9', category: 'desktop',
    description: 'UHD 4K 2160p — high quality',
  },
  cinematic: {
    width: 4096, height: 2160,
    crf: 18, bitrate: 20000, maxrate: 30000, bufsize: 60000,
    aspectLabel: '17:9 DCI', category: 'desktop',
    description: 'DCI 4K — cinema / archive master',
  },

  // ── Mobile Portrait 9:16 ─────────────────────────────────────────────────
  // Optimised for Instagram Reels, TikTok, YouTube Shorts, WhatsApp Status.
  // Both dimensions must be divisible by 2 (libx264 requirement).
  'mobile-hd': {
    width: 1080, height: 1920,
    crf: 23, bitrate: 4000, maxrate: 6000, bufsize: 12000,
    aspectLabel: '9:16', category: 'mobile',
    description: 'Mobile portrait 1080×1920 — Reels / TikTok / Shorts',
  },
  'mobile-4k': {
    width: 2160, height: 3840,
    crf: 20, bitrate: 12000, maxrate: 18000, bufsize: 36000,
    aspectLabel: '9:16', category: 'mobile',
    description: 'Mobile portrait 4K — future-proof vertical',
  },
  'mobile-sd': {
    width: 720, height: 1280,
    crf: 26, bitrate: 2000, maxrate: 3000, bufsize: 6000,
    aspectLabel: '9:16', category: 'mobile',
    description: 'Mobile portrait 720×1280 — lightweight / messaging',
  },

  // ── Mobile Landscape 16:9 (smaller footprint than desktop) ───────────────
  'mobile-landscape': {
    width: 1280, height: 720,
    crf: 24, bitrate: 2500, maxrate: 4000, bufsize: 8000,
    aspectLabel: '16:9', category: 'mobile',
    description: 'Mobile landscape 1280×720 — in-app players / tablets',
  },
  'mobile-landscape-hd': {
    width: 1920, height: 1080,
    crf: 22, bitrate: 4500, maxrate: 7000, bufsize: 14000,
    aspectLabel: '16:9', category: 'mobile',
    description: 'Mobile landscape 1080p — high-res in-app / tablet',
  },

  // ── Square 1:1 ───────────────────────────────────────────────────────────
  // Instagram Feed, Facebook, LinkedIn posts.
  'square-hd': {
    width: 1080, height: 1080,
    crf: 23, bitrate: 3500, maxrate: 5500, bufsize: 11000,
    aspectLabel: '1:1', category: 'social',
    description: 'Square 1080×1080 — Instagram / Facebook feed',
  },
  'square-4k': {
    width: 2160, height: 2160,
    crf: 20, bitrate: 10000, maxrate: 15000, bufsize: 30000,
    aspectLabel: '1:1', category: 'social',
    description: 'Square 4K — high-res social / archive',
  },

  // ── Portrait 4:5 ─────────────────────────────────────────────────────────
  // Instagram Feed portrait optimum (recommended by Meta).
  'portrait-social': {
    width: 1080, height: 1350,
    crf: 23, bitrate: 3800, maxrate: 5700, bufsize: 11400,
    aspectLabel: '4:5', category: 'social',
    description: 'Portrait 1080×1350 — Instagram feed optimum',
  },

  // ── Classic 4:3 ──────────────────────────────────────────────────────────
  // Legacy displays, presentations, some digital frames.
  'classic-hd': {
    width: 1440, height: 1080,
    crf: 23, bitrate: 4000, maxrate: 6000, bufsize: 12000,
    aspectLabel: '4:3', category: 'desktop',
    description: '4:3 1440×1080 — presentations / legacy displays',
  },
  'classic-sd': {
    width: 960, height: 720,
    crf: 25, bitrate: 2000, maxrate: 3000, bufsize: 6000,
    aspectLabel: '4:3', category: 'desktop',
    description: '4:3 960×720 — digital photo frames / SD',
  },

  // ── Ultra-wide 21:9 ──────────────────────────────────────────────────────
  ultrawide: {
    width: 2560, height: 1080,
    crf: 22, bitrate: 8000, maxrate: 12000, bufsize: 24000,
    aspectLabel: '21:9', category: 'desktop',
    description: 'Ultrawide 2560×1080 — gaming monitors / signage',
  },
  'ultrawide-4k': {
    width: 3440, height: 1440,
    crf: 20, bitrate: 14000, maxrate: 21000, bufsize: 42000,
    aspectLabel: '21:9', category: 'desktop',
    description: 'Ultrawide QHD 3440×1440 — premium monitors',
  },
};

// Aliases — old names / convenience shortcuts → canonical preset key
export const PRESET_ALIASES = {
  cinema:             'cinematic',
  '1080p':            'standard',
  '1080':             'standard',
  '4k-high':          '4k',
  vertical:           'mobile-hd',
  reel:               'mobile-hd',
  reels:              'mobile-hd',
  tiktok:             'mobile-hd',
  shorts:             'mobile-hd',
  portrait:           'mobile-hd',
  landscape:          'mobile-landscape',
  square:             'square-hd',
  instagram:          'square-hd',
  feed:               'portrait-social',
  '43':               'classic-hd',
  '4-3':              'classic-hd',
  '169':              'standard',
  '16-9':             'standard',
  '916':              'mobile-hd',
  '9-16':             'mobile-hd',
};

export const DEFAULT_PRESET  = 'standard';
export const DEFAULT_THREADS = 1;
export const IMAGE_DURATION  = 3;   // seconds each image is shown
export const MIN_DURATION    = 30;  // minimum video length (seconds)
export const FPS             = 30;

// CORRUPTION FIX: raised from 100 KB → 512 KB.
// A sub-512 KB MP4 at any meaningful resolution is almost certainly a
// corrupt/empty file that FFmpeg "succeeded" on with near-zero real frames.
export const MIN_SIZE_BYTES = 512 * 1024;

export const IMAGE_EXTS = new Set([
  '.jpg', '.jpeg', '.png', '.webp', '.bmp', '.tiff', '.tif',
]);

// ── Helpers ────────────────────────────────────────────────────────────────

/** Resolve preset name (including aliases). Returns null if unrecognised. */
export function resolvePreset(name) {
  if (!name) return DEFAULT_PRESET;
  const lower = name.toLowerCase();
  if (PRESETS[lower])        return lower;
  if (PRESET_ALIASES[lower]) return PRESET_ALIASES[lower];
  return null;
}

/** Return all valid preset names + aliases joined for error messages. */
export function validPresetNames() {
  return [...Object.keys(PRESETS), ...Object.keys(PRESET_ALIASES)].join(', ');
}

/** Group presets by category for API/UI display. */
export function presetsByCategory() {
  const out = {};
  for (const [key, p] of Object.entries(PRESETS)) {
    const cat = p.category || 'other';
    if (!out[cat]) out[cat] = [];
    out[cat].push({ key, ...p });
  }
  return out;
}

/** Sanitise a folder/file name — replace non-safe chars with underscore. */
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
    folders.push(...await collectFolders(full));
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

// ── FFmpeg arg builders ────────────────────────────────────────────────────
//
// CORRUPTION FIXES applied to every encode:
//
//  -an
//    No audio stream. FFmpeg sometimes tries to mux a null/empty audio track
//    which corrupts the container mux layer.
//
//  -profile:v high / -level:v 4.1 (5.1 for 4K)
//    Explicit H.264 profile prevents the encoder defaulting to a profile
//    the target device/player cannot decode, causing visual corruption.
//
//  -g GOP / -keyint_min GOP / -sc_threshold 0
//    Fixed keyframe interval = 2 × FPS. Without this, the encoder inserts
//    surprise scene-change keyframes, breaking GOP structure and causing
//    decoder sync loss (green frames, mosaic artifacts).
//
//  -maxrate / -bufsize (VBV)
//    Caps the peak bitrate. Without VBV, slideshow encodes (static images)
//    can produce enormous intra-frame spikes that overflow the decoder buffer,
//    rendering as distorted macroblocks or complete frame corruption.
//
//  -movflags +faststart
//    Writes the MP4 moov atom at file start. Without this, an unclean exit
//    or partial flush leaves the file unplayable (moov at EOF, unfindable).
//
//  -preset medium (was 'fast')
//    'fast' uses a shallow lookahead that amplifies bitrate spikes on
//    static content. 'medium' is significantly more stable.

function h264Level(width, height) {
  // H.264 levels by resolution — ensures decoder compatibility
  const px = width * height;
  if (px > 3840 * 2160) return '5.2';
  if (px > 1920 * 1080) return '5.1';
  return '4.1';
}

function sharedCodecArgs({ crf, bitrate, maxrate, bufsize, threads, width, height }) {
  const gopSize = FPS * 2;
  const level   = h264Level(width, height);
  return [
    '-an',
    '-c:v',         'libx264',
    '-profile:v',   'high',
    '-level:v',     level,
    '-crf',         String(crf),
    '-b:v',         `${bitrate}k`,
    '-maxrate',     `${maxrate}k`,
    '-bufsize',     `${bufsize}k`,
    '-preset',      'medium',
    '-pix_fmt',     'yuv420p',
    '-g',           String(gopSize),
    '-keyint_min',  String(gopSize),
    '-sc_threshold','0',
    '-threads',     String(threads),
    '-movflags',    '+faststart',
  ];
}

/**
 * Scale + pad filter that handles BOTH landscape and portrait targets correctly.
 *
 * CORRUPTION FIX: the original scale filter used force_original_aspect_ratio=decrease
 * but did not account for portrait targets (height > width). The pad offsets are now
 * computed symmetrically so they always produce even pixel counts required by yuv420p.
 */
function scaleFilter(width, height) {
  return [
    `scale=${width}:${height}:force_original_aspect_ratio=decrease`,
    `pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2:color=black`,
    `fps=${FPS}`,
    'format=yuv420p',
  ].join(',');
}

/** Build FFmpeg args for a multi-image concat slideshow. */
export function buildConcatArgs({ manifestPath, width, height, crf, bitrate, maxrate, bufsize, threads, outputFile }) {
  return [
    '-y', '-loglevel', 'error',
    '-f', 'concat', '-safe', '0',
    '-i', manifestPath,
    '-vf', scaleFilter(width, height),
    ...sharedCodecArgs({ crf, bitrate, maxrate, bufsize, threads, width, height }),
    outputFile,
  ];
}

/** Build FFmpeg args for a single-image loop. */
export function buildLoopArgs({ imagePath, width, height, crf, bitrate, maxrate, bufsize, threads, duration, outputFile }) {
  return [
    '-y', '-loglevel', 'error',
    '-loop', '1',
    '-framerate', String(FPS),    // input-side hint — stabilises PTS clock
    '-i', imagePath,
    '-vf', scaleFilter(width, height),
    '-t', String(duration),
    ...sharedCodecArgs({ crf, bitrate, maxrate, bufsize, threads, width, height }),
    outputFile,
  ];
}

/**
 * Write an FFmpeg concat manifest.
 *
 * Each image gets an explicit `duration` line.
 * The last image is repeated without a duration so the concat demuxer
 * flushes cleanly — this is the FFmpeg-recommended pattern and prevents
 * the final-frame PTS jump that can corrupt the stream tail.
 */
export async function writeManifest(images) {
  const tmp = `/tmp/manifest_${Date.now()}_${Math.random().toString(36).slice(2)}.txt`;
  const lines = [];
  for (const img of images) {
    lines.push(`file '${img}'`);
    lines.push(`duration ${IMAGE_DURATION}`);
  }
  lines.push(`file '${images[images.length - 1]}'`); // EOF anchor — no duration
  await fs.writeFile(tmp, lines.join('\n') + '\n');
  return tmp;
}

export async function fileSizeBytes(filePath) {
  try { const s = await fs.stat(filePath); return s.size; }
  catch { return 0; }
}

/**
 * Spawn FFmpeg and return { code, stderr }.
 * Logs the full arg string to the job log for post-mortem debugging.
 */
export function runFfmpeg(args, logFile) {
  return new Promise((resolve) => {
    const proc = spawn('ffmpeg', args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, FFREPORT: '' },
    });
    const chunks = [];
    proc.stderr.on('data', d => chunks.push(d));
    proc.stdout.on('data', () => {}); // drain stdout — prevent backpressure hang
    proc.on('close', code => resolve({ code, stderr: Buffer.concat(chunks).toString() }));
    proc.on('error', err  => resolve({ code: -1, stderr: err.message }));
    if (logFile) {
      fs.appendFile(logFile, `=== ffmpeg ${new Date().toISOString()} ===\n`).catch(() => {});
      fs.appendFile(logFile, `CMD: ffmpeg ${args.join(' ')}\n\n`).catch(() => {});
      proc.stderr.on('data', d => fs.appendFile(logFile, d).catch(() => {}));
    }
  });
}
UTILSJS
ok "utils.js written (corruption fixes + mobile presets)"

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
  await fs.mkdir(LOG_DIR,     { recursive: true });
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
  const fileName  = path.basename(filePath);
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
  const outputFile = path.join(OUTPUT_BASE, `${safeName}_${preset}_${dateStamp}.mp4`);
  const logFile    = path.join(LOG_DIR,     `${safeName}_${preset}_${dateStamp}.log`);
  const p          = PRESETS[preset] || PRESETS[DEFAULT_PRESET];
  const { width, height, crf, bitrate, maxrate, bufsize } = p;

  await dbEvent(jobId, 'folder_start', { folder, folderName, safeName, preset });
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
    args = buildLoopArgs({ imagePath: images[0], width, height, crf, bitrate, maxrate, bufsize, threads, duration: totalDuration, outputFile });
    await dbLog('info', `Single-image loop: ${folderName} (${totalDuration}s)`, jobId);
  } else {
    manifestPath = await writeManifest(images);
    args = buildConcatArgs({ manifestPath, width, height, crf, bitrate, maxrate, bufsize, threads, outputFile });
    await dbLog('info', `Multi-image concat: ${folderName} (${images.length} imgs, ${totalDuration}s)`, jobId);
  }

  await dbEvent(jobId, 'ffmpeg_start', { folderName, images: images.length, totalDuration, outputFile, preset });
  const { code, stderr } = await runFfmpeg(args, logFile);
  if (manifestPath) await fs.unlink(manifestPath).catch(() => {});

  if (code !== 0) {
    await dbLog('error', `ffmpeg failed for ${folderName}: ${stderr.slice(0, 500)}`, jobId, { code, folderName, preset });
    await dbEvent(jobId, 'ffmpeg_fail', { folderName, code });
    return { status: 'failed', folderName, error: stderr.slice(0, 500) };
  }

  const sizeBytes = await fileSizeBytes(outputFile);
  if (sizeBytes < MIN_SIZE_BYTES) {
    const reason = `Output too small (${sizeBytes}B < ${MIN_SIZE_BYTES}B) — likely corrupt`;
    await dbLog('warn', `${reason} for ${folderName}`, jobId);
    await fs.unlink(outputFile).catch(() => {});
    await dbEvent(jobId, 'fail_size', { folderName, sizeBytes, minSize: MIN_SIZE_BYTES });
    return { status: 'failed', folderName, error: 'output_too_small' };
  }

  const sizeMb = parseFloat((sizeBytes / 1024 / 1024).toFixed(2));
  await insertMedia(jobId, { mediaType: 'video', filePath: outputFile, folderName });
  await dbEvent(jobId, 'ffmpeg_done', { folderName, outputFile, sizeMb, durationSec: totalDuration, preset });
  await dbLog('info', `Done: ${folderName} → ${outputFile} (${sizeMb}MB, ${totalDuration}s, preset=${preset})`, jobId);
  return { status: 'done', folderName, outputFile, totalImages: images.length, durationSec: totalDuration, sizeMb };
}

export async function processDirectory({ srcPath, preset = DEFAULT_PRESET, threads = DEFAULT_THREADS }) {
  await ensureDirs();
  if (!PRESETS[preset]) throw new Error(`Unknown preset: ${preset}`);
  const jobId = await createJob({ srcPath, preset, threads });
  await dbLog('info', `Job started: ${jobId} | src=${srcPath} preset=${preset} threads=${threads}`, jobId);
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
  await dbLog('info', `Single-folder job: ${jobId} | src=${srcPath} preset=${preset}`, jobId);
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
ROUTESJS
ok "routes.js written"

# ============================================================
# app/src/index.js  — GUI Manager
# ============================================================
log "Writing app/src/index.js..."
cat > "$STACK_DIR/app/src/index.js" << 'INDEXJS'
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
INDEXJS
ok "index.js written"

# ============================================================
# scripts/smoke-test.sh  — extended for all new presets
# ============================================================
log "Writing scripts/smoke-test.sh..."
cat > "$STACK_DIR/scripts/smoke-test.sh" << 'SMOKETEST'
#!/bin/bash
# ============================================================
# smoke-test.sh — Validates FFmpeg Microservice v2 stack
# Usage: bash smoke-test.sh [http://localhost:3000]
# ============================================================
set -euo pipefail

BASE_URL="${1:-http://localhost:3000}"
PASS=0; FAIL=0

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

check() {
  local name="$1" result="$2" expected="$3"
  if echo "$result" | grep -q "$expected"; then
    echo -e "${GREEN}✓ PASS${NC} $name"; ((PASS++))
  else
    echo -e "${RED}✗ FAIL${NC} $name"
    echo "  Expected to contain: $expected"
    echo "  Got: ${result:0:300}"; ((FAIL++))
  fi
}

check_http() {
  local name="$1" url="$2" expected_code="$3"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  if [ "$code" = "$expected_code" ]; then
    echo -e "${GREEN}✓ PASS${NC} $name (HTTP $code)"; ((PASS++))
  else
    echo -e "${RED}✗ FAIL${NC} $name (expected HTTP $expected_code, got $code)"; ((FAIL++))
  fi
}

banner() { echo -e "\n${CYAN}--- $* ---${NC}"; }

echo -e "${CYAN}================================================"
echo "  FFmpeg Microservice v2 — Smoke Test Suite"
echo "  Target: $BASE_URL"
echo -e "================================================${NC}"

echo ""
echo "Waiting for service to be ready (up to 60s)..."
for i in $(seq 1 30); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/status" 2>/dev/null || echo "000")
  if [ "$CODE" = "200" ]; then
    echo -e "${GREEN}✓ Service is up!${NC}"
    break
  fi
  [ "$i" = "30" ] && { echo -e "${RED}Timed out waiting for service.${NC}"; exit 1; }
  sleep 2
done

banner "Core Endpoints"
check     "GET / returns HTML"             "$(curl -s $BASE_URL/)"                             'FFmpeg'
check_http "GET / HTTP 200"               "$BASE_URL/"                                         "200"
check     "GET /status ok:true"           "$(curl -s $BASE_URL/status)"                        '"ok":true'
check     "GET /status db connected"      "$(curl -s $BASE_URL/status)"                        'connected'
check     "GET /status presetsAvailable"  "$(curl -s $BASE_URL/status)"                        'presetsAvailable'
check_http "GET /doc HTTP 200"            "$BASE_URL/doc"                                      "200"
check     "GET /presets has presets key"  "$(curl -s $BASE_URL/presets)"                       '"presets"'
check     "GET /presets has categories"   "$(curl -s $BASE_URL/presets)"                       '"categories"'
check     "GET /presets has mobile-hd"    "$(curl -s $BASE_URL/presets)"                       'mobile-hd'
check     "GET /presets has square-hd"    "$(curl -s $BASE_URL/presets)"                       'square-hd'
check     "GET /presets has ultrawide"    "$(curl -s $BASE_URL/presets)"                       'ultrawide'
check     "GET /jobs returns array"       "$(curl -s $BASE_URL/jobs)"                          '"jobs"'
check     "GET /logs returns array"       "$(curl -s $BASE_URL/logs)"                          '"logs"'
check     "GET /logs/error-global"        "$(curl -s $BASE_URL/logs/error-global)"             '"errors"'
check     "GET /media returns array"      "$(curl -s $BASE_URL/media)"                         '"media"'
check     "GET /notfound has hint"        "$(curl -s $BASE_URL/notfound-xyz)"                  'hint'

banner "Quick Fire — Desktop Presets"
check "POST /process/quick (default)"          "$(curl -s -X POST $BASE_URL/process/quick)"                        '"jobId"'
check "POST /process/quick/standard"           "$(curl -s -X POST $BASE_URL/process/quick/standard)"               '"jobId"'
check "POST /process/quick/high"               "$(curl -s -X POST $BASE_URL/process/quick/high)"                   '"jobId"'
check "POST /process/quick/4k"                 "$(curl -s -X POST $BASE_URL/process/quick/4k)"                     '"jobId"'
check "POST /process/quick/cinematic"          "$(curl -s -X POST $BASE_URL/process/quick/cinematic)"              '"jobId"'
check "POST /process/quick/ultrawide"          "$(curl -s -X POST $BASE_URL/process/quick/ultrawide)"              '"jobId"'
check "POST /process/quick/ultrawide-4k"       "$(curl -s -X POST $BASE_URL/process/quick/ultrawide-4k)"           '"jobId"'
check "POST /process/quick/classic-hd"         "$(curl -s -X POST $BASE_URL/process/quick/classic-hd)"             '"jobId"'
check "POST /process/quick/classic-sd"         "$(curl -s -X POST $BASE_URL/process/quick/classic-sd)"             '"jobId"'

banner "Quick Fire — Mobile Presets (9:16 portrait)"
check "POST /process/quick/mobile-hd"          "$(curl -s -X POST $BASE_URL/process/quick/mobile-hd)"              '"jobId"'
check "POST /process/quick/mobile-4k"          "$(curl -s -X POST $BASE_URL/process/quick/mobile-4k)"              '"jobId"'
check "POST /process/quick/mobile-sd"          "$(curl -s -X POST $BASE_URL/process/quick/mobile-sd)"              '"jobId"'
check "POST /process/quick/mobile-landscape"   "$(curl -s -X POST $BASE_URL/process/quick/mobile-landscape)"       '"jobId"'
check "POST /process/quick/mobile-landscape-hd" "$(curl -s -X POST $BASE_URL/process/quick/mobile-landscape-hd)"  '"jobId"'

banner "Quick Fire — Social / Square Presets"
check "POST /process/quick/square-hd"          "$(curl -s -X POST $BASE_URL/process/quick/square-hd)"              '"jobId"'
check "POST /process/quick/square-4k"          "$(curl -s -X POST $BASE_URL/process/quick/square-4k)"              '"jobId"'
check "POST /process/quick/portrait-social"    "$(curl -s -X POST $BASE_URL/process/quick/portrait-social)"        '"jobId"'

banner "Quick Fire — Aliases"
check "POST /process/quick/cinema (→cinematic)" "$(curl -s -X POST $BASE_URL/process/quick/cinema)"               '"jobId"'
check "POST /process/quick/reel (→mobile-hd)"   "$(curl -s -X POST $BASE_URL/process/quick/reel)"                 '"jobId"'
check "POST /process/quick/reels (→mobile-hd)"  "$(curl -s -X POST $BASE_URL/process/quick/reels)"                '"jobId"'
check "POST /process/quick/tiktok (→mobile-hd)" "$(curl -s -X POST $BASE_URL/process/quick/tiktok)"               '"jobId"'
check "POST /process/quick/shorts (→mobile-hd)" "$(curl -s -X POST $BASE_URL/process/quick/shorts)"               '"jobId"'
check "POST /process/quick/vertical"            "$(curl -s -X POST $BASE_URL/process/quick/vertical)"              '"jobId"'
check "POST /process/quick/portrait"            "$(curl -s -X POST $BASE_URL/process/quick/portrait)"              '"jobId"'
check "POST /process/quick/landscape"           "$(curl -s -X POST $BASE_URL/process/quick/landscape)"             '"jobId"'
check "POST /process/quick/square"              "$(curl -s -X POST $BASE_URL/process/quick/square)"                '"jobId"'
check "POST /process/quick/instagram"           "$(curl -s -X POST $BASE_URL/process/quick/instagram)"             '"jobId"'
check "POST /process/quick/feed"                "$(curl -s -X POST $BASE_URL/process/quick/feed)"                  '"jobId"'
check "POST /process/quick/1080p"               "$(curl -s -X POST $BASE_URL/process/quick/1080p)"                 '"jobId"'
check "POST /process/quick/9-16"                "$(curl -s -X POST $BASE_URL/process/quick/9-16)"                  '"jobId"'
check "POST /process/quick/16-9"                "$(curl -s -X POST $BASE_URL/process/quick/16-9)"                  '"jobId"'
check "POST /process/quick/4-3"                 "$(curl -s -X POST $BASE_URL/process/quick/4-3)"                   '"jobId"'

banner "Quick Fire — Error Cases"
check "POST /process/quick/bad_preset → error"  "$(curl -s -X POST $BASE_URL/process/quick/ultramax1234)"          '"error"'
check "POST /process/quick/UPPERCASE → error"   "$(curl -s -X POST $BASE_URL/process/quick/NOTAPRESET)"            '"error"'

# Grab a job ID for detail check
QUICK_RES=$(curl -s -X POST "$BASE_URL/process/quick/standard")
JOB_ID=$(echo "$QUICK_RES" | grep -o '"jobId":"[^"]*"' | cut -d'"' -f4 || true)
if [ -n "$JOB_ID" ]; then
  sleep 1
  DETAIL=$(curl -s "$BASE_URL/jobs/$JOB_ID")
  banner "Job Detail"
  check "GET /jobs/:id has job"    "$DETAIL" '"job"'
  check "GET /jobs/:id has events" "$DETAIL" '"events"'
  check "GET /jobs/:id has logs"   "$DETAIL" '"logs"'
  check "GET /jobs/:id has media"  "$DETAIL" '"media"'
fi

banner "Process Endpoints"
check "POST /process full body (standard)"      "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"standard\",\"threads\":1}')"    '"jobId"'
check "POST /process mobile-hd"                 "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"mobile-hd\"}')"                '"jobId"'
check "POST /process square-hd"                 "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"square-hd\"}')"                '"jobId"'
check "POST /process portrait-social"           "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"portrait-social\"}')"          '"jobId"'
check "POST /process ultrawide"                 "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"ultrawide\"}')"                '"jobId"'
check "POST /process mode:single"               "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"preset\":\"standard\",\"mode\":\"single\"}')" '"jobId"'
check "POST /process bad preset → error"        "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/x\",\"preset\":\"notexist\"}')"                          '"error"'
check "POST /process missing srcPath → error"   "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"preset\":\"standard\"}')"                                             '"error"'
check "POST /process/folder standard"           "$(curl -s -X POST $BASE_URL/process/folder -H 'Content-Type: application/json' -d '{\"folderPath\":\"/data/media/test\",\"preset\":\"standard\"}')"  '"jobId"'
check "POST /process/folder mobile-hd"          "$(curl -s -X POST $BASE_URL/process/folder -H 'Content-Type: application/json' -d '{\"folderPath\":\"/data/media/test\",\"preset\":\"mobile-hd\"}')" '"jobId"'
check "POST /process/folder no path → error"    "$(curl -s -X POST $BASE_URL/process/folder -H 'Content-Type: application/json' -d '{}')"                                                             '"error"'

banner "Query Filters"
check "GET /jobs?status=running"   "$(curl -s $BASE_URL/jobs?status=running)"   '"jobs"'
check "GET /jobs?status=done"      "$(curl -s $BASE_URL/jobs?status=done)"      '"jobs"'
check "GET /jobs?status=failed"    "$(curl -s $BASE_URL/jobs?status=failed)"    '"jobs"'
check "GET /logs?level=error"      "$(curl -s $BASE_URL/logs?level=error)"      '"logs"'
check "GET /logs?level=info"       "$(curl -s $BASE_URL/logs?level=info)"       '"logs"'
check "GET /media?type=video"      "$(curl -s $BASE_URL/media?type=video)"      '"media"'
check "GET /media?type=image"      "$(curl -s $BASE_URL/media?type=image)"      '"media"'

echo ""
echo -e "${CYAN}================================================"
TOTAL=$((PASS+FAIL))
echo -e "Results: ${GREEN}${PASS}/${TOTAL} passed${NC} | ${RED}${FAIL} failed${NC}"
echo -e "${CYAN}================================================${NC}"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
SMOKETEST
chmod +x "$STACK_DIR/scripts/smoke-test.sh"
ok "smoke-test.sh written (covers all presets + aliases)"

# ============================================================
# Validate file structure
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
  if [ -f "$f" ]; then ok "exists: $f"
  else echo -e "${RED}  ✗ MISSING: $f${NC}"; ALL_OK=false; fi
done
[ "$ALL_OK" = false ] && die "Some files are missing. Setup incomplete."

# ============================================================
# Print tree
# ============================================================
echo ""
log "Generated stack:"
if command -v tree >/dev/null 2>&1; then
  tree "$STACK_DIR"
else
  find "$STACK_DIR" -type f | sort | sed "s|$STACK_DIR/||" | while read -r f; do echo "  $f"; done
fi

# ============================================================
# Optionally build + run
# ============================================================
if [ "$RUN_STACK" = true ]; then
  echo ""
  log "Building and starting stack…"
  cd "$STACK_DIR"
  docker compose down --remove-orphans 2>/dev/null || true
  docker compose build --no-cache
  docker compose up -d
  ok "Stack started!"
  echo ""
  log "Waiting for services to be healthy…"
  sleep 8
  docker compose ps
fi

# ============================================================
# Optionally run smoke tests
# ============================================================
if [ "$RUN_TESTS" = true ]; then
  echo ""
  log "Running smoke tests…"
  if ! bash "$STACK_DIR/scripts/smoke-test.sh" "http://localhost:3000"; then
    die "Smoke tests failed!"
  fi
  ok "All smoke tests passed!"
fi

# ============================================================
# Done
# ============================================================
echo ""
echo -e "${GREEN}================================================"
echo "  ✓  Stack created successfully!  v2"
echo -e "================================================${NC}"
echo ""
echo "  Directory : $STACK_DIR"
echo ""
echo "  Quick start:"
echo -e "  ${CYAN}cd $STACK_DIR && docker compose up -d${NC}"
echo ""
echo "  Or run everything in one shot:"
echo -e "  ${CYAN}bash setup_ffmpeg_v2.sh --run          # build + start${NC}"
echo -e "  ${CYAN}bash setup_ffmpeg_v2.sh --run --test   # build + start + smoke test${NC}"
echo ""
echo "  Endpoints:"
echo "    GUI Manager  : http://localhost:3000/"
echo "    API Docs     : http://localhost:3000/doc"
echo "    Preset JSON  : http://localhost:3000/presets"
echo "    Status       : http://localhost:3000/status"
echo ""
echo "  Preset quick-fire examples:"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/standard${NC}       # 1080p 16:9"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/mobile-hd${NC}      # 1080p 9:16 portrait"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/reel${NC}           # alias → mobile-hd"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/tiktok${NC}         # alias → mobile-hd"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/square-hd${NC}      # 1:1 1080×1080"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/portrait-social${NC} # 4:5 Instagram"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/4k${NC}             # UHD 4K 16:9"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/cinematic${NC}      # DCI 4K"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/ultrawide${NC}      # 21:9 2560×1080"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/classic-hd${NC}     # 4:3 1440×1080"
echo ""