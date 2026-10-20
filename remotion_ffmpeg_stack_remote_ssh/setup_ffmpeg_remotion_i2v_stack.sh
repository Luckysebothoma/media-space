#!/bin/bash
# ============================================================
# setup_i2v_stack.sh — Image→Video Microservice v4 — Full Stack
#
# Consolidates i2v.sh (Ken Burns / ratio / transition / motion
# reel generator) and setup_ffmpeg_v3.sh (Dockerized Node/Postgres
# batch processor) into ONE Node.js microservice with:
#
#   - Folder (grouped/slideshow) OR single-image conversion
#   - All i2v.sh knobs (ratio, resolution, transition, motion,
#     fps, quality, codec, min/max image time, burst-gap) exposed
#     as .env defaults AND per-request overrides
#   - Remote SOURCE locations over SSH (sshfs) or SMB (cifs),
#     configured/stored via API + Postgres (secrets kept on disk,
#     never in the DB)
#   - prom-client /metrics endpoint for Prometheus scraping
#
# Run:
#   bash setup_i2v_stack.sh              # generate files only
#   bash setup_i2v_stack.sh --run        # generate + build + up
#   bash setup_i2v_stack.sh --run --test # + smoke test
# ============================================================

set -euo pipefail

STACK_DIR="./i2v-microservice"
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
mkdir -p "$STACK_DIR/secrets/ssh-keys"
mkdir -p "$STACK_DIR/secrets/smb-creds"
chmod 700 "$STACK_DIR/secrets/ssh-keys" "$STACK_DIR/secrets/smb-creds"
ok "Directories created under $STACK_DIR"

# ============================================================
# .env.example — every i2v.sh knob becomes a default here
# ============================================================
log "Writing .env.example..."
cat > "$STACK_DIR/.env.example" << 'ENVEOF'
# ============================================================
# i2v-microservice — environment defaults
# Copy to .env and adjust. All values here are DEFAULTS that
# can still be overridden per-request in the JSON body of
# POST /process and POST /process/singles.
# ============================================================

# ---- App / DB ----
PORT=3000
NODE_ENV=production
PGHOST=db
PGPORT=5432
PGDATABASE=i2v_db
PGUSER=i2v
PGPASSWORD=change_me_i2v_pass

# ---- Paths (inside the app container) ----
DATA_ROOT=/data/media
OUTPUT_BASE=/data/archives
LOG_DIR=/data/logs
MOUNT_ROOT=/data/remote
SSH_KEY_DIR=/data/secrets/ssh-keys
SMB_CRED_DIR=/data/secrets/smb-creds

# ---- Default render settings (from i2v.sh) ----
DEFAULT_ENGINE=ffmpeg          # ffmpeg | remotion
DEFAULT_PRESET=standard        # see /presets, or set DEFAULT_RATIO instead
DEFAULT_RATIO=9:16              # 9:16 | 16:9 | 1:1 | 4:5
DEFAULT_FPS=30
DEFAULT_QUALITY=high            # low | medium | high
DEFAULT_CODEC=h264               # h264 | h265 | av1 (h264 supported out of box)
DEFAULT_TRANSITION=random        # fade | zoom | slide | random | none
DEFAULT_TRANSITION_DURATION=1.0
DEFAULT_MOTION=random            # kenburns | zoom | pan | random | none
DEFAULT_MIN_IMAGE=5              # seconds, grouped mode
DEFAULT_MAX_IMAGE=30             # seconds, grouped mode
DEFAULT_BURST_GAP=4              # seconds, burst grouping (reserved)
DEFAULT_THREADS=1

# ---- Singles mode (one clip per image) ----
SINGLE_DURATION=30
KEN_BURNS_MAX_ZOOM=1.15
KEN_BURNS_ZOOM_STEP=0.0006

# ---- Prometheus ----
METRICS_ENABLED=true
METRICS_PREFIX=i2v_

# ---- Remote mount behaviour ----
# Container needs CAP_SYS_ADMIN + /dev/fuse (already set in docker-compose.yml)
REMOTE_MOUNT_TIMEOUT_MS=15000
ENVEOF
ok ".env.example written"

cp "$STACK_DIR/.env.example" "$STACK_DIR/.env"
ok ".env created (defaults — edit before production use, especially PGPASSWORD)"

