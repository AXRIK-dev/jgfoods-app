-- ============================================================
-- Migration 036: Weekly invoicing, split/merge, and backdating
-- JG Foods Admin App
-- ============================================================
-- THE PROBLEM
-- Jon has customers who take several deliveries in the same week.
-- Billy Bunters takes four (two sites x Monday and Thursday) and
-- wants ONE invoice covering the lot, with a subtotal per site and
-- a grand total. Tasty Bites takes four to a single address and
-- also wants one weekly invoice. Most other customers want an
-- invoice for every single delivery, exactly as they get today.
--
-- Migration 032 solved half of this: it consolidates orders onto
-- one running invoice, but ONLY for customers with 2+ delivery
-- sites, and the running tab never closes on its own — it collects
-- orders forever until Jon presses "Finalise & send". That means a
-- single-site customer like Tasty Bites can't have weekly billing
-- at all, and a multi-site customer can't have per-delivery billing.
--
-- THIS MIGRATION separates the two ideas that 032 tangled together:
--
--   "How many ADDRESSES does this customer have?"  -> customer_sites
--        Decides whether invoice lines are grouped under site
--        headings. Nothing to do with how often they're billed.
--
--   "How OFTEN do they want an invoice?"           -> billing_mode
--        'per_delivery' (default, unchanged for everyone) or
--        'weekly' (all deliveries in one Mon-Sun week land on one
--        invoice, which closes automatically at the week boundary).
--
-- The two combine freely. Billy Bunters = weekly + 2 sites, so he
-- gets one invoice a week with per-site subtotals — the invoice Jon
-- builds by hand today. A single-site customer can be weekly. A
-- multi-site customer can be per-delivery.
--
-- ALSO IN HERE
--  * split_invoice_by_delivery() — break a weekly invoice back into
--    one invoice per delivery, for when a customer changes their mind.
--  * merge_week_invoices() — the reverse: pull a week's separate
--    invoices onto one.
--  * ensure_delivery_slot() — lets Jon log orders against PAST dates
--    so he can catch the system up with work he's already done.
--
-- SAFE TO RE-RUN. Additive only. A customer left on the default
-- 'per_delivery' behaves exactly as they do today.
-- ============================================================


-- ============================================================
-- 1. customers.billing_mode
-- ============================================================
ALTER TABLE customers
  ADD COLUMN IF NOT EXISTS billing_mode text NOT NULL DEFAULT 'per_delivery';

ALTER TABLE customers DROP CONSTRAINT IF EXISTS customers_billing_mode_check;
ALTER TABLE customers
  ADD CONSTRAINT customers_billing_mode_check
  CHECK (billing_mode IN ('per_delivery', 'weekly'));

COMMENT ON COLUMN customers.billing_mode IS
  'per_delivery = an invoice/receipt per order (default, most customers). '
  'weekly = every delivery in the same Mon-Sun week collects onto one invoice.';

-- Backfill: anyone who already has extra delivery sites was, under
-- migration 032, being consolidated onto a running invoice. Keep that
-- behaviour for them by putting them on weekly billing — otherwise
-- running this migration would silently split Billy Bunters back into
-- four invoices a week.
UPDATE customers c
SET billing_mode = 'weekly'
WHERE billing_mode = 'per_delivery'
  AND EXISTS (SELECT 1 FROM customer_sites s WHERE s.customer_id = c.id);


-- ============================================================
-- 2. invoices.week_start / week_end
-- ============================================================
-- Which Mon-Sun week a weekly invoice covers. NULL on every
-- per-delivery invoice, which is what almost all of them are.
ALTER TABLE invoices ADD COLUMN IF NOT EXISTS week_start date;
ALTER TABLE invoices ADD COLUMN IF NOT EXISTS week_end   date;

COMMENT ON COLUMN invoices.week_start IS
  'Monday of the week this weekly invoice covers. NULL = ordinary per-delivery invoice.';

