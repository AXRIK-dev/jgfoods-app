-- ============================================================
-- Migration 044: Today's takings — one honest number, always right
-- JG Foods Admin App
-- ============================================================
-- WHAT JON ASKED FOR
-- "I want to see my total daily sales every day — the total, split into
--  cash and bank transfer. And I want it to be a running total: when I
--  mark something paid it goes up, if I delete an invoice it comes back
--  down, and if I recorded a payment as cash when it was a bank transfer
--  and switch it over, both figures move."
--
-- The money side of that already worked (migrations 037 and 041). Two
-- things were missing.
--
-- 1. THE FIGURE WAS BURIED. Jon had to go to Finance, then the Daily
--    Sales tab, then find today's row in a table with every date in it.
--    That is not something anyone does every day.
--
-- 2. THE RUNNING TOTAL RELIED ON THE APP REMEMBERING. Every path that
--    touches a payment has to call recompute_daily_sales itself. They
--    all currently do — but that is a rule living in the JavaScript, and
--    the day someone adds a new way to take money and forgets, the
--    takings quietly go wrong and nothing complains. A wrong figure that
--    looks right is the worst kind, because it flows through to the
--    weekly sheet and the accountant.
--
-- WHAT THIS ADDS
--
--   * takings_for_day(date) — everything the dashboard panel needs in
--     one call: money actually RECEIVED that day split cash/bank, what
--     that day's DELIVERIES were worth, and how much of it is still
--     owed. Both figures, because they answer different questions and
--     Jon needs both.
--
--   * Database triggers on invoice_payments and orders, so the day's
--     figures rebuild themselves on any insert, update or delete, from
--     any source. The existing JavaScript calls stay where they are —
--     they just stop being the only thing holding it together.
--
-- SAFE TO RE-RUN. Adds functions and triggers; changes no data except
-- the one-off catch-up at the end, which only corrects days that were
-- already wrong.
--
-- RUN AFTER: 037 (allocations) and 041 (delete cascade).
-- ============================================================


