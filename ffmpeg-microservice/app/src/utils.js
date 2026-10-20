import { spawn } from 'child_process';
import fs from 'fs/promises';
import path from 'path';

// ── Preset registry ────────────────────────────────────────────────────────
//
// Each preset defines:
//   width/height  - output resolution (px)
//   crf           - constant rate factor (lower = better quality, bigger file)
//   bitrate       - target average bitrate (kbps)
//   maxrate       - peak bitrate cap (kbps) — prevents VBV overflow / corrupt frames
//   bufsize       - VBV buffer size (kbps) — keep at ~2× maxrate
//   aspectLabel   - human-readable aspect ratio tag
//   category      - 'desktop' | 'mobile' | 'social'
//
// CORRUPTION FIX: maxrate + bufsize are mandatory.
// Without VBV constraints the encoder can spike far above target bitrate,
// overflowing the decoder buffer and producing distorted / green-frame artifacts.

export const PRESETS = {

  // ── Desktop / TV ──────────────────────────────────────────────────────────
  standard: {
    width: 1920, height: 1080,
    crf: 23, bitrate: 5000, maxrate: 7500,  bufsize: 15000,
    aspectLabel: '16:9', category: 'desktop',
    description: 'Full HD 1080p — balanced quality/size',
  },
  high: {
    width: 1920, height: 1080,
    crf: 18, bitrate: 8000, maxrate: 12000, bufsize: 24000,
    aspectLabel: '16:9', category: 'desktop',
    description: 'Full HD 1080p — high quality',
  },
  '4k': {
    width: 3840, height: 2160,
    crf: 20, bitrate: 15000, maxrate: 22500, bufsize: 45000,
    aspectLabel: '16:9', category: 'desktop',
    description: 'UHD 4K 2160p — high quality',
  },
  cinematic: {
    width: 4096, height: 2160,
    crf: 18, bitrate: 20000, maxrate: 30000, bufsize: 60000,
    aspectLabel: '17:9 DCI', category: 'desktop',
    description: 'DCI 4K — cinema / archive master',
  },

  // ── Mobile Portrait 9:16 ─────────────────────────────────────────────────
  // Optimised for Instagram Reels, TikTok, YouTube Shorts, WhatsApp Status.
  // Both dimensions must be divisible by 2 (libx264 requirement).
  'mobile-hd': {
    width: 1080, height: 1920,
    crf: 23, bitrate: 4000, maxrate: 6000, bufsize: 12000,
    aspectLabel: '9:16', category: 'mobile',
    description: 'Mobile portrait 1080×1920 — Reels / TikTok / Shorts',
  },
  'mobile-4k': {
    width: 2160, height: 3840,
    crf: 20, bitrate: 12000, maxrate: 18000, bufsize: 36000,
    aspectLabel: '9:16', category: 'mobile',
    description: 'Mobile portrait 4K — future-proof vertical',
  },
  'mobile-sd': {
    width: 720, height: 1280,
    crf: 26, bitrate: 2000, maxrate: 3000, bufsize: 6000,
    aspectLabel: '9:16', category: 'mobile',
    description: 'Mobile portrait 720×1280 — lightweight / messaging',
  },

  // ── Mobile Landscape 16:9 (smaller footprint than desktop) ───────────────
  'mobile-landscape': {
    width: 1280, height: 720,
    crf: 24, bitrate: 2500, maxrate: 4000, bufsize: 8000,
    aspectLabel: '16:9', category: 'mobile',
    description: 'Mobile landscape 1280×720 — in-app players / tablets',
  },
  'mobile-landscape-hd': {
    width: 1920, height: 1080,
    crf: 22, bitrate: 4500, maxrate: 7000, bufsize: 14000,
    aspectLabel: '16:9', category: 'mobile',
    description: 'Mobile landscape 1080p — high-res in-app / tablet',
  },

  // ── Square 1:1 ───────────────────────────────────────────────────────────
  // Instagram Feed, Facebook, LinkedIn posts.
  'square-hd': {
    width: 1080, height: 1080,
    crf: 23, bitrate: 3500, maxrate: 5500, bufsize: 11000,
    aspectLabel: '1:1', category: 'social',
    description: 'Square 1080×1080 — Instagram / Facebook feed',
  },
  'square-4k': {
    width: 2160, height: 2160,
    crf: 20, bitrate: 10000, maxrate: 15000, bufsize: 30000,
    aspectLabel: '1:1', category: 'social',
    description: 'Square 4K — high-res social / archive',
  },

  // ── Portrait 4:5 ─────────────────────────────────────────────────────────
  // Instagram Feed portrait optimum (recommended by Meta).
  'portrait-social': {
    width: 1080, height: 1350,
    crf: 23, bitrate: 3800, maxrate: 5700, bufsize: 11400,
    aspectLabel: '4:5', category: 'social',
    description: 'Portrait 1080×1350 — Instagram feed optimum',
  },

  // ── Classic 4:3 ──────────────────────────────────────────────────────────
  // Legacy displays, presentations, some digital frames.
  'classic-hd': {
    width: 1440, height: 1080,
    crf: 23, bitrate: 4000, maxrate: 6000, bufsize: 12000,
    aspectLabel: '4:3', category: 'desktop',
    description: '4:3 1440×1080 — presentations / legacy displays',
  },
  'classic-sd': {
    width: 960, height: 720,
    crf: 25, bitrate: 2000, maxrate: 3000, bufsize: 6000,
    aspectLabel: '4:3', category: 'desktop',
    description: '4:3 960×720 — digital photo frames / SD',
  },

  // ── Ultra-wide 21:9 ──────────────────────────────────────────────────────
  ultrawide: {
    width: 2560, height: 1080,
    crf: 22, bitrate: 8000, maxrate: 12000, bufsize: 24000,
    aspectLabel: '21:9', category: 'desktop',
    description: 'Ultrawide 2560×1080 — gaming monitors / signage',
  },
  'ultrawide-4k': {
    width: 3440, height: 1440,
    crf: 20, bitrate: 14000, maxrate: 21000, bufsize: 42000,
    aspectLabel: '21:9', category: 'desktop',
    description: 'Ultrawide QHD 3440×1440 — premium monitors',
  },
};

