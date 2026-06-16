-- ============================================================
-- Migration 013: Auto-create an invoice/receipt for every order
-- JG Foods Admin App
-- ============================================================
-- Every order now generates a record automatically:
--   • domestic customer  -> a RECEIPT  (marked paid, no due date)
--   • trade/commercial   -> an INVOICE (status 'sent', 30-day terms)
-- Line items are copied from the order. This runs for BOTH order
-- paths: the website (place_order RPC) and manual Log Order in the
-- admin app (which calls create_invoice_for_order directly).
--
-- It is IDEMPOTENT: one invoice per order. Calling it twice for the
-- same order returns the existing invoice and creates nothing new.
--
-- Also fixes a data-model mismatch: the admin app writes
-- customer_type = 'trade', but the original CHECK only allowed
-- 'domestic'/'commercial', so trade-customer saves were failing
-- silently. Section 1 relaxes the constraint to allow all three.
-- ============================================================

-- 1. Allow the 'trade' customer_type the app actually uses --------------
ALTER TABLE customers DROP CONSTRAINT IF EXISTS customers_customer_type_check;
ALTER TABLE customers ADD  CONSTRAINT customers_customer_type_check
  CHECK (customer_type IN ('domestic','commercial','trade'));

-- 2. Sequence for sequential invoice numbers ---------------------------
CREATE SEQUENCE IF NOT EXISTS invoice_number_seq START 1000;

-- 3. The function: build an invoice/receipt from an order -------------
CREATE OR REPLACE FUNCTION create_invoice_for_order(p_order_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order     record;
  v_cust      record;
  v_existing  uuid;
  v_invoice   uuid;
  v_type      text;
  v_prefix    text;
  v_number    text;
  v_total     numeric(10,2);
BEGIN
  -- idempotent: one invoice per order
  SELECT id INTO v_existing FROM invoices WHERE order_id = p_order_id LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_cust FROM customers WHERE id = v_order.customer_id;

  -- receipt for domestic, invoice for everyone else (commercial/trade)
  v_type := CASE WHEN v_cust.customer_type = 'domestic' THEN 'receipt' ELSE 'invoice' END;

  -- prefix: the customer's set prefix, else initials of their name
  -- (first letter of up to 3 words), else 'INV'
  v_prefix := COALESCE(
    NULLIF(v_cust.invoice_prefix, ''),
    NULLIF(upper(array_to_string(ARRAY(
      SELECT left(w, 1)
      FROM unnest(regexp_split_to_array(trim(v_cust.name), '\s+')) AS w
      LIMIT 3
    ), '')), ''),
    'INV'
  );

  v_number := v_prefix || '-' || lpad(nextval('invoice_number_seq')::text, 4, '0');

  -- total from order items (authoritative); fall back to the order total
  SELECT COALESCE(SUM(line_total), 0) INTO v_total
  FROM order_items WHERE order_id = p_order_id;
  IF v_total = 0 THEN
    v_total := COALESCE(v_order.total_amount, 0);
  END IF;

  INSERT INTO invoices (
    invoice_number, customer_id, order_id, invoice_type, status,
    issued_at, due_at, paid_at, subtotal, vat_amount, total_amount
  ) VALUES (
    v_number, v_cust.id, p_order_id, v_type,
    CASE WHEN v_type = 'receipt' THEN 'paid' ELSE 'sent' END,
    now(),
    CASE WHEN v_type = 'invoice' THEN now() + interval '30 days' ELSE NULL END,
    CASE WHEN v_type = 'receipt' THEN now() ELSE NULL END,
    v_total, 0, v_total
  ) RETURNING id INTO v_invoice;

  -- copy the order lines onto the invoice
  INSERT INTO invoice_items (invoice_id, description, unit_price, quantity)
  SELECT v_invoice, product_name, unit_price, quantity
  FROM order_items WHERE order_id = p_order_id;

  RETURN v_invoice;
END;
$$;

-- Admin (authenticated) calls this directly from Log Order; the
-- place_order RPC (SECURITY DEFINER) calls it for website orders.
GRANT EXECUTE ON FUNCTION create_invoice_for_order(uuid) TO authenticated;

-- 4. Hook it into the website order path (place_order) ----------------
-- Same as migration 003, with one added line: after the items are in,
-- create the invoice/receipt. Wrapped so a hiccup here never blocks the
-- order itself.
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

  SELECT id INTO v_customer_id
  FROM customers
  WHERE (email = p_email AND p_email IS NOT NULL AND p_email != '')
     OR (phone = p_phone AND p_phone IS NOT NULL AND p_phone != '')
  LIMIT 1;

  IF v_customer_id IS NULL THEN
    INSERT INTO customers (name, email, phone, address_line_1, postcode, customer_type)
    VALUES (p_name, p_email, p_phone, p_address, p_postcode, p_customer_type)
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

  -- NEW: auto-create the receipt/invoice (never blocks the order)
  BEGIN
    PERFORM create_invoice_for_order(v_order_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- order still succeeds even if invoice creation fails
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

GRANT EXECUTE ON FUNCTION place_order TO anon;

-- ============================================================
-- NOTES
-- • Auto-invoicing EVERY trade order means trade customers get an
--   invoice per order, not the weekly consolidated bill in the Bank
--   Payments sheet. Phil chose this knowingly (16 Jun 2026). If trade
--   should instead be weekly, change v_type handling or skip non-domestic
--   here and invoice trade from a weekly run later.
-- • VAT is recorded as 0 (gross only) — same reason as migration 012's
--   invoice notes: the zero-rated vs standard-rated split needs Jon's call.
-- • Backfill (optional) — create receipts/invoices for orders that already
--   exist and have none:
--     SELECT create_invoice_for_order(o.id) FROM orders o
--     LEFT JOIN invoices i ON i.order_id = o.id
--     WHERE i.id IS NULL AND o.status <> 'cancelled';
-- ============================================================
