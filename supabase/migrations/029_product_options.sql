-- ============================================================
-- Migration 029: Per-product options (e.g. kebab seasoning)
-- JG Foods
-- ============================================================
-- Lets one product carry a customer-chosen variant instead of
-- needing a separate product per combination. Example: a single
-- "Chicken Kebab" product with options {Plain, Piri Piri, BBQ,
-- Garlic, Salt & Pepper, Cajun} — the shopfront stays tidy and the
-- other products don't get buried.
--
-- The chosen option is appended to the order line name at checkout
-- (e.g. "Chicken Kebab — Piri Piri"), so it flows through to the
-- order, the invoice/receipt AND the pick list automatically — Jon
-- sees exactly how many of each seasoning to make. No change to the
-- orders/order_items schema is needed.
--
--   options       = the list the customer picks from (NULL/empty = no choice)
--   option_label  = the dropdown heading, e.g. 'Seasoning' (defaults to 'Option')
--
-- Reusable AXRIK pattern: any product on any future build can offer a
-- simple single-choice variant with no extra tables.
-- Safe + idempotent.
-- ============================================================

ALTER TABLE products
  ADD COLUMN IF NOT EXISTS options      text[],
  ADD COLUMN IF NOT EXISTS option_label text;

-- Existing RLS already covers these columns:
--   • public/anon read of available products (no column restriction)
--   • admin full write
-- so no policy changes are required.

-- ── Keep chosen options when a customer edits their own order ─────────
-- edit_my_order (migration 023) re-snapshotted the line name from the
-- products table, which would drop a chosen option (e.g. the seasoning)
-- on any edit. This version honours a provided product_name when given,
-- so "Chicken Kebab — Piri Piri" survives an edit. Price stays
-- authoritative from the products table.
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

  DELETE FROM order_items WHERE order_id = p_order_id;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_pid := (v_item->>'product_id')::uuid;
    v_qty := GREATEST(1, COALESCE((v_item->>'quantity')::int, 1));
    SELECT name, price INTO v_name, v_price FROM products WHERE id = v_pid AND is_available = true;
    IF v_name IS NULL THEN CONTINUE; END IF;   -- skip anything no longer available
    -- Honour the chosen display name (incl. any option) if supplied
    IF COALESCE(v_item->>'product_name','') <> '' THEN
      v_name := v_item->>'product_name';
    END IF;
    INSERT INTO order_items (order_id, product_id, product_name, unit_price, quantity, unit)
    VALUES (p_order_id, v_pid, v_name, v_price, v_qty, 'pack');
    v_total := v_total + v_price * v_qty;
  END LOOP;

  UPDATE orders SET total_amount = v_total WHERE id = p_order_id;

  IF v_inv_id IS NOT NULL THEN
    DELETE FROM invoice_items WHERE invoice_id = v_inv_id;
    INSERT INTO invoice_items (invoice_id, description, unit_price, quantity)
    SELECT v_inv_id, product_name, unit_price, quantity FROM order_items WHERE order_id = p_order_id;
    UPDATE invoices SET total_amount = v_total WHERE id = v_inv_id;
  END IF;

  RETURN json_build_object('ok', true, 'total', v_total);
END;
$$;

GRANT EXECUTE ON FUNCTION edit_my_order(uuid, jsonb) TO authenticated;
-- ============================================================
