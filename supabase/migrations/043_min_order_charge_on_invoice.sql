-- ============================================================
-- Migration 043: Put the £5 small-order charge on the invoice
-- JG Foods
-- ============================================================
--
-- The charge has always been display-only. The website showed "a £5 delivery
-- charge has been added" and quoted a total including it, then placed an order
-- built purely from the basket lines — so the order, the invoice and the day's
-- takings were all £5 light. Customers were being invoiced less than the site
-- told them they'd pay, on every under-£20 order since launch.
--
-- The fix is to make the charge a real order line, added server-side. Doing it
-- in the database rather than the browser means it's applied identically to a
-- website order, a customer editing their order afterwards, and an order Jon
-- types in himself — and a customer can't remove it by editing the request.
--
-- orders.total_amount and the invoice both pick the line up on their own: the
-- trigger from migration 001 recalculates the order total whenever order_items
-- change, and create_invoice_for_order (013) copies the lines across.
--
-- Run AFTER 042 (which adds customers.exempt_min_charge).

-- ── 1. Mark the charge line so it's never mistaken for a product ──
-- String-matching a description would break the moment the wording changed.
ALTER TABLE order_items
  ADD COLUMN IF NOT EXISTS is_surcharge boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN order_items.is_surcharge IS
  'True for the automatic small-order charge line, so it can be recalculated '
  'without touching the customer''s actual items.';


-- ── 2. The threshold and the amount live in settings ─────────────
-- They were hardcoded in the website, the admin app and now the database;
-- three copies of one number is a bug waiting to happen. app_settings is
-- publicly readable (migration 008), so both front-ends read the same values.
INSERT INTO app_settings (key, value)
VALUES ('min_order', '{"threshold": 20, "charge": 5, "label": "Small-order charge"}')
ON CONFLICT (key) DO NOTHING;


