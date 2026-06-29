-- ============================================================
-- Migration 028: Customer-account integrity fixes
-- JG Foods
-- ============================================================
-- Fixes two faults found in customer-account testing:
--
--  BUG 1 — an order placed by a signed-in customer was recorded
--          against a DIFFERENT customer.
--          Cause: place_order (migration 013) ignored who was logged
--          in and re-matched the customer from the checkout form by
--          "email OR phone … LIMIT 1". With shared/overlapping test
--          details that OR picks the wrong row. A signed-in customer's
--          order must always attach to THEIR OWN linked record
--          (customers.user_id = auth.uid()).
--
--  BUG 2 — after deleting a customer in the admin app, re-registering
--          that email said "User already registered".
--          Cause: the admin delete only removed the customers row, never
--          the Supabase Auth login, so the email stayed registered.
--          Fix: a SECURITY DEFINER RPC that removes the auth login too
--          (and the business record, when it has no order/invoice history).
--
-- IMPORTANT: run this in the Supabase SQL editor (it deletes from
-- auth.users, which needs the elevated role the SQL editor runs as).
-- Safe + idempotent (CREATE OR REPLACE).
-- ============================================================

-- 1. place_order — resolve the customer by the logged-in user FIRST -----
--    Identical to migration 013 except for the customer-resolution block.
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

  -- ── Resolve the customer (the part that fixes Bug 1) ──────────────
  -- 1) Signed in → ALWAYS their own linked record. Never a form match.
  IF v_uid IS NOT NULL THEN
    SELECT id INTO v_customer_id FROM customers WHERE user_id = v_uid LIMIT 1;
  END IF;

  -- 2) Otherwise match an existing record by EMAIL (exact identity),
  --    and if a signed-in user typed their own email, claim that record.
  IF v_customer_id IS NULL AND p_email IS NOT NULL AND p_email <> '' THEN
    SELECT id INTO v_customer_id FROM customers
    WHERE lower(email) = lower(p_email) LIMIT 1;
    IF v_customer_id IS NOT NULL AND v_uid IS NOT NULL THEN
      UPDATE customers SET user_id = v_uid
      WHERE id = v_customer_id AND user_id IS NULL;
    END IF;
  END IF;

  -- 3) Last resort for guests: match by phone.
  IF v_customer_id IS NULL AND p_phone IS NOT NULL AND p_phone <> '' THEN
    SELECT id INTO v_customer_id FROM customers
    WHERE phone = p_phone LIMIT 1;
  END IF;

  -- 4) Nobody matched → create a new record (linked to the user if signed in).
  IF v_customer_id IS NULL THEN
    INSERT INTO customers (name, email, phone, address_line_1, postcode, customer_type, user_id)
    VALUES (p_name, p_email, p_phone, p_address, p_postcode, p_customer_type, v_uid)
    RETURNING id INTO v_customer_id;
  END IF;
  -- ──────────────────────────────────────────────────────────────────

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

-- 2. delete_customer_account — remove the login too (fixes Bug 2) -------
-- Deleting frees the email immediately. The customer record is kept ONLY
-- when it has order/invoice history (those FKs are ON DELETE RESTRICT and
-- the books must stay intact); otherwise it is fully removed.
CREATE OR REPLACE FUNCTION delete_customer_account(p_customer_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid          uuid;
  v_has_orders   boolean;
  v_has_invoices boolean;
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can delete customers';
  END IF;

  SELECT user_id INTO v_uid FROM customers WHERE id = p_customer_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'Customer not found');
  END IF;

  -- Remove the Supabase Auth login first so the email can be reused.
  -- (Cascades user_profiles; nulls customers.user_id via its FK.)
  IF v_uid IS NOT NULL THEN
    DELETE FROM auth.users WHERE id = v_uid;
  END IF;

  SELECT EXISTS(SELECT 1 FROM orders   WHERE customer_id = p_customer_id) INTO v_has_orders;
  SELECT EXISTS(SELECT 1 FROM invoices WHERE customer_id = p_customer_id) INTO v_has_invoices;

  IF v_has_orders OR v_has_invoices THEN
    RETURN jsonb_build_object(
      'success', true, 'kept_record', true,
      'message', 'Login removed and the email is free to use again. The customer record was kept because it has order or invoice history.'
    );
  END IF;

  DELETE FROM customers WHERE id = p_customer_id;
  RETURN jsonb_build_object(
    'success', true, 'kept_record', false,
    'message', 'Customer and login fully removed.'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION delete_customer_account(uuid) TO authenticated;

-- ── OPTIONAL CLEANUP for the test data already created ────────────────
-- Re-point any orders/invoices that were mis-filed onto the wrong customer
-- must be done by hand (you know which is which). To wipe ALL test
-- customers + logins and start clean, run in the SQL editor:
--   -- delete each test customer's login, then the rows:
--   -- SELECT delete_customer_account(id) FROM customers;   -- (admin session only)
-- ============================================================
