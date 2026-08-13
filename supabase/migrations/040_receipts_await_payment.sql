-- ============================================================
-- Migration 040: A receipt isn't paid until the money is recorded
-- JG Foods Admin App
-- ============================================================
-- THE PROBLEM
-- Domestic orders create a RECEIPT, and because those customers pay at
-- the door the receipt was stamped 'paid' the moment it was created —
-- before any money had actually been logged against it.
--
-- That left the two screens contradicting each other:
--
--   Delivery run   -> "Awaiting payment", with the Cash / Bank buttons
--                     (it reads the actual invoice_payments rows)
--   Invoices page  -> "PAID", and no Log payment button at all
--                     (it reads invoices.status)
--
-- Working from the delivery run, everything is right. But if Jon
-- glanced at the Invoices page and took a domestic receipt at its word,
-- he'd never mark it — and since Daily Sales is built from recorded
-- payments (migration 037), that money silently never reached his
-- takings. An invoice claiming to be paid while nothing has been banked
-- is the one thing a set of books must never do.
--
-- THE FIX
-- Receipts are now created awaiting payment, exactly like invoices, and
-- become 'paid' when Jon records the cash or bank transfer — which is
-- also the moment the money reaches Daily Sales. One source of truth.
--
-- Existing receipts are deliberately NOT changed. We can't know from
-- here which were genuinely paid in cash and simply never recorded, and
-- retroactively marking a customer's receipt unpaid is not a decision
-- this migration should make. The admin app now shows those with a
-- "no payment recorded" note and a Log payment button so Jon can settle
-- them as he comes across them.
--
-- SAFE TO RE-RUN. Replaces one function; changes no existing rows.
-- ============================================================