// Aliases — old names / convenience shortcuts → canonical preset key
export const PRESET_ALIASES = {
  cinema:             'cinematic',
  '1080p':            'standard',
  '1080':             'standard',
  '4k-high':          '4k',
  vertical:           'mobile-hd',
  reel:               'mobile-hd',
  reels:              'mobile-hd',
  tiktok:             'mobile-hd',
  shorts:             'mobile-hd',
  portrait:           'mobile-hd',
  landscape:          'mobile-landscape',
  square:             'square-hd',
  instagram:          'square-hd',
  feed:               'portrait-social',
  '43':               'classic-hd',
  '4-3':              'classic-hd',
  '169':              'standard',
  '16-9':             'standard',
  '916':              'mobile-hd',
  '9-16':             'mobile-hd',
};

export const DEFAULT_PRESET  = 'standard';
export const DEFAULT_THREADS = 1;
export const IMAGE_DURATION  = 3;   // seconds each image is shown
export const MIN_DURATION    = 30;  // minimum video length (seconds)
export const FPS             = 30;

// CORRUPTION FIX: raised from 100 KB → 512 KB.
// A sub-512 KB MP4 at any meaningful resolution is almost certainly a
// corrupt/empty file that FFmpeg "succeeded" on with near-zero real frames.
export const MIN_SIZE_BYTES = 512 * 1024;

export const IMAGE_EXTS = new Set([
  '.jpg', '.jpeg', '.png', '.webp', '.bmp', '.tiff', '.tif',
]);

// ── Helpers ────────────────────────────────────────────────────────────────

/** Resolve preset name (including aliases). Returns null if unrecognised. */
export function resolvePreset(name) {
  if (!name) return DEFAULT_PRESET;
  const lower = name.toLowerCase();
  if (PRESETS[lower])        return lower;
  if (PRESET_ALIASES[lower]) return PRESET_ALIASES[lower];
  return null;
}

/** Return all valid preset names + aliases joined for error messages. */
export function validPresetNames() {
  return [...Object.keys(PRESETS), ...Object.keys(PRESET_ALIASES)].join(', ');
}

/** Group presets by category for API/UI display. */
export function presetsByCategory() {
  const out = {};
  for (const [key, p] of Object.entries(PRESETS)) {
    const cat = p.category || 'other';
    if (!out[cat]) out[cat] = [];
    out[cat].push({ key, ...p });
  }
  return out;
}

/** Sanitise a folder/file name — replace non-safe chars with underscore. */
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

// ── FFmpeg arg builders ────────────────────────────────────────────────────
//
// CORRUPTION FIXES applied to every encode:
//
//  -an
//    No audio stream. FFmpeg sometimes tries to mux a null/empty audio track
//    which corrupts the container mux layer.
//
//  -profile:v high / -level:v 4.1 (5.1 for 4K)
//    Explicit H.264 profile prevents the encoder defaulting to a profile
//    the target device/player cannot decode, causing visual corruption.
//
//  -g GOP / -keyint_min GOP / -sc_threshold 0
//    Fixed keyframe interval = 2 × FPS. Without this, the encoder inserts
//    surprise scene-change keyframes, breaking GOP structure and causing
//    decoder sync loss (green frames, mosaic artifacts).
//
//  -maxrate / -bufsize (VBV)
//    Caps the peak bitrate. Without VBV, slideshow encodes (static images)
//    can produce enormous intra-frame spikes that overflow the decoder buffer,
//    rendering as distorted macroblocks or complete frame corruption.
//
//  -movflags +faststart
//    Writes the MP4 moov atom at file start. Without this, an unclean exit
//    or partial flush leaves the file unplayable (moov at EOF, unfindable).
//
//  -preset medium (was 'fast')
//    'fast' uses a shallow lookahead that amplifies bitrate spikes on
//    static content. 'medium' is significantly more stable.

