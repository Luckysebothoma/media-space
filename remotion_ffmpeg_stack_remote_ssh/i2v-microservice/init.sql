CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS jobs (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    status        TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','running','done','failed','skipped')),
    mode          TEXT NOT NULL DEFAULT 'grouped'
                    CHECK (mode IN ('grouped','singles')),
    engine        TEXT NOT NULL DEFAULT 'ffmpeg',
    preset        TEXT,
    ratio         TEXT,
    transition    TEXT,
    motion        TEXT,
    fps           INT  DEFAULT 30,
    threads       INT  NOT NULL DEFAULT 1,
    src_path      TEXT NOT NULL,
    remote_id     UUID,
    output_path   TEXT,
    folder_name   TEXT,
    total_images  INT  DEFAULT 0,
    total_outputs INT  DEFAULT 0,
    duration_sec  INT  DEFAULT 0,
    size_mb       NUMERIC(10,2) DEFAULT 0,
    started_at    TIMESTAMPTZ,
    finished_at   TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    error_msg     TEXT
);

CREATE TABLE IF NOT EXISTS events (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id     UUID REFERENCES jobs(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,
    payload    JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS logs (
    id         BIGSERIAL PRIMARY KEY,
    job_id     UUID REFERENCES jobs(id) ON DELETE SET NULL,
    level      TEXT NOT NULL DEFAULT 'info'
                 CHECK (level IN ('info','warn','error','debug')),
    message    TEXT NOT NULL,
    context    JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS media (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_id      UUID REFERENCES jobs(id) ON DELETE CASCADE,
    media_type  TEXT NOT NULL CHECK (media_type IN ('image','video')),
    file_path   TEXT NOT NULL,
    folder_name TEXT,
    file_name   TEXT,
    size_bytes  BIGINT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Remote source locations (SSH or SMB). Credentials are NEVER stored
-- here in plaintext — secret_ref points to a file under
-- SSH_KEY_DIR/SMB_CRED_DIR on the app container's filesystem.
CREATE TABLE IF NOT EXISTS remotes (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name         TEXT UNIQUE NOT NULL,
    protocol     TEXT NOT NULL CHECK (protocol IN ('ssh','smb')),
    host         TEXT NOT NULL,
    port         INT  NOT NULL DEFAULT 22,
    username     TEXT,
    auth_type    TEXT NOT NULL DEFAULT 'key' CHECK (auth_type IN ('key','password')),
    secret_ref   TEXT,             -- filename under SSH_KEY_DIR / SMB_CRED_DIR
    remote_path  TEXT NOT NULL,    -- e.g. /export/photos  or  sharename/subdir
    domain       TEXT,             -- SMB only
    mount_point  TEXT,             -- computed: MOUNT_ROOT/<name>
    status       TEXT NOT NULL DEFAULT 'unmounted'
                    CHECK (status IN ('unmounted','mounted','error')),
    last_error   TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_jobs_status      ON jobs(status);
CREATE INDEX IF NOT EXISTS idx_jobs_created_at  ON jobs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_job_id    ON events(job_id);
CREATE INDEX IF NOT EXISTS idx_logs_job_id      ON logs(job_id);
CREATE INDEX IF NOT EXISTS idx_logs_level       ON logs(level);
CREATE INDEX IF NOT EXISTS idx_media_job_id     ON media(job_id);
CREATE INDEX IF NOT EXISTS idx_remotes_status   ON remotes(status);

CREATE OR REPLACE VIEW global_error_logs AS
SELECT l.id, l.job_id, l.level, l.message, l.context, l.created_at,
       j.src_path, j.folder_name, j.preset
FROM logs l
LEFT JOIN jobs j ON j.id = l.job_id
WHERE l.level = 'error'
ORDER BY l.created_at DESC;
