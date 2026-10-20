import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { renderMedia, selectComposition } from '@remotion/renderer';
import fs from 'fs/promises';
import path from 'path';

const app = new Hono();
const PORT = parseInt(process.env.PORT || '3100');
const RENDERS_DIR = process.env.RENDER_BASE || '/data/renders';
const AUDIO_DIR   = process.env.AUDIO_BASE  || '/data/audio';

app.get('/health', (c) => c.json({ ok: true, service: 'remotion-worker' }));

/**
 * POST /render
 * Body: {
 *   jobId, images: string[], audioPath?: string,
 *   fps, durationPerImage, transition, width, height,
 *   outputFile, muted
 * }
 */
app.post('/render', async (c) => {
  let body;
  try { body = await c.req.json(); } catch { return c.json({ error: 'Invalid JSON' }, 400); }

  const {
    jobId,
    images = [],
    audioPath = null,
    fps = 30,
    durationPerImage = 3,
    transition = 'fade',
    width = 1920,
    height = 1080,
    outputFile,
    muted = false,
  } = body;

  if (!images.length) return c.json({ error: 'images array is required' }, 400);
  if (!outputFile)    return c.json({ error: 'outputFile is required' }, 400);

  // Verify images exist
  const missing = [];
  for (const img of images) {
    try { await fs.access(img); } catch { missing.push(img); }
  }
  if (missing.length) return c.json({ error: 'Some images not found', missing }, 422);

  await fs.mkdir(path.dirname(outputFile), { recursive: true });

  // Build a self-contained Remotion bundle inline
  const totalFrames = Math.ceil(images.length * durationPerImage * fps);
  const framesPerImage = Math.ceil(durationPerImage * fps);
  const transitionFrames = Math.min(10, Math.floor(framesPerImage / 3));

  // Write a temporary composition file
  const bundleDir = `/tmp/remotion_bundle_${jobId || Date.now()}`;
  await fs.mkdir(bundleDir, { recursive: true });

  const compositionCode = `
import {Composition} from 'remotion';
import {SlideShow} from './Slideshow';
export const RemotionRoot = () => (
  <Composition
    id="HMS"
    component={SlideShow}
    durationInFrames={${totalFrames}}
    fps={${fps}}
    width={${width}}
    height={${height}}
    defaultProps={{
      images: ${JSON.stringify(images)},
      framesPerImage: ${framesPerImage},
      transitionFrames: ${transitionFrames},
      transition: "${transition}",
      audioSrc: ${audioPath && !muted ? JSON.stringify(audioPath) : 'null'},
      muted: ${muted},
    }}
  />
);
`;

  const slideshowCode = `
import {AbsoluteFill, Img, Audio, interpolate, useCurrentFrame, spring, useVideoConfig} from 'remotion';

export const SlideShow = ({images, framesPerImage, transitionFrames, transition, audioSrc, muted}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const imageIndex = Math.min(Math.floor(frame / framesPerImage), images.length - 1);
  const frameWithinSlide = frame % framesPerImage;
  const progress = frameWithinSlide / framesPerImage;

  const getOpacity = () => {
    if (transition === 'fade') {
      if (frameWithinSlide < transitionFrames) return frameWithinSlide / transitionFrames;
      if (frameWithinSlide > framesPerImage - transitionFrames) return (framesPerImage - frameWithinSlide) / transitionFrames;
      return 1;
    }
    return 1;
  };

  const getScale = () => {
    if (transition === 'zoom') return 1 + progress * 0.08;
    return 1;
  };

  const getTranslateX = () => {
    if (transition === 'slide') {
      if (frameWithinSlide < transitionFrames) return (1 - frameWithinSlide / transitionFrames) * 100;
      return 0;
    }
    return 0;
  };

  return (
    <AbsoluteFill style={{background:'#000'}}>
      <AbsoluteFill style={{
        opacity: getOpacity(),
        transform: \`scale(\${getScale()}) translateX(\${getTranslateX()}%)\`,
      }}>
        <Img src={images[imageIndex]}
          style={{width:'100%',height:'100%',objectFit:'cover'}} />
      </AbsoluteFill>
      {audioSrc && !muted && (
        <Audio src={audioSrc} />
      )}
    </AbsoluteFill>
  );
};
`;

  await fs.writeFile(path.join(bundleDir, 'index.jsx'), compositionCode);
  await fs.writeFile(path.join(bundleDir, 'Slideshow.jsx'), slideshowCode);
  await fs.writeFile(path.join(bundleDir, 'package.json'), JSON.stringify({
    name: 'remotion-bundle', version: '1.0.0', type: 'module',
    dependencies: { remotion: '^4.0.0' }
  }));

  try {
    const composition = await selectComposition({
      serveUrl: bundleDir,
      id: 'HMS',
    });

    await renderMedia({
      composition,
      serveUrl: bundleDir,
      codec: 'h264',
      outputLocation: outputFile,
      chromiumOptions: {
        executablePath: process.env.CHROME_PATH || '/usr/bin/chromium',
        disableWebSecurity: true,
      },
      concurrency: 2,
    });

    const stat = await fs.stat(outputFile);
    await fs.rm(bundleDir, { recursive: true, force: true });

    return c.json({
      ok: true,
      outputFile,
      sizeBytes: stat.size,
      sizeMb: parseFloat((stat.size / 1024 / 1024).toFixed(2)),
      images: images.length,
      totalFrames,
      fps,
    });
  } catch (err) {
    await fs.rm(bundleDir, { recursive: true, force: true }).catch(() => {});
    return c.json({ error: err.message }, 500);
  }
});

/**
 * GET /audio — list available audio files
 */
app.get('/audio', async (c) => {
  try {
    await fs.mkdir(AUDIO_DIR, { recursive: true });
    const entries = await fs.readdir(AUDIO_DIR, { withFileTypes: true });
    const files = entries
      .filter(e => e.isFile() && /\.(mp3|wav|aac|ogg|m4a|flac)$/i.test(e.name))
      .map(e => ({
        name: e.name,
        path: path.join(AUDIO_DIR, e.name),
      }));
    return c.json({ audio: files, count: files.length });
  } catch (err) {
    return c.json({ error: err.message }, 500);
  }
});

serve({ fetch: app.fetch, port: PORT }, () => {
  console.log(`[REMOTION] Worker ready on :${PORT}`);
});
