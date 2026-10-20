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
