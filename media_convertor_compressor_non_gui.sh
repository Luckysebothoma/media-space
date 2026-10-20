#!/bin/bash

# ============================================================
# media_convertor_compressor.sh
# Compress JPG + MP4 media stack with PostgreSQL + Redis cache
#
# Features:
# - JPG compression
# - MP4 compression
# - Duplicate detection via SHA256
# - Output renaming with compression profile suffix
# - PostgreSQL media indexing
# - Redis 7-day duplicate cache
# - Dockerized stack
#
# Run:
#   bash media_convertor_compressor.sh [--run]
#
# ============================================================

set -euo pipefail

STACK_DIR="./media-convertor-compressor"
RUN_STACK=false

for arg in "$@"; do
  case $arg in
    --run) RUN_STACK=true ;;
  esac
done

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${CYAN}[SETUP]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ============================================================
# Checks
# ============================================================

log "Checking dependencies..."

command -v docker >/dev/null 2>&1 || die "Docker not installed"
docker compose version >/dev/null 2>&1 || die "Docker compose plugin missing"

ok "Docker OK"

# ============================================================
# Cleanup
# ============================================================

if [ -d "$STACK_DIR" ]; then
  log "Removing old stack..."
  rm -rf "$STACK_DIR"
  ok "Old stack removed"
fi

# ============================================================
# Structure
# ============================================================

mkdir -p "$STACK_DIR/app/src"
mkdir -p "$STACK_DIR/media/input"
mkdir -p "$STACK_DIR/media/output"
mkdir -p "$STACK_DIR/media/duplicates"

ok "Directories created"

# ============================================================
# init.sql
# ============================================================

cat > "$STACK_DIR/init.sql" << 'SQL'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS media_files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sha256 TEXT UNIQUE NOT NULL,

    original_name TEXT NOT NULL,
    compressed_name TEXT NOT NULL,

    media_type TEXT NOT NULL CHECK (media_type IN ('image','video')),

    compression_profile TEXT NOT NULL,

    original_size BIGINT,
    compressed_size BIGINT,

    original_path TEXT NOT NULL,
    compressed_path TEXT NOT NULL,

    width INT,
    height INT,
    duration_sec NUMERIC(10,2),

    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_media_sha256 ON media_files(sha256);
CREATE INDEX IF NOT EXISTS idx_media_type ON media_files(media_type);
CREATE INDEX IF NOT EXISTS idx_media_created ON media_files(created_at DESC);
SQL

ok "init.sql written"

# ============================================================
# docker-compose.yml
# ============================================================

cat > "$STACK_DIR/docker-compose.yml" << 'COMPOSE'
services:

  postgres:
    image: postgres:16-alpine
    container_name: media_pg
    restart: unless-stopped
    environment:
      POSTGRES_DB: media_db
      POSTGRES_USER: media
      POSTGRES_PASSWORD: media_pass
    ports:
      - "5432:5432"
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro

  redis:
    image: redis:7-alpine
    container_name: media_redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data

  app:
    build:
      context: ./app
    container_name: media_app
    restart: unless-stopped
    depends_on:
      - postgres
      - redis
    environment:
      PGHOST: postgres
      PGPORT: 5432
      PGDATABASE: media_db
      PGUSER: media
      PGPASSWORD: media_pass

      REDIS_HOST: redis
      REDIS_PORT: 6379

      INPUT_DIR: /media/input
      OUTPUT_DIR: /media/output
      DUP_DIR: /media/duplicates

      IMAGE_PROFILE: jpg_q75
      VIDEO_PROFILE: mp4_h264_crf28
    volumes:
      - /pics/checked_for_youtube:/media
    command: ["node", "src/index.js"]

volumes:
  pg_data:
  redis_data:
COMPOSE

ok "docker-compose.yml written"

# ============================================================
# Dockerfile
# ============================================================

cat > "$STACK_DIR/app/Dockerfile" << 'DOCKERFILE'
FROM node:22-slim

RUN apt-get update && apt-get install -y \
    ffmpeg \
    imagemagick \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./

RUN npm install

COPY src ./src

CMD ["node", "src/index.js"]
DOCKERFILE

ok "Dockerfile written"

# ============================================================
# package.json
# ============================================================

cat > "$STACK_DIR/app/package.json" << 'PKG'
{
  "name": "media-convertor-compressor",
  "version": "1.0.0",
  "type": "module",
  "dependencies": {
    "pg": "^8.13.1",
    "redis": "^4.7.0"
  }
}
PKG

ok "package.json written"

# ============================================================
# index.js
# ============================================================

cat > "$STACK_DIR/app/src/index.js" << 'NODE'
import fs from 'fs/promises';
import path from 'path';
import crypto from 'crypto';
import { exec } from 'child_process';
import { promisify } from 'util';

