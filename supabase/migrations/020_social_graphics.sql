-- ============================================================
-- Migration 020: Brand graphics studio storage
-- JG Foods Admin App
-- ============================================================
-- Backs the "Graphics" page: Jon generates branded social graphics,
-- saves them to the app, and reopens them later to edit / re-download.
--
-- - social_graphics: one row per saved graphic (the editable spec +
--   a link to the exported PNG). Admin-only.
-- - social-graphics storage bucket: public-read so the saved PNG can
--   be viewed/downloaded; admin-only write.
-- ============================================================

-- 1. Table ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS social_graphics (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title       text NOT NULL DEFAULT 'Untitled graphic',
  template    text NOT NULL DEFAULT 'availability',
  spec        jsonb NOT NULL DEFAULT '{}',     -- headline, items, footer, etc (editable)
  png_url     text,                            -- exported image in storage
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_social_graphics_updated_at ON social_graphics;
CREATE TRIGGER trg_social_graphics_updated_at
  BEFORE UPDATE ON social_graphics
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE social_graphics ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin manages social_graphics" ON social_graphics;
CREATE POLICY "Admin manages social_graphics"
  ON social_graphics FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

-- 2. Storage bucket ------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('social-graphics', 'social-graphics', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- Public can read the PNGs (so they open/share); only logged-in admin writes.
DROP POLICY IF EXISTS "social-graphics public read"  ON storage.objects;
CREATE POLICY "social-graphics public read"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'social-graphics');

DROP POLICY IF EXISTS "social-graphics admin write" ON storage.objects;
CREATE POLICY "social-graphics admin write"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'social-graphics');

DROP POLICY IF EXISTS "social-graphics admin update" ON storage.objects;
CREATE POLICY "social-graphics admin update"
  ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'social-graphics')
  WITH CHECK (bucket_id = 'social-graphics');

-- When to run: after 012/015. Safe + idempotent on the live database.
-- ============================================================
