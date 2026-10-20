import client from 'prom-client';

const PREFIX = process.env.METRICS_PREFIX || 'i2v_';
export const register = new client.Registry();

client.collectDefaultMetrics({ register, prefix: PREFIX });

export const jobsStartedTotal = new client.Counter({
  name: `${PREFIX}jobs_started_total`,
  help: 'Total number of conversion jobs started',
  labelNames: ['mode', 'preset', 'engine'],
  registers: [register],
});

export const jobsCompletedTotal = new client.Counter({
  name: `${PREFIX}jobs_completed_total`,
  help: 'Total number of conversion jobs completed successfully',
  labelNames: ['mode', 'preset', 'engine'],
  registers: [register],
});

export const jobsFailedTotal = new client.Counter({
  name: `${PREFIX}jobs_failed_total`,
  help: 'Total number of conversion jobs that failed',
  labelNames: ['mode', 'preset', 'engine'],
  registers: [register],
});

export const imagesProcessedTotal = new client.Counter({
  name: `${PREFIX}images_processed_total`,
  help: 'Total number of source images processed',
  labelNames: ['mode'],
  registers: [register],
});

export const renderDurationSeconds = new client.Histogram({
  name: `${PREFIX}render_duration_seconds`,
  help: 'Wall-clock time spent inside ffmpeg per output clip',
  labelNames: ['mode', 'preset'],
  buckets: [1, 5, 15, 30, 60, 120, 300, 600, 1200],
  registers: [register],
});

export const outputSizeMb = new client.Histogram({
  name: `${PREFIX}output_size_mb`,
  help: 'Size in MB of rendered output files',
  labelNames: ['mode', 'preset'],
  buckets: [1, 5, 10, 25, 50, 100, 250, 500],
  registers: [register],
});

export const remotesMountedGauge = new client.Gauge({
  name: `${PREFIX}remotes_mounted`,
  help: 'Number of remote sources currently mounted',
  registers: [register],
});

export const remoteMountFailuresTotal = new client.Counter({
  name: `${PREFIX}remote_mount_failures_total`,
  help: 'Total number of failed remote mount attempts',
  labelNames: ['protocol'],
  registers: [register],
});