-- ── 3. Apply (or remove) the charge on an order ───────────────────
-- Safe to call as often as you like — it always rebuilds from scratch, so it
-- both adds the charge and takes it away again when a customer tops their
-- order up over the threshold.
CREATE OR REPLACE FUNCTION apply_min_order_charge(p_order_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cfg        jsonb;
  v_threshold  numeric;
  v_charge     numeric;
  v_label      text;
  v_exempt     boolean;
  v_subtotal   numeric(10,2);
  v_unpriced   int;
BEGIN
  SELECT value INTO v_cfg FROM app_settings WHERE key = 'min_order';
  v_threshold := COALESCE((v_cfg->>'threshold')::numeric, 20);
  v_charge    := COALESCE((v_cfg->>'charge')::numeric, 5);
  v_label     := COALESCE(v_cfg->>'label', 'Small-order charge');

  -- Start clean: drop any charge line already on the order.
  DELETE FROM order_items WHERE order_id = p_order_id AND is_surcharge;

  SELECT COALESCE(SUM(line_total), 0),
         COUNT(*) FILTER (WHERE unit_price IS NULL OR unit_price = 0)
    INTO v_subtotal, v_unpriced
    FROM order_items WHERE order_id = p_order_id;

  -- A trade order can be logged with prices still to agree — those lines read
  -- as £0, which would look like a small order and wrongly attract the charge.
  -- Leave it alone until the order has a real value.
  IF v_unpriced > 0 THEN
    RETURN v_subtotal;
  END IF;

  SELECT c.exempt_min_charge INTO v_exempt
    FROM orders o JOIN customers c ON c.id = o.customer_id
   WHERE o.id = p_order_id;

  IF COALESCE(v_exempt, false) OR v_subtotal <= 0 OR v_subtotal >= v_threshold THEN
    RETURN v_subtotal;
  END IF;

  INSERT INTO order_items (order_id, product_id, product_name, unit_price, quantity, unit, is_surcharge)
  VALUES (p_order_id, NULL,
          v_label || ' (orders under £' || trim(to_char(v_threshold, 'FM999999.99')) || ')',
          v_charge, 1, 'each', true);

  RETURN v_subtotal + v_charge;
END;
$$;

GRANT EXECUTE ON FUNCTION apply_min_order_charge(uuid) TO authenticated;


-- ── 4. Website orders ─────────────────────────────────────────────
-- Same as the version in 035, with the charge applied after the items go in
-- and before the invoice is raised, so the invoice includes it.
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

  -- Audience check (035): trade days for approved trade accounts only
  IF v_slot.audience = 'trade' AND NOT is_approved_trade() THEN
    RETURN jsonb_build_object('error', 'That delivery day is reserved for trade customers — please choose another day');
  END IF;
  IF v_slot.audience = 'domestic' AND is_approved_trade() THEN
    RETURN jsonb_build_object('error', 'That day is a home-delivery round — please choose one of your trade delivery days');
  END IF;

  -- Resolve the customer (028)
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

  -- NEW in 043 — the small-order charge becomes a real line before the
  -- invoice is raised, so what's billed matches what the website quoted.
  PERFORM apply_min_order_charge(v_order_id);

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


-- ── 5. Customers editing their own order ──────────────────────────
-- Same as 023, but the charge is recalculated after the items are rebuilt.
-- This is the case that matters most: add enough to pass £20 and the charge
-- comes off by itself; strip the order back below £20 and it returns.
CREATE OR REPLACE FUNCTION edit_my_order(p_order_id uuid, p_items jsonb)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_customer uuid;
  v_slot     uuid;
  v_is_open  boolean;
  v_cutoff   timestamptz;
  v_inv_id   uuid;
  v_inv_stat text;
  v_total    numeric(10,2) := 0;
  v_item     jsonb;
  v_pid      uuid;
  v_qty      int;
  v_name     text;
  v_price    numeric(10,2);
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('error', 'Please sign in to change your order.');
  END IF;

  SELECT o.customer_id, o.delivery_slot_id INTO v_customer, v_slot
  FROM orders o
  JOIN customers c ON c.id = o.customer_id
  WHERE o.id = p_order_id AND c.user_id = v_uid;
  IF v_customer IS NULL THEN
    RETURN json_build_object('error', 'We could not find that order on your account.');
  END IF;

  SELECT i.id, i.status INTO v_inv_id, v_inv_stat
  FROM invoices i WHERE i.order_id = p_order_id LIMIT 1;
  IF v_inv_stat = 'paid'
     OR (v_inv_id IS NOT NULL AND EXISTS (SELECT 1 FROM invoice_payments p WHERE p.invoice_id = v_inv_id)) THEN
    RETURN json_build_object('error', 'This order has already been paid, so it can no longer be changed online. Please call Jon on 07702 852704.');
  END IF;

  SELECT is_open, cutoff_at INTO v_is_open, v_cutoff FROM delivery_slots WHERE id = v_slot;
  IF v_is_open IS NOT TRUE OR (v_cutoff IS NOT NULL AND v_cutoff <= now()) THEN
    RETURN json_build_object('error', 'The cut-off for this delivery has passed, so the order can no longer be changed online. Please call Jon on 07702 852704.');
  END IF;

  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN json_build_object('error', 'Your order needs at least one item.');
  END IF;

  -- Rebuild the items (prices from the products table)
  DELETE FROM order_items WHERE order_id = p_order_id;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_pid := (v_item->>'product_id')::uuid;
    v_qty := GREATEST(1, COALESCE((v_item->>'quantity')::int, 1));
    SELECT name, price INTO v_name, v_price FROM products WHERE id = v_pid AND is_available = true;
    IF v_name IS NULL THEN CONTINUE; END IF;   -- skip anything no longer available
    INSERT INTO order_items (order_id, product_id, product_name, unit_price, quantity, unit)
    VALUES (p_order_id, v_pid, v_name, v_price, v_qty, 'pack');
  END LOOP;

  -- NEW in 043 — add or drop the small-order charge for the new basket size
  PERFORM apply_min_order_charge(p_order_id);

  -- Total now comes from the lines themselves, charge included
  SELECT COALESCE(SUM(line_total), 0) INTO v_total
    FROM order_items WHERE order_id = p_order_id;

  UPDATE orders SET total_amount = v_total WHERE id = p_order_id;

  -- Keep the linked invoice in step
  IF v_inv_id IS NOT NULL THEN
    DELETE FROM invoice_items WHERE invoice_id = v_inv_id;
    INSERT INTO invoice_items (invoice_id, description, unit_price, quantity)
    SELECT v_inv_id, product_name, unit_price, quantity FROM order_items WHERE order_id = p_order_id;
    UPDATE invoices SET subtotal = v_total, total_amount = v_total WHERE id = v_inv_id;
  END IF;

  RETURN json_build_object('ok', true, 'total', v_total);
END;
$$;

GRANT EXECUTE ON FUNCTION edit_my_order(uuid, jsonb) TO authenticated;

-- Nothing is backdated. Orders already placed keep the totals they were
-- invoiced at — going back and adding £5 to bills Jon has already sent, and
-- in many cases already been paid for, would cause far more trouble than the
-- money is worth.
