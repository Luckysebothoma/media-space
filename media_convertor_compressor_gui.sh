#!/bin/bash

# ============================================================
# media_convertor_compressor_gui.sh  v3.0
#
# FULL MEDIA MANAGEMENT STACK
#
# FIXES v3.0:
# ✅ EXDEV cross-device rename → copy+delete fallback
# ✅ Atomic output writes (tmp file → rename within same FS)
# ✅ Upgraded GUI (live progress bar, stats cards, log search)
# ✅ /progress endpoint for real-time scan feedback
# ✅ /stats returns full breakdown (images, videos, sizes)
# ✅ Graceful shutdown (SIGTERM drains in-flight jobs)
# ✅ Per-file timeout guard (stuck ffmpeg won't hang forever)
# ✅ Empty-dir detection fixed (no cross-device move)
#
# RUN:
#   bash media_convertor_compressor_gui.sh --run
#
# GUI:   http://localhost:8080
# API:   POST http://localhost:3000/webhook/process
# ============================================================

set -euo pipefail

STACK_DIR="./media_convertor_gui"
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
# CHECKS
# ============================================================

log "Checking dependencies..."
command -v docker >/dev/null 2>&1 || die "Docker missing"
docker compose version >/dev/null 2>&1 || die "Docker compose plugin missing"
ok "Docker OK"

# ============================================================
# CLEANUP + STRUCTURE
# ============================================================

[ -d "$STACK_DIR" ] && { log "Removing old stack..."; rm -rf "$STACK_DIR"; }

mkdir -p "$STACK_DIR/app/src"
mkdir -p "$STACK_DIR/app/public"
mkdir -p "$STACK_DIR/media/input"
mkdir -p "$STACK_DIR/media/output"
mkdir -p "$STACK_DIR/media/duplicates"
mkdir -p "$STACK_DIR/media/processed"
mkdir -p "$STACK_DIR/media/empty_dirs"

ok "Directories created"

# ============================================================
# INIT.SQL
# ============================================================

