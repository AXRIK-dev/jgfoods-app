-- ============================================================
-- Migration 041: Deleting an invoice takes its money with it
-- JG Foods Admin App
-- ============================================================
-- THE PROBLEM
-- Deleting an invoice removed the invoice and its payments — the
-- invoice_payments rows cascade away correctly. But daily_sales stores
-- each day's takings as a SAVED FIGURE (orders_bank / orders_cash),
-- recalculated only when something explicitly asks it to. Nothing did.
--
-- So the money stayed in the books after the invoice it came from had
-- gone. And because the weekly sheet and the monthly accountant export
-- are both built from daily_sales, that ghost figure flowed straight
-- through to the accountant. Jon would have had no way of spotting it —
-- the invoice was gone from the Invoices page, but the cash was still
-- sitting in that day's total.
--
-- The same applied to deleting an ORDER off a weekly invoice. That
-- resynced only the order's own delivery date, but a weekly invoice's
-- payments are shared across every delivery on it in proportion to what
-- each was worth (migration 037) — so removing one delivery changes the
-- share landing on ALL the others, and those days were left stale.
--
-- THE FIX
-- Work out every day the invoice's money currently counts towards
-- BEFORE deleting it, then rebuild each of those days afterwards. One
-- correction at daily_sales level flows through to the weekly sheet and
-- the monthly export automatically, because both read from it.
--
-- SAFE TO RE-RUN. Adds one function; changes no data by itself.
-- ============================================================

CREATE OR REPLACE FUNCTION delete_invoice_cascade(p_invoice_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dates date[];
  d       date;
  n       integer := 0;
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can delete an invoice.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM invoices WHERE id = p_invoice_id) THEN
    RETURN 0;   -- already gone; nothing to put right
  END IF;

  -- Every day this invoice's money currently counts towards. Captured now,
  -- because once the rows are deleted there is nothing left to work it out
  -- from and the figures would quietly stay wrong.
  SELECT array_agg(DISTINCT t.d) INTO v_dates
  FROM (
    SELECT COALESCE(s.delivery_date, o.created_at::date) AS d
      FROM orders o
      LEFT JOIN delivery_slots s ON s.id = o.delivery_slot_id
     WHERE o.invoice_id = p_invoice_id
        OR o.id IN (SELECT order_id FROM invoices
                     WHERE id = p_invoice_id AND order_id IS NOT NULL)
    UNION
    SELECT p.paid_at::date
      FROM invoice_payments p
     WHERE p.invoice_id = p_invoice_id
    UNION
    SELECT COALESCE(i.issued_at::date, i.created_at::date)
      FROM invoices i
     WHERE i.id = p_invoice_id
  ) t
  WHERE t.d IS NOT NULL;

  -- Cascades invoice_items and invoice_payments. Orders survive with their
  -- invoice_id set to NULL, so the delivery record is kept and an invoice
  -- can be raised again later if it was deleted by mistake.
  DELETE FROM invoices WHERE id = p_invoice_id;

  IF v_dates IS NOT NULL THEN
    FOREACH d IN ARRAY v_dates LOOP
      PERFORM recompute_daily_sales(d);
      n := n + 1;
    END LOOP;
  END IF;

  RETURN n;
END;
$$;

GRANT EXECUTE ON FUNCTION delete_invoice_cascade(uuid) TO authenticated;


-- ============================================================
-- NOTES FOR PHIL
--
-- * Daily Sales, the weekly sheet and the monthly accountant export all
--   read from daily_sales, so correcting it there fixes all three. There
--   is no separate figure anywhere that needs its own clean-up.
--
-- * Cash tabs are deliberately untouched. cash_tab_entries has no link to
--   an invoice — it's Jon's own running slate for customers who settle a
--   week's cash in one go — so deleting an invoice can't and shouldn't
--   silently alter it.
--
-- * The ORDER is kept when its invoice is deleted, with invoice_id set to
--   NULL. Deleting a bill shouldn't erase the record of a delivery that
--   actually happened, and it means an invoice deleted in error can be
--   raised again from the order.
--
-- * Reusable for other AXRIK clients: any stored running total has to be
--   rebuilt on delete, not just on create and update. This is the sort of
--   thing that silently overstates a year's income.
-- ============================================================
