-- ============================================================
-- Migration 048: Split an invoice by DELIVERY DATE
-- JG Foods Admin App
-- ============================================================
-- WHY
--
-- "Split into one per delivery" grouped by DISTINCT invoice_items.order_id,
-- so it produced one invoice per ORDER. Billy Bunters' BBL-1037 has 4 orders
-- across 2 delivery days (two sites, two days) — that would have given him
-- four invoices when what "one per delivery" means to Jon is two, one for
-- each day the van went out, with both sites on it exactly as they print now.
--
-- It also relied on order_id being present. That column is NULL on every line
-- of an invoice Jon typed up by hand, so on those the loop found nothing,
-- created nothing, and the app reported "only has one delivery on it".
--
-- Splitting by delivery is a question about DATES, so it's now answered with
-- the dates — which every line carries after 046/047 — and falls back to the
-- order's slot date, then the invoice's own date.
--
-- ALSO CHANGED
--   * Works on a finalised invoice, not only a running draft — Jon may well
--     have closed it before deciding to split.
--   * Still refuses when a payment has been recorded, so money can never be
--     separated from the delivery it paid for. Refuses outright if paid.
--   * Lines with no date at all stay on the original invoice rather than
--     being guessed at — visible, and fixable by hand.
--   * week_start is cleared on the new invoices: they're per-delivery now.
--
-- SAFE TO RE-RUN. Replaces one function. Run AFTER 047.
-- ============================================================

