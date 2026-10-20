#!/bin/bash
clear
echo '################################################################################'
echo '#  HYBRID MEDIA STUDIO — Setup Script'
echo '#'
echo '#  Merges:'
echo '#    • Media Organiser API  (file grouping / dedup / scanning)'
echo '#    • FFmpeg Microservice  (image→video batch processing)'
echo '#    • Remotion              (programmatic video with audio)'
echo '#'
echo '#  Services spun up:'
echo '#    • db          PostgreSQL 16  (job + media tracking)'
echo '#    • api         Node 22 Hono   (organise + process + render)'
echo '#    • remotion    Node 22        (Remotion renderer sidecar)'
echo '#'
echo '#  GUI at http://localhost:3000  (dark cinematic theme)'
echo '#  API docs at http://localhost:3000/doc'
echo '#'
echo '#  Usage: bash setup_hybrid_media_studio.sh [--run] [--test] [--dry-run]'
echo '################################################################################'

set -euo pipefail

STACK_DIR="./hybrid-media-studio"
RUN_STACK=false
RUN_TESTS=false
DRY_RUN_MODE=false

for arg in "$@"; do
  case $arg in
    --run)     RUN_STACK=true ;;
    --test)    RUN_TESTS=true ;;
    --dry-run) DRY_RUN_MODE=true ;;
  esac
done

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${CYAN}[SETUP]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo; echo -e "${BOLD}${CYAN}── $* ──────────────────────────────────────────────────────${NC}"; }

# ============================================================
# PREFLIGHT
# ============================================================
section "Preflight checks"
command -v docker      >/dev/null 2>&1 || die "docker not found."
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found."
ok "docker + compose available"

if [ -d "$STACK_DIR" ]; then
  log "Removing existing stack directory..."
  rm -rf "$STACK_DIR"
fi

mkdir -p "$STACK_DIR"/{api/src/{routes,services,utils,middleware},remotion-worker/src,scripts}
ok "Directory structure created under $STACK_DIR"

# ============================================================
# init.sql
# ============================================================
section "Database schema"
cat > "$STACK_DIR/init.sql" << 'INITSQL'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── Jobs ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS jobs (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_type      TEXT NOT NULL DEFAULT 'process'
                    CHECK (job_type IN ('process','render','organise','scan')),
    status        TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','running','done','failed','skipped')),
    preset        TEXT NOT NULL DEFAULT 'standard',
    threads       INT  NOT NULL DEFAULT 1,
    src_path      TEXT NOT NULL,
    output_path   TEXT,
    folder_name   TEXT,
    total_files   INT  DEFAULT 0,
    duration_sec  INT  DEFAULT 0,
    size_mb       NUMERIC(10,2) DEFAULT 0,
    render_opts   JSONB,
    started_at    TIMESTAMPTZ,
    finished_at   TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    error_msg     TEXT
);