-- One OPEN weekly invoice per customer per week. Once Jon finalises it
-- (draft -> sent/paid) the index stops covering it, so a late order for
-- that same week correctly starts a fresh invoice rather than reopening
-- one he has already sent out.
DROP INDEX IF EXISTS idx_invoices_open_week;
CREATE UNIQUE INDEX idx_invoices_open_week
  ON invoices (customer_id, week_start)
  WHERE week_start IS NOT NULL AND status = 'draft';

CREATE INDEX IF NOT EXISTS idx_invoices_customer_week
  ON invoices (customer_id, week_start);


-- ── invoice_items.delivery_date ───────────────────────────────
-- Which delivery a line came from. On a per-delivery invoice every
-- line shares the same date and it's simply not shown. On a weekly
-- invoice it's what lets the printed invoice say "Monday 11 August"
-- above that drop's lines, so a customer taking four deliveries can
-- see what arrived when instead of one merged list.
ALTER TABLE invoice_items ADD COLUMN IF NOT EXISTS delivery_date date;

CREATE INDEX IF NOT EXISTS idx_invoice_items_invoice
  ON invoice_items (invoice_id);

-- Backfill the date onto existing lines that came from an order, so
-- invoices already in the system print the same way as new ones.
UPDATE invoice_items ii
SET delivery_date = COALESCE(s.delivery_date, o.created_at::date)
FROM orders o
LEFT JOIN delivery_slots s ON s.id = o.delivery_slot_id
WHERE ii.order_id = o.id
  AND ii.delivery_date IS NULL;


-- ============================================================
-- 3. Small helpers
-- ============================================================

-- Monday of the week a date falls in. Postgres date_trunc('week')
-- is ISO — weeks start Monday — which is what Jon's week is.
CREATE OR REPLACE FUNCTION jg_week_start(p_date date)
RETURNS date
LANGUAGE sql IMMUTABLE
AS $$ SELECT (date_trunc('week', p_date::timestamp))::date $$;

-- The date an order is actually delivered: its slot's date, falling
-- back to the day it was logged if it somehow has no slot.
CREATE OR REPLACE FUNCTION jg_order_delivery_date(p_order_id uuid)
RETURNS date
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(s.delivery_date, o.created_at::date)
  FROM orders o
  LEFT JOIN delivery_slots s ON s.id = o.delivery_slot_id
  WHERE o.id = p_order_id;
$$;

-- Invoice prefix for a customer: their set prefix, else initials.
CREATE OR REPLACE FUNCTION jg_invoice_prefix(p_customer_id uuid)
RETURNS text
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    NULLIF(c.invoice_prefix, ''),
    NULLIF(upper(array_to_string(ARRAY(
      SELECT left(w, 1)
      FROM unnest(regexp_split_to_array(trim(c.name), '\s+')) AS w
      LIMIT 3
    ), '')), ''),
    'INV'
  )
  FROM customers c WHERE c.id = p_customer_id;
$$;

CREATE OR REPLACE FUNCTION jg_next_invoice_number(p_customer_id uuid)
RETURNS text
LANGUAGE sql VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jg_invoice_prefix(p_customer_id) || '-' ||
         lpad(nextval('invoice_number_seq')::text, 4, '0');
$$;


