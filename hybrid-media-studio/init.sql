CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── Jobs ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS jobs (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_type      TEXT NOT NULL DEFAULT 'process'
                    CHECK (job_type IN ('process','render','organise','scan')),
    status        TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','running','done','failed','skipped')),
    preset        TEXT NOT NULL DEFAULT 'standard',
    threads       INT  NOT NULL DEFAULT 1,
    src_path      TEXT NOT NULL,
    output_path   TEXT,
    folder_name   TEXT,
    total_files   INT  DEFAULT 0,
    duration_sec  INT  DEFAULT 0,
    size_mb       NUMERIC(10,2) DEFAULT 0,
    render_opts   JSONB,
    started_at    TIMESTAMPTZ,
    finished_at   TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    error_msg     TEXT
);

-- ── Media catalogue ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS media (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id       UUID REFERENCES jobs(id) ON DELETE CASCADE,
    media_type   TEXT NOT NULL CHECK (media_type IN ('image','video','audio','render')),
    file_path    TEXT NOT NULL,
    folder_name  TEXT,
    file_name    TEXT,
    size_bytes   BIGINT,
    hash_md5     TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Events ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS events (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id       UUID REFERENCES jobs(id) ON DELETE CASCADE,
    event_type   TEXT NOT NULL,
    payload      JSONB,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Logs ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS logs (
    id           BIGSERIAL PRIMARY KEY,
    job_id       UUID REFERENCES jobs(id) ON DELETE SET NULL,
    level        TEXT NOT NULL DEFAULT 'info'
                   CHECK (level IN ('info','warn','error','debug')),
    message      TEXT NOT NULL,
    context      JSONB,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Render presets ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS render_presets (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name         TEXT UNIQUE NOT NULL,
    config       JSONB NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed default render presets
INSERT INTO render_presets (name, config) VALUES
  ('cineslide',  '{"fps":30,"durationPerImage":3,"transition":"fade","width":1920,"height":1080,"audio":true}'),
  ('reel',       '{"fps":60,"durationPerImage":1,"transition":"zoom","width":1080,"height":1920,"audio":true}'),
  ('slideshow',  '{"fps":24,"durationPerImage":5,"transition":"slide","width":1920,"height":1080,"audio":false}'),
  ('timelapse',  '{"fps":30,"durationPerImage":0.5,"transition":"cut","width":3840,"height":2160,"audio":false}')
ON CONFLICT (name) DO NOTHING;

-- ── Indexes ───────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_jobs_status     ON jobs(status);
CREATE INDEX IF NOT EXISTS idx_jobs_type       ON jobs(job_type);
CREATE INDEX IF NOT EXISTS idx_jobs_created    ON jobs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_media_job_id    ON media(job_id);
CREATE INDEX IF NOT EXISTS idx_media_type      ON media(media_type);
CREATE INDEX IF NOT EXISTS idx_events_job_id   ON events(job_id);
CREATE INDEX IF NOT EXISTS idx_logs_job_id     ON logs(job_id);
CREATE INDEX IF NOT EXISTS idx_logs_level      ON logs(level);

-- ── Views ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW global_error_logs AS
SELECT l.id, l.job_id, l.level, l.message, l.context, l.created_at,
       j.src_path, j.folder_name, j.preset, j.job_type
FROM logs l
LEFT JOIN jobs j ON j.id = l.job_id
WHERE l.level = 'error'
ORDER BY l.created_at DESC;

CREATE OR REPLACE VIEW job_summary AS
SELECT job_type, status, COUNT(*) as count,
       SUM(total_files) as total_files,
       SUM(size_mb) as total_mb
FROM jobs
GROUP BY job_type, status
ORDER BY job_type, status;