import pg from 'pg';
import { createClient } from 'redis';

const run = promisify(exec);

const INPUT_DIR  = process.env.INPUT_DIR;
const OUTPUT_DIR = process.env.OUTPUT_DIR;
const DUP_DIR    = process.env.DUP_DIR;

const IMAGE_PROFILE = process.env.IMAGE_PROFILE;
const VIDEO_PROFILE = process.env.VIDEO_PROFILE;

const IMAGE_EXTS = ['.jpg', '.jpeg'];
const VIDEO_EXTS = ['.mp4'];

const pool = new pg.Pool({
  host: process.env.PGHOST,
  port: process.env.PGPORT,
  database: process.env.PGDATABASE,
  user: process.env.PGUSER,
  password: process.env.PGPASSWORD
});

const redis = createClient({
  url: `redis://${process.env.REDIS_HOST}:${process.env.REDIS_PORT}`
});

await redis.connect();

console.log('[BOOT] Redis connected');

function sha256File(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

async function existsInDatabase(hash) {
  const r = await pool.query(
    'SELECT id FROM media_files WHERE sha256=$1 LIMIT 1',
    [hash]
  );

  return r.rowCount > 0;
}

async function cacheDuplicate(hash) {
  await redis.setEx(`dup:${hash}`, 604800, '1');
}

async function isDuplicate(hash) {
  const cached = await redis.get(`dup:${hash}`);
  if (cached) return true;
  return await existsInDatabase(hash);
}

async function compressImage(src, output) {
  await run(`convert "${src}" -strip -interlace Plane -quality 75 "${output}"`);
}

async function compressVideo(src, output) {
  await run(
    `ffmpeg -y -i "${src}" -vcodec libx264 -crf 28 -preset fast -acodec aac "${output}"`
  );
}

async function processFile(filePath) {

  const stat = await fs.stat(filePath);

  if (!stat.isFile()) return;

  const ext = path.extname(filePath).toLowerCase();

  const isImage = IMAGE_EXTS.includes(ext);
  const isVideo = VIDEO_EXTS.includes(ext);

  if (!isImage && !isVideo) return;

  const fileBuffer = await fs.readFile(filePath);
  const hash = sha256File(fileBuffer);

  const dup = await isDuplicate(hash);

  if (dup) {
    const dupPath = path.join(DUP_DIR, path.basename(filePath));

    await fs.rename(filePath, dupPath);

    console.log('[DUPLICATE]', filePath);

    return;
  }

  const originalName = path.basename(filePath, ext);

  let profile;
  let outputExt;

  if (isImage) {
    profile = IMAGE_PROFILE;
    outputExt = '.jpg';
  } else {
    profile = VIDEO_PROFILE;
    outputExt = '.mp4';
  }

  const outputName = `${originalName}__${profile}__${hash.slice(0,12)}${outputExt}`;

  const outputPath = path.join(OUTPUT_DIR, outputName);

  if (isImage) {
    await compressImage(filePath, outputPath);
  } else {
    await compressVideo(filePath, outputPath);
  }

  const compressedStat = await fs.stat(outputPath);

  await pool.query(`
    INSERT INTO media_files (
      sha256,
      original_name,
      compressed_name,
      media_type,
      compression_profile,
      original_size,
      compressed_size,
      original_path,
      compressed_path
    )
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
  `, [
    hash,
    path.basename(filePath),
    outputName,
    isImage ? 'image' : 'video',
    profile,
    stat.size,
    compressedStat.size,
    filePath,
    outputPath
  ]);

  await cacheDuplicate(hash);

  console.log('[COMPRESSED]', outputName);
}

async function scan() {

  await fs.mkdir(INPUT_DIR, { recursive: true });
  await fs.mkdir(OUTPUT_DIR, { recursive: true });
  await fs.mkdir(DUP_DIR, { recursive: true });

  const files = await fs.readdir(INPUT_DIR);

  for (const file of files) {
    const full = path.join(INPUT_DIR, file);

    try {
      await processFile(full);
    } catch (err) {
      console.error('[ERROR]', file, err.message);
    }
  }
}

console.log('[SCAN] Starting media compression...');
await scan();

console.log('[DONE]');
process.exit(0);
NODE

ok "index.js written"

# ============================================================
# Final
# ============================================================

echo
ok "Media Convertor Compressor stack created"
echo
echo "INPUT:"
echo "  $STACK_DIR/media/input"
echo
echo "OUTPUT:"
echo "  $STACK_DIR/media/output"
echo
echo "DUPLICATES:"
echo "  $STACK_DIR/media/duplicates"
echo

if [ "$RUN_STACK" = true ]; then
  log "Starting stack..."
  cd "$STACK_DIR"
  docker compose up --build -d
  ok "Stack running"
fi