-- ============================================================
-- 1. The unchecked recompute
-- ============================================================
-- recompute_daily_sales() refuses to run for anyone who isn't an admin,
-- which is right for something the app calls directly. But a trigger
-- fires as whoever happened to cause the change, and the whole point of
-- a trigger is that it can't be skipped. If a customer ever pays online
-- and a webhook writes the payment, the admin check would abort their
-- payment with "Only an admin can update takings".
--
-- So the work moves into an internal function with no role check, and
-- the public one keeps its check and delegates. Nothing loses a guard:
-- this function is never granted to anyone and can only be reached from
-- inside a SECURITY DEFINER function or a trigger.
CREATE OR REPLACE FUNCTION recompute_daily_sales_unchecked(p_date date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_bank numeric(10,2);
  v_cash numeric(10,2);
BEGIN
  IF p_date IS NULL THEN RETURN; END IF;

  SELECT
    ROUND(COALESCE(SUM(amount) FILTER (WHERE method = 'bacs'), 0), 2),
    ROUND(COALESCE(SUM(amount) FILTER (WHERE method = 'cash'), 0), 2)
  INTO v_bank, v_cash
  FROM daily_payment_allocations
  WHERE sale_date = p_date;

  INSERT INTO daily_sales (sale_date, orders_bank, orders_cash)
  VALUES (p_date, v_bank, v_cash)
  ON CONFLICT (sale_date)
  DO UPDATE SET orders_bank = EXCLUDED.orders_bank,
                orders_cash = EXCLUDED.orders_cash;
END;
$$;

REVOKE ALL ON FUNCTION recompute_daily_sales_unchecked(date) FROM anon, authenticated;


-- The public one: same signature and behaviour as before, admin check
-- intact, work delegated so there is only one copy of the sums.
CREATE OR REPLACE FUNCTION recompute_daily_sales(p_date date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can update takings';
  END IF;
  PERFORM recompute_daily_sales_unchecked(p_date);
END;
$$;


-- ============================================================
-- 2. Every day one invoice's money could possibly touch
-- ============================================================
-- A weekly invoice's payments are shared across all the deliveries on
-- it, so one payment can move four different days. This lists them.
-- Dates come from the invoice's ORDERS and its own issue date as well as
-- from its payments, so it still cleans up properly after a payment has
-- been deleted and there is nothing left to look at.
CREATE OR REPLACE FUNCTION days_touched_by_invoice(p_invoice_id uuid)
RETURNS SETOF date
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT DISTINCT d FROM (
    SELECT COALESCE(s.delivery_date, o.created_at::date) AS d
      FROM orders o
      LEFT JOIN delivery_slots s ON s.id = o.delivery_slot_id
     WHERE o.invoice_id = p_invoice_id
        OR o.id IN (SELECT order_id FROM invoices
                     WHERE id = p_invoice_id AND order_id IS NOT NULL)
    UNION
    SELECT p.paid_at::date FROM invoice_payments p WHERE p.invoice_id = p_invoice_id
    UNION
    SELECT COALESCE(i.issued_at::date, i.created_at::date)
      FROM invoices i WHERE i.id = p_invoice_id
  ) t
  WHERE d IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION days_touched_by_invoice(uuid) FROM anon, authenticated;


-- ============================================================
-- 3. The triggers — the running total looks after itself
-- ============================================================
-- Fires on ANY change to a payment, whoever made it and however. Mark an
-- order paid, log a payment on an invoice, flip cash to bank, correct an
-- amount, remove a payment: the affected days rebuild immediately.
--
-- OLD and NEW are both handled, so moving a payment from one invoice or
-- date to another corrects the day it left as well as the day it joined.
CREATE OR REPLACE FUNCTION trg_payment_refresh_takings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE d date;
BEGIN
  -- The day it moved off (update or delete)
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    FOR d IN SELECT * FROM days_touched_by_invoice(OLD.invoice_id) LOOP
      PERFORM recompute_daily_sales_unchecked(d);
    END LOOP;
    -- A hand-built invoice with no orders behind it counts on the day the
    -- money came in, and that day is not in the list above once the row
    -- has gone. Do it explicitly.
    PERFORM recompute_daily_sales_unchecked(OLD.paid_at::date);
  END IF;

  -- The day it moved on to (insert or update)
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    FOR d IN SELECT * FROM days_touched_by_invoice(NEW.invoice_id) LOOP
      PERFORM recompute_daily_sales_unchecked(d);
    END LOOP;
    PERFORM recompute_daily_sales_unchecked(NEW.paid_at::date);
  END IF;

  RETURN NULL;   -- AFTER trigger; return value is ignored
END;
$$;

DROP TRIGGER IF EXISTS trg_invoice_payments_takings ON invoice_payments;
CREATE TRIGGER trg_invoice_payments_takings
  AFTER INSERT OR UPDATE OR DELETE ON invoice_payments
  FOR EACH ROW EXECUTE FUNCTION trg_payment_refresh_takings();


-- Orders matter too. A weekly invoice splits its payments across its
-- deliveries in proportion to what each was worth (migration 037), so
-- moving an order to a different delivery day, adding it to or taking it
-- off an invoice, or cancelling it changes the share landing on every
-- OTHER day on that invoice as well. Migration 041 flagged this as a
-- real source of stale figures.
--
-- Deliberately narrow: only fires when the invoice link or the delivery
-- slot actually changes, not on every touch of an order.
CREATE OR REPLACE FUNCTION trg_order_refresh_takings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE d date;
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') AND OLD.invoice_id IS NOT NULL THEN
    FOR d IN SELECT * FROM days_touched_by_invoice(OLD.invoice_id) LOOP
      PERFORM recompute_daily_sales_unchecked(d);
    END LOOP;
  END IF;

  IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.invoice_id IS NOT NULL THEN
    FOR d IN SELECT * FROM days_touched_by_invoice(NEW.invoice_id) LOOP
      PERFORM recompute_daily_sales_unchecked(d);
    END LOOP;
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_orders_takings ON orders;
CREATE TRIGGER trg_orders_takings
  AFTER INSERT OR DELETE OR UPDATE OF invoice_id, delivery_slot_id, status ON orders
  FOR EACH ROW EXECUTE FUNCTION trg_order_refresh_takings();


-- ============================================================
-- 4. takings_for_day — what the dashboard panel reads
-- ============================================================
-- Two different questions, both of which Jon asks, answered side by side:
--
--   RECEIVED  — money that physically arrived today. This is his till.
--               Every payment stamped today, cash and bank, plus
--               anything he typed into the "+ extra" box on Daily Sales
--               for takings that never went near an order.
--
--   DELIVERED — what today's deliveries were worth, and how much of that
--               is still owed. This is his day's trade.
--
-- They are usually the same on a domestic day, where he takes the money
-- at the door. They differ when a pub pays Friday for a week of drops —
-- that money is RECEIVED on the Friday, but the sales belong to the days
-- the meat actually went out, which is how the weekly sheet and the
-- accountant's figures treat it. Showing both means Jon never has to
-- wonder which one he is looking at.
CREATE OR REPLACE FUNCTION takings_for_day(p_date date)
RETURNS TABLE (
  sale_date        date,
  received_cash    numeric,
  received_bank    numeric,
  received_total   numeric,
  payment_count    integer,
  delivered_value  numeric,
  delivered_paid   numeric,
  delivered_unpaid numeric,
  order_count      integer,
  extra_cash       numeric,
  extra_bank       numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pay_cash  numeric(10,2) := 0;
  v_pay_bank  numeric(10,2) := 0;
  v_pay_n     integer       := 0;
  v_xtra_cash numeric(10,2) := 0;
  v_xtra_bank numeric(10,2) := 0;
  v_del_value numeric(10,2) := 0;
  v_del_paid  numeric(10,2) := 0;
  v_ord_n     integer       := 0;
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can see the takings';
  END IF;

  -- Money received on the day itself
  SELECT
    ROUND(COALESCE(SUM(amount) FILTER (WHERE method = 'cash'), 0), 2),
    ROUND(COALESCE(SUM(amount) FILTER (WHERE method = 'bacs'), 0), 2),
    COUNT(*)
  INTO v_pay_cash, v_pay_bank, v_pay_n
  FROM invoice_payments
  WHERE paid_at::date = p_date;

  -- Anything hand-typed into the "+ extra" boxes for that day
  SELECT ROUND(COALESCE(cash, 0), 2), ROUND(COALESCE(bank, 0), 2)
  INTO v_xtra_cash, v_xtra_bank
  FROM daily_sales WHERE daily_sales.sale_date = p_date;

  v_xtra_cash := COALESCE(v_xtra_cash, 0);
  v_xtra_bank := COALESCE(v_xtra_bank, 0);

  -- What that day's deliveries were worth
  SELECT
    ROUND(COALESCE(SUM(COALESCE(
      (SELECT SUM(oi.line_total) FROM order_items oi WHERE oi.order_id = o.id),
      o.total_amount, 0)), 0), 2),
    COUNT(*)
  INTO v_del_value, v_ord_n
  FROM orders o
  JOIN delivery_slots s ON s.id = o.delivery_slot_id
  WHERE s.delivery_date = p_date
    AND o.status <> 'cancelled';

  -- How much of that has been paid — read from the same allocations the
  -- weekly sheet and accountant export use, so the three can never
  -- disagree with each other.
  SELECT ROUND(COALESCE(SUM(amount), 0), 2)
  INTO v_del_paid
  FROM daily_payment_allocations
  WHERE daily_payment_allocations.sale_date = p_date;

  RETURN QUERY SELECT
    p_date,
    v_pay_cash + v_xtra_cash,
    v_pay_bank + v_xtra_bank,
    v_pay_cash + v_xtra_cash + v_pay_bank + v_xtra_bank,
    v_pay_n,
    v_del_value,
    v_del_paid,
    GREATEST(v_del_value - v_del_paid, 0),
    v_ord_n,
    v_xtra_cash,
    v_xtra_bank;
END;
$$;

GRANT EXECUTE ON FUNCTION takings_for_day(date) TO authenticated;


-- ============================================================
-- 5. One-off catch-up
-- ============================================================
-- Rebuild every day that has any payment against it, so anything that
-- drifted before the triggers existed is corrected now rather than only
-- from the next payment onwards.
DO $$
DECLARE d date;
BEGIN
  FOR d IN SELECT DISTINCT sale_date FROM daily_payment_allocations WHERE sale_date IS NOT NULL
  LOOP
    PERFORM recompute_daily_sales_unchecked(d);
  END LOOP;
END $$;


-- ============================================================
-- NOTES FOR PHIL
--
-- * The triggers do NOT replace delete_invoice_cascade (041). When an
--   invoice is deleted its payments cascade away, and by the time the
--   payment trigger fires the invoice row has already gone — so there is
--   nothing left to work the delivery dates out from. 041 captures those
--   days BEFORE the delete, which is still the only way to do it. Keep
--   calling it; the trigger is the safety net for everything else.
--
-- * The existing recompute calls in the admin JavaScript are now
--   belt-and-braces rather than load-bearing. They are harmless (the sums
--   are idempotent) and worth keeping, because they make the figure
--   refresh in the same request rather than on the next read.
--
-- * The orders trigger fires on status changes so a cancelled order stops
--   counting towards the day's delivered value. It only does real work
--   when the order is on an invoice.
--
-- * takings_for_day is admin-only and SECURITY DEFINER because it reads
--   daily_payment_allocations, which is deliberately not exposed to the
--   API. Customers cannot reach it.
--
-- * Reusable for other AXRIK clients: "what did I take today, split by
--   how they paid" is the single most asked-for number in any cash trade.
--   The two-figure answer — received vs delivered — is the bit that stops
--   the arguments about whose number is right.
-- ============================================================
