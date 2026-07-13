-- ============================================================
-- Migration 035: Separate delivery days for trade customers
-- JG Foods
-- ============================================================
-- THE PROBLEM (found 13 Jul): Jon set Tuesday as a usual day meaning
-- it for trade clients only — but the website shows every open day to
-- everyone, so domestic customers booked the trade Tuesday.
--
-- THE FIX: every delivery day now has an AUDIENCE:
--   'domestic' — home customers only (guests + domestic accounts)
--   'trade'    — approved trade accounts only
--   'both'     — anyone
--
-- Jon manages TWO usual-day lists in the admin (home days + trade
-- days). A weekday on both lists becomes a 'both' day. The website
-- shows domestic customers only domestic/both days, and approved
-- trade customers only trade/both days. place_order() enforces the
-- same rule server-side, so nobody can book the wrong day even by
-- fiddling with the page.
--
-- Settings:
--   usual_days  {days:[...]}  — home delivery days (existing)
--   trade_days  {days:[...]}  — trade delivery days (new)
--
-- Reusable AXRIK pattern: audience-scoped scheduling — any client
-- with two customer groups on different rounds gets this for free.
-- Safe + idempotent. Run AFTER 033 (needs is_approved_trade()).
-- ============================================================

-- ── 1. delivery_slots.audience ───────────────────────────────
ALTER TABLE delivery_slots
  ADD COLUMN IF NOT EXISTS audience text NOT NULL DEFAULT 'domestic';

ALTER TABLE delivery_slots
  DROP CONSTRAINT IF EXISTS delivery_slots_audience_check;
ALTER TABLE delivery_slots
  ADD CONSTRAINT delivery_slots_audience_check
  CHECK (audience IN ('domestic','trade','both'));

-- ── 2. trade_days setting (empty until Jon picks his days) ───
INSERT INTO app_settings (key, value)
VALUES ('trade_days', '{"days": []}')
ON CONFLICT (key) DO NOTHING;

-- ── 3. ensure_delivery_slots — now audience-aware ────────────
-- Same rolling auto-generation + holiday behaviour as migration 030,
-- plus: each generated day gets its audience from the two lists, and
-- future days on a CONFIGURED weekday are kept aligned with the lists
-- (so when Jon moves Tuesday from home to trade, already-generated
-- Tuesdays follow — the exact bug that bit us). One-off days Jon opens
-- on weekdays that are on NEITHER list keep whatever audience he chose.
CREATE OR REPLACE FUNCTION ensure_delivery_slots(p_days_ahead int DEFAULT 21)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dom       text[];
  v_trade     text[];
  v_capacity  int;
  v_cutoff    jsonb;
  v_db        int;
  v_hour      int;
  v_min       int;
  v_hol_from  date;
  v_hol_until date;
  v_d         date;
  v_dow       text;
  v_aud       text;
  v_cut       timestamptz;
BEGIN
  -- Home + trade usual days (either list may be empty)
  SELECT ARRAY(SELECT jsonb_array_elements_text(value->'days'))
    INTO v_dom FROM app_settings WHERE key = 'usual_days';
  SELECT ARRAY(SELECT jsonb_array_elements_text(value->'days'))
    INTO v_trade FROM app_settings WHERE key = 'trade_days';
  v_dom   := COALESCE(v_dom,   '{}');
  v_trade := COALESCE(v_trade, '{}');
  IF array_length(v_dom, 1) IS NULL AND array_length(v_trade, 1) IS NULL THEN
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

  -- ── Holiday suppression (unchanged from 030) ─────────────────
  IF v_hol_from IS NOT NULL AND v_hol_until IS NOT NULL AND v_hol_until > v_hol_from THEN
    DELETE FROM delivery_slots ds
    WHERE ds.delivery_date >= v_hol_from AND ds.delivery_date < v_hol_until
      AND NOT EXISTS (SELECT 1 FROM orders o WHERE o.delivery_slot_id = ds.id);
    UPDATE delivery_slots ds SET is_open = false
    WHERE ds.delivery_date >= v_hol_from AND ds.delivery_date < v_hol_until
      AND ds.is_open;
  END IF;

  -- ── Create / align usual-day runs across the horizon ─────────
  v_d := current_date;
  WHILE v_d <= current_date + p_days_ahead LOOP
    v_dow := trim(to_char(v_d, 'Day'));        -- 'Monday', 'Tuesday', …
    v_aud := CASE
      WHEN v_dow = ANY (v_dom) AND v_dow = ANY (v_trade) THEN 'both'
      WHEN v_dow = ANY (v_dom)                            THEN 'domestic'
      WHEN v_dow = ANY (v_trade)                          THEN 'trade'
      ELSE NULL
    END;

    IF v_aud IS NOT NULL
       AND NOT (v_hol_from IS NOT NULL AND v_hol_until IS NOT NULL
                AND v_d >= v_hol_from AND v_d < v_hol_until)
    THEN
      IF NOT EXISTS (SELECT 1 FROM delivery_slots WHERE delivery_date = v_d) THEN
        v_cut := ((v_d - v_db)::timestamp + make_time(v_hour, v_min, 0))
                 AT TIME ZONE 'Europe/London';
        INSERT INTO delivery_slots (delivery_date, day_label, capacity, cutoff_at, is_open, audience)
        VALUES (v_d, v_dow, v_capacity, v_cut, true, v_aud);
      ELSE
        -- Configured weekdays follow the settings — realign if changed
        UPDATE delivery_slots
        SET audience = v_aud
        WHERE delivery_date = v_d AND audience <> v_aud;
      END IF;
    END IF;
    v_d := v_d + 1;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION ensure_delivery_slots(int) TO anon, authenticated;

