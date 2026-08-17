-- ============================================================
-- Migration 045: Who paid what — the daily reconciliation list
-- JG Foods Admin App
-- ============================================================
-- WHAT JON ASKED FOR
-- "Can we mark down cash sale by each individual customer and bank
--  sale by each individual customer, and have a little tab whether or
--  not it's being paid or not? Just so I can reconcile on a daily
--  basis — I have my usual ways of doing things."
--
-- Migration 044 gave him the day's total split cash vs bank. This gives
-- him the list behind it, which is what he actually reconciles against:
-- every stop on today's run, what it came to, and whether the money is
-- in — cash, bank, or still owed.
--
-- TWO GROUPS, because his cash tin has to balance and one list can't do
-- both jobs:
--
--   'run'   — every delivery going out today, paid or not. This is the
--             round he's just done, in the order he did it.
--   'other' — money that came in today against a DIFFERENT day's
--             deliveries. A pub settling last week's invoice is real
--             cash in his pocket tonight but has nothing to do with
--             today's round. Without this group his count would never
--             match.
--
-- The two groups together are exactly the day's takings from 044, so
-- the list and the headline figure can't drift apart.
--
-- SAFE TO RE-RUN. Adds one read-only function; changes no data.
--
-- RUN AFTER: 044.
-- ============================================================


-- ============================================================
-- How much of THIS order has been paid?
-- ============================================================
-- An order on a plain per-delivery invoice is simple: the invoice's
-- payments are that order's payments.
--
-- A weekly invoice covers several deliveries at once, so a part-payment
-- against it isn't "this delivery paid, that one not" — it's a share of
-- each. Split it the same way migration 037 splits it across days, in
-- proportion to what each delivery was worth, so the per-customer list
-- adds up to the same money as the day total. Anything else and Jon
-- reconciles to a figure that doesn't match his own dashboard.
CREATE OR REPLACE VIEW order_payment_state AS
WITH inv_orders AS (
  SELECT DISTINCT
    i.id AS invoice_id,
    o.id AS order_id,
    COALESCE(
      (SELECT SUM(oi.line_total) FROM order_items oi WHERE oi.order_id = o.id),
      o.total_amount, 0
    ) AS order_value
  FROM invoices i
  JOIN orders o
    ON o.invoice_id = i.id
    OR i.order_id   = o.id
),
inv_totals AS (
  SELECT invoice_id, SUM(order_value) AS total_value, COUNT(*) AS order_count
  FROM inv_orders GROUP BY invoice_id
),
inv_paid AS (
  SELECT
    invoice_id,
    SUM(amount)                                    AS paid_total,
    SUM(amount) FILTER (WHERE method = 'cash')     AS paid_cash,
    SUM(amount) FILTER (WHERE method = 'bacs')     AS paid_bank
  FROM invoice_payments GROUP BY invoice_id
)
SELECT
  io.order_id,
  io.invoice_id,
  io.order_value,
  ROUND(COALESCE(ip.paid_total, 0) * CASE
    WHEN it.total_value > 0 THEN io.order_value / it.total_value
    ELSE 1.0 / it.order_count
  END, 2) AS paid_amount,
  ROUND(COALESCE(ip.paid_cash, 0) * CASE
    WHEN it.total_value > 0 THEN io.order_value / it.total_value
    ELSE 1.0 / it.order_count
  END, 2) AS paid_cash,
  ROUND(COALESCE(ip.paid_bank, 0) * CASE
    WHEN it.total_value > 0 THEN io.order_value / it.total_value
    ELSE 1.0 / it.order_count
  END, 2) AS paid_bank
FROM inv_orders io
JOIN inv_totals it ON it.invoice_id = io.invoice_id
LEFT JOIN inv_paid ip ON ip.invoice_id = io.invoice_id;

REVOKE ALL ON order_payment_state FROM anon, authenticated;


