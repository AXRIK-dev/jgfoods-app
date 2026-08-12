-- ============================================================
-- Migration 038: Make "Combine this week onto one" actually
-- combine everything
-- JG Foods Admin App
-- ============================================================
-- THE PROBLEM (found on Billy Bunters, 12 Aug 2026)
-- Jon had two invoices for the same customer, same week:
--
--   BBL-1035     Week of 10-16 Aug    £150.05   sent
--   BBL-232242   12 Aug 2026          £174.40   sent
--
-- and wanted one document to hand the client. Pressing "Combine
-- this week onto one" would have quietly got it wrong, twice over:
--
-- 1. It only recognised an invoice as belonging to a week if the
--    invoice carried a week stamp, or its lines came from ORDERS
--    delivered that week. BBL-232242 was raised by hand — no orders
--    behind it, no week stamp — so it was invisible to the merge.
--    Jon would have pressed Combine, been told it worked, and still
--    had two invoices.
--
-- 2. With no DRAFT weekly invoice to collect into, it minted a
--    brand-new invoice number and moved everything onto that. Jon
--    would end up with a third reference for work the customer has
--    already seen under two others.
--
-- THE FIX
-- * An invoice belongs to a week if ANY of these is true:
--     - it carries that week stamp, or
--     - a line came from an order delivered that week, or
--     - a line carries a delivery date in that week, or
--     - it has no orders behind it at all and was ISSUED that week.
--   The last one is what catches everything Jon has typed by hand.
--
-- * Target: reuse the open weekly invoice if there is one; otherwise
--   keep the OLDEST real invoice in the set and stamp it with the
--   week. The customer keeps a reference they've already seen and no
--   spare number is burned.
--
-- SAFE TO RE-RUN. Replaces one function; changes no data.
-- ============================================================

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
  v_paid     integer;
  v_src      uuid;
  v_ids      uuid[];
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can combine invoices.';
  END IF;

  v_wk_start := jg_week_start(p_week_start);
  v_wk_end   := v_wk_start + 6;

  SELECT array_agg(i.id), count(*) FILTER (WHERE i.status = 'paid')
  INTO v_ids, v_paid
  FROM invoices i
  WHERE i.customer_id = p_customer_id
    AND (
      -- already stamped with this week
      i.week_start = v_wk_start

      -- a line came from an order delivered that week
      OR EXISTS (
        SELECT 1 FROM invoice_items ii
        WHERE ii.invoice_id = i.id
          AND ii.order_id IS NOT NULL
          AND jg_order_delivery_date(ii.order_id) BETWEEN v_wk_start AND v_wk_end
      )

      -- a line carries a delivery date in that week
      OR EXISTS (
        SELECT 1 FROM invoice_items ii
        WHERE ii.invoice_id = i.id
          AND ii.delivery_date BETWEEN v_wk_start AND v_wk_end
      )

      -- raised by hand with nothing behind it, issued that week
      OR (
        NOT EXISTS (
          SELECT 1 FROM invoice_items ii
          WHERE ii.invoice_id = i.id AND ii.order_id IS NOT NULL
        )
        AND NOT EXISTS (SELECT 1 FROM orders o WHERE o.invoice_id = i.id)
        AND COALESCE(i.issued_at::date, i.created_at::date) BETWEEN v_wk_start AND v_wk_end
      )
    );

  IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'No invoices found for that customer in the week beginning %.', v_wk_start;
  END IF;

  IF v_paid > 0 THEN
    RAISE EXCEPTION 'Some of that week''s invoices have already been paid — they can''t be combined. Unmark the payment first if that was a mistake.';
  END IF;

  IF array_length(v_ids, 1) = 1 THEN
    -- Nothing to combine, but stamp it with the week so it's labelled
    -- properly in the list and a later order can join it.
    UPDATE invoices SET week_start = v_wk_start, week_end = v_wk_end
    WHERE id = v_ids[1] AND week_start IS DISTINCT FROM v_wk_start;
    RETURN v_ids[1];
  END IF;

  -- Prefer the open weekly invoice; failing that, the oldest of the set,
  -- so the customer keeps a reference they've already been given.
  SELECT id INTO v_target
  FROM invoices
  WHERE id = ANY(v_ids) AND week_start = v_wk_start AND status = 'draft'
  ORDER BY created_at
  LIMIT 1;

  IF v_target IS NULL THEN
    SELECT id INTO v_target
    FROM invoices
    WHERE id = ANY(v_ids)
    ORDER BY COALESCE(issued_at, created_at), created_at
    LIMIT 1;
  END IF;

  UPDATE invoices
  SET week_start = v_wk_start,
      week_end   = v_wk_end,
      order_id   = NULL          -- it now covers more than one delivery
  WHERE id = v_target;

  -- Move the lines across, repoint the orders, bin the empty shells.
  FOREACH v_src IN ARRAY v_ids LOOP
    CONTINUE WHEN v_src = v_target;
    UPDATE invoice_items    SET invoice_id = v_target WHERE invoice_id = v_src;
    UPDATE orders           SET invoice_id = v_target WHERE invoice_id = v_src;
    -- invoice_payments cascades on delete, so part payments must move first
    -- or banked money would be silently erased.
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

  -- The combined invoice may now span days the takings were split over,
  -- so put the finances back in step (migration 037).
  BEGIN
    PERFORM recompute_daily_sales_for_invoice(v_target);
  EXCEPTION WHEN undefined_function THEN
    NULL;   -- 037 not applied yet; nothing to keep in step
  END;

  RETURN v_target;
END;
$$;

GRANT EXECUTE ON FUNCTION merge_week_invoices(uuid, date) TO authenticated;

-- ============================================================
-- NOTES
-- * Billy Bunters' case: BBL-1035 (weekly, £150.05) and BBL-232242
--   (hand-built, £174.40) now both match the 10-16 Aug week. They
--   combine onto BBL-1035 — the older of the two — at £324.45, with
--   each delivery and site as its own section.
-- * Combining a single invoice is no longer an error; it just stamps
--   it with its week so it's labelled correctly.
-- ============================================================
