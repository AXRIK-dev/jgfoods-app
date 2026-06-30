-- ============================================================
-- Migration 030: Auto-generate delivery days + holiday mode
-- JG Foods
-- ============================================================
-- Until now a "usual day" only appeared on the website once Jon
-- manually clicked "Open this day" for that date — a weekly chore.
-- This adds ensure_delivery_slots(): it makes sure open slots exist
-- for the usual weekdays across the coming weeks, rolling forward
-- forever with no action from Jon. The website calls it on load, so
-- the next delivery days are always there for customers.
--
-- It also honours a HOLIDAY window stored in app_settings:
--   key 'holiday' = { "from": "YYYY-MM-DD", "until": "YYYY-MM-DD" }
--   (from = first day off, until = the RETURN date — first day back).
-- During a holiday the function won't create runs, removes any
-- order-free runs already in that window, and closes any that still
-- have orders (Jon is warned in the admin so he can rebook). Clear the
-- holiday and the usual days regenerate automatically.
--
-- Settings used (all from migration 008's app_settings):
--   usual_days       {days:[...]}
--   default_capacity {value:int}
--   default_cutoff   {days_before,hour,minute}
--   holiday          {from,until}   (optional)
--
-- Reusable AXRIK pattern: hands-off recurring scheduling for any
-- future client. Safe + idempotent.
-- ============================================================

CREATE OR REPLACE FUNCTION ensure_delivery_slots(p_days_ahead int DEFAULT 21)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_days      text[];
  v_capacity  int;
  v_cutoff    jsonb;
  v_db        int;
  v_hour      int;
  v_min       int;
  v_hol_from  date;
  v_hol_until date;
  v_d         date;
  v_dow       text;
  v_cut       timestamptz;
BEGIN
  -- Usual weekdays (nothing to do if none set)
  SELECT ARRAY(SELECT jsonb_array_elements_text(value->'days'))
    INTO v_days FROM app_settings WHERE key = 'usual_days';
  IF v_days IS NULL OR array_length(v_days, 1) IS NULL THEN
    RETURN;
  END IF;

  SELECT COALESCE((value->>'value')::int, 50) INTO v_capacity
    FROM app_settings WHERE key = 'default_capacity';
  v_capacity := COALESCE(v_capacity, 50);

  SELECT value INTO v_cutoff FROM app_settings WHERE key = 'default_cutoff';
  v_db   := COALESCE((v_cutoff->>'days_before')::int, 1);
  v_hour := COALESCE((v_cutoff->>'hour')::int, 17);
  v_min  := COALESCE((v_cutoff->>'minute')::int, 0);

  SELECT (value->>'from')::date, (value->>'until')::date
    INTO v_hol_from, v_hol_until FROM app_settings WHERE key = 'holiday';

  -- ── Holiday suppression ──────────────────────────────────────
  IF v_hol_from IS NOT NULL AND v_hol_until IS NOT NULL AND v_hol_until > v_hol_from THEN
    -- remove order-free runs in the window (clean — they regenerate after)
    DELETE FROM delivery_slots ds
    WHERE ds.delivery_date >= v_hol_from AND ds.delivery_date < v_hol_until
      AND NOT EXISTS (SELECT 1 FROM orders o WHERE o.delivery_slot_id = ds.id);
    -- close any that still have orders (can't delete; Jon rebooks them)
    UPDATE delivery_slots ds SET is_open = false
    WHERE ds.delivery_date >= v_hol_from AND ds.delivery_date < v_hol_until
      AND ds.is_open;
  END IF;

  -- ── Create missing usual-day runs across the horizon ─────────
  v_d := current_date;
  WHILE v_d <= current_date + p_days_ahead LOOP
    v_dow := trim(to_char(v_d, 'Day'));        -- 'Monday', 'Tuesday', …
    IF v_dow = ANY (v_days)
       AND NOT (v_hol_from IS NOT NULL AND v_hol_until IS NOT NULL
                AND v_d >= v_hol_from AND v_d < v_hol_until)
       AND NOT EXISTS (SELECT 1 FROM delivery_slots WHERE delivery_date = v_d)
    THEN
      v_cut := ((v_d - v_db)::timestamp + make_time(v_hour, v_min, 0))
               AT TIME ZONE 'Europe/London';
      INSERT INTO delivery_slots (delivery_date, day_label, capacity, cutoff_at, is_open)
      VALUES (v_d, v_dow, v_capacity, v_cut, true);
    END IF;
    v_d := v_d + 1;
  END LOOP;
END;
$$;

-- The website (anon) calls this on load; the admin (authenticated) too.
GRANT EXECUTE ON FUNCTION ensure_delivery_slots(int) TO anon, authenticated;

-- When to run: after 008 (app_settings + flexible days). Safe + idempotent.
-- ============================================================
