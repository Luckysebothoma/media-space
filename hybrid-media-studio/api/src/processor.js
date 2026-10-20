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
