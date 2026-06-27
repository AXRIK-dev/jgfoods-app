-- ============================================================
-- Migration 021: Records retention cleanup (6-year default)
-- JG Foods Admin App
-- ============================================================
-- Jon is VAT registered, so invoices/financial records must be kept
-- at least 6 YEARS. This adds two admin-only functions:
--   1. records_due_for_cleanup(years) — counts what's older than the
--      retention period, so Jon can REVIEW before anything is deleted.
--   2. cleanup_old_records(years) — permanently deletes those records
--      in one transaction, in a foreign-key-safe order, and returns
--      how many of each were removed.
--
-- Covers: invoices (+items/payments), orders (+items), delivery
-- temperature logs, and customers with no activity left in the window.
-- Nothing is deleted automatically — the admin app calls #1 to show a
-- summary, and only calls #2 after Jon confirms.
--
-- SAFETY: both functions require the caller to be 'admin'. Deletion is
-- transactional (all-or-nothing). Retention defaults to 6 years.
-- ============================================================

-- 1. What is due for cleanup? (read-only) --------------------------------
CREATE OR REPLACE FUNCTION records_due_for_cleanup(p_years int DEFAULT 6)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cutoff timestamptz := now() - make_interval(years => GREATEST(p_years, 1));
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can review record retention';
  END IF;

  RETURN json_build_object(
    'cutoff',    cutoff,
    'years',     GREATEST(p_years, 1),
    'invoices',  (SELECT count(*) FROM invoices       WHERE created_at   < cutoff),
    'orders',    (SELECT count(*) FROM orders         WHERE created_at   < cutoff),
    'temps',     (SELECT count(*) FROM delivery_temps WHERE delivery_date < cutoff::date),
    'customers', (SELECT count(*) FROM customers c
                  WHERE c.created_at < cutoff
                    AND NOT EXISTS (SELECT 1 FROM orders   o WHERE o.customer_id = c.id AND o.created_at >= cutoff)
                    AND NOT EXISTS (SELECT 1 FROM invoices i WHERE i.customer_id = c.id AND i.created_at >= cutoff))
  );
END;
$$;

-- 2. Perform the cleanup (destructive, transactional) --------------------
CREATE OR REPLACE FUNCTION cleanup_old_records(p_years int DEFAULT 6)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  cutoff  timestamptz := now() - make_interval(years => GREATEST(p_years, 1));
  n_inv   int := 0;
  n_ord   int := 0;
  n_temp  int := 0;
  n_cust  int := 0;
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can delete records';
  END IF;

  -- Invoices first (cascades invoice_items + invoice_payments)
  DELETE FROM invoices WHERE created_at < cutoff;
  GET DIAGNOSTICS n_inv = ROW_COUNT;

  -- Orders next (cascades order_items)
  DELETE FROM orders WHERE created_at < cutoff;
  GET DIAGNOSTICS n_ord = ROW_COUNT;

  -- Temperature logs older than the window
  DELETE FROM delivery_temps WHERE delivery_date < cutoff::date;
  GET DIAGNOSTICS n_temp = ROW_COUNT;

  -- Customers with nothing left in the retention window (their temps cascade)
  DELETE FROM customers c
   WHERE c.created_at < cutoff
     AND NOT EXISTS (SELECT 1 FROM orders   o WHERE o.customer_id = c.id)
     AND NOT EXISTS (SELECT 1 FROM invoices i WHERE i.customer_id = c.id);
  GET DIAGNOSTICS n_cust = ROW_COUNT;

  RETURN json_build_object('invoices', n_inv, 'orders', n_ord, 'temps', n_temp, 'customers', n_cust);
END;
$$;

-- When to run: after 012/015 (needs current_user_role). Safe + idempotent.
-- ============================================================
