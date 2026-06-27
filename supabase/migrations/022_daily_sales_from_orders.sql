-- ============================================================
-- Migration 022: Auto-fill Daily Sales from paid orders
-- JG Foods Admin App
-- ============================================================
-- Makes the bookkeeping fill itself: each delivery day's takings come
-- automatically from that day's PAID orders (cash vs bank), so Jon
-- barely types anything. Additive model — these auto figures sit
-- ALONGSIDE the existing manual bank/cash columns (for the rare takings
-- not captured as an order), so manual entries are never overwritten.
--
--   day total = orders_bank + bank (manual) + orders_cash + cash (manual)
--
-- The admin app calls recompute_daily_sales(date) whenever an order on
-- that day is paid, edited or deleted, keeping it perfectly in step.
-- ============================================================

ALTER TABLE daily_sales
  ADD COLUMN IF NOT EXISTS orders_bank numeric(10,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS orders_cash numeric(10,2) NOT NULL DEFAULT 0;

-- Recompute a single delivery date's order-takings from the paid orders.
-- Sums invoice_payments (cash / bacs) for every order delivered that day.
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
    COALESCE(SUM(p.amount) FILTER (WHERE p.method = 'bacs'), 0),
    COALESCE(SUM(p.amount) FILTER (WHERE p.method = 'cash'), 0)
  INTO v_bank, v_cash
  FROM orders o
  JOIN delivery_slots   s ON s.id = o.delivery_slot_id
  JOIN invoices         i ON i.order_id = o.id
  JOIN invoice_payments p ON p.invoice_id = i.id
  WHERE s.delivery_date = p_date;

  INSERT INTO daily_sales (sale_date, orders_bank, orders_cash)
  VALUES (p_date, v_bank, v_cash)
  ON CONFLICT (sale_date)
  DO UPDATE SET orders_bank = EXCLUDED.orders_bank,
                orders_cash = EXCLUDED.orders_cash;
END;
$$;

-- When to run: after 016 (daily_sales) and 004/006 (payments + roles).
-- Safe + idempotent.
-- ============================================================