-- ============================================================
-- 4. ensure_delivery_slot — backdating
-- ============================================================
-- Jon needs to enter orders he has already delivered, to get the
-- system caught up with the week he's just worked. The Log Order
-- screen only ever offered future open days, and delivery_slots is
-- UNIQUE on delivery_date, so there was no safe way to attach an
-- order to a past Monday.
--
-- This returns the slot for any date, creating it if it doesn't
-- exist. Past dates are created CLOSED and CONFIRMED so they never
-- appear as a bookable day on the website or clutter the runs page —
-- they're history, not work to do.
CREATE OR REPLACE FUNCTION ensure_delivery_slot(p_date date)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id    uuid;
  v_label text;
  v_past  boolean;
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can create a delivery day.';
  END IF;

  SELECT id INTO v_id FROM delivery_slots WHERE delivery_date = p_date;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  v_label := trim(to_char(p_date, 'Day'));
  v_past  := p_date < CURRENT_DATE;

  INSERT INTO delivery_slots (delivery_date, day_label, is_open, is_confirmed, notes)
  VALUES (
    p_date,
    v_label,
    NOT v_past,          -- past days are never open for new orders
    v_past,              -- and are already done
    CASE WHEN v_past THEN 'Added when catching up past orders' ELSE NULL END
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;


-- ============================================================
-- 5. create_invoice_for_order — billing-mode aware
-- ============================================================
-- Replaces the version in migration 032.
--
--   billing_mode = 'per_delivery'  -> one invoice per order, issued
--       immediately. Identical to migration 013/032 behaviour, with
--       one improvement: if the order has a site, its lines still
--       carry the site label so the address prints on the invoice.
--
--   billing_mode = 'weekly'        -> the order's lines are appended
--       to that customer's OPEN invoice for the Mon-Sun week the
--       delivery falls in, creating it if this is the week's first
--       order. Lines are grouped by site label where the customer
--       has sites, giving Billy Bunters' per-site subtotals.
--
-- Backdated orders slot into the correct historical week on their own,
-- because the week is taken from the delivery date, not from today.
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
      CASE WHEN v_type = 'receipt' THEN 'paid' ELSE 'sent' END,
      now(),
      CASE WHEN v_type = 'invoice' THEN now() + interval '30 days' ELSE NULL END,
      CASE WHEN v_type = 'receipt' THEN now() ELSE NULL END,
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


-- ============================================================
-- 6. split_invoice_by_delivery
-- ============================================================
-- Takes a weekly invoice and breaks it back out into one invoice per
-- delivery — for the customer who decides they'd rather have them
-- separate after all, or for the week where one site needs invoicing
-- ahead of the other.
--
-- Only ever runs on a DRAFT invoice, so a sent or paid invoice can
-- never be pulled apart underneath the customer. Returns the number
-- of invoices created.
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
  v_total    numeric(10,2);
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

  -- If money has already been logged against it there's no honest way to
  -- decide which delivery that payment belongs to, so don't guess.
  IF EXISTS (SELECT 1 FROM invoice_payments WHERE invoice_id = p_invoice_id) THEN
    RAISE EXCEPTION 'There are payments logged against % — remove them first if you want to split it, so the money stays with the right delivery.',
      v_inv.invoice_number;
  END IF;

  -- One new invoice per order on this invoice. Lines that came from a
  -- manual entry rather than an order (order_id IS NULL) stay behind.
  -- Oldest delivery first, so the new invoice numbers run in date order.
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

    -- Each split invoice is a finished document dated the day it went out —
    -- not another running tab for Jon to remember to close.
    INSERT INTO invoices (
      invoice_number, customer_id, order_id, invoice_type, status,
      issued_at, due_at, paid_at, subtotal, vat_amount, total_amount, notes
    ) VALUES (
      v_number, v_inv.customer_id, v_order_id, v_inv.invoice_type,
      CASE WHEN v_inv.invoice_type = 'receipt' THEN 'paid' ELSE 'sent' END,
      v_deliv::timestamptz,
      CASE WHEN v_inv.invoice_type = 'invoice'
           THEN v_deliv::timestamptz + interval '30 days' ELSE NULL END,
      CASE WHEN v_inv.invoice_type = 'receipt' THEN v_deliv::timestamptz ELSE NULL END,
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

  -- If nothing is left on the original, clear it away. If manual lines
  -- remain, keep it and re-total it.
  SELECT count(*) INTO v_left FROM invoice_items WHERE invoice_id = p_invoice_id;
  IF v_left = 0 THEN
    DELETE FROM invoices WHERE id = p_invoice_id;
  ELSE
    PERFORM recalc_invoice_totals(p_invoice_id);
  END IF;

  RETURN v_count;
END;
$$;


-- ============================================================
-- 7. merge_week_invoices
-- ============================================================
-- The reverse of the above: pull every unpaid invoice this customer
-- has for a given Mon-Sun week onto a single weekly invoice. This is
-- what Jon uses when he's entered a week's deliveries separately and
-- then wants to send one bill — including catching up a past week.
--
-- Refuses to touch anything already paid, so nothing that's been
-- settled or reconciled can be disturbed. Returns the invoice id of
-- the combined invoice.
CREATE OR REPLACE FUNCTION merge_week_invoices(p_customer_id uuid, p_week_start date)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wk_start date;
  v_wk_end   date;
  v_target   uuid;
  v_type     text;
  v_number   text;
  v_paid     integer;
  v_src      uuid;
  v_ids      uuid[];
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can combine invoices.';
  END IF;

  v_wk_start := jg_week_start(p_week_start);
  v_wk_end   := v_wk_start + 6;

  -- Every invoice for this customer whose delivery falls in that week —
  -- either because it's already stamped with the week, or because one of
  -- its lines came from an order delivered inside it.
  SELECT array_agg(i.id), count(*) FILTER (WHERE i.status = 'paid')
  INTO v_ids, v_paid
  FROM invoices i
  WHERE i.customer_id = p_customer_id
    AND (
      i.week_start = v_wk_start
      OR EXISTS (
        SELECT 1
        FROM invoice_items ii
        WHERE ii.invoice_id = i.id
          AND ii.order_id IS NOT NULL
          AND jg_order_delivery_date(ii.order_id) BETWEEN v_wk_start AND v_wk_end
      )
    );

  IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'No invoices found for that customer in the week beginning %.', v_wk_start;
  END IF;

  IF v_paid > 0 THEN
    RAISE EXCEPTION 'Some of that week''s invoices have already been paid — they can''t be combined. Unmark the payment first if that was a mistake.';
  END IF;

  -- Reuse an existing weekly invoice for the week if there is one,
  -- otherwise promote nothing — make a fresh one and move everything on.
  SELECT id INTO v_target
  FROM invoices
  WHERE id = ANY(v_ids) AND week_start = v_wk_start AND status = 'draft'
  ORDER BY created_at
  LIMIT 1;

  SELECT CASE WHEN customer_type = 'domestic' THEN 'receipt' ELSE 'invoice' END
  INTO v_type FROM customers WHERE id = p_customer_id;

  IF v_target IS NULL THEN
    v_number := jg_next_invoice_number(p_customer_id);
    INSERT INTO invoices (
      invoice_number, customer_id, order_id, invoice_type, status,
      issued_at, week_start, week_end, subtotal, vat_amount, total_amount
    ) VALUES (
      v_number, p_customer_id, NULL, v_type, 'draft',
      NULL, v_wk_start, v_wk_end, 0, 0, 0
    ) RETURNING id INTO v_target;
  ELSE
    UPDATE invoices
    SET week_start = v_wk_start, week_end = v_wk_end, order_id = NULL
    WHERE id = v_target;
  END IF;

  -- Move the lines across, repoint the orders, bin the empty shells.
  FOREACH v_src IN ARRAY v_ids LOOP
    CONTINUE WHEN v_src = v_target;
    UPDATE invoice_items    SET invoice_id = v_target WHERE invoice_id = v_src;
    UPDATE orders           SET invoice_id = v_target WHERE invoice_id = v_src;
    -- Part payments move across with the lines. invoice_payments cascades on
    -- delete, so missing this step would quietly erase money Jon has banked.
    UPDATE invoice_payments SET invoice_id = v_target WHERE invoice_id = v_src;
    DELETE FROM invoices WHERE id = v_src;
  END LOOP;

  UPDATE orders o
  SET invoice_id = v_target
  WHERE EXISTS (
    SELECT 1 FROM invoice_items ii
    WHERE ii.invoice_id = v_target AND ii.order_id = o.id
  );

  PERFORM recalc_invoice_totals(v_target);

  RETURN v_target;
END;
$$;


-- ============================================================
-- 8. Grants
-- ============================================================
GRANT EXECUTE ON FUNCTION jg_week_start(date)                     TO authenticated;
GRANT EXECUTE ON FUNCTION jg_order_delivery_date(uuid)            TO authenticated;
GRANT EXECUTE ON FUNCTION jg_invoice_prefix(uuid)                 TO authenticated;
GRANT EXECUTE ON FUNCTION jg_next_invoice_number(uuid)            TO authenticated;
GRANT EXECUTE ON FUNCTION ensure_delivery_slot(date)              TO authenticated;
GRANT EXECUTE ON FUNCTION create_invoice_for_order(uuid)          TO authenticated;
GRANT EXECUTE ON FUNCTION split_invoice_by_delivery(uuid)         TO authenticated;
GRANT EXECUTE ON FUNCTION merge_week_invoices(uuid, date)         TO authenticated;


-- ============================================================
-- 9. Adopt the invoices that are already open
-- ============================================================
-- Without this, a running tab created by migration 032 has
-- week_start = NULL, so the new weekly lookup can't see it. The next
-- order for that customer would start a SECOND invoice for the same
-- week and Jon would be looking at two open bills for Billy Bunters.
--
-- So: stamp each existing open tab with the week it actually covers,
-- and it simply carries on as that week's invoice.
--
-- Deliberately cautious. A tab is only adopted when:
--   * all its deliveries fall inside ONE Mon-Sun week, and
--   * that customer has no other open invoice already stamped with
--     that week (which would breach idx_invoices_open_week and fail
--     the whole migration).
--
-- Anything left unstamped is a tab that has been running for more
-- than a week. Those are left exactly as they are for Jon to finalise
-- or split by hand — guessing a single week for them would put
-- deliveries on the wrong bill.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT i.id,
           i.customer_id,
           min(jg_week_start(ii.delivery_date)) AS wk
    FROM invoices i
    JOIN invoice_items ii ON ii.invoice_id = i.id
    WHERE i.status     = 'draft'
      AND i.week_start IS NULL
      AND ii.delivery_date IS NOT NULL
    GROUP BY i.id, i.customer_id
    HAVING min(jg_week_start(ii.delivery_date)) = max(jg_week_start(ii.delivery_date))
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM invoices x
      WHERE x.customer_id = r.customer_id
        AND x.status      = 'draft'
        AND x.week_start  = r.wk
        AND x.id         <> r.id
    ) THEN
      UPDATE invoices
      SET week_start = r.wk,
          week_end   = r.wk + 6
      WHERE id = r.id;
    END IF;
  END LOOP;
END $$;


-- ============================================================
-- NOTES FOR PHIL
--
-- * Nothing changes for a customer on the default 'per_delivery'
--   mode. The only difference from 032 is that their invoice lines
--   now carry a site label if the order had a site, which just means
--   the address prints as a heading.
--
-- * Existing multi-site customers are moved to 'weekly' by the
--   backfill in section 1, so Billy Bunters carries on exactly as he
--   was — except his running tab now closes at the end of each week
--   instead of running on until Jon remembers to finalise it.
--
-- * No existing invoice is renumbered, re-totalled or re-dated. The
--   only column touched on invoices that already exist is week_start
--   /week_end, and only on OPEN tabs (section 9).
--
-- * Orders already invoiced individually are NOT retro-combined by
--   this migration. Switching a customer to weekly only affects
--   orders logged from that point on. To pull a week Jon has already
--   entered onto one bill, use "Combine this week onto one" on the
--   Invoices page — that's what merge_week_invoices is for.
--
-- * That combine won't touch anything already marked PAID, which
--   includes every domestic receipt (they're auto-paid on creation).
--   Weekly billing is really a trade/commercial arrangement.
--
-- * Reusable for other AXRIK clients: billing_mode + week_start is a
--   generic "bill per job or bill per week" pattern that will suit any
--   trade doing repeat drops to the same customer.
-- ============================================================
