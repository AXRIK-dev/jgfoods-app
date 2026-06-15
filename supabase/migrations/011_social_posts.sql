-- ============================================================
-- Migration 011: Social posts (AI post generator)
-- JG Foods Admin App
-- ============================================================
-- Stores the social media posts Jon generates so that:
--   1. He has a history he can reuse / re-copy.
--   2. Recent posts can be fed to the AI as style examples, so each
--      new post sounds like Jon (the "learns what he posts" effect).
--
-- Generation itself is generation-only (no auto-publishing): Jon
-- copies the finished post and schedules it himself in Meta Business
-- Suite. So nothing here talks to Facebook/Instagram.
--
-- Admin-only: drivers have no business with marketing. anon gets nothing.
-- House-style defaults (CTAs, sign-off, hashtags) live in app_settings
-- under the 'social_style' key — no schema change needed for those.
-- ============================================================

CREATE TABLE IF NOT EXISTS social_posts (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_notes             text,                       -- what Jon typed in
  post_text             text NOT NULL,              -- the finished post
  included_availability boolean NOT NULL DEFAULT false,
  source                text NOT NULL DEFAULT 'template'
                          CHECK (source IN ('template','ai')),
  status                text NOT NULL DEFAULT 'draft'
                          CHECK (status IN ('draft','used')),
  created_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_social_posts_created_at
  ON social_posts (created_at DESC);

-- ── RLS: admin-only ───────────────────────────────────────────
ALTER TABLE social_posts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin manages social_posts" ON social_posts;
CREATE POLICY "Admin manages social_posts"
  ON social_posts FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

-- ── Seed default house style (idempotent) ─────────────────────
-- Stored in app_settings so Jon can edit it in the admin without a
-- migration. Only inserts if it isn't already there.
INSERT INTO app_settings (key, value)
VALUES (
  'social_style',
  jsonb_build_object(
    'channels',  '💬 DM to order  ·  🌐 jgfoodsnorthwest.com  ·  📞 07702 852704',
    'signoff',   'Thanks, Jon 😊',
    'hashtags',  '#JGFoods #FreshMeat #Ormskirk #WestLancashire #LocalButcher #MeatDelivery #HomeDelivery #SupportLocal'
  )
)
ON CONFLICT (key) DO NOTHING;