-- ── 4. place_order — enforce the audience server-side ────────
-- Identical to migration 028 except for the audience check after the
-- slot availability checks. Uses is_approved_trade() from 033.
CREATE OR REPLACE FUNCTION place_order(
  p_name           text,
  p_email          text,
  p_phone          text,
  p_address        text,
  p_postcode       text,
  p_slot_id        uuid,
  p_items          jsonb,
  p_customer_type  text DEFAULT 'domestic',
  p_channel        text DEFAULT 'website',
  p_notes          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid          uuid := auth.uid();   -- the signed-in customer, or NULL for a guest
  v_customer_id  uuid;
  v_order_id     uuid;
  v_slot         record;
  v_item         jsonb;
  v_ref          text;
BEGIN
  SELECT * INTO v_slot FROM delivery_slots WHERE id = p_slot_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Delivery slot not found');
  END IF;
  IF NOT v_slot.is_open THEN
    RETURN jsonb_build_object('error', 'Sorry, this delivery slot is now closed');
  END IF;
  IF v_slot.cutoff_at IS NOT NULL AND now() > v_slot.cutoff_at THEN
    RETURN jsonb_build_object('error', 'The order cut-off for this slot has passed');
  END IF;
  IF v_slot.orders_count >= v_slot.capacity THEN
    RETURN jsonb_build_object('error', 'Sorry, this delivery slot is fully booked');
  END IF;

  -- ── Audience check (new in 035) ────────────────────────────────────
  -- Trade days are for approved trade accounts; home days for everyone
  -- else. The website already filters the picker — this is the backstop.
  IF v_slot.audience = 'trade' AND NOT is_approved_trade() THEN
    RETURN jsonb_build_object('error', 'That delivery day is reserved for trade customers — please choose another day');
  END IF;
  IF v_slot.audience = 'domestic' AND is_approved_trade() THEN
    RETURN jsonb_build_object('error', 'That day is a home-delivery round — please choose one of your trade delivery days');
  END IF;

  -- ── Resolve the customer (from migration 028) ──────────────────────
  IF v_uid IS NOT NULL THEN
    SELECT id INTO v_customer_id FROM customers WHERE user_id = v_uid LIMIT 1;
  END IF;

  IF v_customer_id IS NULL AND p_email IS NOT NULL AND p_email <> '' THEN
    SELECT id INTO v_customer_id FROM customers
    WHERE lower(email) = lower(p_email) LIMIT 1;
    IF v_customer_id IS NOT NULL AND v_uid IS NOT NULL THEN
      UPDATE customers SET user_id = v_uid
      WHERE id = v_customer_id AND user_id IS NULL;
    END IF;
  END IF;

  IF v_customer_id IS NULL AND p_phone IS NOT NULL AND p_phone <> '' THEN
    SELECT id INTO v_customer_id FROM customers
    WHERE phone = p_phone LIMIT 1;
  END IF;

  IF v_customer_id IS NULL THEN
    INSERT INTO customers (name, email, phone, address_line_1, postcode, customer_type, user_id)
    VALUES (p_name, p_email, p_phone, p_address, p_postcode, p_customer_type, v_uid)
    RETURNING id INTO v_customer_id;
  END IF;
  -- ────────────────────────────────────────────────────────────────────

  INSERT INTO orders (customer_id, delivery_slot_id, channel, status, notes)
  VALUES (v_customer_id, p_slot_id, p_channel, 'pending', p_notes)
  RETURNING id INTO v_order_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO order_items (order_id, product_id, product_name, unit_price, quantity, unit)
    VALUES (
      v_order_id,
      (v_item->>'product_id')::uuid,
      v_item->>'product_name',
      (v_item->>'unit_price')::numeric,
      (v_item->>'quantity')::integer,
      COALESCE(v_item->>'unit', 'pack')
    );
  END LOOP;

  -- auto-create the receipt/invoice (never blocks the order)
  BEGIN
    PERFORM create_invoice_for_order(v_order_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  v_ref := 'JGF-' || upper(substring(v_order_id::text, 1, 6));

  RETURN jsonb_build_object(
    'success',    true,
    'order_id',   v_order_id,
    'reference',  v_ref,
    'slot_date',  v_slot.delivery_date,
    'slot_day',   v_slot.day_label
  );
END;
$$;

GRANT EXECUTE ON FUNCTION place_order TO anon, authenticated;

-- ── 5. One-time tidy-up for the days already in the table ────
-- Existing future slots default to 'domestic'; the first
-- ensure_delivery_slots() run realigns any weekday that Jon has on a
-- list. Nothing else to do here.

-- When to run: after 033. Safe + idempotent (CREATE OR REPLACE / IF NOT EXISTS).
-- ============================================================
