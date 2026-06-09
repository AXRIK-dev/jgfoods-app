-- ============================================================
-- Migration 003: place_order RPC
-- JG Foods Admin App
-- ============================================================
-- Public can call this function to place an order without
-- having direct insert access to orders or customers tables.
-- Runs as SECURITY DEFINER so it can write to locked tables.
-- Enforces slot capacity and cut-off before inserting.

CREATE OR REPLACE FUNCTION place_order(
  p_name           text,
  p_email          text,
  p_phone          text,
  p_address        text,
  p_postcode       text,
  p_slot_id        uuid,
  p_items          jsonb,  -- [{product_id, product_name, unit_price, quantity, unit}]
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

  -- 1. Check slot exists, is open, and hasn't hit capacity or cut-off
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

  -- 2. Find or create customer (match on email, fallback to phone)
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

  -- 3. Create the order
  INSERT INTO orders (customer_id, delivery_slot_id, channel, status, notes)
  VALUES (v_customer_id, p_slot_id, p_channel, 'pending', p_notes)
  RETURNING id INTO v_order_id;

  -- 4. Insert order items
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

  -- 5. Build a short human-readable reference
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

-- Allow anonymous callers (website visitors) to call this function
GRANT EXECUTE ON FUNCTION place_order TO anon;
