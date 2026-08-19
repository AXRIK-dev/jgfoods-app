-- ============================================================
-- Migration 046: An invoice is dated by its DELIVERY, not by the day
--                it was created or the day it was printed
-- JG Foods Admin App
-- ============================================================
-- THE PROBLEM (reported by Jon, 19 Aug 2026)
--
--   1. He reprinted Monday's invoice today because a customer's name was
--      slightly wrong. The reprint came out dated today, not Monday.
--   2. He printed today all the invoices for tomorrow's deliveries.
--      Every one of them says today.
--
-- Both come from the same root cause: nothing ever stored "the date this
-- invoice is for". create_invoice_for_order stamped issued_at = now(), and
-- the PDF builder didn't even read that — it called new Date() at the moment
-- of printing. So the date on the paper was "whenever this came out of the
-- printer", which is exactly what an invoice must never be. Jon's customers
-- reconcile invoices against delivery notes; a date that moves is a date they
-- will query.
--
-- The delivery date was never actually lost — invoice_items.delivery_date has
-- been populated correctly on every line since migration 036. It just wasn't
-- being read. So this migration is a correction, not a rebuild: no invoice
-- needs reissuing and no number changes.
--
-- THE FIX
--   * invoices.delivery_date — one stored answer, written once at creation.
--   * issued_at and due_at line up with it, so 30-day terms run from the
--     delivery the customer is being billed for.
--   * Existing invoices are back-filled from their own line items.
--
-- Weekly invoices are unaffected: they are headed "W/C <week start>", which
-- was already derived from the delivery dates and was already correct.
--
-- SAFE TO RE-RUN. Adds one column, replaces three functions, and back-fills
-- only rows that haven't been set yet. Touches no amounts, no invoice
-- numbers and no payment records.
--
-- Run AFTER 045.
-- ============================================================


-- ── 1. Where the date now lives ───────────────────────────────
ALTER TABLE invoices
  ADD COLUMN IF NOT EXISTS delivery_date date;

COMMENT ON COLUMN invoices.delivery_date IS
  'The delivery this invoice covers. This is the date printed on the '
  'document, and it never changes once set — printing or reprinting must '
  'not restamp it. NULL on weekly invoices, which are headed by week_start '
  'instead.';

CREATE INDEX IF NOT EXISTS idx_invoices_delivery_date
  ON invoices (delivery_date);


-- ── 2. Back-fill what's already been issued ───────────────────
-- Every per-delivery invoice takes the earliest delivery date on its own
-- lines. Weekly invoices are skipped — week_start already dates those.
UPDATE invoices i
SET    delivery_date = d.first_delivery
FROM (
  SELECT invoice_id, min(delivery_date) AS first_delivery
  FROM   invoice_items
  WHERE  delivery_date IS NOT NULL
  GROUP  BY invoice_id
) d
WHERE i.id = d.invoice_id
  AND i.delivery_date IS NULL
  AND i.week_start    IS NULL;

-- Anything left is an invoice Jon typed up by hand before this existed, so
-- its lines carry no delivery date. The date he chose on the form went into
-- issued_at, which is the best record we have of the day he meant.
UPDATE invoices
SET    delivery_date = issued_at::date
WHERE  delivery_date IS NULL
  AND  week_start    IS NULL
  AND  issued_at     IS NOT NULL;


-- ── 3. Realign issued_at and the 30 days with the delivery ────
-- issued_at is read midday so a date-only value can't drift across a
-- timezone boundary and show the day before.
--
-- Payment records are NOT touched. paid_at is a statement of when money
-- actually arrived and must stay exactly as it is.
-- Drafts are left alone: a running tab is deliberately un-issued until Jon
-- presses Finalise, and that's when its dates get set.
UPDATE invoices
SET    issued_at = (delivery_date + time '12:00') AT TIME ZONE 'Europe/London'
WHERE  delivery_date IS NOT NULL
  AND  week_start    IS NULL
  AND  status       <> 'draft';

UPDATE invoices
SET    due_at = ((delivery_date + 30) + time '12:00') AT TIME ZONE 'Europe/London'
WHERE  delivery_date IS NOT NULL
  AND  week_start    IS NULL
  AND  status       <> 'draft'
  AND  invoice_type  = 'invoice'
  AND  due_at IS NOT NULL;


