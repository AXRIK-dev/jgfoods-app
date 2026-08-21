-- ============================================================
-- Migration 050: Move an invoice to a different DELIVERY DATE
-- JG Foods Admin App
-- ============================================================
-- WHY
--
-- 21 Aug 2026. Jon logged Canella's order while catching up mid-week and
-- picked LAST week's delivery day by mistake. The order, the receipt and
-- the £84 all filed themselves under 10-16 Aug, so last week's sales are
-- £84 too high and this week's £84 too low, and his books don't balance.
--
-- Until now the only fix was "delete it and type it again" — which mints a
-- new invoice number, loses the payment, and is exactly the sort of job a
-- non-technical user gets wrong at 9pm on a Friday.
--
-- A wrong date is a correction, not a re-entry. This moves it.
--
-- WHAT IT MOVES
--
--   * every order on the invoice -> the delivery slot for the new date
--     (created if it doesn't exist yet, via ensure_delivery_slot)
--   * invoices.delivery_date, issued_at, and due_at (30-day terms re-run
--     from the new delivery, per 046)
--   * invoices.week_start / week_end when it's a weekly invoice
--   * every invoice_items.delivery_date on it
--   * daily sales for BOTH the old day and the new one
--
-- WHAT IT DOES NOT MOVE (unless you ask)
--
--   The PAYMENT. Sales belong to the delivery date, money belongs to the
--   date it landed — that's the rule the whole app runs on, and moving a
--   delivery must not quietly move cash into a week it wasn't received in.
--   Pass p_move_payments => true only when the money genuinely came in on
--   the new date too (typical for a doorstep receipt logged in one go).
--
-- ALLOWED WHEN PAID. Unlike split, this is safe on a settled invoice —
-- it changes a date, never an amount, and the money stays attached to the
-- same invoice throughout.
--
-- SAFE TO RE-RUN. Adds one function. Run AFTER 048.
-- ============================================================

CREATE OR REPLACE FUNCTION move_invoice_to_date(
  p_invoice_id     uuid,
  p_new_date       date,
  p_move_payments  boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inv       record;
  v_old       date;
  v_slot      uuid;
  v_issued    timestamptz;
  v_wk_start  date;
  v_wk_end    date;
  v_orders    int := 0;
  v_lines     int := 0;
  v_pays      int := 0;
  v_days      int;
  v_extra     int := 0;
  v_clash     uuid;
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can change the date on an invoice.';
  END IF;

  IF p_new_date IS NULL THEN
    RAISE EXCEPTION 'Pick the day the delivery actually went out.';
  END IF;

  SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invoice not found.';
  END IF;

  -- The date it's on now. Prefer the linked order's slot — that's the fact
  -- everything else is derived from (046) — then the stored column.
  SELECT COALESCE(
           (SELECT s.delivery_date
              FROM orders o
              JOIN delivery_slots s ON s.id = o.delivery_slot_id
             WHERE o.invoice_id = p_invoice_id OR o.id = v_inv.order_id
             ORDER BY s.delivery_date
             LIMIT 1),
           v_inv.delivery_date,
           v_inv.issued_at::date)
    INTO v_old;

  IF v_old IS NOT NULL AND v_old = p_new_date THEN
    RETURN jsonb_build_object(
      'moved', false,
      'reason', 'already_on_that_date',
      'from', v_old,
      'to',   p_new_date);
  END IF;

  -- More than one delivery day on it? Moving would flatten them all onto
  -- one date. Refuse and say so — "Split into one per delivery" first, then
  -- move the day that's wrong.
  SELECT count(DISTINCT COALESCE(
           ii.delivery_date,
           CASE WHEN ii.order_id IS NOT NULL THEN jg_order_delivery_date(ii.order_id) END))
    INTO v_days
    FROM invoice_items ii
   WHERE ii.invoice_id = p_invoice_id;

  IF COALESCE(v_days, 0) > 1 THEN
    RAISE EXCEPTION 'There are % different delivery days on %. Split it into one per delivery first, then move the day that is wrong.',
      v_days, v_inv.invoice_number;
  END IF;

  v_issued   := (p_new_date + time '12:00') AT TIME ZONE 'Europe/London';
  v_wk_start := jg_week_start(p_new_date);
  v_wk_end   := v_wk_start + 6;

  -- A weekly invoice still collecting deliveries is unique per customer per
  -- week (036). Moving one into a week that already has an open one would
  -- hit that index with a database error Jon can do nothing with.
  IF v_inv.week_start IS NOT NULL AND v_inv.status = 'draft' THEN
    SELECT id INTO v_clash
      FROM invoices
     WHERE customer_id = v_inv.customer_id
       AND week_start  = v_wk_start
       AND status      = 'draft'
       AND id <> p_invoice_id
     LIMIT 1;
    IF v_clash IS NOT NULL THEN
      RAISE EXCEPTION 'This customer already has an invoice still collecting for the week of %. Use "Combine this week onto one" instead of moving this one.',
        to_char(v_wk_start, 'DD/MM/YYYY');
    END IF;
  END IF;

  -- ── 1. The orders ────────────────────────────────────────────
  -- The slot date is the authoritative delivery date, so this is the part
  -- that actually moves the delivery. An invoice Jon typed up by hand has
  -- no order behind it, and in that case no slot is created — otherwise
  -- re-dating a hand-written invoice to a future date would quietly put a
  -- bookable delivery day on the website.
  IF EXISTS (
    SELECT 1 FROM orders o
     WHERE o.invoice_id = p_invoice_id
        OR o.id = v_inv.order_id
        OR o.id IN (SELECT ii.order_id FROM invoice_items ii
                     WHERE ii.invoice_id = p_invoice_id AND ii.order_id IS NOT NULL)
  ) THEN
    -- Past dates come back closed and confirmed (036), so nothing reopens.
    v_slot := ensure_delivery_slot(p_new_date);

    UPDATE orders
       SET delivery_slot_id = v_slot
     WHERE (invoice_id = p_invoice_id OR id = v_inv.order_id)
       AND delivery_slot_id IS DISTINCT FROM v_slot;
    GET DIAGNOSTICS v_orders = ROW_COUNT;

    -- Orders reached only through the line items (hand-built or combined).
    UPDATE orders o
       SET delivery_slot_id = v_slot
     WHERE o.id IN (SELECT ii.order_id FROM invoice_items ii
                     WHERE ii.invoice_id = p_invoice_id AND ii.order_id IS NOT NULL)
       AND o.delivery_slot_id IS DISTINCT FROM v_slot;
    GET DIAGNOSTICS v_extra = ROW_COUNT;
    v_orders := v_orders + v_extra;
  END IF;

  -- ── 2. The lines ─────────────────────────────────────────────
  UPDATE invoice_items
     SET delivery_date = p_new_date
   WHERE invoice_id = p_invoice_id;
  GET DIAGNOSTICS v_lines = ROW_COUNT;

  -- ── 3. The invoice ───────────────────────────────────────────
  UPDATE invoices
     SET delivery_date = p_new_date,
         issued_at     = v_issued,
         due_at        = CASE WHEN invoice_type = 'invoice'
                              THEN v_issued + interval '30 days' ELSE due_at END,
         week_start    = CASE WHEN week_start IS NOT NULL THEN v_wk_start ELSE NULL END,
         week_end      = CASE WHEN week_start IS NOT NULL THEN v_wk_end   ELSE NULL END
   WHERE id = p_invoice_id;

  -- ── 4. The money, only if asked ──────────────────────────────
  IF p_move_payments THEN
    UPDATE invoice_payments
       SET paid_at = v_issued
     WHERE invoice_id = p_invoice_id;
    GET DIAGNOSTICS v_pays = ROW_COUNT;

    IF v_inv.paid_at IS NOT NULL THEN
      UPDATE invoices SET paid_at = v_issued WHERE id = p_invoice_id;
    END IF;
  END IF;

  -- ── 5. Put both days' figures right ──────────────────────────
  BEGIN
    PERFORM recompute_daily_sales_for_invoice(p_invoice_id);
    IF v_old IS NOT NULL THEN PERFORM recompute_daily_sales(v_old); END IF;
    PERFORM recompute_daily_sales(p_new_date);
  EXCEPTION WHEN undefined_function THEN
    NULL;   -- pre-037 database; the invoice move itself still stands
  END;

  RETURN jsonb_build_object(
    'moved',          true,
    'from',           v_old,
    'to',             p_new_date,
    'invoice_number', v_inv.invoice_number,
    'orders_moved',   v_orders,
    'lines_updated',  v_lines,
    'payments_moved', v_pays,
    'week_start',     CASE WHEN v_inv.week_start IS NOT NULL THEN v_wk_start ELSE NULL END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION move_invoice_to_date(uuid, date, boolean) TO authenticated;


-- ============================================================
-- FIX CANELLA'S ORDER (21 Aug 2026) — the one that prompted this
--
-- C-899169, £84, sitting on the week of 10–16 Aug. Find it and move it to
-- the day it actually went out. Run in the Supabase SQL editor as an admin.
--
--   -- 1. See where it is now
--   SELECT i.invoice_number, i.delivery_date, i.week_start, i.status,
--          s.delivery_date AS slot_date, o.id AS order_id
--   FROM invoices i
--   LEFT JOIN orders o        ON o.invoice_id = i.id OR o.id = i.order_id
--   LEFT JOIN delivery_slots s ON s.id = o.delivery_slot_id
--   WHERE i.invoice_number = 'C-899169';
--
--   -- 2. Move it (change the date to the real delivery day).
--   --    Add true as the third argument only if the £84 also came in
--   --    that day rather than last week.
--   SELECT move_invoice_to_date(
--     (SELECT id FROM invoices WHERE invoice_number = 'C-899169'),
--     DATE '2026-08-20'
--   );
--
--   -- 3. Confirm
--   SELECT i.invoice_number, i.delivery_date, i.week_start, s.delivery_date
--   FROM invoices i
--   LEFT JOIN orders o         ON o.invoice_id = i.id OR o.id = i.order_id
--   LEFT JOIN delivery_slots s ON s.id = o.delivery_slot_id
--   WHERE i.invoice_number = 'C-899169';
--
-- Jon doesn't need any of this — Actions → 📅 Change the delivery date does
-- the same thing. It's here in case Phil wants it fixed before the deploy.
--
--
-- NOTES FOR PHIL
--
-- * The slot for a past date is created CLOSED and CONFIRMED (036), so
--   moving an order onto a day that was never a delivery day doesn't put a
--   bookable slot on the website.
--
-- * delivery_slots.orders_count keeps itself right — migration 010 made the
--   trigger fire on delivery_slot_id changes.
--
-- * delivery_temps rows are keyed by their own delivery_date and are NOT
--   moved. If Jon logged a temperature against the wrong day it stays where
--   it is; that's a food-safety record of when the reading was taken.
--
-- * Reusable for other AXRIK clients: any app where a document's date is a
--   fact about the work needs a "this is on the wrong day" correction, and
--   it has to move the SOURCE record (here, the order's slot), not just the
--   document — otherwise the display heals itself straight back.
-- ============================================================