-- ============================================================
-- takings_breakdown_for_day — the list on the dashboard
-- ============================================================
CREATE OR REPLACE FUNCTION takings_breakdown_for_day(p_date date)
RETURNS TABLE (
  grp            text,      -- 'run' = today's deliveries, 'other' = money in from another day
  order_id       uuid,
  invoice_id     uuid,
  customer_id    uuid,
  customer_name  text,
  site_label     text,
  amount         numeric,   -- what the delivery came to ('run') / what was paid ('other')
  paid_amount    numeric,
  paid_cash      numeric,
  paid_bank      numeric,
  pay_state      text,      -- 'cash' | 'bank' | 'split' | 'part' | 'unpaid'
  detail         text,      -- context line, e.g. the invoice it settles
  sort_key       text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can see the takings';
  END IF;

  RETURN QUERY
  -- ── Group 1: every stop on today's run ──────────────────────
  SELECT
    'run'::text,
    o.id,
    ops.invoice_id,
    o.customer_id,
    c.name::text,
    COALESCE(cs.label, '')::text,
    COALESCE(ops.order_value, o.total_amount, 0)::numeric,
    COALESCE(ops.paid_amount, 0)::numeric,
    COALESCE(ops.paid_cash, 0)::numeric,
    COALESCE(ops.paid_bank, 0)::numeric,
    CASE
      WHEN COALESCE(ops.paid_amount, 0) <= 0.001 THEN 'unpaid'
      -- Still short of the full amount: say so rather than showing a tick.
      WHEN COALESCE(ops.paid_amount, 0) + 0.005
           < COALESCE(ops.order_value, o.total_amount, 0) THEN 'part'
      WHEN COALESCE(ops.paid_cash, 0) > 0.001
       AND COALESCE(ops.paid_bank, 0) > 0.001 THEN 'split'
      WHEN COALESCE(ops.paid_cash, 0) > 0.001 THEN 'cash'
      ELSE 'bank'
    END::text,
    CASE
      WHEN c.billing_mode = 'weekly' THEN 'On their weekly invoice'
      ELSE ''
    END::text,
    '1'::text
  FROM orders o
  JOIN delivery_slots s  ON s.id = o.delivery_slot_id
  JOIN customers c       ON c.id = o.customer_id
  LEFT JOIN customer_sites cs ON cs.id = o.site_id
  LEFT JOIN order_payment_state ops ON ops.order_id = o.id
  WHERE s.delivery_date = p_date
    AND o.status <> 'cancelled'

  UNION ALL

  -- ── Group 2: money in today that ISN'T for today's round ────
  -- One line per payment, showing only the part that doesn't belong to a
  -- delivery on today's run — otherwise the same money would appear
  -- twice, once here and once as a tick against a stop above.
  --
  -- The "share" below is what fraction of the invoice today's deliveries
  -- account for, so:
  --   invoice has nothing delivered today  -> share 0   -> whole payment
  --   invoice is purely today's delivery   -> share 1   -> nothing (right)
  --   weekly invoice spanning today + Mon  -> part      -> the remainder
  -- One formula, all three cases, and every pound taken today lands
  -- somewhere in the list exactly once.
  SELECT
    'other'::text,
    NULL::uuid,
    p.invoice_id,
    i.customer_id,
    c2.name::text,
    ''::text,
    ROUND(p.amount * (1 - rest.today_share), 2)::numeric,
    ROUND(p.amount * (1 - rest.today_share), 2)::numeric,
    (CASE WHEN p.method = 'cash' THEN ROUND(p.amount * (1 - rest.today_share), 2) ELSE 0 END)::numeric,
    (CASE WHEN p.method = 'bacs' THEN ROUND(p.amount * (1 - rest.today_share), 2) ELSE 0 END)::numeric,
    (CASE WHEN p.method = 'cash' THEN 'cash' ELSE 'bank' END)::text,
    (COALESCE(i.invoice_number, 'invoice')
      || CASE
           WHEN i.week_start IS NOT NULL
             THEN ' · w/e ' || to_char(COALESCE(i.week_end, i.week_start), 'DD Mon')
           ELSE ''
         END)::text,
    '2'::text
  FROM invoice_payments p
  JOIN invoices  i  ON i.id = p.invoice_id
  JOIN customers c2 ON c2.id = i.customer_id
  CROSS JOIN LATERAL (
    SELECT COALESCE(
      SUM(ops.order_value) FILTER (WHERE s2.delivery_date = p_date
                                     AND o2.status <> 'cancelled')
      / NULLIF(SUM(ops.order_value), 0), 0) AS today_share
    FROM order_payment_state ops
    JOIN orders o2         ON o2.id = ops.order_id
    JOIN delivery_slots s2 ON s2.id = o2.delivery_slot_id
    WHERE ops.invoice_id = p.invoice_id
  ) rest
  WHERE p.paid_at::date = p_date
    AND ROUND(p.amount * (1 - rest.today_share), 2) > 0.005

  -- 13 = sort_key (run before other), 5 = customer_name
  ORDER BY 13, 5;
END;
$$;

GRANT EXECUTE ON FUNCTION takings_breakdown_for_day(date) TO authenticated;


-- ============================================================
-- NOTES FOR PHIL
--
-- * The two groups add up to the same money as takings_for_day(), because
--   both read the same payments. If they ever disagree, something is
--   wrong with the data rather than with one of the two views.
--
-- * 'part' exists because a weekly customer paying half their invoice
--   shouldn't show a green tick against every delivery on it. Jon needs
--   to see he's still owed something.
--
-- * A multi-site customer gets one line per site, labelled, because
--   that's how the deliveries actually happen and how he'd count them.
--
-- * order_payment_state is REVOKEd from the API for the same reason as
--   daily_payment_allocations — it's read only from inside SECURITY
--   DEFINER functions, so RLS can't be side-stepped through it.
--
-- * Reusable for other AXRIK clients: "the list behind today's number"
--   is what any owner-operator actually reconciles against. The headline
--   figure gets built first and then everyone asks for this.
-- ============================================================
