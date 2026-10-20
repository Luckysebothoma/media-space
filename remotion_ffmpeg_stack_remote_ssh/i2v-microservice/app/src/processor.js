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
