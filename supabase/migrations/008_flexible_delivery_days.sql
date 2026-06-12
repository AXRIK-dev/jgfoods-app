-- ============================================================
-- Migration 008: Flexible delivery days
-- JG Foods Admin App
-- ============================================================
-- Jon's delivery days are not fixed. He needs to:
--   - take planned or last-minute days off
--   - add one-off delivery days on ANY weekday (e.g. a Friday)
--   - keep a set of "usual" days that appear automatically each week
--
-- Two changes:
--   1. Relax the day_label constraint so any weekday is allowed.
--   2. Add an app_settings table holding Jon's usual days + defaults,
--      so the admin app knows which days to auto-open each week.
--
-- Slot generation itself lives in the admin app (visible, easy to
-- adjust) — this migration just relaxes the schema and stores config.
-- ============================================================

-- ── 1. Allow delivery on any day of the week ─────────────────
-- The original constraint locked day_label to Monday/Wednesday/Thursday.
ALTER TABLE delivery_slots
  DROP CONSTRAINT IF EXISTS delivery_slots_day_label_check;

ALTER TABLE delivery_slots
  ADD CONSTRAINT delivery_slots_day_label_check
  CHECK (day_label IN (
    'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'
  ));

-- ── 2. app_settings: simple key/value store for business config ──
-- Reusable across AXRIK builds — any setting Jon (or a future client)
-- can change without a code deploy lives here.
CREATE TABLE IF NOT EXISTS app_settings (
  key         text PRIMARY KEY,
  value       jsonb NOT NULL DEFAULT '{}',
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Auto-update updated_at (reuses the function created in migration 001)
DROP TRIGGER IF EXISTS trg_app_settings_updated_at ON app_settings;
CREATE TRIGGER trg_app_settings_updated_at
  BEFORE UPDATE ON app_settings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── 3. Seed Jon's defaults ───────────────────────────────────
-- usual_days        : weekdays that auto-open each week
-- default_capacity  : max orders per run
-- default_cutoff    : how the cut-off time is derived for a new slot
--                     (the evening before the delivery day)
INSERT INTO app_settings (key, value) VALUES
  ('usual_days',       '{"days": ["Monday","Wednesday","Thursday"]}'),
  ('default_capacity', '{"value": 50}'),
  ('default_cutoff',   '{"days_before": 1, "hour": 23, "minute": 59}')
ON CONFLICT (key) DO NOTHING;

-- ── 4. RLS ───────────────────────────────────────────────────
ALTER TABLE app_settings ENABLE ROW LEVEL SECURITY;

-- Settings hold no secrets (usual days, capacity) — safe to read publicly
-- so the website could surface "we deliver on…" if ever needed.
CREATE POLICY "Public read app_settings"
  ON app_settings FOR SELECT
  USING (true);

-- Only the logged-in admin can change settings.
CREATE POLICY "Admin write app_settings"
  ON app_settings FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');