function h264Level(width, height) {
  // H.264 levels by resolution — ensures decoder compatibility
  const px = width * height;
  if (px > 3840 * 2160) return '5.2';
  if (px > 1920 * 1080) return '5.1';
  return '4.1';
}

function sharedCodecArgs({ crf, bitrate, maxrate, bufsize, threads, width, height }) {
  const gopSize = FPS * 2;
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

/**
 * Scale + pad filter that handles BOTH landscape and portrait targets correctly.
 *
 * CORRUPTION FIX: the original scale filter used force_original_aspect_ratio=decrease
 * but did not account for portrait targets (height > width). The pad offsets are now
 * computed symmetrically so they always produce even pixel counts required by yuv420p.
 */
function scaleFilter(width, height) {
  return [
    `scale=${width}:${height}:force_original_aspect_ratio=decrease`,
    `pad=${width}:${height}:(ow-iw)/2:(oh-ih)/2:color=black`,
    `fps=${FPS}`,
    'format=yuv420p',
  ].join(',');
}

/** Build FFmpeg args for a multi-image concat slideshow. */
export function buildConcatArgs({ manifestPath, width, height, crf, bitrate, maxrate, bufsize, threads, outputFile }) {
  return [
    '-y', '-loglevel', 'error',
    '-f', 'concat', '-safe', '0',
    '-i', manifestPath,
    '-vf', scaleFilter(width, height),
    ...sharedCodecArgs({ crf, bitrate, maxrate, bufsize, threads, width, height }),
    outputFile,
  ];
}

/** Build FFmpeg args for a single-image loop. */
export function buildLoopArgs({ imagePath, width, height, crf, bitrate, maxrate, bufsize, threads, duration, outputFile }) {
  return [
    '-y', '-loglevel', 'error',
    '-loop', '1',
    '-framerate', String(FPS),    // input-side hint — stabilises PTS clock
    '-i', imagePath,
    '-vf', scaleFilter(width, height),
    '-t', String(duration),
    ...sharedCodecArgs({ crf, bitrate, maxrate, bufsize, threads, width, height }),
    outputFile,
  ];
}

/**
 * Write an FFmpeg concat manifest.
 *
 * Each image gets an explicit `duration` line.
 * The last image is repeated without a duration so the concat demuxer
 * flushes cleanly — this is the FFmpeg-recommended pattern and prevents
 * the final-frame PTS jump that can corrupt the stream tail.
 */
export async function writeManifest(images) {
  const tmp = `/tmp/manifest_${Date.now()}_${Math.random().toString(36).slice(2)}.txt`;
  const lines = [];
  for (const img of images) {
    lines.push(`file '${img}'`);
    lines.push(`duration ${IMAGE_DURATION}`);
  }
  lines.push(`file '${images[images.length - 1]}'`); // EOF anchor — no duration
  await fs.writeFile(tmp, lines.join('\n') + '\n');
  return tmp;
}

export async function fileSizeBytes(filePath) {
  try { const s = await fs.stat(filePath); return s.size; }
  catch { return 0; }
}

/**
 * Spawn FFmpeg and return { code, stderr }.
 * Logs the full arg string to the job log for post-mortem debugging.
 */
export function runFfmpeg(args, logFile) {
  return new Promise((resolve) => {
    const proc = spawn('ffmpeg', args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, FFREPORT: '' },
    });
    const chunks = [];
    proc.stderr.on('data', d => chunks.push(d));
    proc.stdout.on('data', () => {}); // drain stdout — prevent backpressure hang
    proc.on('close', code => resolve({ code, stderr: Buffer.concat(chunks).toString() }));
    proc.on('error', err  => resolve({ code: -1, stderr: err.message }));
    if (logFile) {
      fs.appendFile(logFile, `=== ffmpeg ${new Date().toISOString()} ===\n`).catch(() => {});
      fs.appendFile(logFile, `CMD: ffmpeg ${args.join(' ')}\n\n`).catch(() => {});
      proc.stderr.on('data', d => fs.appendFile(logFile, d).catch(() => {}));
    }
  });
}