-- ── Media catalogue ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS media (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id       UUID REFERENCES jobs(id) ON DELETE CASCADE,
    media_type   TEXT NOT NULL CHECK (media_type IN ('image','video','audio','render')),
    file_path    TEXT NOT NULL,
    folder_name  TEXT,
    file_name    TEXT,
    size_bytes   BIGINT,
    hash_md5     TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Events ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS events (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id       UUID REFERENCES jobs(id) ON DELETE CASCADE,
    event_type   TEXT NOT NULL,
    payload      JSONB,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Logs ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS logs (
    id           BIGSERIAL PRIMARY KEY,
    job_id       UUID REFERENCES jobs(id) ON DELETE SET NULL,
    level        TEXT NOT NULL DEFAULT 'info'
                   CHECK (level IN ('info','warn','error','debug')),
    message      TEXT NOT NULL,
    context      JSONB,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Render presets ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS render_presets (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name         TEXT UNIQUE NOT NULL,
    config       JSONB NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed default render presets
INSERT INTO render_presets (name, config) VALUES
  ('cineslide',  '{"fps":30,"durationPerImage":3,"transition":"fade","width":1920,"height":1080,"audio":true}'),
  ('reel',       '{"fps":60,"durationPerImage":1,"transition":"zoom","width":1080,"height":1920,"audio":true}'),
  ('slideshow',  '{"fps":24,"durationPerImage":5,"transition":"slide","width":1920,"height":1080,"audio":false}'),
  ('timelapse',  '{"fps":30,"durationPerImage":0.5,"transition":"cut","width":3840,"height":2160,"audio":false}')
ON CONFLICT (name) DO NOTHING;

-- ── Indexes ───────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_jobs_status     ON jobs(status);
CREATE INDEX IF NOT EXISTS idx_jobs_type       ON jobs(job_type);
CREATE INDEX IF NOT EXISTS idx_jobs_created    ON jobs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_media_job_id    ON media(job_id);
CREATE INDEX IF NOT EXISTS idx_media_type      ON media(media_type);
CREATE INDEX IF NOT EXISTS idx_events_job_id   ON events(job_id);
CREATE INDEX IF NOT EXISTS idx_logs_job_id     ON logs(job_id);
CREATE INDEX IF NOT EXISTS idx_logs_level      ON logs(level);

-- ── Views ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW global_error_logs AS
SELECT l.id, l.job_id, l.level, l.message, l.context, l.created_at,
       j.src_path, j.folder_name, j.preset, j.job_type
FROM logs l
LEFT JOIN jobs j ON j.id = l.job_id
WHERE l.level = 'error'
ORDER BY l.created_at DESC;

CREATE OR REPLACE VIEW job_summary AS
SELECT job_type, status, COUNT(*) as count,
       SUM(total_files) as total_files,
       SUM(size_mb) as total_mb
FROM jobs
GROUP BY job_type, status
ORDER BY job_type, status;
INITSQL
ok "init.sql written"

# ============================================================
# docker-compose.yml
# ============================================================
section "docker-compose.yml"
cat > "$STACK_DIR/docker-compose.yml" << 'COMPOSE'
services:

  db:
    image: postgres:16-alpine
    container_name: hms_db
    restart: unless-stopped
    environment:
      POSTGRES_DB:       hms_db
      POSTGRES_USER:     hms
      POSTGRES_PASSWORD: hms_pass
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U hms -d hms_db"]
      interval: 5s
      timeout: 5s
      retries: 10
    ports:
      - "5401:5432"

  remotion:
    build:
      context: ./remotion-worker
      dockerfile: Dockerfile
    container_name: hms_remotion
    restart: unless-stopped
    environment:
      PORT: 3100
    volumes:
      - shared_media:/data/media
      - shared_renders:/data/renders
      - shared_audio:/data/audio
    ports:
      - "3100:3100"
    healthcheck:
      test: ["CMD-SHELL", "node -e \"fetch('http://localhost:3100/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 30s

  api:
    build:
      context: ./api
      dockerfile: Dockerfile
    container_name: hms_api
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      remotion:
        condition: service_healthy
    environment:
      PORT:           3000
      PGHOST:         db
      PGPORT:         5432
      PGDATABASE:     hms_db
      PGUSER:         hms
      PGPASSWORD:     hms_pass
      DATA_ROOT:      /data/media
      OUTPUT_BASE:    /data/output
      RENDER_BASE:    /data/renders
      AUDIO_BASE:     /data/audio
      LOG_DIR:        /data/logs
      REMOTION_URL:   http://remotion:3100
      FFMPEG_THREADS: 2
    volumes:
      - shared_media:/data/media
      - shared_output:/data/output
      - shared_renders:/data/renders
      - shared_audio:/data/audio
      - shared_logs:/data/logs
    ports:
      - "3012:3000"
    healthcheck:
      test: ["CMD-SHELL", "node -e \"fetch('http://localhost:3000/status').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  pg_data:
  shared_media:
  shared_output:
  shared_renders:
  shared_audio:
  shared_logs:
COMPOSE
ok "docker-compose.yml written"

# ============================================================
# REMOTION WORKER
# ============================================================
section "Remotion worker service"

cat > "$STACK_DIR/remotion-worker/Dockerfile" << 'RDOCKERFILE'
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    ffmpeg \
    fonts-liberation \
    libgbm1 \
    libasound2 \
    && rm -rf /var/lib/apt/lists/*

ENV PUPPETEER_SKIP_DOWNLOAD=true
ENV CHROME_PATH=/usr/bin/chromium

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY src ./src

RUN mkdir -p /data/media /data/renders /data/audio

EXPOSE 3100
CMD ["node", "src/server.js"]
RDOCKERFILE

cat > "$STACK_DIR/remotion-worker/package.json" << 'RPKG'
{
  "name": "hms-remotion-worker",
  "version": "1.0.0",
  "type": "module",
  "dependencies": {
    "@hono/node-server": "^1.13.7",
    "hono": "^4.6.3",
    "remotion": "^4.0.0",
    "@remotion/renderer": "^4.0.0",
    "@remotion/media-utils": "^4.0.0"
  }
}
RPKG

cat > "$STACK_DIR/remotion-worker/src/server.js" << 'RSERVER'
import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { renderMedia, selectComposition } from '@remotion/renderer';
import fs from 'fs/promises';
import path from 'path';

const app = new Hono();
const PORT = parseInt(process.env.PORT || '3100');
const RENDERS_DIR = process.env.RENDER_BASE || '/data/renders';
const AUDIO_DIR   = process.env.AUDIO_BASE  || '/data/audio';

app.get('/health', (c) => c.json({ ok: true, service: 'remotion-worker' }));

/**
 * POST /render
 * Body: {
 *   jobId, images: string[], audioPath?: string,
 *   fps, durationPerImage, transition, width, height,
 *   outputFile, muted
 * }
 */
app.post('/render', async (c) => {
  let body;
  try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON' }, 400); }

  const {
    jobId,
    images = [],
    audioPath = null,
    fps = 30,
    durationPerImage = 3,
    transition = 'fade',
    width = 1920,
    height = 1080,
    outputFile,
    muted = false,
  } = body;

  if (!images.length) return c.json({ error: 'images array is required' }, 400);
  if (!outputFile)    return c.json({ error: 'outputFile is required' }, 400);

  // Verify images exist
  const missing = [];
  for (const img of images) {
    try { await fs.access(img); } catch { missing.push(img); }
  }
  if (missing.length) return c.json({ error: 'Some images not found', missing }, 422);

  await fs.mkdir(path.dirname(outputFile), { recursive: true });

  // Build a self-contained Remotion bundle inline
  const totalFrames = Math.ceil(images.length * durationPerImage * fps);
  const framesPerImage = Math.ceil(durationPerImage * fps);
  const transitionFrames = Math.min(10, Math.floor(framesPerImage / 3));

  // Write a temporary composition file
  const bundleDir = `/tmp/remotion_bundle_${jobId || Date.now()}`;
  await fs.mkdir(bundleDir, { recursive: true });

  const compositionCode = `
import {Composition} from 'remotion';
import {SlideShow} from './Slideshow';
export const RemotionRoot = () => (
  <Composition
    id="HMS"
    component={SlideShow}
    durationInFrames={${totalFrames}}
    fps={${fps}}
    width={${width}}
    height={${height}}
    defaultProps={{
      images: ${JSON.stringify(images)},
      framesPerImage: ${framesPerImage},
      transitionFrames: ${transitionFrames},
      transition: "${transition}",
      audioSrc: ${audioPath && !muted ? JSON.stringify(audioPath) : 'null'},
      muted: ${muted},
    }}
  />
);
`;

  const slideshowCode = `
import {AbsoluteFill, Img, Audio, interpolate, useCurrentFrame, spring, useVideoConfig} from 'remotion';

export const SlideShow = ({images, framesPerImage, transitionFrames, transition, audioSrc, muted}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const imageIndex = Math.min(Math.floor(frame / framesPerImage), images.length - 1);
  const frameWithinSlide = frame % framesPerImage;
  const progress = frameWithinSlide / framesPerImage;

  const getOpacity = () => {
    if (transition === 'fade') {
      if (frameWithinSlide < transitionFrames) return frameWithinSlide / transitionFrames;
      if (frameWithinSlide > framesPerImage - transitionFrames) return (framesPerImage - frameWithinSlide) / transitionFrames;
      return 1;
    }
    return 1;
  };

  const getScale = () => {
    if (transition === 'zoom') return 1 + progress * 0.08;
    return 1;
  };

  const getTranslateX = () => {
    if (transition === 'slide') {
      if (frameWithinSlide < transitionFrames) return (1 - frameWithinSlide / transitionFrames) * 100;
      return 0;
    }
    return 0;
  };

  return (
    <AbsoluteFill style={{background:'#000'}}>
      <AbsoluteFill style={{
        opacity: getOpacity(),
        transform: \`scale(\${getScale()}) translateX(\${getTranslateX()}%)\`,
      }}>
        <Img src={images[imageIndex]}
          style={{width:'100%',height:'100%',objectFit:'cover'}} />
      </AbsoluteFill>
      {audioSrc && !muted && (
        <Audio src={audioSrc} />
      )}
    </AbsoluteFill>
  );
};
`;

  await fs.writeFile(path.join(bundleDir, 'index.jsx'), compositionCode);
  await fs.writeFile(path.join(bundleDir, 'Slideshow.jsx'), slideshowCode);
  await fs.writeFile(path.join(bundleDir, 'package.json'), JSON.stringify({
    name: 'remotion-bundle', version: '1.0.0', type: 'module',
    dependencies: { remotion: '^4.0.0' }
  }));

  try {
    const composition = await selectComposition({
      serveUrl: bundleDir,
      id: 'HMS',
    });

    await renderMedia({
      composition,
      serveUrl: bundleDir,
      codec: 'h264',
      outputLocation: outputFile,
      chromiumOptions: {
        executablePath: process.env.CHROME_PATH || '/usr/bin/chromium',
        disableWebSecurity: true,
      },
      concurrency: 2,
    });

    const stat = await fs.stat(outputFile);
    await fs.rm(bundleDir, { recursive: true, force: true });

    return c.json({
      ok: true,
      outputFile,
      sizeBytes: stat.size,
      sizeMb: parseFloat((stat.size / 1024 / 1024).toFixed(2)),
      images: images.length,
      totalFrames,
      fps,
    });
  } catch (err) {
    await fs.rm(bundleDir, { recursive: true, force: true }).catch(() => {});
    return c.json({ error: err.message }, 500);
  }
});

/**
 * GET /audio — list available audio files
 */
app.get('/audio', async (c) => {
  try {
    await fs.mkdir(AUDIO_DIR, { recursive: true });
    const entries = await fs.readdir(AUDIO_DIR, { withFileTypes: true });
    const files = entries
      .filter(e => e.isFile() && /\.(mp3|wav|aac|ogg|m4a|flac)$/i.test(e.name))
      .map(e => ({
        name: e.name,
        path: path.join(AUDIO_DIR, e.name),
      }));
    return c.json({ audio: files, count: files.length });
  } catch (err) {
    return c.json({ error: err.message }, 500);
  }
});

serve({ fetch: app.fetch, port: PORT }, () => {
  console.log(`[REMOTION] Worker ready on :${PORT}`);
});
RSERVER
ok "Remotion worker written"

# ============================================================
# API — Dockerfile
# ============================================================
section "API service"
cat > "$STACK_DIR/api/Dockerfile" << 'ADOCKERFILE'
FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY src ./src

RUN mkdir -p /data/media /data/output /data/renders /data/audio /data/logs

EXPOSE 3000
CMD ["node", "src/index.js"]
ADOCKERFILE

# ============================================================
# API — package.json
# ============================================================
cat > "$STACK_DIR/api/package.json" << 'APKG'
{
  "name": "hms-api",
  "version": "2.0.0",
  "type": "module",
  "scripts": {
    "start": "node src/index.js",
    "dev":   "node --watch src/index.js"
  },
  "dependencies": {
    "@hono/node-server": "^1.13.7",
    "hono":             "^4.6.3",
    "pg":               "^8.13.1"
  }
}
APKG

# ============================================================
# API — src/db.js
# ============================================================
cat > "$STACK_DIR/api/src/db.js" << 'DBJS'
import pg from 'pg';
const { Pool } = pg;

export const pool = new Pool({
  host:     process.env.PGHOST     || 'db',
  port:     parseInt(process.env.PGPORT || '5432'),
  database: process.env.PGDATABASE || 'hms_db',
  user:     process.env.PGUSER     || 'hms',
  password: process.env.PGPASSWORD || 'hms_pass',
});
pool.on('error', (err) => console.error('[DB] Pool error', err.message));

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

# ============================================================
# API — src/utils.js
# ============================================================
cat > "$STACK_DIR/api/src/utils.js" << 'UTILSJS'
import { spawn } from 'child_process';
import fs from 'fs/promises';
import path from 'path';
import crypto from 'crypto';

export const IMAGE_EXTS = new Set(['.jpg','.jpeg','.png','.webp','.bmp','.tiff','.tif','.gif']);
export const VIDEO_EXTS = new Set(['.mp4','.mkv','.mov','.avi','.flv','.wmv']);
export const AUDIO_EXTS = new Set(['.mp3','.wav','.aac','.ogg','.m4a','.flac']);

export const FFMPEG_PRESETS = {
  standard:  { width: 1920, height: 1080, crf: 23, bitrate: 5000 },
  high:      { width: 1920, height: 1080, crf: 18, bitrate: 8000 },
  '4k':      { width: 3840, height: 2160, crf: 20, bitrate: 15000 },
  cinematic: { width: 4096, height: 2160, crf: 18, bitrate: 20000 },
  reel:      { width: 1080, height: 1920, crf: 20, bitrate: 6000 },
};

export const REMOTION_PRESETS = {
  cineslide: { fps: 30, durationPerImage: 3, transition: 'fade',  width: 1920, height: 1080 },
  reel:      { fps: 60, durationPerImage: 1, transition: 'zoom',  width: 1080, height: 1920 },
  slideshow: { fps: 24, durationPerImage: 5, transition: 'slide', width: 1920, height: 1080 },
  timelapse: { fps: 30, durationPerImage: 0.5, transition: 'cut', width: 3840, height: 2160 },
};

export const IMAGE_DURATION  = 3;
export const MIN_DURATION    = 10;
export const FPS             = 30;

export function humanReadable(bytes) {
  if (bytes > 1_073_741_824) return `${(bytes/1_073_741_824).toFixed(2)}GB`;
  if (bytes > 1_048_576)     return `${(bytes/1_048_576).toFixed(2)}MB`;
  if (bytes > 1_024)         return `${(bytes/1_024).toFixed(2)}KB`;
  return `${bytes}B`;
}

export async function getFileSize(fp) {
  try { const s = await fs.stat(fp); return s.size; } catch { return 0; }
}

export async function hashFile(fp) {
  try {
    const buf = await fs.readFile(fp);
    return crypto.createHash('md5').update(buf).digest('hex');
  } catch { return null; }
}

/** Walk directory recursively, excluding an optional exclusion path */
export async function walkDir(dir, exclude = null) {
  const results = [];
  let entries;
  try { entries = await fs.readdir(dir, { withFileTypes: true }); }
  catch { return results; }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (exclude && full.startsWith(exclude)) continue;
    if (e.isDirectory()) results.push(...await walkDir(full, exclude));
    else if (e.isFile()) results.push(full);
  }
  return results;
}

export async function collectMedia(dir, type = 'both', exclude = null) {
  const files = await walkDir(dir, exclude);
  return files.filter(f => {
    const ext = path.extname(f).toLowerCase();
    if (type === 'image') return IMAGE_EXTS.has(ext);
    if (type === 'video') return VIDEO_EXTS.has(ext);
    if (type === 'audio') return AUDIO_EXTS.has(ext);
    return IMAGE_EXTS.has(ext) || VIDEO_EXTS.has(ext);
  });
}

export async function collectImages(dir) { return collectMedia(dir, 'image'); }
export async function collectVideos(dir) { return collectMedia(dir, 'video'); }

export function extractDateStamp(filename) {
  const m = filename.match(/^(\d{8})_?/); return m ? m[1] : null;
}
export function extractHourStamp(filename) {
  const m = filename.match(/^\d{8}_(\d{2})/); return m ? m[1] : null;
}
export function extractMinuteStamp(filename) {
  const m = filename.match(/^\d{8}_(\d{4})/); return m ? m[1] : null;
}

export function buildFfmpegConcatArgs({ manifestPath, width, height, crf, bitrate, threads, outputFile, audioPath, muted }) {
  const args = ['-y', '-loglevel', 'error',
    '-f', 'concat', '-safe', '0', '-i', manifestPath];
  if (audioPath && !muted) args.push('-i', audioPath);
  args.push('-vf', `scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2,fps=${FPS}`);
  args.push('-c:v', 'libx264', '-crf', String(crf), '-b:v', `${bitrate}k`, '-preset', 'fast', '-pix_fmt', 'yuv420p', '-threads', String(threads));
  if (audioPath && !muted) args.push('-c:a', 'aac', '-b:a', '192k', '-shortest');
  else args.push('-an');
  args.push(outputFile);
  return args;
}

export async function writeConcatManifest(images, durationPerImage = IMAGE_DURATION) {
  const tmp = `/tmp/manifest_${Date.now()}_${Math.random().toString(36).slice(2)}.txt`;
  const lines = [];
  for (const img of images) {
    lines.push(`file '${img}'`);
    lines.push(`duration ${durationPerImage}`);
  }
  lines.push(`file '${images[images.length - 1]}'`);
  await fs.writeFile(tmp, lines.join('\n') + '\n');
  return tmp;
}

export function runFfmpeg(args) {
  return new Promise(resolve => {
    const proc = spawn('ffmpeg', args, { stdio: ['ignore','ignore','pipe'] });
    const chunks = [];
    proc.stderr.on('data', d => chunks.push(d));
    proc.on('close', code => resolve({ code, stderr: Buffer.concat(chunks).toString() }));
    proc.on('error', err => resolve({ code: -1, stderr: err.message }));
  });
}

export async function safeMove(src, dstDir, dryRun = false) {
  const base = path.basename(src);
  let dst = path.join(dstDir, base);
  if (!dryRun) {
    await fs.mkdir(dstDir, { recursive: true });
    if (await fs.access(dst).then(() => true).catch(() => false)) {
      const ext = path.extname(base), stem = path.basename(base, ext);
      let c = 1;
      while (await fs.access(path.join(dstDir, `${stem}_${c}${ext}`)).then(() => true).catch(() => false)) c++;
      dst = path.join(dstDir, `${stem}_${c}${ext}`);
    }
    await fs.rename(src, dst);
  }
  return dst;
}

export async function removeEmptyDirs(dir) {
  let removed = 0;
  try {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const e of entries) {
      if (e.isDirectory()) removed += await removeEmptyDirs(path.join(dir, e.name));
    }
    const remaining = await fs.readdir(dir);
    if (remaining.length === 0) { await fs.rmdir(dir); removed++; }
  } catch (_) {}
  return removed;
}
UTILSJS

# ============================================================
# API — src/organiser.js
# ============================================================
cat > "$STACK_DIR/api/src/organiser.js" << 'ORGJS'
import path from 'path';
import fs from 'fs/promises';
import {
  collectMedia, getFileSize, hashFile, safeMove, removeEmptyDirs,
  humanReadable, extractDateStamp, extractHourStamp, extractMinuteStamp,
} from './utils.js';
import { pool, dbLog, dbEvent } from './db.js';

const OUTPUT_BASE = process.env.OUTPUT_BASE || '/data/output';

async function createOrganiseJob(srcPath, jobType = 'organise') {
  const r = await pool.query(
    `INSERT INTO jobs (job_type, status, src_path, preset, started_at)
     VALUES ($1, 'running', $2, 'organise', NOW()) RETURNING id`,
    [jobType, srcPath]
  );
  return r.rows[0].id;
}

async function finaliseJob(jobId, { status, totalFiles, sizeMb, outputPath, errorMsg }) {
  await pool.query(
    `UPDATE jobs SET status=$1, total_files=$2, size_mb=$3, output_path=$4, error_msg=$5, finished_at=NOW()
     WHERE id=$6`,
    [status, totalFiles, sizeMb, outputPath, errorMsg, jobId]
  );
}

async function insertMediaRecord(jobId, { filePath, mediaType, folderName }) {
  const fileName  = path.basename(filePath);
  const sizeBytes = await getFileSize(filePath);
  const hash      = await hashFile(filePath);
  await pool.query(
    `INSERT INTO media (job_id, media_type, file_path, folder_name, file_name, size_bytes, hash_md5)
     VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT DO NOTHING`,
    [jobId, mediaType, filePath, folderName, fileName, sizeBytes, hash]
  );
}

function groupFiles(files, granularity) {
  const groups = new Map();
  for (const f of files) {
    const fname = path.basename(f);
    const ds = extractDateStamp(fname);
    const hs = extractHourStamp(fname);
    const ms = extractMinuteStamp(fname);
    let key;
    switch (granularity) {
      case 'burst':  key = ms ? `${ds}_${ms}` : 'undated'; break;
      case 'hour':   key = hs ? `${ds}_${hs}` : 'undated'; break;
      case 'day':    key = ds || 'undated'; break;
      case 'month':  key = ds ? ds.slice(0, 6) : 'undated'; break;
      case 'year':   key = ds ? ds.slice(0, 4) : 'undated'; break;
      default:       key = 'all';
    }
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(f);
  }
  return groups;
}

async function buildGroupDir(baseDir, key, files) {
  let totalBytes = 0;
  for (const f of files) totalBytes += await getFileSize(f);
  const gb = totalBytes / 1_073_741_824;
  const label = gb >= 0.1 ? `${gb.toFixed(1)}gb` : `${Math.round(totalBytes/1_048_576)}mb`;
  return path.join(baseDir, `${key}__${files.length}_${label}`);
}

export async function organiseFiles({ srcPath, outputDir, mediaType = 'both', granularity = 'day', dryRun = false }) {
  const jobId = await createOrganiseJob(srcPath, 'organise');
  await dbEvent(jobId, 'organise_start', { srcPath, outputDir, mediaType, granularity, dryRun });

  const outBase = outputDir || path.join(OUTPUT_BASE, 'organised');
  const exclude = outBase;

  let allFiles, totalBytes = 0, movedCount = 0;
  const groups_summary = [], errors = [], duplicates = [];

  try {
    allFiles = await collectMedia(srcPath, mediaType, exclude);
    await dbLog('info', `Found ${allFiles.length} files to organise`, jobId, { granularity });

    // Dedup by hash
    const hashMap = new Map();
    for (const f of allFiles) {
      const h = await hashFile(f);
      if (!h) continue;
      if (!hashMap.has(h)) hashMap.set(h, []);
      hashMap.get(h).push(f);
    }

    const groups = groupFiles(allFiles, granularity);

    for (const [key, files] of [...groups.entries()].sort()) {
      if (files.length < 1) continue;
      const gDir = await buildGroupDir(outBase, key, files);
      const moved = [];
      for (const f of files) {
        const h = await hashFile(f);
        const copies = h ? (hashMap.get(h) || []) : [];
        const isDup = copies.length > 1 && copies[0] !== f;

        let targetDir = isDup ? path.join(gDir, '.duplicates') : gDir;
        try {
          const dst = await safeMove(f, targetDir, dryRun);
          moved.push(path.basename(f));
          if (!dryRun) await insertMediaRecord(jobId, {
            filePath: dst,
            mediaType: path.extname(f).match(/\.(mp4|mkv|mov|avi)$/i) ? 'video' : 'image',
            folderName: key,
          });
          totalBytes += await getFileSize(isDup ? f : dst);
          movedCount++;
          if (isDup) duplicates.push({ original: copies[0], duplicate: f });
        } catch (e) {
          errors.push(`${path.basename(f)}: ${e.message}`);
        }
      }
      groups_summary.push({ key, dir: gDir, count: files.length, files: moved });
      await dbLog('info', `Organised group ${key}: ${files.length} files`, jobId);
    }

    if (!dryRun) await removeEmptyDirs(srcPath);

    await finaliseJob(jobId, {
      status: errors.length ? 'failed' : 'done',
      totalFiles: movedCount,
      sizeMb: parseFloat((totalBytes / 1_048_576).toFixed(2)),
      outputPath: outBase,
      errorMsg: errors.length ? errors.slice(0,3).join('; ') : null,
    });
    await dbEvent(jobId, 'organise_done', { movedCount, groupCount: groups_summary.length, duplicates: duplicates.length });

    return { jobId, dryRun, groups: groups_summary, duplicates, errors, movedCount, totalBytes, totalHuman: humanReadable(totalBytes) };
  } catch (err) {
    await dbLog('error', `organise crashed: ${err.message}`, jobId);
    await finaliseJob(jobId, { status: 'failed', totalFiles: 0, sizeMb: 0, outputPath: null, errorMsg: err.message });
    throw err;
  }
}

export async function scanFiles({ srcPath, mediaType = 'both' }) {
  const files = await collectMedia(srcPath, mediaType);
  let totalBytes = 0;
  const byType = { image: 0, video: 0 };
  for (const f of files) {
    totalBytes += await getFileSize(f);
    const ext = path.extname(f).toLowerCase();
    if (['.jpg','.jpeg','.png','.webp','.gif','.bmp'].includes(ext)) byType.image++;
    else byType.video++;
  }
  return { totalFiles: files.length, byType, totalBytes, totalHuman: humanReadable(totalBytes) };
}
ORGJS

# ============================================================
# API — src/processor.js  (FFmpeg batch)
# ============================================================
cat > "$STACK_DIR/api/src/processor.js" << 'PROCJS'
import fs from 'fs/promises';
import path from 'path';
import { pool, dbLog, dbEvent } from './db.js';
import {
  FFMPEG_PRESETS, collectImages, collectMedia, getFileSize,
  buildFfmpegConcatArgs, writeConcatManifest, runFfmpeg, humanReadable,
  walkDir,
} from './utils.js';

const OUTPUT_BASE = process.env.OUTPUT_BASE || '/data/output';
const LOG_DIR     = process.env.LOG_DIR     || '/data/logs';

async function createJob(srcPath, preset, threads) {
  const r = await pool.query(
    `INSERT INTO jobs (job_type, status, src_path, preset, threads, started_at)
     VALUES ('process','running',$1,$2,$3,NOW()) RETURNING id`,
    [srcPath, preset, threads]
  );
  return r.rows[0].id;
}

async function finaliseJob(jobId, data) {
  const { status, outputPath, folderName, totalFiles, durationSec, sizeMb, errorMsg } = data;
  await pool.query(
    `UPDATE jobs SET status=$1,output_path=$2,folder_name=$3,total_files=$4,
     duration_sec=$5,size_mb=$6,error_msg=$7,finished_at=NOW() WHERE id=$8`,
    [status, outputPath, folderName, totalFiles, durationSec, sizeMb, errorMsg, jobId]
  );
}

async function processFolder(jobId, folder, preset, threads, audioPath = null, muted = false) {
  const cfg       = FFMPEG_PRESETS[preset] || FFMPEG_PRESETS.standard;
  const name      = path.basename(folder);
  const stamp     = new Date().toISOString().replace(/[:.]/g,'').slice(0,15);
  const outFile   = path.join(OUTPUT_BASE, 'videos', `${name}_${stamp}.mp4`);
  await fs.mkdir(path.dirname(outFile), { recursive: true });
  await fs.mkdir(LOG_DIR, { recursive: true });

  const images = await collectImages(folder);
  if (images.length === 0) {
    await dbLog('warn', `No images in ${name}`, jobId);
    return { status: 'skipped', folderName: name };
  }

  const totalDuration = Math.max(images.length * 3, 10);
  const manifest = await writeConcatManifest(images);

  const args = buildFfmpegConcatArgs({
    manifestPath: manifest, ...cfg,
    threads, outputFile: outFile,
    audioPath: audioPath || null,
    muted,
  });

  await dbEvent(jobId, 'ffmpeg_start', { name, images: images.length });
  const { code, stderr } = await runFfmpeg(args);
  await fs.unlink(manifest).catch(() => {});

  if (code !== 0) {
    await dbLog('error', `ffmpeg failed: ${stderr.slice(0,300)}`, jobId);
    return { status: 'failed', folderName: name, error: stderr.slice(0,300) };
  }

  const sizeBytes = await getFileSize(outFile);
  if (sizeBytes < 1024) {
    await fs.unlink(outFile).catch(() => {});
    return { status: 'failed', folderName: name, error: 'output_too_small' };
  }

  const sizeMb = parseFloat((sizeBytes/1024/1024).toFixed(2));
  await dbLog('info', `Done: ${name} → ${outFile} (${sizeMb}MB)`, jobId);
  return { status:'done', folderName:name, outputFile:outFile, totalImages:images.length, durationSec:totalDuration, sizeMb };
}

/** Recursively find all sub-folders containing images */
async function collectImageFolders(srcPath) {
  const folders = [];
  async function walk(dir) {
    let entries;
    try { entries = await fs.readdir(dir, { withFileTypes: true }); } catch { return; }
    const imgs = entries.filter(e => e.isFile() && /\.(jpg|jpeg|png|webp|gif|bmp)$/i.test(e.name));
    if (imgs.length > 0) folders.push(dir);
    for (const e of entries) {
      if (e.isDirectory() && e.name !== '.duplicates') await walk(path.join(dir, e.name));
    }
  }
  await walk(srcPath);
  return folders;
}

export async function processDirectory({ srcPath, preset = 'standard', threads = 2, audioPath = null, muted = false }) {
  if (!FFMPEG_PRESETS[preset]) throw new Error(`Unknown preset: ${preset}`);
  const jobId = await createJob(srcPath, preset, threads);
  await dbEvent(jobId, 'job_start', { srcPath, preset, threads, audioPath: !!audioPath, muted });

  setImmediate(async () => {
    try {
      const folders = await collectImageFolders(srcPath);
      await dbLog('info', `Found ${folders.length} image folder(s)`, jobId);

      let success = 0, skip = 0, fail = 0, lastOut = null;
      for (const folder of folders) {
        const res = await processFolder(jobId, folder, preset, threads, audioPath, muted);
        if (res.status === 'done')    { success++; lastOut = res.outputFile; }
        else if (res.status === 'skipped') skip++;
        else fail++;
      }

      const finalStatus = fail > 0 ? 'failed' : success > 0 ? 'done' : 'skipped';
      await finaliseJob(jobId, { status: finalStatus, outputPath: lastOut, folderName: null, totalFiles: success, durationSec: 0, sizeMb: 0, errorMsg: null });
      await dbEvent(jobId, 'job_done', { success, skip, fail });
    } catch (err) {
      await dbLog('error', `Process crashed: ${err.message}`, jobId);
      await pool.query(`UPDATE jobs SET status='failed',error_msg=$1,finished_at=NOW() WHERE id=$2`, [err.message, jobId]);
    }
  });
  return jobId;
}
PROCJS

# ============================================================
# API — src/renderer.js  (Remotion proxy)
# ============================================================
cat > "$STACK_DIR/api/src/renderer.js" << 'RENDERJS'
import path from 'path';
import fs from 'fs/promises';
import { pool, dbLog, dbEvent } from './db.js';
import { collectImages, getFileSize, humanReadable, REMOTION_PRESETS } from './utils.js';

const REMOTION_URL  = process.env.REMOTION_URL  || 'http://remotion:3100';
const RENDER_BASE   = process.env.RENDER_BASE   || '/data/renders';
const AUDIO_BASE    = process.env.AUDIO_BASE    || '/data/audio';

async function createRenderJob(srcPath, preset) {
  const r = await pool.query(
    `INSERT INTO jobs (job_type, status, src_path, preset, started_at)
     VALUES ('render','running',$1,$2,NOW()) RETURNING id`,
    [srcPath, preset]
  );
  return r.rows[0].id;
}

async function finaliseJob(jobId, data) {
  await pool.query(
    `UPDATE jobs SET status=$1, output_path=$2, total_files=$3, size_mb=$4,
     duration_sec=$5, error_msg=$6, render_opts=$7, finished_at=NOW() WHERE id=$8`,
    [data.status, data.outputPath, data.totalFiles, data.sizeMb,
     data.durationSec, data.errorMsg, data.renderOpts ? JSON.stringify(data.renderOpts) : null, jobId]
  );
}

export async function renderWithRemotion({ srcPath, preset = 'cineslide', audioPath = null, muted = false, customOpts = {} }) {
  const cfg  = { ...(REMOTION_PRESETS[preset] || REMOTION_PRESETS.cineslide), ...customOpts };
  const jobId = await createRenderJob(srcPath, preset);
  await dbEvent(jobId, 'render_start', { srcPath, preset, muted, audioPath: !!audioPath });
  await dbLog('info', `Render job started: ${jobId}`, jobId);

  setImmediate(async () => {
    try {
      // Collect images recursively
      const images = await collectImages(srcPath);
      if (images.length === 0) {
        await dbLog('warn', 'No images found for render', jobId);
        await finaliseJob(jobId, { status: 'skipped', outputPath: null, totalFiles: 0, sizeMb: 0, durationSec: 0, errorMsg: 'no_images', renderOpts: cfg });
        return;
      }

      const stamp      = new Date().toISOString().replace(/[:.]/g,'').slice(0,15);
      const folderName = path.basename(srcPath);
      const outputFile = path.join(RENDER_BASE, `${folderName}_${preset}_${stamp}.mp4`);
      await fs.mkdir(RENDER_BASE, { recursive: true });

      const totalDuration = Math.ceil(images.length * cfg.durationPerImage);

      const payload = {
        jobId,
        images,
        audioPath: audioPath && !muted ? audioPath : null,
        muted,
        outputFile,
        ...cfg,
      };

      const res  = await fetch(`${REMOTION_URL}/render`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const data = await res.json();

      if (!res.ok || !data.ok) {
        throw new Error(data.error || 'Remotion render failed');
      }

      await dbLog('info', `Render complete: ${outputFile} (${data.sizeMb}MB)`, jobId);
      await finaliseJob(jobId, {
        status:     'done',
        outputPath: outputFile,
        totalFiles: images.length,
        sizeMb:     data.sizeMb || 0,
        durationSec: totalDuration,
        errorMsg:   null,
        renderOpts: cfg,
      });
      await dbEvent(jobId, 'render_done', { outputFile, sizeMb: data.sizeMb, images: images.length });
    } catch (err) {
      await dbLog('error', `Render crashed: ${err.message}`, jobId);
      await pool.query(`UPDATE jobs SET status='failed',error_msg=$1,finished_at=NOW() WHERE id=$2`, [err.message, jobId]);
    }
  });

  return jobId;
}
RENDERJS

# ============================================================
# API — src/routes.js
# ============================================================
cat > "$STACK_DIR/api/src/routes.js" << 'ROUTESJS'
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
ROUTESJS

# ============================================================
# API — src/index.js  (GUI + routing)
# ============================================================
section "GUI (main index.js)"
cat > "$STACK_DIR/api/src/index.js" << 'INDEXJS'
import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { logger } from 'hono/logger';
import { pool } from './db.js';
import api from './routes.js';

const app = new Hono();
app.use('*', logger());

const DATA_ROOT    = process.env.DATA_ROOT    || '/data/media';
const AUDIO_BASE   = process.env.AUDIO_BASE   || '/data/audio';
const RENDER_BASE  = process.env.RENDER_BASE  || '/data/renders';
const OUTPUT_BASE  = process.env.OUTPUT_BASE  || '/data/output';

// ══════════════════════════════════════════════════════════════
// GUI — Hybrid Media Studio
// ══════════════════════════════════════════════════════════════
app.get('/', (c) => {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hybrid Media Studio</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Bebas+Neue&family=DM+Mono:wght@300;400;500&family=Outfit:wght@300;400;500;600;700&display=swap" rel="stylesheet">
<style>
:root {
  --void:    #06060c;
  --deep:    #0c0c18;
  --panel:   #111120;
  --card:    #16162a;
  --border:  #1e1e38;
  --border2: #2a2a50;
  --ember:   #ff4500;
  --ember2:  #ff7043;
  --ice:     #00c8ff;
  --mint:    #00e5a0;
  --gold:    #ffc940;
  --rose:    #ff4d8a;
  --text:    #d8d8f5;
  --muted:   #5a5a8a;
  --dim:     #3a3a60;
  --mono:    'DM Mono', monospace;
  --sans:    'Outfit', sans-serif;
  --display: 'Bebas Neue', sans-serif;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html{font-size:14px;scroll-behavior:smooth}
body{background:var(--void);color:var(--text);font-family:var(--sans);min-height:100vh;overflow-x:hidden}

/* ── NOISE OVERLAY ── */
body::before{
  content:'';position:fixed;inset:0;
  background-image:url("data:image/svg+xml,%3Csvg viewBox='0 0 512 512' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.75' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='0.04'/%3E%3C/svg%3E");
  pointer-events:none;z-index:0;opacity:.5;
}

/* ── LAYOUT ── */
.layout{display:grid;grid-template-columns:72px 260px 1fr;grid-template-rows:auto 1fr;min-height:100vh;position:relative;z-index:1}

/* ── ICON RAIL ── */
.rail{grid-row:1/3;background:var(--deep);border-right:1px solid var(--border);display:flex;flex-direction:column;align-items:center;padding:.75rem 0;gap:.25rem}
.rail-logo{font-family:var(--display);font-size:1.6rem;color:var(--ember2);letter-spacing:.05em;writing-mode:vertical-rl;transform:rotate(180deg);padding:.5rem 0 1rem;line-height:1}
.rail-btn{width:44px;height:44px;border-radius:10px;border:1px solid transparent;background:none;cursor:pointer;display:flex;align-items:center;justify-content:center;font-size:1.2rem;color:var(--muted);transition:all .15s;position:relative}
.rail-btn:hover{background:var(--panel);color:var(--text);border-color:var(--border2)}
.rail-btn.active{background:var(--card);color:var(--ember2);border-color:var(--border2)}
.rail-btn .tooltip{position:absolute;left:56px;background:var(--card);border:1px solid var(--border2);color:var(--text);font-size:.7rem;font-family:var(--mono);padding:.25rem .5rem;border-radius:4px;white-space:nowrap;pointer-events:none;opacity:0;transition:opacity .15s;z-index:999}
.rail-btn:hover .tooltip{opacity:1}
.rail-divider{width:32px;height:1px;background:var(--border);margin:.25rem 0}

/* ── SIDEBAR ── */
.sidebar{background:var(--deep);border-right:1px solid var(--border);padding:1rem .85rem;overflow-y:auto;display:flex;flex-direction:column;gap:1rem}
.sidebar-hdr{font-family:var(--mono);font-size:.6rem;color:var(--muted);text-transform:uppercase;letter-spacing:.14em;padding-left:.1rem;margin-bottom:.35rem}

/* ── Status chips ── */
.status-bar{display:flex;flex-direction:column;gap:.35rem}
.schip{display:flex;align-items:center;gap:.5rem;padding:.4rem .6rem;border-radius:6px;background:var(--card);border:1px solid var(--border);font-size:.7rem;font-family:var(--mono)}
.schip .dot{width:7px;height:7px;border-radius:50%;flex-shrink:0}
.dot-ok{background:var(--mint);box-shadow:0 0 6px var(--mint)}
.dot-warn{background:var(--gold);animation:blink 1.2s infinite}
.dot-err{background:var(--ember)}
.dot-off{background:var(--dim)}
@keyframes blink{0%,100%{opacity:1}50%{opacity:.3}}

/* ── Preset cards ── */
.preset-section{display:flex;flex-direction:column;gap:.3rem}
.preset-card{border-radius:8px;padding:.65rem .75rem;border:1px solid var(--border);background:var(--card);cursor:pointer;transition:all .18s;position:relative;overflow:hidden}
.preset-card::after{content:'';position:absolute;bottom:0;left:0;right:0;height:2px;background:var(--ember);transform:scaleX(0);transform-origin:left;transition:transform .2s}
.preset-card:hover::after,.preset-card.sel::after{transform:scaleX(1)}
.preset-card:hover,.preset-card.sel{border-color:var(--border2);background:#1c1c32}
.preset-card.sel{border-color:var(--ember)}
.preset-name{font-family:var(--display);font-size:1.05rem;letter-spacing:.04em;color:var(--text)}
.preset-sub{font-size:.62rem;font-family:var(--mono);color:var(--muted);margin-top:.1rem}
.preset-tag{position:absolute;top:.4rem;right:.5rem;font-size:.55rem;padding:.1rem .3rem;border-radius:3px;font-family:var(--mono);font-weight:500}
.tag-ffmpeg{background:rgba(0,200,255,.12);color:var(--ice);border:1px solid rgba(0,200,255,.2)}
.tag-remotion{background:rgba(255,77,138,.12);color:var(--rose);border:1px solid rgba(255,77,138,.2)}

/* ── Audio picker ── */
.audio-row{display:flex;align-items:center;gap:.4rem}
.audio-row select,.audio-row input{flex:1;background:var(--card);border:1px solid var(--border2);color:var(--text);font-family:var(--mono);font-size:.72rem;padding:.4rem .5rem;border-radius:5px;outline:none}
.audio-row select:focus,.audio-row input:focus{border-color:var(--ice)}
.audio-row select option{background:var(--card)}
.mute-toggle{display:flex;align-items:center;gap:.3rem;font-family:var(--mono);font-size:.65rem;color:var(--muted);cursor:pointer}
.mute-toggle input{accent-color:var(--ember)}

/* ── MAIN ── */
.main{padding:1.5rem;overflow-y:auto;display:flex;flex-direction:column;gap:1.25rem}

/* ── TOP BAR ── */
.topbar{display:flex;align-items:center;gap:1rem;margin-bottom:.25rem}
.page-title{font-family:var(--display);font-size:2.2rem;letter-spacing:.06em;color:var(--text);line-height:1}
.page-title span{color:var(--ember2)}
.topbar-actions{margin-left:auto;display:flex;gap:.5rem}
.tbtn{background:none;border:1px solid var(--border2);color:var(--muted);padding:.3rem .75rem;border-radius:6px;cursor:pointer;font-size:.72rem;font-family:var(--mono);transition:all .15s}
.tbtn:hover{border-color:var(--text);color:var(--text)}

/* ── SECTIONS ── */
.section{display:none}.section.visible{display:flex;flex-direction:column;gap:1rem}

/* ── CARD ── */
.card{background:var(--panel);border:1px solid var(--border);border-radius:14px;padding:1.25rem 1.5rem}
.card-hdr{display:flex;align-items:center;justify-content:space-between;margin-bottom:1rem}
.card-title{font-family:var(--display);font-size:1.35rem;letter-spacing:.05em;display:flex;align-items:center;gap:.5rem}
.badge{font-family:var(--mono);font-size:.55rem;padding:.15rem .4rem;border-radius:4px;font-weight:500;letter-spacing:.06em}
.badge-ember{background:rgba(255,69,0,.15);color:var(--ember2);border:1px solid rgba(255,69,0,.25)}
.badge-ice{background:rgba(0,200,255,.12);color:var(--ice);border:1px solid rgba(0,200,255,.2)}
.badge-mint{background:rgba(0,229,160,.1);color:var(--mint);border:1px solid rgba(0,229,160,.2)}
.badge-rose{background:rgba(255,77,138,.1);color:var(--rose);border:1px solid rgba(255,77,138,.2)}

/* ── FORM ── */
.form-grid{display:grid;grid-template-columns:1fr 1fr;gap:.75rem;margin-bottom:.75rem}
.form-grid.full{grid-template-columns:1fr}
.field label{display:block;font-size:.62rem;font-family:var(--mono);color:var(--muted);text-transform:uppercase;letter-spacing:.1em;margin-bottom:.3rem}
.field input,.field select,.field textarea{width:100%;background:var(--card);border:1px solid var(--border2);color:var(--text);font-family:var(--mono);font-size:.76rem;padding:.5rem .7rem;border-radius:6px;outline:none;transition:border-color .15s}
.field input:focus,.field select:focus{border-color:var(--ice)}
.field select option{background:var(--card)}

/* ── PILLS ── */
.pills{display:flex;gap:.35rem;flex-wrap:wrap}
.pill{padding:.3rem .8rem;border-radius:20px;border:1px solid var(--border2);background:none;color:var(--muted);cursor:pointer;font-size:.7rem;font-family:var(--mono);transition:all .15s}
.pill:hover{border-color:var(--text);color:var(--text)}
.pill.active{background:rgba(0,200,255,.08);border-color:var(--ice);color:var(--ice)}

/* ── LAUNCH BUTTON ── */
.launch{width:100%;padding:.8rem;border-radius:8px;border:none;background:linear-gradient(130deg,var(--ember),var(--ember2));color:#fff;font-family:var(--display);font-size:1.3rem;letter-spacing:.08em;cursor:pointer;transition:all .2s;margin-top:.6rem;position:relative;overflow:hidden}
.launch::before{content:'';position:absolute;inset:0;background:linear-gradient(130deg,transparent,rgba(255,255,255,.08));pointer-events:none}
.launch:hover{transform:translateY(-2px);box-shadow:0 8px 28px rgba(255,69,0,.4)}
.launch:active{transform:none}
.launch:disabled{opacity:.45;cursor:not-allowed;transform:none;box-shadow:none}
.launch.remotion{background:linear-gradient(130deg,#c2185b,var(--rose))}
.launch.remotion:hover{box-shadow:0 8px 28px rgba(255,77,138,.4)}
.launch.pipeline{background:linear-gradient(130deg,#1565c0,var(--ice))}
.launch.pipeline:hover{box-shadow:0 8px 28px rgba(0,200,255,.35)}
.launch.organise{background:linear-gradient(130deg,#1b5e20,var(--mint))}
.launch.organise:hover{box-shadow:0 8px 28px rgba(0,229,160,.35)}

/* ── TOAST ── */
.toast{margin-top:.65rem;padding:.55rem .8rem;border-radius:6px;font-family:var(--mono);font-size:.72rem;display:none;word-break:break-all;line-height:1.5}
.toast.ok{background:rgba(0,229,160,.08);border:1px solid rgba(0,229,160,.25);color:var(--mint);display:block}
.toast.err{background:rgba(255,69,0,.08);border:1px solid rgba(255,69,0,.25);color:var(--ember2);display:block}

/* ── QUICK STRIP ── */
.quick-strip{display:grid;grid-template-columns:repeat(4,1fr);gap:.5rem}
.qcard{border:1px solid var(--border);background:var(--card);border-radius:10px;padding:.75rem;cursor:pointer;transition:all .18s;text-align:center;position:relative;overflow:hidden}
.qcard:hover{transform:translateY(-2px);border-color:var(--border2)}
.qcard .qname{font-family:var(--display);font-size:1.2rem;letter-spacing:.04em;display:block;margin-bottom:.2rem}
.qcard .qsub{font-size:.6rem;font-family:var(--mono);color:var(--muted)}
.qcard.q-standard:hover{border-color:var(--ice);box-shadow:0 4px 18px rgba(0,200,255,.15)}
.qcard.q-high:hover{border-color:#a78bfa;box-shadow:0 4px 18px rgba(167,139,250,.15)}
.qcard.q-4k:hover{border-color:var(--mint);box-shadow:0 4px 18px rgba(0,229,160,.15)}
.qcard.q-cinematic:hover{border-color:var(--ember2);box-shadow:0 4px 18px rgba(255,112,67,.15)}

/* ── JOBS TABLE ── */
.jtable{width:100%;border-collapse:collapse}
.jtable thead th{font-family:var(--mono);font-size:.6rem;color:var(--muted);text-transform:uppercase;letter-spacing:.1em;padding:.4rem .6rem;text-align:left;border-bottom:1px solid var(--border)}
.jtable tbody tr{border-bottom:1px solid var(--border);cursor:pointer;transition:background .1s}
.jtable tbody tr:hover{background:var(--card)}
.jtable tbody td{padding:.5rem .6rem;font-size:.76rem;font-family:var(--mono)}
.jbadge{display:inline-flex;align-items:center;gap:.25rem;padding:.12rem .45rem;border-radius:20px;font-size:.6rem;font-weight:600;font-family:var(--mono)}
.jbadge.running{background:rgba(255,201,64,.1);color:var(--gold);border:1px solid rgba(255,201,64,.3)}
.jbadge.done{background:rgba(0,229,160,.1);color:var(--mint);border:1px solid rgba(0,229,160,.3)}
.jbadge.failed{background:rgba(255,69,0,.1);color:var(--ember2);border:1px solid rgba(255,69,0,.3)}
.jbadge.skipped{background:rgba(90,90,138,.1);color:var(--muted);border:1px solid var(--border)}
.jbadge.pending{background:rgba(0,200,255,.1);color:var(--ice);border:1px solid rgba(0,200,255,.3)}
.type-badge{font-size:.58rem;padding:.1rem .3rem;border-radius:3px;font-family:var(--mono);font-weight:600}
.type-process{background:rgba(0,200,255,.1);color:var(--ice)}
.type-render{background:rgba(255,77,138,.1);color:var(--rose)}
.type-organise{background:rgba(0,229,160,.1);color:var(--mint)}
.type-scan{background:rgba(90,90,138,.1);color:var(--muted)}
.empty{text-align:center;padding:2.5rem;color:var(--muted);font-family:var(--mono);font-size:.78rem}

/* ── DRAWER ── */
.overlay{position:fixed;inset:0;background:rgba(6,6,12,.75);backdrop-filter:blur(6px);z-index:200;display:none;align-items:stretch;justify-content:flex-end}
.overlay.open{display:flex}
.drawer{width:min(660px,95vw);background:var(--panel);border-left:1px solid var(--border2);overflow-y:auto;padding:1.5rem;animation:slideIn .22s ease}
@keyframes slideIn{from{transform:translateX(50px);opacity:0}to{transform:none;opacity:1}}
.dclose{float:right;background:none;border:1px solid var(--border2);color:var(--muted);padding:.3rem .7rem;border-radius:6px;cursor:pointer;font-family:var(--mono);font-size:.72rem;margin-bottom:1rem}
.dclose:hover{border-color:var(--ember);color:var(--ember)}
.dgrid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:.45rem;margin:1rem 0}
.dcell{background:var(--card);border:1px solid var(--border);border-radius:6px;padding:.5rem .7rem}
.dcell .dl{font-size:.58rem;font-family:var(--mono);color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin-bottom:.15rem}
.dcell .dv{font-family:var(--mono);font-size:.78rem}
.log-wrap{max-height:260px;overflow-y:auto;margin-top:.5rem}
.log-row{display:flex;gap:.5rem;padding:.3rem 0;border-bottom:1px solid var(--border);font-family:var(--mono);font-size:.65rem;align-items:flex-start}
.log-lvl{flex-shrink:0;padding:.08rem .3rem;border-radius:3px;font-size:.58rem;font-weight:700;min-width:34px;text-align:center}
.lvl-info{background:rgba(0,200,255,.1);color:var(--ice)}
.lvl-warn{background:rgba(255,201,64,.1);color:var(--gold)}
.lvl-error{background:rgba(255,69,0,.1);color:var(--ember2)}
.lvl-debug{background:rgba(90,90,138,.1);color:var(--muted)}
.log-msg{color:var(--muted);flex:1;word-break:break-word}
.log-time{color:var(--dim);flex-shrink:0;font-size:.58rem}

/* ── THREAD SLIDER ── */
.slider-row{display:flex;align-items:center;gap:.5rem}
.slider-row input[type=range]{flex:1;accent-color:var(--ember2)}
.slider-val{font-family:var(--mono);font-size:.72rem;color:var(--ember2);min-width:1rem;text-align:right}

/* ── PIPELINE STEPS ── */
.pipe-steps{display:flex;gap:.5rem;margin-bottom:1rem;align-items:center}
.pipe-step{flex:1;text-align:center;padding:.5rem;border-radius:8px;border:1px solid var(--border);background:var(--card);font-family:var(--mono);font-size:.65rem;color:var(--muted);position:relative}
.pipe-step.on{border-color:var(--ice);color:var(--ice);background:rgba(0,200,255,.05)}
.pipe-arrow{color:var(--muted);font-size:.9rem;flex-shrink:0}

/* ── FOOTER ── */
footer{position:fixed;bottom:0;right:0;left:332px;background:var(--deep);border-top:1px solid var(--border);padding:.3rem 1.5rem;display:flex;align-items:center;gap:1rem;font-size:.62rem;font-family:var(--mono);color:var(--muted);z-index:10}
.f-spacer{flex:1}
#auto-ref{accent-color:var(--ember2);cursor:pointer}

/* ── SCROLLBAR ── */
::-webkit-scrollbar{width:4px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:var(--border2);border-radius:2px}
</style>
</head>
<body>
<div class="layout">

<!-- ICON RAIL -->
<nav class="rail">
  <div class="rail-logo">HMS</div>
  <button class="rail-btn active" id="r-home"    onclick="nav('home')"     title="Home">🏠<span class="tooltip">Dashboard</span></button>
  <button class="rail-btn"        id="r-organise" onclick="nav('organise')" title="Organise">📁<span class="tooltip">Organise Files</span></button>
  <button class="rail-btn"        id="r-process"  onclick="nav('process')"  title="Process">⚙️<span class="tooltip">FFmpeg Process</span></button>
  <button class="rail-btn"        id="r-render"   onclick="nav('render')"   title="Render">🎬<span class="tooltip">Remotion Render</span></button>
  <button class="rail-btn"        id="r-pipeline" onclick="nav('pipeline')" title="Pipeline">⚡<span class="tooltip">Full Pipeline</span></button>
  <div class="rail-divider"></div>
  <button class="rail-btn"        id="r-jobs"    onclick="nav('jobs')"     title="Jobs">📋<span class="tooltip">Job Queue</span></button>
  <button class="rail-btn"        id="r-media"   onclick="nav('media')"    title="Media">🖼️<span class="tooltip">Media Library</span></button>
  <button class="rail-btn"        id="r-logs"    onclick="nav('logs')"     title="Logs">📜<span class="tooltip">Error Logs</span></button>
</nav>

<!-- SIDEBAR -->
<aside class="sidebar">
  <!-- System status -->
  <div>
    <div class="sidebar-hdr">System</div>
    <div class="status-bar">
      <div class="schip"><span class="dot dot-off" id="db-dot"></span><span id="db-lbl">DB</span><span style="margin-left:auto;color:var(--dim)" id="db-stat">—</span></div>
      <div class="schip"><span class="dot dot-off" id="rem-dot"></span><span id="rem-lbl">Remotion</span><span style="margin-left:auto;color:var(--dim)" id="rem-stat">—</span></div>
      <div class="schip"><span class="dot dot-ok"></span><span>Running</span><span style="margin-left:auto;color:var(--gold);font-size:.7rem" id="running-n">0</span></div>
      <div class="schip"><span class="dot dot-ok" style="background:var(--mint)"></span><span>Done</span><span style="margin-left:auto;color:var(--mint);font-size:.7rem" id="done-n">0</span></div>
      <div class="schip"><span class="dot dot-err"></span><span>Failed</span><span style="margin-left:auto;color:var(--ember2);font-size:.7rem" id="fail-n">0</span></div>
    </div>
  </div>

  <!-- Active preset -->
  <div>
    <div class="sidebar-hdr">Active Preset</div>
    <div class="preset-section" id="sidebar-presets">
      <div class="preset-card sel" data-preset="standard" onclick="selectPreset('standard',this)">
        <span class="preset-tag tag-ffmpeg">FFmpeg</span>
        <div class="preset-name">Standard</div>
        <div class="preset-sub">1080p · CRF23 · 5Mbps</div>
      </div>
      <div class="preset-card" data-preset="high" onclick="selectPreset('high',this)">
        <span class="preset-tag tag-ffmpeg">FFmpeg</span>
        <div class="preset-name">High</div>
        <div class="preset-sub">1080p · CRF18 · 8Mbps</div>
      </div>
      <div class="preset-card" data-preset="4k" onclick="selectPreset('4k',this)">
        <span class="preset-tag tag-ffmpeg">FFmpeg</span>
        <div class="preset-name">4K</div>
        <div class="preset-sub">2160p · CRF20 · 15Mbps</div>
      </div>
      <div class="preset-card" data-preset="cinematic" onclick="selectPreset('cinematic',this)">
        <span class="preset-tag tag-ffmpeg">FFmpeg</span>
        <div class="preset-name">Cinematic</div>
        <div class="preset-sub">4096×2160 · CRF18 · 20Mbps</div>
      </div>
      <div class="preset-card" data-preset="cineslide" onclick="selectPreset('cineslide',this)">
        <span class="preset-tag tag-remotion">Remotion</span>
        <div class="preset-name">Cineslide</div>
        <div class="preset-sub">Fade · 30fps · 1080p</div>
      </div>
      <div class="preset-card" data-preset="reel" onclick="selectPreset('reel',this)">
        <span class="preset-tag tag-remotion">Remotion</span>
        <div class="preset-name">Reel</div>
        <div class="preset-sub">Zoom · 60fps · Vertical</div>
      </div>
      <div class="preset-card" data-preset="slideshow" onclick="selectPreset('slideshow',this)">
        <span class="preset-tag tag-remotion">Remotion</span>
        <div class="preset-name">Slideshow</div>
        <div class="preset-sub">Slide · 24fps · No audio</div>
      </div>
      <div class="preset-card" data-preset="timelapse" onclick="selectPreset('timelapse',this)">
        <span class="preset-tag tag-remotion">Remotion</span>
        <div class="preset-name">Timelapse</div>
        <div class="preset-sub">Cut · 4K · 0.5s/img</div>
      </div>
    </div>
  </div>

  <!-- Audio -->
  <div>
    <div class="sidebar-hdr">Audio Track</div>
    <div class="audio-row" style="margin-bottom:.35rem">
      <select id="audio-select" onchange="syncAudio()">
        <option value="">— no audio —</option>
      </select>
    </div>
    <label class="mute-toggle">
      <input type="checkbox" id="mute-toggle" onchange="syncAudio()"> Mute output
    </label>
  </div>
</aside>

<!-- MAIN -->
<main class="main">

<!-- ── DASHBOARD ── -->
<div class="section visible" id="section-home">
  <div class="topbar">
    <div>
      <div class="page-title">HYBRID<span> MEDIA</span> STUDIO</div>
      <div style="font-size:.72rem;color:var(--muted);margin-top:.2rem;font-family:var(--mono)">Organise → Process → Render</div>
    </div>
    <div class="topbar-actions">
      <button class="tbtn" onclick="refreshStatus()">↻ Refresh</button>
      <button class="tbtn" onclick="window.open('/doc','_blank')">API ↗</button>
    </div>
  </div>

  <div class="card">
    <div class="card-hdr">
      <div class="card-title">⚡ Quick Fire <span class="badge badge-ember">FFmpeg</span></div>
      <div style="font-size:.68rem;font-family:var(--mono);color:var(--muted)">Process ${DATA_ROOT}</div>
    </div>
    <div class="quick-strip">
      <div class="qcard q-standard" onclick="quickProcess('standard')">
        <span class="qname" style="color:var(--ice)">Standard</span>
        <span class="qsub">1080p · CRF23</span>
      </div>
      <div class="qcard q-high" onclick="quickProcess('high')">
        <span class="qname" style="color:#a78bfa">High</span>
        <span class="qsub">1080p · CRF18</span>
      </div>
      <div class="qcard q-4k" onclick="quickProcess('4k')">
        <span class="qname" style="color:var(--mint)">4K</span>
        <span class="qsub">2160p · CRF20</span>
      </div>
      <div class="qcard q-cinematic" onclick="quickProcess('cinematic')">
        <span class="qname" style="color:var(--ember2)">Cinematic</span>
        <span class="qsub">4096×2160</span>
      </div>
    </div>
    <div id="toast-quick" class="toast"></div>
  </div>

  <div class="card">
    <div class="card-hdr">
      <div class="card-title">🎬 Quick Render <span class="badge badge-rose">Remotion</span></div>
      <div style="font-size:.68rem;font-family:var(--mono);color:var(--muted)">Animated video from ${DATA_ROOT}</div>
    </div>
    <div class="quick-strip" style="grid-template-columns:repeat(4,1fr)">
      <div class="qcard" onclick="quickRender('cineslide')" style="border-color:#3a1030">
        <span class="qname" style="color:var(--rose)">Cineslide</span>
        <span class="qsub">Fade · 30fps</span>
      </div>
      <div class="qcard" onclick="quickRender('reel')" style="border-color:#3a1030">
        <span class="qname" style="color:var(--rose)">Reel</span>
        <span class="qsub">Zoom · 60fps</span>
      </div>
      <div class="qcard" onclick="quickRender('slideshow')" style="border-color:#3a1030">
        <span class="qname" style="color:var(--rose)">Slideshow</span>
        <span class="qsub">Slide · 24fps</span>
      </div>
      <div class="qcard" onclick="quickRender('timelapse')" style="border-color:#3a1030">
        <span class="qname" style="color:var(--rose)">Timelapse</span>
        <span class="qsub">Cut · 4K</span>
      </div>
    </div>
    <div id="toast-qrender" class="toast"></div>
  </div>
</div>

<!-- ── ORGANISE ── -->
<div class="section" id="section-organise">
  <div class="topbar"><div class="page-title">ORGANISE <span>FILES</span></div></div>
  <div class="card">
    <div class="card-title" style="margin-bottom:1rem">📁 Group & Deduplicate <span class="badge badge-mint">Organise</span></div>
    <div class="form-grid">
      <div class="field"><label>Source Directory</label><input id="org-src" type="text" value="${DATA_ROOT}" placeholder="/data/media"></div>
      <div class="field"><label>Output Directory</label><input id="org-out" type="text" placeholder="/data/output/organised (auto)"></div>
    </div>
    <div class="form-grid">
      <div class="field">
        <label>Media Type</label>
        <select id="org-type">
          <option value="both">Both (images + videos)</option>
          <option value="image">Images only</option>
          <option value="video">Videos only</option>
        </select>
      </div>
      <div class="field">
        <label>Group By</label>
        <select id="org-gran">
          <option value="day">Day (YYYYMMDD)</option>
          <option value="hour">Hour (YYYYMMDD_HH)</option>
          <option value="burst">Burst (YYYYMMDD_HHMM)</option>
          <option value="month">Month (YYYYMM)</option>
          <option value="year">Year (YYYY)</option>
        </select>
      </div>
    </div>
    <label class="mute-toggle" style="margin-bottom:.75rem">
      <input type="checkbox" id="org-dry"> Dry run (preview only)
    </label>
    <button class="launch organise" onclick="doOrganise()">📁 ORGANISE FILES</button>
    <div id="toast-org" class="toast"></div>
  </div>

  <div class="card">
    <div class="card-title" style="margin-bottom:1rem">🔍 Scan Directory</div>
    <div class="form-grid">
      <div class="field"><label>Directory to Scan</label><input id="scan-src" type="text" value="${DATA_ROOT}"></div>
      <div class="field">
        <label>Type</label>
        <select id="scan-type">
          <option value="both">Both</option>
          <option value="image">Images</option>
          <option value="video">Videos</option>
        </select>
      </div>
    </div>
    <button class="launch organise" onclick="doScan()">🔍 SCAN</button>
    <div id="toast-scan" class="toast"></div>
  </div>
</div>

<!-- ── PROCESS ── -->
<div class="section" id="section-process">
  <div class="topbar"><div class="page-title">FFMPEG <span>PROCESS</span></div></div>
  <div class="card">
    <div class="card-title" style="margin-bottom:1rem">⚙️ Batch Image→Video <span class="badge badge-ice">FFmpeg</span></div>
    <div class="form-grid">
      <div class="field"><label>Source Path</label><input id="proc-src" type="text" value="${DATA_ROOT}"></div>
      <div class="field">
        <label>Preset</label>
        <select id="proc-preset">
          <option value="standard">Standard — 1080p CRF23</option>
          <option value="high">High — 1080p CRF18</option>
          <option value="4k">4K — 2160p CRF20</option>
          <option value="cinematic">Cinematic — 4096×2160</option>
          <option value="reel">Reel — 1080×1920 vertical</option>
        </select>
      </div>
    </div>
    <div class="form-grid">
      <div class="field">
        <label>Threads — <span id="tval">2</span></label>
        <div class="slider-row">
          <input type="range" min="1" max="16" value="2" id="thread-slider" oninput="document.getElementById('tval').textContent=this.value">
        </div>
      </div>
      <div class="field">
        <label>Audio (optional)</label>
        <input id="proc-audio" type="text" placeholder="/data/audio/track.mp3 (leave blank for mute)">
      </div>
    </div>
    <label class="mute-toggle" style="margin-bottom:.75rem">
      <input type="checkbox" id="proc-mute"> Force mute (ignore audio)
    </label>
    <button class="launch" onclick="doProcess()">▶ LAUNCH PROCESS</button>
    <div id="toast-proc" class="toast"></div>
  </div>
</div>

<!-- ── RENDER ── -->
<div class="section" id="section-render">
  <div class="topbar"><div class="page-title">REMOTION <span>RENDER</span></div></div>
  <div class="card">
    <div class="card-title" style="margin-bottom:1rem">🎬 Animated Video <span class="badge badge-rose">Remotion</span></div>
    <div class="form-grid">
      <div class="field"><label>Source Path</label><input id="ren-src" type="text" value="${DATA_ROOT}"></div>
      <div class="field">
        <label>Render Preset</label>
        <select id="ren-preset">
          <option value="cineslide">Cineslide — Fade · 30fps · 1080p</option>
          <option value="reel">Reel — Zoom · 60fps · Vertical</option>
          <option value="slideshow">Slideshow — Slide · 24fps</option>
          <option value="timelapse">Timelapse — Cut · 4K · 0.5s/img</option>
        </select>
      </div>
    </div>
    <div class="form-grid">
      <div class="field">
        <label>Audio File</label>
        <input id="ren-audio" type="text" placeholder="/data/audio/track.mp3">
      </div>
      <div class="field">
        <label>Transition</label>
        <select id="ren-transition">
          <option value="fade">Fade</option>
          <option value="zoom">Zoom</option>
          <option value="slide">Slide</option>
          <option value="cut">Cut (no transition)</option>
        </select>
      </div>
    </div>
    <label class="mute-toggle" style="margin-bottom:.75rem">
      <input type="checkbox" id="ren-mute"> Mute (no audio)
    </label>
    <button class="launch remotion" onclick="doRender()">🎬 RENDER VIDEO</button>
    <div id="toast-ren" class="toast"></div>
  </div>
</div>

<!-- ── PIPELINE ── -->
<div class="section" id="section-pipeline">
  <div class="topbar"><div class="page-title">FULL <span>PIPELINE</span></div></div>
  <div class="card">
    <div class="card-title" style="margin-bottom:.75rem">⚡ Organise → Process → Render <span class="badge badge-ember">Auto</span></div>
    <div class="pipe-steps">
      <div class="pipe-step on" id="ps-organise">📁 Organise</div>
      <div class="pipe-arrow">→</div>
      <div class="pipe-step on" id="ps-process">⚙️ FFmpeg</div>
      <div class="pipe-arrow">→</div>
      <div class="pipe-step on" id="ps-render">🎬 Remotion</div>
    </div>
    <label style="display:flex;align-items:center;gap:.5rem;font-size:.68rem;font-family:var(--mono);color:var(--muted);cursor:pointer;margin-bottom:.35rem">
      <input type="checkbox" checked id="pipe-org" onchange="togglePipeStep('organise')"> Include Organise step
    </label>
    <label style="display:flex;align-items:center;gap:.5rem;font-size:.68rem;font-family:var(--mono);color:var(--muted);cursor:pointer;margin-bottom:.35rem">
      <input type="checkbox" checked id="pipe-proc" onchange="togglePipeStep('process')"> Include FFmpeg Process step
    </label>
    <label style="display:flex;align-items:center;gap:.5rem;font-size:.68rem;font-family:var(--mono);color:var(--muted);cursor:pointer;margin-bottom:.75rem">
      <input type="checkbox" checked id="pipe-ren" onchange="togglePipeStep('render')"> Include Remotion Render step
    </label>
    <div class="form-grid">
      <div class="field"><label>Source Path</label><input id="pipe-src" type="text" value="${DATA_ROOT}"></div>
      <div class="field"><label>Group By</label>
        <select id="pipe-gran">
          <option value="day">Day</option><option value="hour">Hour</option>
          <option value="burst">Burst</option><option value="month">Month</option>
        </select>
      </div>
    </div>
    <div class="form-grid">
      <div class="field"><label>FFmpeg Preset</label>
        <select id="pipe-fpreset">
          <option value="standard">Standard</option><option value="high">High</option>
          <option value="4k">4K</option><option value="cinematic">Cinematic</option>
        </select>
      </div>
      <div class="field"><label>Remotion Preset</label>
        <select id="pipe-rpreset">
          <option value="cineslide">Cineslide</option><option value="reel">Reel</option>
          <option value="slideshow">Slideshow</option><option value="timelapse">Timelapse</option>
        </select>
      </div>
    </div>
    <div class="field" style="margin-bottom:.75rem"><label>Audio File (optional)</label>
      <input id="pipe-audio" type="text" placeholder="/data/audio/track.mp3">
    </div>
    <label class="mute-toggle" style="margin-bottom:.5rem">
      <input type="checkbox" id="pipe-dry"> Dry run
    </label>
    <label class="mute-toggle" style="margin-bottom:.75rem">
      <input type="checkbox" id="pipe-mute"> Mute all outputs
    </label>
    <button class="launch pipeline" onclick="doPipeline()">⚡ RUN FULL PIPELINE</button>
    <div id="toast-pipe" class="toast"></div>
  </div>
</div>

<!-- ── JOBS ── -->
<div class="section" id="section-jobs">
  <div class="topbar">
    <div class="page-title">JOB <span>QUEUE</span></div>
    <div class="topbar-actions">
      <div class="pills">
        <button class="pill active" onclick="filterJobs('')"         id="jf-all">All</button>
        <button class="pill"        onclick="filterJobs('process')"  id="jf-process">Process</button>
        <button class="pill"        onclick="filterJobs('render')"   id="jf-render">Render</button>
        <button class="pill"        onclick="filterJobs('organise')" id="jf-organise">Organise</button>
      </div>
      <button class="tbtn" onclick="loadJobs()">↻</button>
    </div>
  </div>
  <div class="card">
    <div id="jobs-wrap"></div>
  </div>
</div>

<!-- ── MEDIA ── -->
<div class="section" id="section-media">
  <div class="topbar">
    <div class="page-title">MEDIA <span>LIBRARY</span></div>
    <div class="topbar-actions">
      <div class="pills">
        <button class="pill active" onclick="filterMedia('')"       id="mf-all">All</button>
        <button class="pill"        onclick="filterMedia('image')"  id="mf-image">Images</button>
        <button class="pill"        onclick="filterMedia('video')"  id="mf-video">Video</button>
        <button class="pill"        onclick="filterMedia('render')" id="mf-render">Renders</button>
      </div>
      <button class="tbtn" onclick="loadMedia()">↻</button>
    </div>
  </div>
  <div class="card"><div id="media-wrap"></div></div>
</div>

<!-- ── ERROR LOGS ── -->
<div class="section" id="section-logs">
  <div class="topbar">
    <div class="page-title">ERROR <span>LOGS</span></div>
    <div class="topbar-actions"><button class="tbtn" onclick="loadLogs()">↻</button></div>
  </div>
  <div class="card"><div id="logs-wrap"></div></div>
</div>

</main><!-- /main -->
</div><!-- /layout -->

<footer>
  <span>Hybrid Media Studio v2.0</span><span>·</span>
  <span id="ft-time"></span>
  <span class="f-spacer"></span>
  <label style="display:flex;align-items:center;gap:.35rem;cursor:pointer">
    <input type="checkbox" id="auto-ref" checked> Auto-refresh
  </label>
</footer>

<!-- DRAWER -->
<div class="overlay" id="overlay" onclick="closeDrawer(event)">
  <div class="drawer" id="drawer">
    <button class="dclose" onclick="forceCloseDrawer()">✕ Close</button>
    <div id="drawer-body"></div>
  </div>
</div>

<script>
// ── State ──────────────────────────────────────────────────────────────────
let activePreset   = 'standard';
let activeAudio    = '';
let activeMute     = false;
let activeSection  = 'home';
let jobFilter      = '';
let mediaFilter    = '';
let autoRefTick    = null;

// ── Navigation ─────────────────────────────────────────────────────────────
function nav(name) {
  document.querySelectorAll('.section').forEach(s => s.classList.remove('visible'));
  document.querySelectorAll('.rail-btn').forEach(b => b.classList.remove('active'));
  document.getElementById('section-'+name)?.classList.add('visible');
  document.getElementById('r-'+name)?.classList.add('active');
  activeSection = name;
  if (name==='jobs')  loadJobs();
  if (name==='media') loadMedia();
  if (name==='logs')  loadLogs();
}

// ── Preset selection ───────────────────────────────────────────────────────
function selectPreset(p, el) {
  activePreset = p;
  document.querySelectorAll('.preset-card').forEach(c => c.classList.remove('sel'));
  el.classList.add('sel');
  // sync dropdowns
  ['proc-preset','ren-preset','pipe-fpreset','pipe-rpreset'].forEach(id => {
    const el = document.getElementById(id);
    if (el) [...el.options].forEach(o => { if (o.value===p) el.value=p; });
  });
}

// ── Audio sync ─────────────────────────────────────────────────────────────
function syncAudio() {
  activeAudio = document.getElementById('audio-select').value;
  activeMute  = document.getElementById('mute-toggle').checked;
}

async function loadAudioList() {
  try {
    const r = await fetch('/audio');
    const d = await r.json();
    const sel = document.getElementById('audio-select');
    const existing = sel.innerHTML;
    const opts = (d.audio||[]).map(a => \`<option value="\${a.path}">\${a.name}</option>\`).join('');
    sel.innerHTML = '<option value="">— no audio —</option>' + opts;
  } catch {}
}

// ── Status refresh ─────────────────────────────────────────────────────────
async function refreshStatus() {
  try {
    const r = await fetch('/status');
    const d = await r.json();
    const dbDot = document.getElementById('db-dot');
    const remDot = document.getElementById('rem-dot');
    if (d.ok) { dbDot.className='dot dot-ok'; document.getElementById('db-lbl').textContent='DB'; }
    else { dbDot.className='dot dot-err'; document.getElementById('db-lbl').textContent='DB ERR'; }
    if (d.remotion==='connected') { remDot.className='dot dot-ok'; document.getElementById('rem-lbl').textContent='Remotion'; }
    else { remDot.className='dot dot-warn'; document.getElementById('rem-lbl').textContent='Remotion'; }
    const s = d.stats || {};
    document.getElementById('running-n').textContent = s.running||0;
    document.getElementById('done-n').textContent    = s.done||0;
    document.getElementById('fail-n').textContent    = s.failed||0;
  } catch { document.getElementById('db-dot').className='dot dot-err'; }
}

// ── Toast helper ───────────────────────────────────────────────────────────
function toast(id, type, msg) {
  const el = document.getElementById(id);
  if (!el) return;
  el.className = 'toast '+type;
  el.textContent = msg;
  setTimeout(() => { el.style.display='none'; }, 8000);
}

// ── Quick actions ──────────────────────────────────────────────────────────
async function quickProcess(preset) {
  try {
    const r = await fetch(\`/process/quick/\${preset}\`, { method:'POST' });
    const d = await r.json();
    if (d.jobId) toast('toast-quick','ok',\`✓ Process job started — \${d.jobId.slice(0,8)}…\`);
    else toast('toast-quick','err','✗ '+d.error);
    refreshStatus();
  } catch(e) { toast('toast-quick','err','✗ '+e.message); }
}

async function quickRender(preset) {
  try {
    const r = await fetch(\`/render/quick/\${preset}\`, { method:'POST' });
    const d = await r.json();
    if (d.jobId) toast('toast-qrender','ok',\`✓ Render job started — \${d.jobId.slice(0,8)}…\`);
    else toast('toast-qrender','err','✗ '+d.error);
    refreshStatus();
  } catch(e) { toast('toast-qrender','err','✗ '+e.message); }
}

// ── Organise ───────────────────────────────────────────────────────────────
async function doOrganise() {
  const body = {
    srcPath:     document.getElementById('org-src').value.trim(),
    outputDir:   document.getElementById('org-out').value.trim() || undefined,
    mediaType:   document.getElementById('org-type').value,
    granularity: document.getElementById('org-gran').value,
    dryRun:      document.getElementById('org-dry').checked,
  };
  try {
    const r = await fetch('/organise', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body) });
    const d = await r.json();
    if (d.jobId) toast('toast-org','ok',\`✓ Organise started (jobId: \${d.jobId.slice(0,8)}…)\`);
    else toast('toast-org','err','✗ '+(d.error||JSON.stringify(d)));
    refreshStatus();
  } catch(e) { toast('toast-org','err','✗ '+e.message); }
}

async function doScan() {
  const body = { srcPath: document.getElementById('scan-src').value.trim(), mediaType: document.getElementById('scan-type').value };
  try {
    const r = await fetch('/organise/scan', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body) });
    const d = await r.json();
    toast('toast-scan','ok',\`Scanned: \${d.totalFiles} files · \${d.totalHuman} · 🖼 \${d.byType?.image||0} images · 🎬 \${d.byType?.video||0} videos\`);
  } catch(e) { toast('toast-scan','err','✗ '+e.message); }
}

// ── Process ────────────────────────────────────────────────────────────────
async function doProcess() {
  const body = {
    srcPath:   document.getElementById('proc-src').value.trim(),
    preset:    document.getElementById('proc-preset').value,
    threads:   parseInt(document.getElementById('thread-slider').value),
    audioPath: document.getElementById('proc-audio').value.trim() || null,
    muted:     document.getElementById('proc-mute').checked,
  };
  try {
    const r = await fetch('/process', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body) });
    const d = await r.json();
    if (d.jobId) toast('toast-proc','ok',\`✓ Process job started — \${d.jobId.slice(0,8)}…\`);
    else toast('toast-proc','err','✗ '+d.error);
    refreshStatus();
  } catch(e) { toast('toast-proc','err','✗ '+e.message); }
}

// ── Render ─────────────────────────────────────────────────────────────────
async function doRender() {
  const body = {
    srcPath:   document.getElementById('ren-src').value.trim(),
    preset:    document.getElementById('ren-preset').value,
    audioPath: document.getElementById('ren-audio').value.trim() || activeAudio || null,
    muted:     document.getElementById('ren-mute').checked || activeMute,
    options:   { transition: document.getElementById('ren-transition').value },
  };
  try {
    const r = await fetch('/render', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body) });
    const d = await r.json();
    if (d.jobId) toast('toast-ren','ok',\`✓ Render job started — \${d.jobId.slice(0,8)}…\`);
    else toast('toast-ren','err','✗ '+d.error);
    refreshStatus();
  } catch(e) { toast('toast-ren','err','✗ '+e.message); }
}

// ── Pipeline ───────────────────────────────────────────────────────────────
function togglePipeStep(step) {
  const on = document.getElementById('pipe-'+step.slice(0,3)).checked;
  document.getElementById('ps-'+step).classList.toggle('on', on);
}

async function doPipeline() {
  const body = {
    srcPath:       document.getElementById('pipe-src').value.trim(),
    granularity:   document.getElementById('pipe-gran').value,
    ffmpegPreset:  document.getElementById('pipe-fpreset').value,
    remotionPreset:document.getElementById('pipe-rpreset').value,
    audioPath:     document.getElementById('pipe-audio').value.trim() || null,
    dryRun:        document.getElementById('pipe-dry').checked,
    muted:         document.getElementById('pipe-mute').checked,
    skipOrganise:  !document.getElementById('pipe-org').checked,
    skipProcess:   !document.getElementById('pipe-proc').checked,
    skipRender:    !document.getElementById('pipe-ren').checked,
  };
  try {
    const r = await fetch('/pipeline', { method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body) });
    const d = await r.json();
    if (d.ok) toast('toast-pipe','ok',\`✓ Pipeline launched — \${d.pipeline.length} step(s) queued\`);
    else toast('toast-pipe','err','✗ '+(d.error||'Pipeline error'));
    refreshStatus();
  } catch(e) { toast('toast-pipe','err','✗ '+e.message); }
}

// ── Jobs ───────────────────────────────────────────────────────────────────
let _jf = '';
function filterJobs(type) {
  _jf = type;
  ['all','process','render','organise'].forEach(t => {
    document.getElementById('jf-'+t)?.classList.toggle('active', (t==='all'&&!type)||(t===type));
  });
  loadJobs();
}

async function loadJobs() {
  const wrap = document.getElementById('jobs-wrap');
  wrap.innerHTML = '<div class="empty">Loading…</div>';
  try {
    const url = '/jobs?limit=100' + (_jf ? '&type='+_jf : '');
    const d = await (await fetch(url)).json();
    if (!d.jobs?.length) { wrap.innerHTML = '<div class="empty">No jobs found</div>'; return; }
    const rows = d.jobs.map(j => {
      const dur = j.finished_at && j.started_at
        ? Math.round((new Date(j.finished_at)-new Date(j.started_at))/1000)+'s' : '—';
      return \`<tr onclick="openJob('\${j.id}')">
        <td style="color:var(--dim)">\${j.id.slice(0,8)}…</td>
        <td><span class="jbadge \${j.status}">\${j.status}</span></td>
        <td><span class="type-badge type-\${j.job_type}">\${j.job_type}</span></td>
        <td>\${j.preset}</td>
        <td style="color:var(--muted);max-width:160px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">\${j.src_path}</td>
        <td>\${j.total_files||0}</td>
        <td>\${j.size_mb||0}mb</td>
        <td style="color:var(--dim)">\${dur}</td>
      </tr>\`;
    }).join('');
    wrap.innerHTML = \`<table class="jtable">
      <thead><tr><th>ID</th><th>Status</th><th>Type</th><th>Preset</th><th>Path</th><th>Files</th><th>Size</th><th>Time</th></tr></thead>
      <tbody>\${rows}</tbody>
    </table>\`;
  } catch(e) { wrap.innerHTML = \`<div class="empty" style="color:var(--ember2)">Error: \${e.message}</div>\`; }
}

async function openJob(id) {
  const overlay = document.getElementById('overlay');
  const body    = document.getElementById('drawer-body');
  overlay.classList.add('open');
  body.innerHTML = '<div class="empty">Loading…</div>';
  try {
    const d = await (await fetch('/jobs/'+id)).json();
    const j = d.job;
    const dur = j.finished_at && j.started_at ? Math.round((new Date(j.finished_at)-new Date(j.started_at))/1000)+'s' : 'running';
    const logRows = (d.logs||[]).map(l => \`<div class="log-row">
      <span class="log-lvl lvl-\${l.level}">\${l.level}</span>
      <span class="log-msg">\${l.message}</span>
      <span class="log-time">\${new Date(l.created_at).toLocaleTimeString()}</span>
    </div>\`).join('');
    body.innerHTML = \`
      <div style="font-size:.62rem;font-family:var(--mono);color:var(--muted);margin-bottom:.4rem">\${j.id}</div>
      <div style="display:flex;align-items:center;gap:.75rem;margin-bottom:.75rem">
        <div style="font-family:var(--display);font-size:1.5rem">\${j.folder_name||j.src_path}</div>
        <span class="jbadge \${j.status}">\${j.status}</span>
        <span class="type-badge type-\${j.job_type}">\${j.job_type}</span>
      </div>
      <div class="dgrid">
        <div class="dcell"><div class="dl">Preset</div><div class="dv">\${j.preset}</div></div>
        <div class="dcell"><div class="dl">Duration</div><div class="dv">\${dur}</div></div>
        <div class="dcell"><div class="dl">Files</div><div class="dv">\${j.total_files||0}</div></div>
        <div class="dcell"><div class="dl">Size</div><div class="dv">\${j.size_mb||0} MB</div></div>
        <div class="dcell"><div class="dl">Video sec</div><div class="dv">\${j.duration_sec||0}s</div></div>
        <div class="dcell"><div class="dl">Threads</div><div class="dv">\${j.threads||'—'}</div></div>
      </div>
      \${j.output_path?\`<div style="background:rgba(0,229,160,.05);border:1px solid rgba(0,229,160,.15);border-radius:6px;padding:.5rem .75rem;font-family:var(--mono);font-size:.68rem;color:var(--mint);margin-bottom:.75rem">📦 \${j.output_path}</div>\`:''}
      \${j.error_msg?\`<div style="background:rgba(255,69,0,.05);border:1px solid rgba(255,69,0,.15);border-radius:6px;padding:.5rem .75rem;font-family:var(--mono);font-size:.68rem;color:var(--ember2);margin-bottom:.75rem">✗ \${j.error_msg}</div>\`:''}
      <div style="font-family:var(--mono);font-size:.6rem;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin-bottom:.4rem">Logs (\${d.logs?.length||0})</div>
      <div class="log-wrap">\${logRows||'<div style="padding:1rem;text-align:center;color:var(--muted);font-size:.72rem">No logs</div>'}</div>
    \`;
  } catch(e) { body.innerHTML = \`<div class="empty" style="color:var(--ember2)">Error: \${e.message}</div>\`; }
}

function closeDrawer(e) { if (e.target===document.getElementById('overlay')) forceCloseDrawer(); }
function forceCloseDrawer() { document.getElementById('overlay').classList.remove('open'); }

// ── Media ──────────────────────────────────────────────────────────────────
let _mf = '';
function filterMedia(type) {
  _mf = type;
  ['all','image','video','render'].forEach(t => {
    document.getElementById('mf-'+t)?.classList.toggle('active', (t==='all'&&!type)||(t===type));
  });
  loadMedia();
}

async function loadMedia() {
  const wrap = document.getElementById('media-wrap');
  wrap.innerHTML = '<div class="empty">Loading…</div>';
  try {
    const url = '/media?limit=200' + (_mf ? '&type='+_mf : '');
    const d = await (await fetch(url)).json();
    if (!d.media?.length) { wrap.innerHTML = '<div class="empty">No media tracked yet</div>'; return; }
    const rows = d.media.map(m => \`<tr>
      <td><span class="type-badge type-\${m.media_type==='render'?'render':m.media_type==='video'?'render':'organise'}">\${m.media_type}</span></td>
      <td style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">\${m.file_name||'—'}</td>
      <td style="color:var(--muted)">\${m.folder_name||'—'}</td>
      <td>\${m.size_bytes?(m.size_bytes/1024/1024).toFixed(1)+' MB':'—'}</td>
      <td style="color:var(--dim)">\${new Date(m.created_at).toLocaleString()}</td>
    </tr>\`).join('');
    wrap.innerHTML = \`<table class="jtable">
      <thead><tr><th>Type</th><th>File</th><th>Folder</th><th>Size</th><th>Created</th></tr></thead>
      <tbody>\${rows}</tbody>
    </table>\`;
  } catch(e) { wrap.innerHTML = \`<div class="empty" style="color:var(--ember2)">Error: \${e.message}</div>\`; }
}

// ── Error Logs ─────────────────────────────────────────────────────────────
async function loadLogs() {
  const wrap = document.getElementById('logs-wrap');
  wrap.innerHTML = '<div class="empty">Loading…</div>';
  try {
    const d = await (await fetch('/logs/errors?limit=100')).json();
    if (!d.errors?.length) { wrap.innerHTML = '<div class="empty" style="color:var(--mint)">✓ No errors logged</div>'; return; }
    const rows = d.errors.map(e => \`<tr>
      <td style="color:var(--muted)">\${new Date(e.created_at).toLocaleString()}</td>
      <td style="color:var(--dim)">\${e.job_id?.slice(0,8)||'—'}…</td>
      <td><span class="type-badge type-\${e.job_type||'scan'}">\${e.job_type||'—'}</span></td>
      <td style="color:var(--muted)">\${e.folder_name||'—'}</td>
      <td style="color:var(--ember2);max-width:280px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">\${e.message}</td>
    </tr>\`).join('');
    wrap.innerHTML = \`<table class="jtable">
      <thead><tr><th>Time</th><th>Job</th><th>Type</th><th>Folder</th><th>Message</th></tr></thead>
      <tbody>\${rows}</tbody>
    </table>\`;
  } catch(e) { wrap.innerHTML = \`<div class="empty" style="color:var(--ember2)">Error: \${e.message}</div>\`; }
}

// ── Clock + auto-refresh ───────────────────────────────────────────────────
function startAuto() {
  autoRefTick = setInterval(() => {
    refreshStatus();
    if (activeSection==='jobs')  loadJobs();
    if (activeSection==='media') loadMedia();
  }, 6000);
}
document.getElementById('auto-ref').addEventListener('change', function() {
  if (this.checked) startAuto(); else clearInterval(autoRefTick);
});
setInterval(() => { document.getElementById('ft-time').textContent = new Date().toLocaleTimeString(); }, 1000);

// ── Init ───────────────────────────────────────────────────────────────────
refreshStatus();
loadAudioList();
startAuto();
document.getElementById('ft-time').textContent = new Date().toLocaleTimeString();
</script>
</body>
</html>`;
  return c.html(html);
});

// Doc endpoint
app.get('/doc', (c) => c.json({
  service: 'Hybrid Media Studio',
  version: '2.0.0',
  gui: 'GET /',
  endpoints: {
    status:   'GET /status',
    audio:    'GET /audio',
    presets:  'GET /presets',
    organise: 'POST /organise — {srcPath, outputDir?, mediaType, granularity, dryRun}',
    scan:     'POST /organise/scan — {srcPath, mediaType}',
    process:  'POST /process — {srcPath, preset, threads, audioPath?, muted}',
    quickP:   'POST /process/quick/:preset',
    render:   'POST /render — {srcPath, preset, audioPath?, muted, options?}',
    quickR:   'POST /render/quick/:preset',
    pipeline: 'POST /pipeline — {srcPath, granularity, ffmpegPreset, remotionPreset, audioPath?, muted, dryRun, skipOrganise, skipProcess, skipRender}',
    jobs:     'GET /jobs?status=&type=&limit=&offset=',
    job:      'GET /jobs/:id',
    logs:     'GET /logs?level=&job_id=&limit=',
    errors:   'GET /logs/errors',
    media:    'GET /media?job_id=&type=&limit=',
    summary:  'GET /summary',
  }
}));

app.route('/', api);
app.notFound((c) => c.json({ error: 'Not found', hint: 'Visit / for GUI, /doc for API reference' }, 404));
app.onError((err, c) => {
  console.error('[UNHANDLED]', err.message);
  return c.json({ error: 'Internal server error', message: err.message }, 500);
});

const PORT = parseInt(process.env.PORT || '3000');

async function start() {
  let retries = 20;
  while (retries > 0) {
    try { await pool.query('SELECT 1'); console.log('[DB] Connected'); break; }
    catch { retries--; console.log(\`[DB] Waiting… (\${retries} retries)\`); await new Promise(r => setTimeout(r, 2000)); }
  }
  if (retries === 0) { console.error('[DB] Could not connect. Exiting.'); process.exit(1); }

  serve({ fetch: app.fetch, port: PORT }, (info) => {
    console.log(\`[HMS] GUI         → http://0.0.0.0:\${info.port}/\`);
    console.log(\`[HMS] API docs    → http://0.0.0.0:\${info.port}/doc\`);
    console.log(\`[HMS] Status      → http://0.0.0.0:\${info.port}/status\`);
  });
}

start();
INDEXJS
ok "index.js (GUI) written"

# ============================================================
# Smoke test script
# ============================================================
section "Smoke tests"
cat > "$STACK_DIR/scripts/smoke-test.sh" << 'SMOKE'
#!/bin/bash
# Hybrid Media Studio — Smoke Test
set -euo pipefail
BASE="${1:-http://localhost:3000}"
PASS=0; FAIL=0
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

chk() {
  local name="$1" body="$2" expect="$3"
  if echo "$body" | grep -q "$expect"; then echo -e "${GREEN}✓${NC} $name"; ((PASS++));
  else echo -e "${RED}✗${NC} $name — expected '$expect'"; echo "  got: ${body:0:200}"; ((FAIL++)); fi
}

echo -e "${CYAN}═══ HMS Smoke Tests → $BASE ═══${NC}"

# Wait for service
for i in $(seq 1 40); do
  [ "$(curl -sf -o/dev/null -w '%{http_code}' $BASE/status 2>/dev/null||echo 0)" = "200" ] && break
  [ $i = 40 ] && { echo "Timed out waiting"; exit 1; }
  sleep 2
done

chk "GET / HTML"           "$(curl -sf $BASE/)"              "HYBRID"
chk "GET /status ok"       "$(curl -sf $BASE/status)"        '"ok":true'
chk "GET /status remotion" "$(curl -sf $BASE/status)"        'remotion'
chk "GET /doc"             "$(curl -sf $BASE/doc)"           '"service"'
chk "GET /presets"         "$(curl -sf $BASE/presets)"       '"ffmpeg"'
chk "GET /audio"           "$(curl -sf $BASE/audio)"         '"audio"'
chk "GET /jobs"            "$(curl -sf $BASE/jobs)"          '"jobs"'
chk "GET /media"           "$(curl -sf $BASE/media)"         '"media"'
chk "GET /logs/errors"     "$(curl -sf $BASE/logs/errors)"   '"errors"'
chk "GET /summary"         "$(curl -sf $BASE/summary)"       '"jobs"'
chk "GET /notfound 404"    "$(curl -sf $BASE/xyzzy 2>/dev/null || echo 'Not found')" "Not found"

# Organise scan
SCAN=$(curl -sf -X POST $BASE/organise/scan -H 'Content-Type: application/json' -d '{"srcPath":"/data/media","mediaType":"both"}')
chk "POST /organise/scan"    "$SCAN"  '"totalFiles"'

# Process quick
PQ=$(curl -sf -X POST $BASE/process/quick/standard)
chk "POST /process/quick/standard" "$PQ" '"jobId"'

# Render quick
RQ=$(curl -sf -X POST $BASE/render/quick/cineslide)
chk "POST /render/quick/cineslide" "$RQ" '"jobId"'

# Pipeline
PP=$(curl -sf -X POST $BASE/pipeline -H 'Content-Type: application/json' \
  -d '{"srcPath":"/data/media","skipOrganise":false,"skipProcess":false,"skipRender":false,"dryRun":true}')
chk "POST /pipeline"  "$PP" '"pipeline"'

# Bad preset
BP=$(curl -sf -X POST $BASE/process/quick/ultramax 2>/dev/null || echo '{"error":"x"}')
chk "Bad preset error" "$BP" '"error"'

echo ""
echo -e "${CYAN}Results: ${GREEN}${PASS} passed${NC} | ${RED}${FAIL} failed${NC}${CYAN}${NC}"
[ $FAIL -gt 0 ] && exit 1; exit 0
SMOKE
chmod +x "$STACK_DIR/scripts/smoke-test.sh"
ok "smoke-test.sh written"

# ============================================================
# Validate files
# ============================================================
section "Validating generated files"
REQUIRED=(
  "$STACK_DIR/init.sql"
  "$STACK_DIR/docker-compose.yml"
  "$STACK_DIR/api/Dockerfile"
  "$STACK_DIR/api/package.json"
  "$STACK_DIR/api/src/index.js"
  "$STACK_DIR/api/src/routes.js"
  "$STACK_DIR/api/src/db.js"
  "$STACK_DIR/api/src/utils.js"
  "$STACK_DIR/api/src/organiser.js"
  "$STACK_DIR/api/src/processor.js"
  "$STACK_DIR/api/src/renderer.js"
  "$STACK_DIR/remotion-worker/Dockerfile"
  "$STACK_DIR/remotion-worker/package.json"
  "$STACK_DIR/remotion-worker/src/server.js"
  "$STACK_DIR/scripts/smoke-test.sh"
)
for f in "${REQUIRED[@]}"; do
  [ -f "$f" ] && ok "$(basename $f)" || { echo -e "${RED}  ✗ MISSING: $f${NC}"; }
done

# Print tree
echo ""
section "Stack layout"
if command -v tree >/dev/null 2>&1; then tree "$STACK_DIR";
else find "$STACK_DIR" -type f | sort | sed "s|$STACK_DIR/||" | while read -r f; do echo "  $f"; done; fi

# ============================================================
# Optionally build + run
# ============================================================
if [ "$RUN_STACK" = true ]; then
  section "Building and starting stack"
  cd "$STACK_DIR"
  docker compose down --remove-orphans 2>/dev/null || true
  docker compose build --no-cache
  docker compose up -d
  ok "Stack started!"
  log "Waiting for services…"
  sleep 10
  docker compose ps
fi

if [ "$RUN_TESTS" = true ]; then
  section "Running smoke tests"
  sleep 5
  bash "$STACK_DIR/scripts/smoke-test.sh" "http://localhost:3000"
fi

# ============================================================
# Final summary
# ============================================================
echo ""
echo -e "${GREEN}████████████████████████████████████████████████████████████████${NC}"
echo -e "${GREEN}  ✓  HYBRID MEDIA STUDIO — stack created successfully!${NC}"
echo -e "${GREEN}████████████████████████████████████████████████████████████████${NC}"
echo ""
echo "  Stack dir : $STACK_DIR"
echo ""
echo "  ── Start ────────────────────────────────────────────────────"
echo -e "  ${CYAN}cd $STACK_DIR && docker compose up -d${NC}"
echo ""
echo "  ── Or with flags ────────────────────────────────────────────"
echo -e "  ${CYAN}bash setup_hybrid_media_studio.sh --run         # build+start${NC}"
echo -e "  ${CYAN}bash setup_hybrid_media_studio.sh --run --test  # build+start+test${NC}"
echo ""
echo "  ── Endpoints ────────────────────────────────────────────────"
echo "    GUI (dark studio)  →  http://localhost:3000/"
echo "    API reference      →  http://localhost:3000/doc"
echo "    System status      →  http://localhost:3000/status"
echo "    Remotion worker    →  http://localhost:3100/health"
echo ""
echo "  ── Quick fire ───────────────────────────────────────────────"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/quick/cinematic${NC}"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/render/quick/cineslide${NC}"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/render/quick/reel${NC}"
echo ""
echo "  ── Full pipeline ────────────────────────────────────────────"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/pipeline \\${NC}"
echo -e "  ${CYAN}  -H 'Content-Type: application/json' \\${NC}"
echo -e "  ${CYAN}  -d '{\"srcPath\":\"/data/media\",\"remotionPreset\":\"cineslide\",${NC}"
echo -e "  ${CYAN}       \"audioPath\":\"/data/audio/track.mp3\",\"muted\":false}'${NC}"
echo ""
echo "  ── Put media + audio here ───────────────────────────────────"
echo "    Images / videos  →  docker volume: shared_media"
echo "    Audio tracks     →  docker volume: shared_audio"
echo "    FFmpeg output    →  docker volume: shared_output"
echo "    Remotion renders →  docker volume: shared_renders"
echo ""