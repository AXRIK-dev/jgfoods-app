-- ============================================================
-- Migration 024: Mix & match offers on categories
-- JG Foods
-- ============================================================
-- Lets Jon turn a category into a "pick N for £X" offer (e.g. a
-- "Special offers" category set to "pick 3 for £15"). Any product he
-- puts in that category becomes part of the deal. On the website each
-- item is priced at the deal rate (deal_price ÷ deal_qty) and customers
-- choose them in multiples of deal_qty.
--
-- Both columns NULL = a normal category (no offer).
-- ============================================================

ALTER TABLE categories
  ADD COLUMN IF NOT EXISTS deal_qty   integer,
  ADD COLUMN IF NOT EXISTS deal_price numeric(10,2);

-- Make customer order-editing deal-aware: products in an offer category
-- are priced at the deal rate (deal_price ÷ deal_qty), not their own price.
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
  v_dqty     int;
  v_dprice   numeric(10,2);
BEGIN
  IF v_uid IS NULL THEN
    RETURN json_build_object('error', 'Please sign in to change your order.');
  END IF;

  SELECT o.customer_id, o.delivery_slot_id INTO v_customer, v_slot
  FROM orders o JOIN customers c ON c.id = o.customer_id
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
    SELECT p.name, p.price, c.deal_qty, c.deal_price
      INTO v_name, v_price, v_dqty, v_dprice
    FROM products p LEFT JOIN categories c ON c.name = p.category
    WHERE p.id = v_pid AND p.is_available = true;
    IF v_name IS NULL THEN CONTINUE; END IF;
    IF v_dqty IS NOT NULL AND v_dprice IS NOT NULL AND v_dqty > 0 THEN
      v_price := round(v_dprice / v_dqty, 2);   -- mix & match deal rate
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

-- When to run: after 017 (categories) and 023 (edit_my_order). Safe + idempotent.
-- ============================================================
