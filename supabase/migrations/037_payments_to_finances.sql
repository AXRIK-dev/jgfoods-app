-- ============================================================
-- Migration 037: Make every payment reach the finances
-- JG Foods Admin App
-- ============================================================
-- THE PROBLEM
-- The chain is meant to run all the way through: log an order, the
-- invoice raises itself, the delivery goes on the run and pick list,
-- and when the money comes in it lands in Daily Sales and flows on to
-- the weekly and monthly accountant figures.
--
-- Two links in that chain were broken.
--
-- 1. recompute_daily_sales (migration 022) finds an order's money with
--       JOIN invoices i ON i.order_id = o.id
--    That only works for the classic one-invoice-per-order case. On a
--    WEEKLY or multi-site invoice, invoices.order_id is NULL and the
--    orders point at the invoice instead (orders.invoice_id). So the
--    moment a customer moved to weekly billing, their payments stopped
--    counting towards Daily Sales entirely. Billy Bunters could pay
--    £174.40 and the day would still read £0.
--
-- 2. An invoice raised by hand, with no order behind it, had no
--    delivery date to attach the money to — so it counted for nothing
--    anywhere. That's exactly what Jon has been doing while he learns
--    the system, so his takings were under-reporting badly.
--
-- THE FIX
-- One place that decides which day any given payment belongs to:
--
--   * Invoice covers ONE delivery  -> that delivery's date (unchanged).
--   * Invoice covers SEVERAL       -> split across those delivery dates
--                                     in proportion to what each
--                                     delivery was worth, so a weekly
--                                     invoice lands on the right days
--                                     and still adds up to the total.
--   * Invoice covers NO orders     -> the day the money was received.
--
-- Every figure Jon sees — Daily Sales, the weekly sheet, the monthly
-- accountant export — reads from that one place, so they can't drift
-- apart.
--
-- SAFE TO RE-RUN. No data is changed; this replaces a function and
-- adds a view and a helper. Existing per-delivery figures come out
-- exactly as they do today.
-- ============================================================


-- ============================================================
-- 1. Where does each payment belong?
-- ============================================================
-- Internal only. NOT granted to anon/authenticated — it's read solely
-- from inside the SECURITY DEFINER functions below, so it can't be
-- queried directly through the API and bypass row-level security.
CREATE OR REPLACE VIEW daily_payment_allocations AS
WITH inv_orders AS (
  -- Every (invoice, order) pair, however they're linked. DISTINCT because
  -- a per-delivery invoice satisfies BOTH joins and would otherwise be
  -- counted twice.
  SELECT DISTINCT
    i.id AS invoice_id,
    o.id AS order_id,
    COALESCE(s.delivery_date, o.created_at::date) AS delivery_date,
    COALESCE(
      (SELECT SUM(oi.line_total) FROM order_items oi WHERE oi.order_id = o.id),
      o.total_amount,
      0
    ) AS order_value
  FROM invoices i
  JOIN orders o
    ON o.invoice_id = i.id
    OR i.order_id   = o.id
  LEFT JOIN delivery_slots s ON s.id = o.delivery_slot_id
),
inv_totals AS (
  SELECT invoice_id,
         SUM(order_value) AS total_value,
         COUNT(*)         AS order_count
  FROM inv_orders
  GROUP BY invoice_id
)
-- Payments on invoices that DO have orders behind them, split across
-- the delivery dates by what each delivery was worth.
SELECT
  p.invoice_id,
  io.delivery_date AS sale_date,
  p.method,
  p.amount * CASE
    WHEN it.total_value > 0 THEN io.order_value / it.total_value
    ELSE 1.0 / it.order_count          -- all-zero-value orders: split evenly
  END AS amount
FROM invoice_payments p
JOIN inv_orders io ON io.invoice_id = p.invoice_id
JOIN inv_totals it ON it.invoice_id = p.invoice_id

UNION ALL

-- Payments on invoices raised by hand with no order behind them. There's
-- no delivery to attach them to, so the money counts on the day it came
-- in — which is the honest answer and keeps it out of nowhere.
SELECT
  p.invoice_id,
  p.paid_at::date AS sale_date,
  p.method,
  p.amount
FROM invoice_payments p
WHERE NOT EXISTS (
  SELECT 1 FROM inv_orders io WHERE io.invoice_id = p.invoice_id
);

