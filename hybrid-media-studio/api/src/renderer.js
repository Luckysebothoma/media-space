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
