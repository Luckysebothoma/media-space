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

    // Use copyFile + unlink instead of rename to support cross-device moves
    // (fs.rename fails with EXDEV when source and destination are on different
    // filesystem mount points, which is common with Docker volumes)
    await fs.copyFile(filePath, dupPath);
    await fs.unlink(filePath);

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