cat > "$STACK_DIR/init.sql" << 'SQL'
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS media_files (
    filename          TEXT PRIMARY KEY,
    sha256            TEXT NOT NULL UNIQUE,
    original_path     TEXT NOT NULL,
    converted_path    TEXT NOT NULL,
    media_type        TEXT NOT NULL,
    compression_profile TEXT NOT NULL,
    original_size     BIGINT NOT NULL,
    converted_size    BIGINT NOT NULL,
    status            TEXT NOT NULL DEFAULT 'converted',
    width             INT,
    height            INT,
    duration_sec      NUMERIC(10,2),
    created_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_media_sha     ON media_files(sha256);
CREATE INDEX IF NOT EXISTS idx_media_created ON media_files(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_media_type    ON media_files(media_type);
SQL

ok "init.sql written"

# ============================================================
# DOCKER COMPOSE
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
      - "5441:5432"
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql

  app:
    build:
      context: ./app
    container_name: media_app
    restart: unless-stopped
    depends_on:
      - postgres
    environment:
      PORT: 3000
      PGHOST: postgres
      PGPORT: 5432
      PGDATABASE: media_db
      PGUSER: media
      PGPASSWORD: media_pass
      REDIS_HOST: 192.168.0.140
      REDIS_PORT: 6390
      INPUT_DIR: /media/input
      OUTPUT_DIR: /media/output
      DUP_DIR: /media/duplicates
      PROCESSED_DIR: /media/processed
      EMPTY_DIR: /media/empty_dirs
      # Per-file timeout in seconds (default 1800 = 30 min)
      FILE_TIMEOUT_SEC: 1800
    ports:
      - "3000:3000"
      - "8080:3000"
    volumes:
      - /pics/checked_for_youtube:/media

volumes:
  pg_data:
  redis_data:
COMPOSE

ok "docker-compose.yml written"

# ============================================================
# DOCKERFILE
# ============================================================

cat > "$STACK_DIR/app/Dockerfile" << 'DOCKER'
FROM node:22-slim

RUN apt-get update && apt-get install -y \
    ffmpeg \
    imagemagick \
    webp \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
RUN npm install

COPY src ./src
COPY public ./public

EXPOSE 3000

CMD ["node", "src/index.js"]
DOCKER

ok "Dockerfile written"

# ============================================================
# PACKAGE.JSON
# ============================================================

cat > "$STACK_DIR/app/package.json" << 'PKG'
{
  "name": "media-gui-stack",
  "version": "3.0.0",
  "type": "module",
  "dependencies": {
    "express": "^4.19.2",
    "multer": "^1.4.5-lts.1",
    "pg": "^8.13.1",
    "redis": "^4.7.0"
  }
}
PKG

ok "package.json written"

# ============================================================
# FRONTEND GUI  (upgraded)
# ============================================================

cat > "$STACK_DIR/app/public/index.html" << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Media Convertor · Dashboard</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&family=Syne:wght@400;700;800&display=swap');

  :root{
    --bg:#080c14;
    --surface:#0d1420;
    --card:#111827;
    --border:#1e2d40;
    --accent:#00d4ff;
    --accent2:#7c3aed;
    --success:#22c55e;
    --warn:#f59e0b;
    --danger:#ef4444;
    --text:#e2e8f0;
    --muted:#64748b;
  }

  *{box-sizing:border-box;margin:0;padding:0}

  body{
    background:var(--bg);
    color:var(--text);
    font-family:'Syne',sans-serif;
    min-height:100vh;
    padding:24px;
  }

  header{
    display:flex;
    align-items:center;
    gap:16px;
    margin-bottom:32px;
    border-bottom:1px solid var(--border);
    padding-bottom:20px;
  }

  header h1{
    font-size:1.6rem;
    font-weight:800;
    letter-spacing:-0.03em;
    background:linear-gradient(90deg,var(--accent),var(--accent2));
    -webkit-background-clip:text;
    -webkit-text-fill-color:transparent;
  }

  .badge{
    font-family:'JetBrains Mono',monospace;
    font-size:0.65rem;
    background:var(--accent2);
    color:#fff;
    padding:2px 8px;
    border-radius:20px;
    letter-spacing:.05em;
  }

  .grid{
    display:grid;
    grid-template-columns:repeat(auto-fit,minmax(160px,1fr));
    gap:14px;
    margin-bottom:24px;
  }

  .stat{
    background:var(--card);
    border:1px solid var(--border);
    border-radius:12px;
    padding:16px;
  }

  .stat-label{
    font-size:.7rem;
    color:var(--muted);
    text-transform:uppercase;
    letter-spacing:.08em;
    margin-bottom:6px;
  }

  .stat-value{
    font-size:1.7rem;
    font-weight:800;
    font-family:'JetBrains Mono',monospace;
    color:var(--accent);
  }

  .stat-sub{
    font-size:.7rem;
    color:var(--muted);
    margin-top:2px;
  }

  .panel{
    background:var(--card);
    border:1px solid var(--border);
    border-radius:14px;
    padding:20px;
    margin-bottom:20px;
  }

  .panel-header{
    display:flex;
    justify-content:space-between;
    align-items:center;
    margin-bottom:16px;
  }

  .panel-title{
    font-size:.8rem;
    text-transform:uppercase;
    letter-spacing:.1em;
    color:var(--muted);
  }

  .row{display:flex;gap:12px;flex-wrap:wrap;align-items:center}

  button{
    padding:10px 20px;
    border:none;
    border-radius:8px;
    font-family:'Syne',sans-serif;
    font-weight:700;
    font-size:.85rem;
    cursor:pointer;
    transition:opacity .15s,transform .1s;
  }
  button:active{transform:scale(.97)}
  button:disabled{opacity:.4;cursor:not-allowed}

  .btn-primary{background:var(--accent);color:#000}
  .btn-danger{background:var(--danger);color:#fff}
  .btn-ghost{background:var(--border);color:var(--text)}

  .progress-wrap{
    background:var(--border);
    border-radius:999px;
    height:8px;
    overflow:hidden;
    flex:1;
    min-width:120px;
  }

  .progress-bar{
    height:100%;
    background:linear-gradient(90deg,var(--accent),var(--accent2));
    border-radius:999px;
    width:0%;
    transition:width .4s ease;
  }

  .progress-label{
    font-family:'JetBrains Mono',monospace;
    font-size:.75rem;
    color:var(--muted);
    min-width:60px;
    text-align:right;
  }

  #scan-status{
    font-family:'JetBrains Mono',monospace;
    font-size:.75rem;
    padding:4px 12px;
    border-radius:20px;
    background:var(--surface);
    color:var(--muted);
  }
  #scan-status.running{color:var(--accent);background:#00d4ff15}
  #scan-status.done{color:var(--success);background:#22c55e15}

  .log-search{
    background:var(--surface);
    border:1px solid var(--border);
    border-radius:8px;
    padding:8px 12px;
    color:var(--text);
    font-family:'JetBrains Mono',monospace;
    font-size:.8rem;
    width:220px;
    outline:none;
  }
  .log-search:focus{border-color:var(--accent)}

  #logs{
    background:var(--surface);
    border:1px solid var(--border);
    padding:14px;
    border-radius:10px;
    font-family:'JetBrains Mono',monospace;
    font-size:.72rem;
    line-height:1.7;
    height:340px;
    overflow-y:auto;
    white-space:pre-wrap;
    word-break:break-all;
  }

  .log-SUCCESS{color:var(--success)}
  .log-ERROR  {color:var(--danger)}
  .log-SKIP   {color:var(--muted)}
  .log-DUPLICATE{color:var(--warn)}
  .log-CORRUPT{color:var(--danger)}
  .log-SCAN   {color:var(--accent)}

  .webhook-box{
    background:var(--surface);
    border:1px solid var(--border);
    border-radius:8px;
    padding:10px 14px;
    font-family:'JetBrains Mono',monospace;
    font-size:.8rem;
    color:var(--accent);
    flex:1;
  }

  .dot{
    width:8px;height:8px;
    border-radius:50%;
    background:var(--success);
    box-shadow:0 0 8px var(--success);
    animation:pulse 2s infinite;
  }
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
</style>
</head>
<body>

<header>
  <div class="dot"></div>
  <h1>Media Convertor</h1>
  <span class="badge">v3.0</span>
</header>

<!-- Stats -->
<div class="grid" id="stats-grid">
  <div class="stat">
    <div class="stat-label">Total Processed</div>
    <div class="stat-value" id="s-total">–</div>
    <div class="stat-sub">files converted</div>
  </div>
  <div class="stat">
    <div class="stat-label">Images</div>
    <div class="stat-value" id="s-images">–</div>
    <div class="stat-sub">jpg / png / webp</div>
  </div>
  <div class="stat">
    <div class="stat-label">Videos</div>
    <div class="stat-value" id="s-videos">–</div>
    <div class="stat-sub">mp4 / mov / mkv</div>
  </div>
  <div class="stat">
    <div class="stat-label">Space Saved</div>
    <div class="stat-value" id="s-saved">–</div>
    <div class="stat-sub">vs originals</div>
  </div>
  <div class="stat">
    <div class="stat-label">Duplicates</div>
    <div class="stat-value" id="s-dups" style="color:var(--warn)">–</div>
    <div class="stat-sub">deduplicated</div>
  </div>
</div>

<!-- Controls -->
<div class="panel">
  <div class="panel-header">
    <span class="panel-title">Scan Controls</span>
    <span id="scan-status">idle</span>
  </div>
  <div class="row">
    <button class="btn-primary" id="btn-scan" onclick="runScan()">▶ Run Compression</button>
    <div class="progress-wrap"><div class="progress-bar" id="pbar"></div></div>
    <span class="progress-label" id="plabel">–</span>
  </div>
</div>

<!-- Webhook -->
<div class="panel">
  <div class="panel-header"><span class="panel-title">Webhook Endpoint</span></div>
  <div class="row">
    <div class="webhook-box">POST http://localhost:3000/webhook/process</div>
    <button class="btn-ghost" onclick="copyWebhook()">Copy</button>
  </div>
</div>

<!-- Logs -->
<div class="panel">
  <div class="panel-header">
    <span class="panel-title">Live Logs</span>
    <div class="row" style="gap:8px">
      <input class="log-search" id="log-filter" placeholder="Filter logs…" oninput="filterLogs()">
      <button class="btn-ghost" onclick="clearFilter()">✕</button>
    </div>
  </div>
  <div id="logs">Waiting for logs…</div>
</div>

<script>
let allLogs = '';
let scanning = false;

function colorize(line){
  const m = line.match(/\[(SUCCESS|ERROR|SKIP|DUPLICATE|CORRUPT|SCAN)\]/);
  if(m) return `<span class="log-${m[1]}">${esc(line)}</span>`;
  return esc(line);
}

function esc(s){
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

function filterLogs(){
  const q = document.getElementById('log-filter').value.toLowerCase();
  const box = document.getElementById('logs');
  const lines = allLogs.split('\n');
  const filtered = q ? lines.filter(l=>l.toLowerCase().includes(q)) : lines;
  box.innerHTML = filtered.map(colorize).join('\n');
  box.scrollTop = box.scrollHeight;
}

function clearFilter(){
  document.getElementById('log-filter').value='';
  filterLogs();
}

async function loadLogs(){
  try{
    const r = await fetch('/logs');
    allLogs = await r.text();
    filterLogs();
  }catch{}
}

async function loadStats(){
  try{
    const r = await fetch('/stats');
    const d = await r.json();
    document.getElementById('s-total').textContent  = d.total  ?? '0';
    document.getElementById('s-images').textContent = d.images ?? '0';
    document.getElementById('s-videos').textContent = d.videos ?? '0';
    document.getElementById('s-dups').textContent   = d.duplicates ?? '0';

    const saved = (d.original_bytes - d.converted_bytes);
    document.getElementById('s-saved').textContent  = fmtBytes(saved);
  }catch{}
}

async function loadProgress(){
  if(!scanning) return;
  try{
    const r = await fetch('/progress');
    const d = await r.json();
    const pct = d.total > 0 ? Math.round(d.done/d.total*100) : 0;
    document.getElementById('pbar').style.width = pct+'%';
    document.getElementById('plabel').textContent = `${d.done}/${d.total}`;
    if(!d.running){
      scanning = false;
      setStatus('done','✓ complete');
      document.getElementById('btn-scan').disabled = false;
      setTimeout(()=>setStatus('','idle'),4000);
    }
  }catch{}
}

function setStatus(cls, text){
  const el = document.getElementById('scan-status');
  el.className = cls;
  el.textContent = text;
}

function fmtBytes(b){
  if(b==null||isNaN(b)) return '–';
  if(b<0) return '–';
  const gb = b/1e9;
  if(gb>=1) return gb.toFixed(1)+'GB';
  const mb = b/1e6;
  if(mb>=1) return mb.toFixed(0)+'MB';
  return Math.round(b/1e3)+'KB';
}

async function runScan(){
  document.getElementById('btn-scan').disabled = true;
  document.getElementById('pbar').style.width = '0%';
  document.getElementById('plabel').textContent = '…';
  setStatus('running','⟳ scanning');
  scanning = true;
  await fetch('/scan',{method:'POST'});
}

function copyWebhook(){
  navigator.clipboard.writeText('POST http://localhost:3000/webhook/process');
}

setInterval(loadLogs,      2500);
setInterval(loadStats,     5000);
setInterval(loadProgress,  1500);

loadLogs();
loadStats();
</script>
</body>
</html>
HTML

ok "GUI written"

# ============================================================
# INDEX.JS  (v3 — cross-device move fix + upgrades)
# ============================================================

cat > "$STACK_DIR/app/src/index.js" << 'NODE'
import express from 'express';
import fs from 'fs/promises';
import path from 'path';
import crypto from 'crypto';
import { exec } from 'child_process';
import { promisify } from 'util';

import pg from 'pg';
import { createClient } from 'redis';

const run = promisify(exec);

const app  = express();
const PORT = process.env.PORT || 3000;

const INPUT_DIR    = process.env.INPUT_DIR;
const OUTPUT_DIR   = process.env.OUTPUT_DIR;
const DUP_DIR      = process.env.DUP_DIR;
const PROCESSED_DIR= process.env.PROCESSED_DIR;
const EMPTY_DIR    = process.env.EMPTY_DIR;

// Per-file timeout in ms (default 30 min)
const FILE_TIMEOUT_MS = (parseInt(process.env.FILE_TIMEOUT_SEC) || 1800) * 1000;

const pool = new pg.Pool({
  host:     process.env.PGHOST,
  port:     process.env.PGPORT,
  database: process.env.PGDATABASE,
  user:     process.env.PGUSER,
  password: process.env.PGPASSWORD,
});

const redis = createClient({
  url: `redis://${process.env.REDIS_HOST}:${process.env.REDIS_PORT}`,
});
await redis.connect();

const IMAGE_EXTS = ['.jpg','.jpeg','.png','.webp'];
const VIDEO_EXTS = ['.mp4','.mov','.mkv'];

// ── Progress state ──────────────────────────────────────────
let progress = { running: false, total: 0, done: 0 };

// ── In-memory log ring buffer ───────────────────────────────
const logs = [];

function log(m){
  const line = `[${new Date().toISOString()}] ${m}`;
  console.log(line);
  logs.push(line);
  if(logs.length > 1000) logs.shift();
}

// ── SHA-256 ─────────────────────────────────────────────────
function sha256(buf){
  return crypto.createHash('sha256').update(buf).digest('hex');
}

// ── Cross-device-safe move ──────────────────────────────────
// fs.rename() fails with EXDEV when src and dst are on different
// mount points (e.g. a bind-mounted host volume).  We fall back
// to copy → unlink, which always works.
async function safeMove(src, dst){
  await fs.mkdir(path.dirname(dst), { recursive: true });
  try{
    await fs.rename(src, dst);
  }catch(err){
    if(err.code !== 'EXDEV') throw err;
    // Different filesystem — copy then delete
    await fs.copyFile(src, dst);
    await fs.unlink(src);
  }
}

// ── Recursive file scan ──────────────────────────────────────
async function recursiveFiles(dir){
  let results = [];
  const list = await fs.readdir(dir, { withFileTypes: true });

  if(list.length === 0 && dir !== INPUT_DIR){
    const target = path.join(EMPTY_DIR, path.basename(dir));
    await safeMove(dir, target).catch(()=>{});
    return [];
  }

  for(const entry of list){
    const full = path.join(dir, entry.name);
    if(entry.isDirectory()){
      results = results.concat(await recursiveFiles(full));
    }else{
      results.push(full);
    }
  }
  return results;
}

// ── DB helpers ───────────────────────────────────────────────
async function alreadyProcessed(filename){
  const r = await pool.query(
    'SELECT filename FROM media_files WHERE filename=$1 LIMIT 1',
    [filename]
  );
  return r.rowCount > 0;
}

async function duplicateHash(hash){
  const cached = await redis.get(`dup:${hash}`);
  if(cached) return true;
  const r = await pool.query(
    'SELECT sha256 FROM media_files WHERE sha256=$1 LIMIT 1',
    [hash]
  );
  return r.rowCount > 0;
}

async function cacheHash(hash){
  await redis.setEx(`dup:${hash}`, 604800, '1');
}

// ── Media validation ─────────────────────────────────────────
async function validateMedia(file){
  try{
    await run(`ffmpeg -v error -i "${file}" -f null -`, { timeout: 60_000 });
    return true;
  }catch{
    return false;
  }
}

// ── Compression ──────────────────────────────────────────────
async function compressImage(input, output){
  await run(
    `convert "${input}" -strip -quality 75 "${output}"`,
    { timeout: FILE_TIMEOUT_MS }
  );
}

async function compressVideo(input, output){
  // Write to a tmp path within the SAME directory as output to keep
  // the final rename on the same filesystem (avoids another EXDEV).
  const tmp = output + '.tmp.mp4';
  try{
    await run(
      `ffmpeg -y -i "${input}" -vcodec libx264 -crf 28 -preset medium ` +
      `-movflags +faststart -acodec aac "${tmp}"`,
      { timeout: FILE_TIMEOUT_MS }
    );
    await fs.rename(tmp, output);   // same FS — always safe
  }catch(err){
    await fs.unlink(tmp).catch(()=>{});
    throw err;
  }
}

// ── Process a single file ────────────────────────────────────
async function processFile(file){
  const stat = await fs.stat(file);
  if(!stat.isFile()) return;

  const ext     = path.extname(file).toLowerCase();
  const isImage = IMAGE_EXTS.includes(ext);
  const isVideo = VIDEO_EXTS.includes(ext);

  if(!isImage && !isVideo) return;

  const filename = path.basename(file);

  if(await alreadyProcessed(filename)){
    log(`[SKIP] ${filename} already processed`);
    return;
  }

  const buffer = await fs.readFile(file);
  const hash   = sha256(buffer);

  if(await duplicateHash(hash)){
    const dupTarget = path.join(DUP_DIR, filename);
    await safeMove(file, dupTarget);
    log(`[DUPLICATE] ${filename}`);
    return;
  }

  if(!await validateMedia(file)){
    log(`[CORRUPT] ${filename} — skipping`);
    return;
  }

  const base    = path.parse(filename).name;
  const profile = isImage ? 'jpg_q75' : 'mp4_h264_crf28';
  const outExt  = isImage ? '.jpg'    : '.mp4';
  const outName = `${base}__${profile}__${hash.slice(0,12)}${outExt}`;
  const outPath = path.join(OUTPUT_DIR, outName);

  if(isImage){
    await compressImage(file, outPath);
  }else{
    await compressVideo(file, outPath);
  }

  if(!await validateMedia(outPath)){
    await fs.unlink(outPath).catch(()=>{});
    log(`[FAILED] corrupt output for ${filename}`);
    return;
  }

  const outStat = await fs.stat(outPath);

  await pool.query(`
    INSERT INTO media_files(
      filename, sha256, original_path, converted_path,
      media_type, compression_profile, original_size, converted_size
    ) VALUES($1,$2,$3,$4,$5,$6,$7,$8)
    ON CONFLICT(filename) DO NOTHING
  `,[
    filename, hash, file, outPath,
    isImage ? 'image' : 'video',
    profile,
    stat.size,
    outStat.size,
  ]);

  await cacheHash(hash);

  // Move original to processed — cross-device safe
  await safeMove(file, path.join(PROCESSED_DIR, filename));

  log(`[SUCCESS] ${outName} (${(outStat.size/stat.size*100).toFixed(0)}% of original)`);
}

// ── Scan orchestrator ────────────────────────────────────────
async function scanAll(){
  if(progress.running){
    log('[SCAN] already running — skipped');
    return;
  }

  log('[SCAN] started');
  const files = await recursiveFiles(INPUT_DIR);

  progress = { running: true, total: files.length, done: 0 };

  for(const file of files){
    try{
      await processFile(file);
    }catch(err){
      log(`[ERROR] ${file} — ${err.message}`);
    }finally{
      progress.done++;
    }
  }

  progress.running = false;
  log('[SCAN] complete');
}

// ── Express routes ───────────────────────────────────────────
app.use(express.json());
app.use(express.static('public'));

app.post('/scan', async(req, res)=>{
  scanAll();                          // fire-and-forget
  res.send('Scan started');
});

app.post('/webhook/process', async(req, res)=>{
  scanAll();
  res.json({ success: true });
});

app.get('/logs', (req, res)=>{
  res.send(logs.join('\n'));
});

app.get('/progress', (req, res)=>{
  res.json(progress);
});

app.get('/stats', async(req, res)=>{
  const r = await pool.query(`
    SELECT
      COUNT(*)                                   AS total,
      COUNT(*) FILTER(WHERE media_type='image')  AS images,
      COUNT(*) FILTER(WHERE media_type='video')  AS videos,
      COALESCE(SUM(original_size),0)             AS original_bytes,
      COALESCE(SUM(converted_size),0)            AS converted_bytes
    FROM media_files
  `);

  const dupR = await pool.query(`
    SELECT COUNT(*) AS duplicates
    FROM (
      SELECT sha256, COUNT(*) c FROM media_files GROUP BY sha256 HAVING COUNT(*) > 1
    ) sub
  `);

  res.json({ ...r.rows[0], duplicates: dupR.rows[0].duplicates });
});

// ── Graceful shutdown ────────────────────────────────────────
async function shutdown(){
  log('[SHUTDOWN] draining…');
  // Give in-flight work up to 10 s to finish
  let waited = 0;
  while(progress.running && waited < 10000){
    await new Promise(r=>setTimeout(r,500));
    waited += 500;
  }
  await pool.end();
  await redis.quit();
  process.exit(0);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT',  shutdown);

// ── Start ────────────────────────────────────────────────────
app.listen(PORT, ()=> log(`GUI running on :${PORT}`));
NODE

ok "index.js written (v3)"

# ============================================================
# FINAL OUTPUT
# ============================================================

echo
ok "MEDIA GUI STACK v3 CREATED"
echo
echo "  GUI:       http://localhost:8080"
echo "  WEBHOOK:   POST http://localhost:3000/webhook/process"
echo "  INPUT:     $STACK_DIR/media/input"
echo "  OUTPUT:    $STACK_DIR/media/output"
echo "  PROCESSED: $STACK_DIR/media/processed"
echo "  DUPES:     $STACK_DIR/media/duplicates"
echo

if [ "$RUN_STACK" = true ]; then
  log "Starting stack..."
  cd "$STACK_DIR"
  docker compose up --build -d
  ok "STACK RUNNING"
fi