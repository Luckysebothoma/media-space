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
