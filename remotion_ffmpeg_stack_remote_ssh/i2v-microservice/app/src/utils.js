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
