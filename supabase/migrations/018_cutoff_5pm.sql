-- ============================================================
-- Migration 018: Delivery cut-off 5pm (was 23:59)
-- JG Foods Admin App
-- ============================================================
-- WHY: Orders must be in by 5pm the DAY BEFORE each delivery so Jon
-- has time to buy stock and load the van. Migration 008 seeded the
-- cut-off as 23:59; this moves it to 17:00. The seeded row overrides
-- the app's code default, so this update is required — a code change
-- alone won't take effect.
--
-- SAFE + IDEMPOTENT: re-running this produces the same end state.
-- ============================================================

-- 1. Update the stored default so newly-opened slots use 5pm -------------
UPDATE app_settings
   SET value = '{"days_before": 1, "hour": 17, "minute": 0}'
 WHERE key = 'default_cutoff';

-- (create it if it is somehow missing)
INSERT INTO app_settings (key, value)
VALUES ('default_cutoff', '{"days_before": 1, "hour": 17, "minute": 0}')
ON CONFLICT (key) DO NOTHING;

-- 2. Move every existing FUTURE slot to 5pm the day before its delivery --
--    cutoff_at is timestamptz; build the 17:00 wall-time in UK local time
--    (Europe/London handles BST/GMT automatically) and store the instant.
UPDATE delivery_slots
   SET cutoff_at = (((delivery_date - INTERVAL '1 day')::date + TIME '17:00')
                    AT TIME ZONE 'Europe/London')
 WHERE delivery_date >= CURRENT_DATE;

-- 3. Check (optional) — confirm the new cut-offs:
--    SELECT delivery_date, day_label, cutoff_at
--    FROM delivery_slots WHERE delivery_date >= CURRENT_DATE
--    ORDER BY delivery_date;
-- ============================================================
