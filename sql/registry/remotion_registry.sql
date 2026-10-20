SET timezone TO 'Africa/Johannesburg';
CREATE TABLE IF NOT EXISTS remotion_templates (
  id             SERIAL PRIMARY KEY,
  name           TEXT UNIQUE NOT NULL,
  composition_id TEXT NOT NULL,
  description    TEXT,
  fps            INT  NOT NULL DEFAULT 30 CHECK (fps BETWEEN 1 AND 120),
  max_width      INT  NOT NULL DEFAULT 1920,
  max_height     INT  NOT NULL DEFAULT 1080,
  transitions    JSONB NOT NULL DEFAULT '{"type":"xfade","duration_s":0.5}',
  motion         JSONB NOT NULL DEFAULT '{"kenburns":{"zoom_step":0.0008,"max_zoom":1.25},"speed_ramps":[]}',
  effects        JSONB NOT NULL DEFAULT '[]',
  layout         JSONB NOT NULL DEFAULT '{}',
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS trg_touch_remotion ON remotion_templates;
CREATE TRIGGER trg_touch_remotion BEFORE UPDATE ON remotion_templates
  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
INSERT INTO remotion_templates (name, composition_id, description, fps, motion, transitions) VALUES
 ('cineslide','CineSlide','Cinematic slow-zoom slideshow',24,
   '{"kenburns":{"zoom_step":0.0005,"max_zoom":1.2},"speed_ramps":[]}','{"type":"xfade","duration_s":1.0}'),
 ('reel','Reel','Fast social reel with speed ramps',30,
   '{"kenburns":{"zoom_step":0.0012,"max_zoom":1.35},"speed_ramps":[{"at":0.8,"rate":1.5}]}','{"type":"slide","duration_s":0.3}'),
 ('slideshow','Slideshow','Plain crossfade slideshow',30,
   '{"kenburns":{"zoom_step":0.0,"max_zoom":1.0},"speed_ramps":[]}','{"type":"xfade","duration_s":0.5}'),
 ('timelapse','Timelapse','Short-frame-time timelapse',60,
   '{"kenburns":{"zoom_step":0.0002,"max_zoom":1.1},"speed_ramps":[]}','{"type":"none","duration_s":0}')
ON CONFLICT (name) DO NOTHING;
