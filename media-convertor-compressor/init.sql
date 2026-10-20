CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS media_files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sha256 TEXT UNIQUE NOT NULL,

    original_name TEXT NOT NULL,
    compressed_name TEXT NOT NULL,

    media_type TEXT NOT NULL CHECK (media_type IN ('image','video')),

    compression_profile TEXT NOT NULL,

    original_size BIGINT,
    compressed_size BIGINT,

    original_path TEXT NOT NULL,
    compressed_path TEXT NOT NULL,

    width INT,
    height INT,
    duration_sec NUMERIC(10,2),

    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_media_sha256 ON media_files(sha256);
CREATE INDEX IF NOT EXISTS idx_media_type ON media_files(media_type);
CREATE INDEX IF NOT EXISTS idx_media_created ON media_files(created_at DESC);