CREATE OR REPLACE FUNCTION create_invoice_for_order(p_order_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order      record;
  v_cust       record;
  v_site       record;
  v_existing   uuid;
  v_invoice    uuid;
  v_open_inv   uuid;
  v_type       text;
  v_number     text;
  v_total      numeric(10,2);
  v_deliv      date;
  v_wk_start   date;
  v_wk_end     date;
  v_label      text;
BEGIN
  -- Idempotent on both paths: never invoice the same order twice.
  SELECT id INTO v_existing FROM invoices WHERE order_id = p_order_id LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT invoice_id INTO v_existing FROM orders WHERE id = p_order_id;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_cust FROM customers WHERE id = v_order.customer_id;

  -- Receipt for domestic, invoice for commercial/trade (unchanged).
  v_type := CASE WHEN v_cust.customer_type = 'domestic' THEN 'receipt' ELSE 'invoice' END;

  -- Order total from its items, falling back to the order's own total.
  SELECT COALESCE(SUM(line_total), 0) INTO v_total
  FROM order_items WHERE order_id = p_order_id;
  IF v_total = 0 THEN
    v_total := COALESCE(v_order.total_amount, 0);
  END IF;

  -- Site heading for this order's lines, if it's going to a named site.
  v_site  := NULL;
  v_label := NULL;
  IF v_order.site_id IS NOT NULL THEN
    SELECT * INTO v_site FROM customer_sites WHERE id = v_order.site_id;
    v_label := COALESCE(
      v_site.label,
      NULLIF(concat_ws(', ', v_site.address_line_1, v_site.postcode), '')
    );
  END IF;

  v_deliv := jg_order_delivery_date(p_order_id);

  -- ── Per-delivery: one invoice for this order, issued now ──
  IF COALESCE(v_cust.billing_mode, 'per_delivery') <> 'weekly' THEN
    v_number := jg_next_invoice_number(v_cust.id);

    INSERT INTO invoices (
      invoice_number, customer_id, order_id, invoice_type, status,
      issued_at, due_at, paid_at, subtotal, vat_amount, total_amount
    ) VALUES (
      v_number, v_cust.id, p_order_id, v_type,
      -- CHANGED IN 040: a receipt now awaits payment like everything else.
      -- It becomes 'paid' when Jon records the cash or bank transfer, which
      -- is the same moment the money reaches Daily Sales.
      'sent',
      now(),
      -- 30-day terms apply to trade invoices; a doorstep receipt has none.
      CASE WHEN v_type = 'invoice' THEN now() + interval '30 days' ELSE NULL END,
      NULL,
      v_total, 0, v_total
    ) RETURNING id INTO v_invoice;

    INSERT INTO invoice_items (invoice_id, order_id, description, unit_price, quantity, site_label, delivery_date)
    SELECT v_invoice, p_order_id, product_name, unit_price, quantity, v_label, v_deliv
    FROM order_items WHERE order_id = p_order_id;

    UPDATE orders SET invoice_id = v_invoice WHERE id = p_order_id;

    RETURN v_invoice;
  END IF;

  -- ── Weekly: append to this week's open invoice ──
  v_wk_start := jg_week_start(v_deliv);
  v_wk_end   := v_wk_start + 6;

  SELECT id INTO v_open_inv
  FROM invoices
  WHERE customer_id = v_cust.id
    AND status      = 'draft'
    AND week_start  = v_wk_start
  LIMIT 1;

  IF v_open_inv IS NULL THEN
    v_number := jg_next_invoice_number(v_cust.id);
    INSERT INTO invoices (
      invoice_number, customer_id, order_id, invoice_type, status,
      issued_at, week_start, week_end, subtotal, vat_amount, total_amount
    ) VALUES (
      v_number, v_cust.id, NULL, v_type, 'draft',
      NULL, v_wk_start, v_wk_end, 0, 0, 0
    ) RETURNING id INTO v_open_inv;
  END IF;

  INSERT INTO invoice_items (invoice_id, order_id, description, unit_price, quantity, site_label, delivery_date)
  SELECT v_open_inv, p_order_id, product_name, unit_price, quantity, v_label, v_deliv
  FROM order_items WHERE order_id = p_order_id;

  PERFORM recalc_invoice_totals(v_open_inv);

  UPDATE orders SET invoice_id = v_open_inv WHERE id = p_order_id;

  RETURN v_open_inv;
END;
$$;

GRANT EXECUTE ON FUNCTION create_invoice_for_order(uuid) TO authenticated;


-- ── split_invoice_by_delivery: same rule ──────────────────────
-- A receipt produced by splitting a weekly invoice shouldn't claim to be
-- paid either. (Splitting already refuses when payments exist, so there
-- is never money to carry over.)
CREATE OR REPLACE FUNCTION split_invoice_by_delivery(p_invoice_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inv      record;
  v_order_id uuid;
  v_new_inv  uuid;
  v_number   text;
  v_deliv    date;
  v_count    integer := 0;
  v_left     integer;
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can split an invoice.';
  END IF;

  SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invoice not found.';
  END IF;

  IF v_inv.status <> 'draft' THEN
    RAISE EXCEPTION 'Only a running (draft) invoice can be split. % has already been %.',
      v_inv.invoice_number, v_inv.status;
  END IF;

  IF EXISTS (SELECT 1 FROM invoice_payments WHERE invoice_id = p_invoice_id) THEN
    RAISE EXCEPTION 'There are payments logged against % — remove them first if you want to split it, so the money stays with the right delivery.',
      v_inv.invoice_number;
  END IF;

  FOR v_order_id IN
    SELECT o.id
    FROM orders o
    WHERE o.id IN (
      SELECT DISTINCT ii.order_id
      FROM invoice_items ii
      WHERE ii.invoice_id = p_invoice_id AND ii.order_id IS NOT NULL
    )
    ORDER BY jg_order_delivery_date(o.id), o.created_at
  LOOP
    v_deliv  := jg_order_delivery_date(v_order_id);
    v_number := jg_next_invoice_number(v_inv.customer_id);

    INSERT INTO invoices (
      invoice_number, customer_id, order_id, invoice_type, status,
      issued_at, due_at, paid_at, subtotal, vat_amount, total_amount, notes
    ) VALUES (
      v_number, v_inv.customer_id, v_order_id, v_inv.invoice_type,
      'sent',
      v_deliv::timestamptz,
      CASE WHEN v_inv.invoice_type = 'invoice'
           THEN v_deliv::timestamptz + interval '30 days' ELSE NULL END,
      NULL,
      0, 0, 0,
      'Split from ' || v_inv.invoice_number
    ) RETURNING id INTO v_new_inv;

    UPDATE invoice_items
    SET invoice_id = v_new_inv
    WHERE invoice_id = p_invoice_id AND order_id = v_order_id;

    UPDATE orders SET invoice_id = v_new_inv WHERE id = v_order_id;

    PERFORM recalc_invoice_totals(v_new_inv);
    v_count := v_count + 1;
  END LOOP;

  SELECT count(*) INTO v_left FROM invoice_items WHERE invoice_id = p_invoice_id;
  IF v_left = 0 THEN
    DELETE FROM invoices WHERE id = p_invoice_id;
  ELSE
    PERFORM recalc_invoice_totals(p_invoice_id);
  END IF;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION split_invoice_by_delivery(uuid) TO authenticated;


-- ============================================================
-- NOTES FOR PHIL
--
-- * Jon's Unpaid list and the dashboard's outstanding figure will grow
--   by the domestic receipts he hasn't recorded money against. That
--   isn't a regression — it's the true position, and it clears as he
--   marks each one Cash or Bank on the delivery run as he always has.
--
-- * Nothing about the delivery run changes. It already read the real
--   payments, which is why it was the screen telling the truth.
--
-- * Reusable for other AXRIK clients: never let a document's status
--   claim money that hasn't been recorded. Status should be derived
--   from the payments, not set hopefully at creation.
-- ============================================================