-- ── 4. New invoices carry the delivery date from the start ────
-- Identical to the version in migration 040 apart from the dates: the
-- per-delivery branch now stamps delivery_date, and issues/dues from the
-- delivery rather than from now().
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
  v_issued     timestamptz;
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

  -- CHANGED IN 046: the invoice is dated by the delivery, not by now().
  -- An order logged on Wednesday for a Thursday delivery is a Thursday
  -- invoice, and stays one however many times it's printed.
  v_issued := COALESCE(
    (v_deliv + time '12:00') AT TIME ZONE 'Europe/London',
    now()
  );

  -- ── Per-delivery: one invoice for this order ──
  IF COALESCE(v_cust.billing_mode, 'per_delivery') <> 'weekly' THEN
    v_number := jg_next_invoice_number(v_cust.id);

    INSERT INTO invoices (
      invoice_number, customer_id, order_id, invoice_type, status,
      delivery_date, issued_at, due_at, paid_at, subtotal, vat_amount, total_amount
    ) VALUES (
      v_number, v_cust.id, p_order_id, v_type,
      -- From 040: a receipt awaits payment like everything else. It becomes
      -- 'paid' when Jon records the cash or bank transfer, which is the same
      -- moment the money reaches Daily Sales.
      'sent',
      v_deliv,
      v_issued,
      -- 30-day terms run from the delivery; a doorstep receipt has none.
      CASE WHEN v_type = 'invoice' THEN v_issued + interval '30 days' ELSE NULL END,
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
  -- delivery_date stays NULL here on purpose. A weekly invoice covers several
  -- deliveries, so it is headed "W/C <week start>" rather than a single date.
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


-- ── 5. Splitting a weekly invoice keeps each delivery's date ──
-- This already dated each new invoice by its delivery; it now records that
-- date in the column the app reads, instead of only in issued_at.
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
  v_issued   timestamptz;
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
    v_issued := COALESCE((v_deliv + time '12:00') AT TIME ZONE 'Europe/London', now());
    v_number := jg_next_invoice_number(v_inv.customer_id);

    INSERT INTO invoices (
      invoice_number, customer_id, order_id, invoice_type, status,
      delivery_date, issued_at, due_at, paid_at, subtotal, vat_amount, total_amount, notes
    ) VALUES (
      v_number, v_inv.customer_id, v_order_id, v_inv.invoice_type,
      'sent',
      v_deliv,
      v_issued,
      CASE WHEN v_inv.invoice_type = 'invoice'
           THEN v_issued + interval '30 days' ELSE NULL END,
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


-- ── 6. A customer editing their order mustn't wipe the date ───
-- edit_my_order rebuilt the invoice lines from scratch and dropped both
-- delivery_date and site_label while doing it — so a customer adding a pack
-- of sausages to their own order silently blanked the date on Jon's invoice
-- and, on a multi-site account, the site heading with it. Both are carried
-- over now.
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
  v_deliv    date;
  v_label    text;
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

  -- From 043 — add or drop the small-order charge for the new basket size
  PERFORM apply_min_order_charge(p_order_id);

  -- Total now comes from the lines themselves, charge included
  SELECT COALESCE(SUM(line_total), 0) INTO v_total
    FROM order_items WHERE order_id = p_order_id;

  UPDATE orders SET total_amount = v_total WHERE id = p_order_id;

  -- Keep the linked invoice in step, WITHOUT losing its delivery date or
  -- site heading (046). Both are read off the lines being replaced so a
  -- hand-corrected date survives the rebuild.
  IF v_inv_id IS NOT NULL THEN
    SELECT min(delivery_date), min(site_label)
      INTO v_deliv, v_label
      FROM invoice_items WHERE invoice_id = v_inv_id;

    v_deliv := COALESCE(v_deliv, jg_order_delivery_date(p_order_id));

    DELETE FROM invoice_items WHERE invoice_id = v_inv_id;
    INSERT INTO invoice_items (invoice_id, order_id, description, unit_price, quantity, site_label, delivery_date)
    SELECT v_inv_id, p_order_id, product_name, unit_price, quantity, v_label, v_deliv
    FROM order_items WHERE order_id = p_order_id;

    UPDATE invoices
    SET subtotal = v_total,
        total_amount = v_total,
        delivery_date = COALESCE(delivery_date, CASE WHEN week_start IS NULL THEN v_deliv END)
    WHERE id = v_inv_id;
  END IF;

  RETURN json_build_object('ok', true, 'total', v_total);
END;
$$;

GRANT EXECUTE ON FUNCTION edit_my_order(uuid, jsonb) TO authenticated;


-- ============================================================
-- CHECK IT WORKED
--
--   -- Nothing should come back with no date against it:
--   SELECT invoice_number, delivery_date, issued_at::date, week_start
--   FROM invoices
--   WHERE delivery_date IS NULL AND week_start IS NULL;
--
--   -- And the dates should read as delivery days, not typing-up days:
--   SELECT invoice_number, delivery_date, total_amount
--   FROM invoices ORDER BY created_at DESC LIMIT 20;
--
--
-- NOTES FOR PHIL
--
-- * Jon's Unpaid/Overdue counts may shift by a day or two either way, because
--   the 30 days now run from the delivery instead of from when the invoice was
--   raised. No invoice changes value.
--
-- * The From/To filters on the Invoices page now search by delivery date, so
--   "the first week of August" returns that week's deliveries rather than
--   whatever was typed up that week. That is what Jon means by the question.
--
-- * Finance and Daily Sales are untouched and still follow the PAYMENT date —
--   money counts on the day it arrives, which is correct for the books and is
--   a different question from the date on the paperwork.
--
-- * Reusable for other AXRIK clients: a document's date is a fact about the
--   work it describes, and belongs in a stored column. Never derive it at
--   render time from new Date() / now() — that produces paperwork that
--   changes every time you look at it.
-- ============================================================
