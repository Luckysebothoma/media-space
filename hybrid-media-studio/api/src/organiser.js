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