CREATE OR REPLACE FUNCTION split_invoice_by_delivery(p_invoice_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inv      record;
  v_deliv    date;
  v_new_inv  uuid;
  v_number   text;
  v_issued   timestamptz;
  v_order    uuid;
  v_orders   int;
  v_dates    int;
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

  IF EXISTS (SELECT 1 FROM invoice_payments WHERE invoice_id = p_invoice_id) THEN
    RAISE EXCEPTION 'There are payments logged against % — remove them first if you want to split it, so the money stays with the right delivery.',
      v_inv.invoice_number;
  END IF;

  IF v_inv.status = 'paid' THEN
    RAISE EXCEPTION '% is marked paid, so it can no longer be split.', v_inv.invoice_number;
  END IF;

  -- How many distinct delivery days are on it. Computed inline rather than
  -- in a temp table: this runs as an RPC, and a temp table that outlives the
  -- statement would collide the second time Jon pressed the button.
  SELECT count(DISTINCT COALESCE(
           ii.delivery_date,
           CASE WHEN ii.order_id IS NOT NULL THEN jg_order_delivery_date(ii.order_id) END,
           v_inv.delivery_date))
    INTO v_dates
    FROM invoice_items ii
   WHERE ii.invoice_id = p_invoice_id;

  -- One day (or none we can date) — nothing to split. Returning 0 lets the
  -- app say so plainly instead of pretending it did something.
  IF v_dates < 2 THEN
    RETURN 0;
  END IF;

  FOR v_deliv IN
    SELECT DISTINCT COALESCE(
             ii.delivery_date,
             CASE WHEN ii.order_id IS NOT NULL THEN jg_order_delivery_date(ii.order_id) END,
             v_inv.delivery_date) AS d
      FROM invoice_items ii
     WHERE ii.invoice_id = p_invoice_id
       AND COALESCE(
             ii.delivery_date,
             CASE WHEN ii.order_id IS NOT NULL THEN jg_order_delivery_date(ii.order_id) END,
             v_inv.delivery_date) IS NOT NULL
     ORDER BY 1
  LOOP
    v_issued := COALESCE((v_deliv + time '12:00') AT TIME ZONE 'Europe/London', now());
    v_number := jg_next_invoice_number(v_inv.customer_id);

    -- Carry the order link across only when this day is one single order.
    -- Two sites on the same day means two orders, and the invoice shouldn't
    -- claim to be for just one of them.
    SELECT count(DISTINCT ii.order_id) INTO v_orders
      FROM invoice_items ii
     WHERE ii.invoice_id = p_invoice_id
       AND ii.order_id IS NOT NULL
       AND COALESCE(ii.delivery_date, jg_order_delivery_date(ii.order_id), v_inv.delivery_date) = v_deliv;

    v_order := NULL;
    IF v_orders = 1 THEN
      SELECT DISTINCT ii.order_id INTO v_order
        FROM invoice_items ii
       WHERE ii.invoice_id = p_invoice_id
         AND ii.order_id IS NOT NULL
         AND COALESCE(ii.delivery_date, jg_order_delivery_date(ii.order_id), v_inv.delivery_date) = v_deliv;
    END IF;

    INSERT INTO invoices (
      invoice_number, customer_id, order_id, invoice_type, status,
      delivery_date, issued_at, due_at, paid_at,
      week_start, week_end, subtotal, vat_amount, total_amount, notes
    ) VALUES (
      v_number, v_inv.customer_id, v_order, v_inv.invoice_type,
      CASE WHEN v_inv.status = 'draft' THEN 'draft' ELSE 'sent' END,
      v_deliv,
      v_issued,
      CASE WHEN v_inv.invoice_type = 'invoice'
           THEN v_issued + interval '30 days' ELSE NULL END,
      NULL,
      NULL, NULL,             -- no longer a weekly invoice
      0, 0, 0,
      'Split from ' || v_inv.invoice_number
    ) RETURNING id INTO v_new_inv;

    UPDATE invoice_items ii
    SET    invoice_id    = v_new_inv,
           delivery_date = COALESCE(ii.delivery_date, v_deliv)
    WHERE  ii.invoice_id = p_invoice_id
      AND  COALESCE(
             ii.delivery_date,
             CASE WHEN ii.order_id IS NOT NULL THEN jg_order_delivery_date(ii.order_id) END,
             v_inv.delivery_date) = v_deliv;

    -- Point every order that landed that day at its new invoice.
    UPDATE orders o
    SET    invoice_id = v_new_inv
    WHERE  o.id IN (SELECT ii.order_id FROM invoice_items ii
                    WHERE ii.invoice_id = v_new_inv AND ii.order_id IS NOT NULL);

    PERFORM recalc_invoice_totals(v_new_inv);
    v_count := v_count + 1;
  END LOOP;

  -- Anything left couldn't be dated. It stays put rather than being guessed.
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
-- WHY BBL-1037 DIDN'T SPLIT — check this before blaming the function
--
-- The diagnostic showed status=draft, 4 orders, 2 dates, 0 lines without an
-- order. The OLD function should have split that into 4. It still has all 10
-- lines, so it never ran — something raised before it got going. Most likely
-- a payment logged against it:
--
--   SELECT p.id, p.method, p.amount, p.paid_at
--   FROM invoice_payments p
--   JOIN invoices i ON i.id = p.invoice_id
--   WHERE i.invoice_number = 'BBL-1037';
--
-- Any rows = that's the blocker. Remove the payment, split, then log the
-- payment again against the right day's invoice.
--
-- No rows = check the admin role of the login being used:
--
--   SELECT current_user_role();     -- must return 'admin'
--
--
-- AFTER SPLITTING — confirm
--
--   SELECT invoice_number, delivery_date, total_amount, status, notes
--   FROM invoices
--   WHERE customer_id = (SELECT customer_id FROM invoices WHERE invoice_number = 'BBL-1037')
--   ORDER BY delivery_date;
--
--
-- NOTES FOR PHIL
--
-- * BBL-1037 has 4 orders on 2 days. This gives TWO invoices — one per
--   delivery day, each keeping both sites grouped as they print now. If Jon
--   wants one per site-drop instead (four), say so and I'll change the
--   grouping to date + site.
--
-- * Splitting mints new numbers from the customer's sequence and the original
--   number goes with the original invoice. If BBL-1037 has already been sent,
--   Billy Bunters needs telling it's been replaced.
--
-- * Reusable for other AXRIK clients: group by the FACT you're splitting on,
--   not by a foreign key that's usually but not always there.
-- ============================================================