# ============================================================
# init.sql
# ============================================================
log "Writing init.sql..."
cat > "$STACK_DIR/init.sql" << 'INITSQL'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS jobs (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    status        TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','running','done','failed','skipped')),
    mode          TEXT NOT NULL DEFAULT 'grouped'
                    CHECK (mode IN ('grouped','singles')),
    engine        TEXT NOT NULL DEFAULT 'ffmpeg',
    preset        TEXT,
    ratio         TEXT,
    transition    TEXT,
    motion        TEXT,
    fps           INT  DEFAULT 30,
    threads       INT  NOT NULL DEFAULT 1,
    src_path      TEXT NOT NULL,
    remote_id     UUID,
    output_path   TEXT,
    folder_name   TEXT,
    total_images  INT  DEFAULT 0,
    total_outputs INT  DEFAULT 0,
    duration_sec  INT  DEFAULT 0,
    size_mb       NUMERIC(10,2) DEFAULT 0,
    started_at    TIMESTAMPTZ,
    finished_at   TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    error_msg     TEXT
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

-- Remote source locations (SSH or SMB). Credentials are NEVER stored
-- here in plaintext — secret_ref points to a file under
-- SSH_KEY_DIR/SMB_CRED_DIR on the app container's filesystem.
CREATE TABLE IF NOT EXISTS remotes (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name         TEXT UNIQUE NOT NULL,
    protocol     TEXT NOT NULL CHECK (protocol IN ('ssh','smb')),
    host         TEXT NOT NULL,
    port         INT  NOT NULL DEFAULT 22,
    username     TEXT,
    auth_type    TEXT NOT NULL DEFAULT 'key' CHECK (auth_type IN ('key','password')),
    secret_ref   TEXT,             -- filename under SSH_KEY_DIR / SMB_CRED_DIR
    remote_path  TEXT NOT NULL,    -- e.g. /export/photos  or  sharename/subdir
    domain       TEXT,             -- SMB only
    mount_point  TEXT,             -- computed: MOUNT_ROOT/<name>
    status       TEXT NOT NULL DEFAULT 'unmounted'
                    CHECK (status IN ('unmounted','mounted','error')),
    last_error   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_jobs_status      ON jobs(status);
CREATE INDEX IF NOT EXISTS idx_jobs_created_at  ON jobs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_job_id    ON events(job_id);
CREATE INDEX IF NOT EXISTS idx_logs_job_id      ON logs(job_id);
CREATE INDEX IF NOT EXISTS idx_logs_level       ON logs(level);
CREATE INDEX IF NOT EXISTS idx_media_job_id     ON media(job_id);
CREATE INDEX IF NOT EXISTS idx_remotes_status   ON remotes(status);

CREATE OR REPLACE VIEW global_error_logs AS
SELECT l.id, l.job_id, l.level, l.message, l.context, l.created_at,
       j.src_path, j.folder_name, j.preset
FROM logs l
LEFT JOIN jobs j ON j.id = l.job_id
WHERE l.level = 'error'
ORDER BY l.created_at DESC;
INITSQL
ok "init.sql written (adds remotes table)"

# ============================================================
# docker-compose.yml
# ============================================================
log "Writing docker-compose.yml..."
cat > "$STACK_DIR/docker-compose.yml" << 'COMPOSE'
services:

  db:
    image: postgres:16-alpine
    container_name: i2v_db
    restart: unless-stopped
    env_file: .env
    environment:
      POSTGRES_DB:       ${PGDATABASE}
      POSTGRES_USER:     ${PGUSER}
      POSTGRES_PASSWORD: ${PGPASSWORD}
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${PGUSER} -d ${PGDATABASE}"]
      interval: 5s
      timeout: 5s
      retries: 10

  app:
    build:
      context: ./app
      dockerfile: Dockerfile
    container_name: i2v_app
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    env_file: .env
    environment:
      PGHOST: db
    # Remote SSHFS/CIFS mounts require elevated privileges inside the
    # container. Scope is deliberately limited to SYS_ADMIN + /dev/fuse
    # rather than full --privileged.
    cap_add:
      - SYS_ADMIN
    devices:
      - /dev/fuse
    security_opt:
      - apparmor:unconfined
    volumes:
      - ./data/media:/data/media
      - ./data/archives:/data/archives
      - ./data/logs:/data/logs
      - ./data/remote:/data/remote:shared
      - ./secrets/ssh-keys:/data/secrets/ssh-keys
      - ./secrets/smb-creds:/data/secrets/smb-creds
    ports:
      - "3019:3000"
    healthcheck:
      test: ["CMD-SHELL", "node -e \"fetch('http://localhost:3000/status').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
      interval: 10s
      timeout: 5s
      retries: 5

  # Optional Prometheus scraper — enable with:
  #   docker compose --profile monitoring up -d
  prometheus:
    image: prom/prometheus:latest
    container_name: i2v_prometheus
    profiles: ["monitoring"]
    restart: unless-stopped
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prom_data:/prometheus
    ports:
      - "9090:9090"
    depends_on:
      - app

volumes:
  pg_data:
  prom_data:
COMPOSE
ok "docker-compose.yml written (app has SSHFS/CIFS capability, optional prometheus profile)"

# ============================================================
# prometheus.yml (used only if --profile monitoring is enabled)
# ============================================================
log "Writing prometheus.yml..."
cat > "$STACK_DIR/prometheus.yml" << 'PROMEOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'i2v-app'
    static_configs:
      - targets: ['app:3000']
    metrics_path: /metrics
PROMEOF
ok "prometheus.yml written"

# ============================================================
# app/Dockerfile
# ============================================================
log "Writing app/Dockerfile..."
cat > "$STACK_DIR/app/Dockerfile" << 'DOCKERFILE'
FROM node:22-slim

# ffmpeg          -> rendering
# openssh-client   -> ssh transport
# sshfs            -> mount remote SSH sources
# sshpass          -> password-based sshfs (key auth preferred)
# cifs-utils       -> mount SMB/CIFS sources
# fuse3            -> user-space mount support for sshfs
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    openssh-client \
    sshfs \
    sshpass \
    cifs-utils \
    fuse3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY src ./src

RUN mkdir -p /data/media /data/archives /data/logs /data/remote \
             /data/secrets/ssh-keys /data/secrets/smb-creds

EXPOSE 3000

# Runs as root: required for mount/mount.cifs and sshfs with allow_other.
CMD ["node", "src/index.js"]
DOCKERFILE
ok "Dockerfile written (ffmpeg + sshfs + cifs-utils + sshpass)"

# ============================================================
# app/package.json
# ============================================================
log "Writing app/package.json..."
cat > "$STACK_DIR/app/package.json" << 'PKG'
{
  "name": "i2v-microservice",
  "version": "4.0.0",
  "type": "module",
  "scripts": {
    "start": "node src/index.js",
    "dev":   "node --watch src/index.js"
  },
  "dependencies": {
    "@hono/node-server": "^1.13.7",
    "hono":              "^4.6.3",
    "pg":                "^8.13.1",
    "prom-client":       "^15.1.3"
  }
}
PKG
ok "package.json written (adds prom-client)"

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
  database: process.env.PGDATABASE || 'i2v_db',
  user:     process.env.PGUSER     || 'i2v',
  password: process.env.PGPASSWORD || 'i2v_pass',
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
# app/src/metrics.js — prom-client wiring
# ============================================================
log "Writing app/src/metrics.js..."
cat > "$STACK_DIR/app/src/metrics.js" << 'METRICSJS'
import client from 'prom-client';

const PREFIX = process.env.METRICS_PREFIX || 'i2v_';
export const register = new client.Registry();

client.collectDefaultMetrics({ register, prefix: PREFIX });

export const jobsStartedTotal = new client.Counter({
  name: `${PREFIX}jobs_started_total`,
  help: 'Total number of conversion jobs started',
  labelNames: ['mode', 'preset', 'engine'],
  registers: [register],
});

export const jobsCompletedTotal = new client.Counter({
  name: `${PREFIX}jobs_completed_total`,
  help: 'Total number of conversion jobs completed successfully',
  labelNames: ['mode', 'preset', 'engine'],
  registers: [register],
});

export const jobsFailedTotal = new client.Counter({
  name: `${PREFIX}jobs_failed_total`,
  help: 'Total number of conversion jobs that failed',
  labelNames: ['mode', 'preset', 'engine'],
  registers: [register],
});

export const imagesProcessedTotal = new client.Counter({
  name: `${PREFIX}images_processed_total`,
  help: 'Total number of source images processed',
  labelNames: ['mode'],
  registers: [register],
});

export const renderDurationSeconds = new client.Histogram({
  name: `${PREFIX}render_duration_seconds`,
  help: 'Wall-clock time spent inside ffmpeg per output clip',
  labelNames: ['mode', 'preset'],
  buckets: [1, 5, 15, 30, 60, 120, 300, 600, 1200],
  registers: [register],
});

export const outputSizeMb = new client.Histogram({
  name: `${PREFIX}output_size_mb`,
  help: 'Size in MB of rendered output files',
  labelNames: ['mode', 'preset'],
  buckets: [1, 5, 10, 25, 50, 100, 250, 500],
  registers: [register],
});

export const remotesMountedGauge = new client.Gauge({
  name: `${PREFIX}remotes_mounted`,
  help: 'Number of remote sources currently mounted',
  registers: [register],
});

export const remoteMountFailuresTotal = new client.Counter({
  name: `${PREFIX}remote_mount_failures_total`,
  help: 'Total number of failed remote mount attempts',
  labelNames: ['protocol'],
  registers: [register],
});
METRICSJS
ok "metrics.js written"

# ============================================================
# app/src/utils.js — presets, ratios, transitions, motion (i2v.sh logic)
# ============================================================
log "Writing app/src/utils.js..."
cat > "$STACK_DIR/app/src/utils.js" << 'UTILSJS'
import { spawn } from 'child_process';
import fs from 'fs/promises';
import path from 'path';

// ── Preset registry ─────────────────────────────────────────────────────
// Each preset carries the render target (width/height) plus the encode
// ladder (crf/bitrate/maxrate/bufsize). maxrate+bufsize (VBV) are mandatory
// on every encode — without them static-image slideshows can spike far
// above target bitrate and produce corrupt/green frames.
export const PRESETS = {
  standard:            { width: 1920, height: 1080, crf: 23, bitrate: 5000,  maxrate: 7500,  bufsize: 15000, aspectLabel: '16:9', category: 'desktop', description: 'Full HD 1080p — balanced' },
  high:                { width: 1920, height: 1080, crf: 18, bitrate: 8000,  maxrate: 12000, bufsize: 24000, aspectLabel: '16:9', category: 'desktop', description: 'Full HD 1080p — high quality' },
  '4k':                { width: 3840, height: 2160, crf: 20, bitrate: 15000, maxrate: 22500, bufsize: 45000, aspectLabel: '16:9', category: 'desktop', description: 'UHD 4K 2160p' },
  cinematic:           { width: 4096, height: 2160, crf: 18, bitrate: 20000, maxrate: 30000, bufsize: 60000, aspectLabel: '17:9', category: 'desktop', description: 'DCI 4K cinema/archive master' },
  'mobile-hd':         { width: 1080, height: 1920, crf: 23, bitrate: 4000,  maxrate: 6000,  bufsize: 12000, aspectLabel: '9:16', category: 'mobile',  description: 'Reels / TikTok / Shorts' },
  'mobile-4k':         { width: 2160, height: 3840, crf: 20, bitrate: 12000, maxrate: 18000, bufsize: 36000, aspectLabel: '9:16', category: 'mobile',  description: 'Vertical 4K' },
  'mobile-sd':         { width: 720,  height: 1280, crf: 26, bitrate: 2000,  maxrate: 3000,  bufsize: 6000,  aspectLabel: '9:16', category: 'mobile',  description: 'Lightweight vertical' },
  'mobile-landscape':  { width: 1280, height: 720,  crf: 24, bitrate: 2500,  maxrate: 4000,  bufsize: 8000,  aspectLabel: '16:9', category: 'mobile',  description: 'In-app / tablet' },
  'square-hd':         { width: 1080, height: 1080, crf: 23, bitrate: 3500,  maxrate: 5500,  bufsize: 11000, aspectLabel: '1:1',  category: 'social',  description: 'Instagram/Facebook feed' },
  'square-4k':         { width: 2160, height: 2160, crf: 20, bitrate: 10000, maxrate: 15000, bufsize: 30000, aspectLabel: '1:1',  category: 'social',  description: 'High-res square' },
  'portrait-social':   { width: 1080, height: 1350, crf: 23, bitrate: 3800,  maxrate: 5700,  bufsize: 11400, aspectLabel: '4:5',  category: 'social',  description: 'Instagram feed optimum' },
  'classic-hd':        { width: 1440, height: 1080, crf: 23, bitrate: 4000,  maxrate: 6000,  bufsize: 12000, aspectLabel: '4:3',  category: 'desktop', description: 'Presentations / legacy' },
  ultrawide:           { width: 2560, height: 1080, crf: 22, bitrate: 8000,  maxrate: 12000, bufsize: 24000, aspectLabel: '21:9', category: 'desktop', description: 'Ultrawide monitors' },
};

export const PRESET_ALIASES = {
  cinema: 'cinematic', '1080p': 'standard', '1080': 'standard', '4k-high': '4k',
  vertical: 'mobile-hd', reel: 'mobile-hd', reels: 'mobile-hd', tiktok: 'mobile-hd',
  shorts: 'mobile-hd', portrait: 'mobile-hd', landscape: 'mobile-landscape',
  square: 'square-hd', instagram: 'square-hd', feed: 'portrait-social',
  '43': 'classic-hd', '4-3': 'classic-hd', '169': 'standard', '16-9': 'standard',
  '916': 'mobile-hd', '9-16': 'mobile-hd',
};

// Ratio strings from i2v.sh (--ratio) map straight onto a default preset.
export const RATIO_TO_PRESET = {
  '9:16': 'mobile-hd',
  '16:9': 'standard',
  '1:1':  'square-hd',
  '4:5':  'portrait-social',
};

export const TRANSITIONS = ['fade', 'zoom', 'slide', 'none'];
// Maps our public transition names onto ffmpeg xfade transition= values.
export const TRANSITION_XFADE_MAP = { fade: 'fade', zoom: 'zoomin', slide: 'slideleft' };

export const MOTIONS = ['kenburns', 'zoom', 'pan', 'none'];

export const DEFAULT_PRESET  = process.env.DEFAULT_PRESET  || 'standard';
export const DEFAULT_THREADS = parseInt(process.env.DEFAULT_THREADS || '1');
export const DEFAULT_FPS     = parseInt(process.env.DEFAULT_FPS || '30');
export const DEFAULT_TRANSITION          = process.env.DEFAULT_TRANSITION || 'random';
export const DEFAULT_TRANSITION_DURATION = parseFloat(process.env.DEFAULT_TRANSITION_DURATION || '1.0');
export const DEFAULT_MOTION  = process.env.DEFAULT_MOTION || 'random';
export const MIN_IMAGE_SEC   = parseInt(process.env.DEFAULT_MIN_IMAGE || '5');
export const MAX_IMAGE_SEC   = parseInt(process.env.DEFAULT_MAX_IMAGE || '30');

export const SINGLE_DURATION      = parseInt(process.env.SINGLE_DURATION || '30');
export const KEN_BURNS_MAX_ZOOM   = parseFloat(process.env.KEN_BURNS_MAX_ZOOM  || '1.15');
export const KEN_BURNS_ZOOM_STEP  = parseFloat(process.env.KEN_BURNS_ZOOM_STEP || '0.0006');

export const MIN_SIZE_BYTES = 512 * 1024;

export const IMAGE_EXTS = new Set(['.jpg', '.jpeg', '.png', '.webp', '.bmp', '.tiff', '.tif', '.heic']);

// ── Helpers ───────────────────────────────────────────────────────────────

export function resolvePreset(nameOrRatio) {
  if (!nameOrRatio) return DEFAULT_PRESET;
  const lower = String(nameOrRatio).toLowerCase();
  if (PRESETS[lower])           return lower;
  if (PRESET_ALIASES[lower])    return PRESET_ALIASES[lower];
  if (RATIO_TO_PRESET[nameOrRatio]) return RATIO_TO_PRESET[nameOrRatio];
  return null;
}

export function validPresetNames() {
  return [...Object.keys(PRESETS), ...Object.keys(PRESET_ALIASES), ...Object.keys(RATIO_TO_PRESET)].join(', ');
}

export function presetsByCategory() {
  const out = {};
  for (const [key, p] of Object.entries(PRESETS)) {
    const cat = p.category || 'other';
    if (!out[cat]) out[cat] = [];
    out[cat].push({ key, ...p });
  }
  return out;
}

export function pickRandom(arr) { return arr[Math.floor(Math.random() * arr.length)]; }

export function resolveTransition(name) {
  const t = (name || DEFAULT_TRANSITION).toLowerCase();
  if (t === 'random') return pickRandom(['fade', 'zoom', 'slide']);
  if (TRANSITIONS.includes(t)) return t;
  return 'fade';
}

export function resolveMotion(name) {
  const m = (name || DEFAULT_MOTION).toLowerCase();
  if (m === 'random') return pickRandom(['kenburns', 'zoom', 'pan']);
  if (MOTIONS.includes(m)) return m;
  return 'kenburns';
}

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

// ── FFmpeg building blocks ──────────────────────────────────────────────

function h264Level(width, height) {
  const px = width * height;
  if (px > 3840 * 2160) return '5.2';
  if (px > 1920 * 1080) return '5.1';
  return '4.1';
}

function sharedCodecArgs({ crf, bitrate, maxrate, bufsize, threads, width, height, fps = DEFAULT_FPS }) {
  const gopSize = fps * 2;
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

function scaleFilter(width, height, fps = DEFAULT_FPS) {
  return [
    `scale=${width}:${height}:force_original_aspect_ratio=decrease`,
    `pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2:color=black`,
    `fps=${fps}`,
  ].join(',');
}

/** Basic programmatic motion (Ken Burns / zoom / pan) applied to one still. */
function motionFilter(motion, width, height, durationSec, fps = DEFAULT_FPS) {
  const totalFrames = Math.round(fps * durationSec);
  const upW = width * 2, upH = height * 2;
  const base = `scale=${upW}:${upH}:force_original_aspect_ratio=increase,crop=${upW}:${upH}`;

  if (motion === 'none') {
    return `scale=${width}:${height}:force_original_aspect_ratio=decrease,pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2:color=black`;
  }
  if (motion === 'zoom') {
    return `${base},zoompan=z='min(zoom+${KEN_BURNS_ZOOM_STEP},${KEN_BURNS_MAX_ZOOM})':d=${totalFrames}:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=${width}x${height}:fps=${fps}`;
  }
  if (motion === 'pan') {
    return `${base},zoompan=z='1.05':d=${totalFrames}:x='if(gte(on,1),x+1,(iw-iw/zoom)/2)':y='ih/2-(ih/zoom/2)':s=${width}x${height}:fps=${fps}`;
  }
  // kenburns (default) — slow zoom drifting toward center
  return `${base},zoompan=z='min(zoom+${KEN_BURNS_ZOOM_STEP},${KEN_BURNS_MAX_ZOOM})':d=${totalFrames}:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=${width}x${height}:fps=${fps}`;
}

/** Single-image → single clip (SINGLES mode). */
export function buildSingleArgs({ imagePath, width, height, crf, bitrate, maxrate, bufsize, threads, duration, motion, fps, outputFile }) {
  return [
    '-y', '-loglevel', 'error',
    '-loop', '1',
    '-i', imagePath,
    '-vf', `${motionFilter(motion, width, height, duration, fps)},format=yuv420p`,
    '-t', String(duration),
    ...sharedCodecArgs({ crf, bitrate, maxrate, bufsize, threads, width, height, fps }),
    outputFile,
  ];
}

/** Multi-image concat, no transitions (fast path). */
export function buildConcatArgs({ manifestPath, width, height, crf, bitrate, maxrate, bufsize, threads, fps, outputFile }) {
  return [
    '-y', '-loglevel', 'error',
    '-f', 'concat', '-safe', '0',
    '-i', manifestPath,
    '-vf', `${scaleFilter(width, height, fps)},format=yuv420p`,
    ...sharedCodecArgs({ crf, bitrate, maxrate, bufsize, threads, width, height, fps }),
    outputFile,
  ];
}

/** Single-image loop (grouped mode, folder with exactly one image). */
export function buildLoopArgs({ imagePath, width, height, crf, bitrate, maxrate, bufsize, threads, duration, fps, outputFile }) {
  return [
    '-y', '-loglevel', 'error',
    '-loop', '1',
    '-framerate', String(fps),
    '-i', imagePath,
    '-vf', `${scaleFilter(width, height, fps)},format=yuv420p`,
    '-t', String(duration),
    ...sharedCodecArgs({ crf, bitrate, maxrate, bufsize, threads, width, height, fps }),
    outputFile,
  ];
}

/**
 * Multi-image slideshow WITH crossfade transitions + per-image motion —
 * the direct equivalent of i2v.sh's --transition / --motion options.
 * Equal-length-clip xfade offsets: offset_k = (k+1)*(dur-xd) for k=0..n-2.
 */
export function buildXfadeArgs({ images, width, height, perImageDuration, transitionDuration, transitionType, motion, fps, crf, bitrate, maxrate, bufsize, threads, outputFile }) {
  const inputs = [];
  const filters = [];
  const clipLen = perImageDuration + transitionDuration;

  images.forEach((img, i) => {
    inputs.push('-loop', '1', '-t', String(clipLen), '-i', img);
    const mf = motionFilter(motion, width, height, clipLen, fps);
    filters.push(`[${i}:v]${mf},format=yuv420p,setsar=1[v${i}]`);
  });

  let last = 'v0';
  let offset = perImageDuration - transitionDuration;
  for (let i = 1; i < images.length; i++) {
    const out  = `x${i}`;
    const type = transitionType === 'random'
      ? pickRandom(Object.values(TRANSITION_XFADE_MAP))
      : (TRANSITION_XFADE_MAP[transitionType] || 'fade');
    filters.push(`[${last}][v${i}]xfade=transition=${type}:duration=${transitionDuration}:offset=${offset.toFixed(2)}[${out}]`);
    last = out;
    offset += (perImageDuration - transitionDuration);
  }

  return [
    '-y', '-loglevel', 'error',
    ...inputs,
    '-filter_complex', filters.join(';'),
    '-map', `[${last}]`,
    ...sharedCodecArgs({ crf, bitrate, maxrate, bufsize, threads, width, height, fps }),
    outputFile,
  ];
}

export async function writeManifest(images, imageDuration) {
  const tmp = `/tmp/manifest_${Date.now()}_${Math.random().toString(36).slice(2)}.txt`;
  const lines = [];
  for (const img of images) {
    lines.push(`file '${img}'`);
    lines.push(`duration ${imageDuration}`);
  }
  lines.push(`file '${images[images.length - 1]}'`); // EOF anchor
  await fs.writeFile(tmp, lines.join('\n') + '\n');
  return tmp;
}

export async function fileSizeBytes(filePath) {
  try { const s = await fs.stat(filePath); return s.size; }
  catch { return 0; }
}

export function runFfmpeg(args, logFile) {
  return new Promise((resolve) => {
    const proc = spawn('ffmpeg', args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const chunks = [];
    proc.stderr.on('data', d => chunks.push(d));
    proc.stdout.on('data', () => {});
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
ok "utils.js written (presets + ratio/transition/motion, xfade builder)"

# ============================================================
# app/src/remotes.js — SSH (sshfs) and SMB (cifs) mount management
# ============================================================
log "Writing app/src/remotes.js..."
cat > "$STACK_DIR/app/src/remotes.js" << 'REMOTESJS'
import { spawn } from 'child_process';
import fs from 'fs/promises';
import path from 'path';
import { pool, dbLog } from './db.js';
import { sanitiseName } from './utils.js';

const MOUNT_ROOT   = process.env.MOUNT_ROOT   || '/data/remote';
const SSH_KEY_DIR   = process.env.SSH_KEY_DIR  || '/data/secrets/ssh-keys';
const SMB_CRED_DIR  = process.env.SMB_CRED_DIR || '/data/secrets/smb-creds';
const MOUNT_TIMEOUT = parseInt(process.env.REMOTE_MOUNT_TIMEOUT_MS || '15000');

function run(cmd, args, timeoutMs = MOUNT_TIMEOUT) {
  return new Promise((resolve) => {
    const proc = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const out = [], err = [];
    const timer = setTimeout(() => { proc.kill('SIGKILL'); }, timeoutMs);
    proc.stdout.on('data', d => out.push(d));
    proc.stderr.on('data', d => err.push(d));
    proc.on('close', code => {
      clearTimeout(timer);
      resolve({ code, stdout: Buffer.concat(out).toString(), stderr: Buffer.concat(err).toString() });
    });
    proc.on('error', e => { clearTimeout(timer); resolve({ code: -1, stdout: '', stderr: e.message }); });
  });
}

export function mountPointFor(name) {
  return path.join(MOUNT_ROOT, sanitiseName(name));
}

/**
 * Persist SSH/SMB credentials to disk (never to the DB) with 0600 perms.
 * Returns the secret_ref (filename only) to store on the remotes row.
 */
export async function storeSecret({ protocol, name, authType, password, privateKey, domain, username }) {
  const safe = sanitiseName(name);
  if (protocol === 'ssh') {
    if (authType === 'key') {
      const file = path.join(SSH_KEY_DIR, `${safe}.key`);
      await fs.writeFile(file, privateKey.endsWith('\n') ? privateKey : privateKey + '\n', { mode: 0o600 });
      return `${safe}.key`;
    }
    const file = path.join(SSH_KEY_DIR, `${safe}.pass`);
    await fs.writeFile(file, password, { mode: 0o600 });
    return `${safe}.pass`;
  }
  // smb
  const file = path.join(SMB_CRED_DIR, `${safe}.cred`);
  const lines = [`username=${username || ''}`, `password=${password || ''}`];
  if (domain) lines.push(`domain=${domain}`);
  await fs.writeFile(file, lines.join('\n') + '\n', { mode: 0o600 });
  return `${safe}.cred`;
}

export async function deleteSecret({ protocol, secretRef }) {
  if (!secretRef) return;
  const dir = protocol === 'ssh' ? SSH_KEY_DIR : SMB_CRED_DIR;
  await fs.unlink(path.join(dir, secretRef)).catch(() => {});
}

async function ensureMountPoint(mountPoint) {
  await fs.mkdir(mountPoint, { recursive: true });
}

async function isMounted(mountPoint) {
  const { stdout } = await run('mountpoint', ['-q', mountPoint]).then(
    r => r, () => ({ stdout: '' })
  );
  const r = await run('sh', ['-c', `mountpoint -q '${mountPoint}'`]);
  return r.code === 0;
}

export async function mountRemote(remote) {
  const mountPoint = remote.mount_point || mountPointFor(remote.name);
  await ensureMountPoint(mountPoint);

  if (remote.protocol === 'ssh') {
    const target = `${remote.username}@${remote.host}:${remote.remote_path}`;
    const opts = [
      `port=${remote.port || 22}`,
      'allow_other',
      'reconnect',
      'ServerAliveInterval=15',
      'StrictHostKeyChecking=no',
      'UserKnownHostsFile=/dev/null',
    ];

    if (remote.auth_type === 'key') {
      const keyFile = path.join(SSH_KEY_DIR, remote.secret_ref);
      opts.push(`IdentityFile=${keyFile}`);
      const args = ['-o', opts.join(','), target, mountPoint];
      const res = await run('sshfs', args);
      return finalizeMount(remote, res);
    }

    const passFile = path.join(SSH_KEY_DIR, remote.secret_ref);
    const args = ['-f', passFile, 'sshfs', '-o', [...opts, 'password_stdin'].join(','), target, mountPoint];
    const res = await run('sshpass', args);
    return finalizeMount(remote, res);
  }

  if (remote.protocol === 'smb') {
    const credFile = path.join(SMB_CRED_DIR, remote.secret_ref);
    const unc = `//${remote.host}/${remote.remote_path}`.replace(/\/+/g, '/').replace(':/', '://');
    const optParts = [`credentials=${credFile}`, 'vers=3.0', 'uid=0', 'gid=0', 'file_mode=0644', 'dir_mode=0755'];
    if (remote.domain) optParts.push(`domain=${remote.domain}`);
    const args = ['-t', 'cifs', `//${remote.host}/${remote.remote_path}`, mountPoint, '-o', optParts.join(',')];
    const res = await run('mount', args);
    return finalizeMount(remote, res);
  }

  return { ok: false, error: `Unknown protocol: ${remote.protocol}` };
}

async function finalizeMount(remote, res) {
  if (res.code !== 0) {
    await dbLog('error', `Mount failed for remote "${remote.name}": ${res.stderr.slice(0, 400)}`, null, { remoteId: remote.id });
    return { ok: false, error: res.stderr.slice(0, 400) || 'mount failed' };
  }
  await dbLog('info', `Mounted remote "${remote.name}" (${remote.protocol}) at ${remote.mount_point || mountPointFor(remote.name)}`, null, { remoteId: remote.id });
  return { ok: true };
}

export async function unmountRemote(remote) {
  const mountPoint = remote.mount_point || mountPointFor(remote.name);
  const cmd = remote.protocol === 'ssh' ? 'fusermount' : 'umount';
  const args = remote.protocol === 'ssh' ? ['-u', mountPoint] : [mountPoint];
  const res = await run(cmd, args);
  if (res.code !== 0) {
    await dbLog('warn', `Unmount had issues for "${remote.name}": ${res.stderr.slice(0, 300)}`, null, { remoteId: remote.id });
    return { ok: false, error: res.stderr.slice(0, 300) };
  }
  await dbLog('info', `Unmounted remote "${remote.name}"`, null, { remoteId: remote.id });
  return { ok: true };
}

export async function countMounted() {
  const r = await pool.query(`SELECT COUNT(*) FROM remotes WHERE status='mounted'`);
  return parseInt(r.rows[0].count, 10);
}
REMOTESJS
ok "remotes.js written (sshfs key/password + cifs mount/unmount, secrets kept off DB)"

# ============================================================
# app/src/processor.js
# ============================================================
log "Writing app/src/processor.js..."
cat > "$STACK_DIR/app/src/processor.js" << 'PROCESSORJS'
import fs from 'fs/promises';
import path from 'path';
import { pool, dbLog, dbEvent } from './db.js';
import {
  PRESETS, DEFAULT_PRESET, DEFAULT_THREADS, DEFAULT_FPS,
  MIN_IMAGE_SEC, MAX_IMAGE_SEC, MIN_SIZE_BYTES, SINGLE_DURATION,
  DEFAULT_TRANSITION, DEFAULT_TRANSITION_DURATION, DEFAULT_MOTION,
  resolvePreset, resolveTransition, resolveMotion, sanitiseName,
  collectFolders, collectImages,
  buildConcatArgs, buildLoopArgs, buildSingleArgs, buildXfadeArgs,
  writeManifest, fileSizeBytes, runFfmpeg,
} from './utils.js';
import {
  jobsStartedTotal, jobsCompletedTotal, jobsFailedTotal,
  imagesProcessedTotal, renderDurationSeconds, outputSizeMb,
} from './metrics.js';

const OUTPUT_BASE = process.env.OUTPUT_BASE || '/data/archives';
const LOG_DIR     = process.env.LOG_DIR     || '/data/logs';

async function ensureDirs() {
  await fs.mkdir(OUTPUT_BASE, { recursive: true });
  await fs.mkdir(LOG_DIR,     { recursive: true });
}

async function createJob({ srcPath, preset, threads, mode, engine, ratio, transition, motion, fps, remoteId }) {
  const r = await pool.query(
    `INSERT INTO jobs (status, mode, engine, preset, ratio, transition, motion, fps, threads, src_path, remote_id, started_at)
     VALUES ('running',$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,NOW()) RETURNING id`,
    [mode, engine || 'ffmpeg', preset, ratio || null, transition || null, motion || null, fps || DEFAULT_FPS, threads, srcPath, remoteId || null]
  );
  return r.rows[0].id;
}

async function finaliseJob(jobId, { status, outputPath, folderName, totalImages, totalOutputs = 0, durationSec, sizeMb, errorMsg }) {
  await pool.query(
    `UPDATE jobs SET status=$1, output_path=$2, folder_name=$3,
     total_images=$4, total_outputs=$5, duration_sec=$6, size_mb=$7, error_msg=$8, finished_at=NOW()
     WHERE id=$9`,
    [status, outputPath, folderName, totalImages, totalOutputs, durationSec, sizeMb, errorMsg, jobId]
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

function optionsFromRequest(body = {}) {
  const preset  = resolvePreset(body.ratio || body.preset) || DEFAULT_PRESET;
  const threads = parseInt(body.threads) || DEFAULT_THREADS;
  const fps     = parseInt(body.fps) || DEFAULT_FPS;
  const transition         = resolveTransition(body.transition);
  const transitionDuration = parseFloat(body.transitionDuration) || DEFAULT_TRANSITION_DURATION;
  const motion  = resolveMotion(body.motion);
  return { preset, threads, fps, transition, transitionDuration, motion };
}

// ── GROUPED MODE (folder → 1 slideshow, with transitions + motion) ──────

async function processFolder(jobId, folder, opts) {
  const { preset, threads, fps, transition, transitionDuration, motion } = opts;
  const folderName = path.basename(folder);
  const safeName   = sanitiseName(folderName);
  const dateStamp  = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const outputFile = path.join(OUTPUT_BASE, `${safeName}_${preset}_${dateStamp}.mp4`);
  const logFile    = path.join(LOG_DIR,     `${safeName}_${preset}_${dateStamp}.log`);
  const p          = PRESETS[preset] || PRESETS[DEFAULT_PRESET];
  const { width, height, crf, bitrate, maxrate, bufsize } = p;

  await dbEvent(jobId, 'folder_start', { folder, folderName, safeName, preset, transition, motion });
  const images = await collectImages(folder);

  if (images.length === 0) {
    await dbLog('warn', `[SKIP] No images in: ${folderName}`, jobId);
    await dbEvent(jobId, 'skip', { reason: 'no_images', folder });
    return { status: 'skipped', folderName };
  }

  for (const img of images) {
    await insertMedia(jobId, { mediaType: 'image', filePath: img, folderName });
  }
  imagesProcessedTotal.inc({ mode: 'grouped' }, images.length);

  let args, manifestPath = null;
  let totalDuration;

  if (images.length === 1) {
    totalDuration = MAX_IMAGE_SEC;
    args = buildLoopArgs({ imagePath: images[0], width, height, crf, bitrate, maxrate, bufsize, threads, duration: totalDuration, fps, outputFile });
    await dbLog('info', `Single-image loop: ${folderName} (${totalDuration}s)`, jobId);
  } else if (transition !== 'none') {
    const perImageDuration = Math.max(MIN_IMAGE_SEC, Math.min(MAX_IMAGE_SEC, Math.floor(MAX_IMAGE_SEC / images.length) || MIN_IMAGE_SEC));
    totalDuration = perImageDuration * images.length;
    args = buildXfadeArgs({
      images, width, height, perImageDuration, transitionDuration, transitionType: transition, motion,
      fps, crf, bitrate, maxrate, bufsize, threads, outputFile,
    });
    await dbLog('info', `Xfade slideshow: ${folderName} (${images.length} imgs, ${transition} transition, ${motion} motion)`, jobId);
  } else {
    const perImageDuration = Math.max(MIN_IMAGE_SEC, Math.min(MAX_IMAGE_SEC, Math.floor(MAX_IMAGE_SEC / images.length) || MIN_IMAGE_SEC));
    totalDuration = perImageDuration * images.length;
    manifestPath = await writeManifest(images, perImageDuration);
    args = buildConcatArgs({ manifestPath, width, height, crf, bitrate, maxrate, bufsize, threads, fps, outputFile });
    await dbLog('info', `Concat slideshow (no transition): ${folderName} (${images.length} imgs)`, jobId);
  }

  await dbEvent(jobId, 'ffmpeg_start', { folderName, images: images.length, totalDuration, outputFile, preset });
  const startedAt = Date.now();
  const { code, stderr } = await runFfmpeg(args, logFile);
  renderDurationSeconds.observe({ mode: 'grouped', preset }, (Date.now() - startedAt) / 1000);
  if (manifestPath) await fs.unlink(manifestPath).catch(() => {});

  if (code !== 0) {
    await dbLog('error', `ffmpeg failed for ${folderName}: ${stderr.slice(0, 500)}`, jobId, { code, folderName, preset });
    await dbEvent(jobId, 'ffmpeg_fail', { folderName, code });
    return { status: 'failed', folderName, error: stderr.slice(0, 500) };
  }

  const sizeBytes = await fileSizeBytes(outputFile);
  if (sizeBytes < MIN_SIZE_BYTES) {
    await dbLog('warn', `Output too small for ${folderName} (${sizeBytes}B) — likely corrupt`, jobId);
    await fs.unlink(outputFile).catch(() => {});
    await dbEvent(jobId, 'fail_size', { folderName, sizeBytes });
    return { status: 'failed', folderName, error: 'output_too_small' };
  }

  const sizeMb = parseFloat((sizeBytes / 1024 / 1024).toFixed(2));
  outputSizeMb.observe({ mode: 'grouped', preset }, sizeMb);
  await insertMedia(jobId, { mediaType: 'video', filePath: outputFile, folderName });
  await dbEvent(jobId, 'ffmpeg_done', { folderName, outputFile, sizeMb, durationSec: totalDuration, preset });
  await dbLog('info', `Done: ${folderName} → ${outputFile} (${sizeMb}MB, ${totalDuration}s)`, jobId);
  return { status: 'done', folderName, outputFile, totalImages: images.length, durationSec: totalDuration, sizeMb };
}

export async function processDirectory({ srcPath, body = {}, remoteId = null }) {
  await ensureDirs();
  const opts = optionsFromRequest(body);
  if (!PRESETS[opts.preset]) throw new Error(`Unknown preset/ratio: ${body.preset || body.ratio}`);
  const jobId = await createJob({ srcPath, mode: 'grouped', remoteId, ...opts });
  jobsStartedTotal.inc({ mode: 'grouped', preset: opts.preset, engine: 'ffmpeg' });
  await dbLog('info', `Job started: ${jobId} | src=${srcPath} preset=${opts.preset} transition=${opts.transition} motion=${opts.motion}`, jobId);
  await dbEvent(jobId, 'job_start', { srcPath, mode: 'grouped', ...opts });

  setImmediate(async () => {
    try {
      const folders = await collectFolders(srcPath);
      const allFolders = folders.length ? folders : [srcPath];
      let successCount = 0, skipCount = 0, failCount = 0, lastOutput = null, totalImages = 0;
      for (const folder of allFolders) {
        const result = await processFolder(jobId, folder, opts);
        if      (result.status === 'done')    { successCount++; lastOutput = result.outputFile; totalImages += result.totalImages || 0; }
        else if (result.status === 'skipped') { skipCount++; }
        else                                  { failCount++; }
      }
      const finalStatus = failCount > 0 && successCount === 0 ? 'failed' : successCount > 0 ? 'done' : 'skipped';
      await finaliseJob(jobId, { status: finalStatus, outputPath: lastOutput, folderName: null, totalImages, totalOutputs: successCount, durationSec: 0, sizeMb: 0, errorMsg: null });
      if (finalStatus === 'done') jobsCompletedTotal.inc({ mode: 'grouped', preset: opts.preset, engine: 'ffmpeg' });
      if (finalStatus === 'failed') jobsFailedTotal.inc({ mode: 'grouped', preset: opts.preset, engine: 'ffmpeg' });
      await dbEvent(jobId, 'job_done', { successCount, skipCount, failCount });
    } catch (err) {
      jobsFailedTotal.inc({ mode: 'grouped', preset: opts.preset, engine: 'ffmpeg' });
      await dbLog('error', `Job crashed: ${err.message}`, jobId, { stack: err.stack });
      await pool.query(`UPDATE jobs SET status='failed', error_msg=$1, finished_at=NOW() WHERE id=$2`, [err.message, jobId]);
    }
  });
  return jobId;
}

// ── SINGLES MODE (one clip per image, no bucket grouping) ───────────────

async function processImageSingle(jobId, imagePath, folderName, opts, index) {
  const { preset, threads, fps, motion } = opts;
  const p = PRESETS[preset] || PRESETS[DEFAULT_PRESET];
  const { width, height, crf, bitrate, maxrate, bufsize } = p;
  const baseName   = path.basename(imagePath, path.extname(imagePath));
  const safeName   = sanitiseName(baseName);
  const dateStamp  = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const outputFile = path.join(OUTPUT_BASE, `${safeName}_single_${preset}_${dateStamp}_${index}.mp4`);
  const logFile    = path.join(LOG_DIR,     `${safeName}_single_${preset}_${dateStamp}_${index}.log`);

  await insertMedia(jobId, { mediaType: 'image', filePath: imagePath, folderName });

  const args = buildSingleArgs({ imagePath, width, height, crf, bitrate, maxrate, bufsize, threads, duration: SINGLE_DURATION, motion, fps, outputFile });

  await dbEvent(jobId, 'single_start', { imagePath, folderName, outputFile, preset, motion });
  const startedAt = Date.now();
  const { code, stderr } = await runFfmpeg(args, logFile);
  renderDurationSeconds.observe({ mode: 'singles', preset }, (Date.now() - startedAt) / 1000);

  if (code !== 0) {
    await dbLog('error', `singles ffmpeg failed for ${baseName}: ${stderr.slice(0, 500)}`, jobId, { code, imagePath, preset });
    await dbEvent(jobId, 'single_fail', { imagePath, code });
    return { status: 'failed', imagePath, error: stderr.slice(0, 500) };
  }

  const sizeBytes = await fileSizeBytes(outputFile);
  if (sizeBytes < MIN_SIZE_BYTES) {
    await dbLog('warn', `Singles output too small for ${baseName} (${sizeBytes}B) — likely corrupt`, jobId);
    await fs.unlink(outputFile).catch(() => {});
    await dbEvent(jobId, 'single_fail_size', { imagePath, sizeBytes });
    return { status: 'failed', imagePath, error: 'output_too_small' };
  }

  const sizeMb = parseFloat((sizeBytes / 1024 / 1024).toFixed(2));
  outputSizeMb.observe({ mode: 'singles', preset }, sizeMb);
  await insertMedia(jobId, { mediaType: 'video', filePath: outputFile, folderName });
  await dbEvent(jobId, 'single_done', { imagePath, outputFile, sizeMb, durationSec: SINGLE_DURATION, preset });
  await dbLog('info', `Single done: ${baseName} → ${outputFile} (${sizeMb}MB)`, jobId);
  return { status: 'done', imagePath, outputFile, sizeMb };
}

async function processFolderSingles(jobId, folder, opts) {
  const folderName = path.basename(folder);
  await dbEvent(jobId, 'folder_start_singles', { folder, folderName, preset: opts.preset });
  const images = await collectImages(folder);

  if (images.length === 0) {
    return { status: 'skipped', folderName, done: 0, failed: 0, total: 0, lastOutput: null };
  }
  imagesProcessedTotal.inc({ mode: 'singles' }, images.length);

  let done = 0, failed = 0, lastOutput = null, idx = 0;
  for (const img of images) {
    idx++;
    const result = await processImageSingle(jobId, img, folderName, opts, idx);
    if (result.status === 'done') { done++; lastOutput = result.outputFile; }
    else                          { failed++; }
  }
  return { status: failed > 0 && done === 0 ? 'failed' : 'done', folderName, done, failed, total: images.length, lastOutput };
}

/** srcPath may be a single folder OR a tree — every image anywhere under it becomes its own clip. */
export async function processDirectorySingles({ srcPath, body = {}, remoteId = null, singleFolderOnly = false }) {
  await ensureDirs();
  const opts = optionsFromRequest(body);
  if (!PRESETS[opts.preset]) throw new Error(`Unknown preset/ratio: ${body.preset || body.ratio}`);
  const jobId = await createJob({ srcPath, mode: 'singles', remoteId, ...opts });
  jobsStartedTotal.inc({ mode: 'singles', preset: opts.preset, engine: 'ffmpeg' });
  await dbLog('info', `Singles job started: ${jobId} | src=${srcPath} preset=${opts.preset} motion=${opts.motion}`, jobId);
  await dbEvent(jobId, 'job_start', { srcPath, mode: 'singles', ...opts });

  setImmediate(async () => {
    try {
      const folders = singleFolderOnly ? [srcPath] : [srcPath, ...await collectFolders(srcPath)];
      let totalImages = 0, totalDone = 0, totalFailed = 0, lastOutput = null, lastFolder = null;
      for (const folder of folders) {
        const result = await processFolderSingles(jobId, folder, opts);
        totalImages += result.total  || 0;
        totalDone   += result.done   || 0;
        totalFailed += result.failed || 0;
        if (result.lastOutput) { lastOutput = result.lastOutput; lastFolder = result.folderName; }
      }
      const finalStatus = totalDone === 0 && totalFailed === 0 ? 'skipped' : (totalFailed > 0 && totalDone === 0 ? 'failed' : 'done');
      await finaliseJob(jobId, {
        status: finalStatus, outputPath: lastOutput, folderName: lastFolder,
        totalImages, totalOutputs: totalDone, durationSec: SINGLE_DURATION, sizeMb: 0, errorMsg: null,
      });
      if (finalStatus === 'done') jobsCompletedTotal.inc({ mode: 'singles', preset: opts.preset, engine: 'ffmpeg' });
      if (finalStatus === 'failed') jobsFailedTotal.inc({ mode: 'singles', preset: opts.preset, engine: 'ffmpeg' });
      await dbEvent(jobId, 'job_done', { totalImages, totalDone, totalFailed });
    } catch (err) {
      jobsFailedTotal.inc({ mode: 'singles', preset: opts.preset, engine: 'ffmpeg' });
      await dbLog('error', `Singles job crashed: ${err.message}`, jobId, { stack: err.stack });
      await pool.query(`UPDATE jobs SET status='failed', error_msg=$1, finished_at=NOW() WHERE id=$2`, [err.message, jobId]);
    }
  });
  return jobId;
}
PROCESSORJS
ok "processor.js written (grouped w/ xfade transitions + singles w/ motion, metrics wired in)"

# ============================================================
# app/src/routes.js
# ============================================================
log "Writing app/src/routes.js..."
cat > "$STACK_DIR/app/src/routes.js" << 'ROUTESJS'
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
ROUTESJS
ok "routes.js written (/remotes CRUD + mount/unmount + /remotes/:id/process, /metrics)"

# ============================================================
# app/src/index.js
# ============================================================
log "Writing app/src/index.js..."
cat > "$STACK_DIR/app/src/index.js" << 'INDEXJS'
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
INDEXJS
ok "index.js written"

# ============================================================
# scripts/smoke-test.sh
# ============================================================
log "Writing scripts/smoke-test.sh..."
cat > "$STACK_DIR/scripts/smoke-test.sh" << 'SMOKETEST'
#!/bin/bash
# ============================================================
# smoke-test.sh — Validates i2v-microservice v4 stack
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
echo "  i2v-microservice v4 — Smoke Test Suite"
echo "  Target: $BASE_URL"
echo -e "================================================${NC}"

echo ""
echo "Waiting for service to be ready (up to 60s)..."
for i in $(seq 1 30); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/status" 2>/dev/null || echo "000")
  if [ "$CODE" = "200" ]; then echo -e "${GREEN}✓ Service is up!${NC}"; break; fi
  [ "$i" = "30" ] && { echo -e "${RED}Timed out waiting for service.${NC}"; exit 1; }
  sleep 2
done

banner "Core Endpoints"
check_http "GET / HTTP 200"          "$BASE_URL/"        "200"
check      "GET /status ok:true"     "$(curl -s $BASE_URL/status)"   '"ok":true'
check      "GET /status remotes key" "$(curl -s $BASE_URL/status)"   'remotes_mounted'
check_http "GET /doc HTTP 200"       "$BASE_URL/doc"      "200"
check_http "GET /metrics HTTP 200"   "$BASE_URL/metrics"  "200"
check      "GET /metrics has jobs_started" "$(curl -s $BASE_URL/metrics)" 'i2v_jobs_started_total'
check      "GET /presets has transitions"  "$(curl -s $BASE_URL/presets)" '"transitions"'
check      "GET /presets has motions"      "$(curl -s $BASE_URL/presets)" '"motions"'
check      "GET /presets has mobile-hd"    "$(curl -s $BASE_URL/presets)" 'mobile-hd'
check      "GET /jobs returns array"       "$(curl -s $BASE_URL/jobs)"    '"jobs"'
check      "GET /remotes returns array"    "$(curl -s $BASE_URL/remotes)" '"remotes"'
check      "GET /logs returns array"       "$(curl -s $BASE_URL/logs)"    '"logs"'
check      "GET /media returns array"      "$(curl -s $BASE_URL/media)"   '"media"'

banner "Grouped Mode"
check "POST /process/quick/standard"  "$(curl -s -X POST $BASE_URL/process/quick/standard)" '"jobId"'
check "POST /process (ratio 9:16)"    "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"ratio\":\"9:16\",\"transition\":\"fade\",\"motion\":\"kenburns\"}')" '"jobId"'
check "POST /process bad preset"      "$(curl -s -X POST $BASE_URL/process -H 'Content-Type: application/json' -d '{\"srcPath\":\"/x\",\"preset\":\"notexist\"}')" '"error"'

banner "Singles Mode"
check "POST /process/singles/standard" "$(curl -s -X POST $BASE_URL/process/singles/standard)" '"jobId"'
check "POST /process/singles full body" "$(curl -s -X POST $BASE_URL/process/singles -H 'Content-Type: application/json' -d '{\"srcPath\":\"/data/media\",\"ratio\":\"1:1\",\"motion\":\"zoom\"}')" '"jobId"'
check "POST /process/singles missing srcPath falls back to DATA_ROOT" "$(curl -s -X POST $BASE_URL/process/singles -H 'Content-Type: application/json' -d '{}')" '"jobId"'

banner "Remotes — validation paths (no live host required)"
check "POST /remotes missing fields → error" "$(curl -s -X POST $BASE_URL/remotes -H 'Content-Type: application/json' -d '{\"name\":\"x\"}')" '"error"'
check "POST /remotes bad protocol → error"   "$(curl -s -X POST $BASE_URL/remotes -H 'Content-Type: application/json' -d '{\"name\":\"x\",\"protocol\":\"ftp\",\"host\":\"h\",\"remotePath\":\"/p\"}')" '"error"'
check "POST /remotes (ssh key) creates row"  "$(curl -s -X POST $BASE_URL/remotes -H 'Content-Type: application/json' -d '{\"name\":\"smoketest-ssh\",\"protocol\":\"ssh\",\"host\":\"127.0.0.1\",\"username\":\"test\",\"authType\":\"key\",\"privateKey\":\"dummy\",\"remotePath\":\"/tmp\"}')" '"remote"'
check "GET /remotes lists it"                "$(curl -s $BASE_URL/remotes)" 'smoketest-ssh'

REMOTE_ID=$(curl -s "$BASE_URL/remotes" | grep -o '"id":"[^"]*","name":"smoketest-ssh"' | grep -o '[a-f0-9-]\{36\}' | head -1 || true)
if [ -n "$REMOTE_ID" ]; then
  banner "Remotes — cleanup"
  check "DELETE /remotes/:id" "$(curl -s -X DELETE $BASE_URL/remotes/$REMOTE_ID)" '"ok":true'
fi

banner "Query Filters"
check "GET /jobs?mode=grouped" "$(curl -s $BASE_URL/jobs?mode=grouped)" '"jobs"'
check "GET /jobs?mode=singles" "$(curl -s $BASE_URL/jobs?mode=singles)" '"jobs"'
check "GET /logs?level=error"  "$(curl -s $BASE_URL/logs?level=error)"  '"logs"'

echo ""
echo -e "${CYAN}================================================"
TOTAL=$((PASS+FAIL))
echo -e "Results: ${GREEN}${PASS}/${TOTAL} passed${NC} | ${RED}${FAIL} failed${NC}"
echo -e "${CYAN}================================================${NC}"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
SMOKETEST
chmod +x "$STACK_DIR/scripts/smoke-test.sh"
ok "smoke-test.sh written"

# ============================================================
# Local data dirs (bind mounts referenced in docker-compose.yml)
# ============================================================
mkdir -p "$STACK_DIR/data/media" "$STACK_DIR/data/archives" "$STACK_DIR/data/logs" "$STACK_DIR/data/remote"
ok "local data/ directories created (media, archives, logs, remote)"

# ============================================================
# Validate file structure
# ============================================================
log "Validating file structure..."
EXPECTED_FILES=(
  "$STACK_DIR/.env"
  "$STACK_DIR/init.sql"
  "$STACK_DIR/docker-compose.yml"
  "$STACK_DIR/prometheus.yml"
  "$STACK_DIR/app/Dockerfile"
  "$STACK_DIR/app/package.json"
  "$STACK_DIR/app/src/index.js"
  "$STACK_DIR/app/src/db.js"
  "$STACK_DIR/app/src/metrics.js"
  "$STACK_DIR/app/src/utils.js"
  "$STACK_DIR/app/src/remotes.js"
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
  tree "$STACK_DIR" -I 'data'
else
  find "$STACK_DIR" -type f -not -path "*/data/*" | sort | sed "s|$STACK_DIR/||" | while read -r f; do echo "  $f"; done
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
  cd - >/dev/null
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
echo "  ✓  i2v-microservice v4 created successfully!"
echo -e "================================================${NC}"
echo ""
echo "  Directory : $STACK_DIR"
echo ""
echo "  1) Review/edit secrets: $STACK_DIR/.env  (set PGPASSWORD!)"
echo "  2) Start:"
echo -e "     ${CYAN}cd $STACK_DIR && docker compose up -d --build${NC}"
echo "  3) Optional Prometheus scraper:"
echo -e "     ${CYAN}docker compose --profile monitoring up -d${NC}"
echo ""
echo "  Or one-shot from here:"
echo -e "  ${CYAN}bash setup_i2v_stack.sh --run          # build + start${NC}"
echo -e "  ${CYAN}bash setup_i2v_stack.sh --run --test   # + smoke test${NC}"
echo ""
echo "  Grouped mode (folder → 1 video, transitions + motion, per i2v.sh):"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process -H 'Content-Type: application/json' \\
       -d '{\"srcPath\":\"/data/media/album1\",\"ratio\":\"9:16\",\"transition\":\"fade\",\"motion\":\"kenburns\"}'${NC}"
echo ""
echo "  Singles mode (1 image → 1 clip, no bucket grouping):"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/process/singles/mobile-hd${NC}"
echo ""
echo "  Register + mount a remote SSH source, then convert it:"
echo -e "  ${CYAN}curl -X POST http://localhost:3000/remotes -H 'Content-Type: application/json' -d '{
    \"name\":\"nas-photos\",\"protocol\":\"ssh\",\"host\":\"192.168.1.50\",\"port\":22,
    \"username\":\"pi\",\"authType\":\"key\",\"privateKey\":\"<paste key>\",\"remotePath\":\"/export/photos\"}'
  curl -X POST http://localhost:3000/remotes/<id>/mount
  curl -X POST http://localhost:3000/remotes/<id>/process -H 'Content-Type: application/json' \\
       -d '{\"ratio\":\"16:9\",\"transition\":\"slide\"}'${NC}"
echo ""
echo "  Metrics for Prometheus/Grafana:"
echo -e "  ${CYAN}curl http://localhost:3000/metrics${NC}"
echo ""