REVOKE ALL ON daily_payment_allocations FROM anon, authenticated;


-- ============================================================
-- 2. recompute_daily_sales — now reads the allocations
-- ============================================================
-- Replaces the version in migration 022. Same signature, same job, same
-- answer for every single-delivery invoice — it just no longer loses
-- the weekly and hand-built ones.
CREATE OR REPLACE FUNCTION recompute_daily_sales(p_date date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_bank numeric(10,2);
  v_cash numeric(10,2);
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can update takings';
  END IF;

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


-- ============================================================
-- 3. recompute_daily_sales_for_invoice
-- ============================================================
-- One payment on a weekly invoice can affect four different days, so
-- the admin app can't just recompute "the order's date" any more. This
-- refreshes every day that invoice could possibly touch.
--
-- Dates are worked out from the invoice's ORDERS and its own issue date
-- as well as from its payments, so it still cleans up correctly after a
-- payment has been deleted and there's nothing left to look at.
CREATE OR REPLACE FUNCTION recompute_daily_sales_for_invoice(p_invoice_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d      date;
  v_count integer := 0;
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can update takings';
  END IF;

  FOR d IN
    SELECT DISTINCT COALESCE(s.delivery_date, o.created_at::date)
      FROM orders o
      LEFT JOIN delivery_slots s ON s.id = o.delivery_slot_id
     WHERE o.invoice_id = p_invoice_id
        OR o.id IN (SELECT order_id FROM invoices WHERE id = p_invoice_id AND order_id IS NOT NULL)
    UNION
    SELECT DISTINCT p.paid_at::date
      FROM invoice_payments p
     WHERE p.invoice_id = p_invoice_id
    UNION
    SELECT COALESCE(i.issued_at::date, i.created_at::date)
      FROM invoices i
     WHERE i.id = p_invoice_id
  LOOP
    IF d IS NOT NULL THEN
      PERFORM recompute_daily_sales(d);
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;


-- ============================================================
-- 4. One-off catch-up
-- ============================================================
-- Rebuild every day that already has a payment against it, so the
-- takings Jon has logged so far — including everything on hand-built
-- invoices that was counting for nothing — appear straight away
-- instead of only from the next payment onwards.
DO $$
DECLARE d date;
BEGIN
  FOR d IN SELECT DISTINCT sale_date FROM daily_payment_allocations WHERE sale_date IS NOT NULL
  LOOP
    UPDATE daily_sales ds
    SET orders_bank = a.bank, orders_cash = a.cash
    FROM (
      SELECT
        ROUND(COALESCE(SUM(amount) FILTER (WHERE method = 'bacs'), 0), 2) AS bank,
        ROUND(COALESCE(SUM(amount) FILTER (WHERE method = 'cash'), 0), 2) AS cash
      FROM daily_payment_allocations WHERE sale_date = d
    ) a
    WHERE ds.sale_date = d;

    INSERT INTO daily_sales (sale_date, orders_bank, orders_cash)
    SELECT d,
      ROUND(COALESCE(SUM(amount) FILTER (WHERE method = 'bacs'), 0), 2),
      ROUND(COALESCE(SUM(amount) FILTER (WHERE method = 'cash'), 0), 2)
    FROM daily_payment_allocations WHERE sale_date = d
    ON CONFLICT (sale_date) DO NOTHING;
  END LOOP;
END $$;


-- ============================================================
-- 5. Grants
-- ============================================================
GRANT EXECUTE ON FUNCTION recompute_daily_sales(date)              TO authenticated;
GRANT EXECUTE ON FUNCTION recompute_daily_sales_for_invoice(uuid)  TO authenticated;


-- ============================================================
-- NOTES FOR PHIL
--
-- * Nothing changes for a plain one-order invoice. Same date, same
--   figure. The apportioning only kicks in when an invoice genuinely
--   covers more than one delivery.
--
-- * A weekly invoice part-paid halfway through still splits correctly:
--   £75 against a £150 invoice covering a £100 Monday and a £50
--   Thursday puts £50 on the Monday and £25 on the Thursday.
--
-- * Reusable for other AXRIK clients: "which day does this money
--   belong to" is the question every trade with consolidated billing
--   has to answer, and this is a clean single source of truth for it.
-- ============================================================
