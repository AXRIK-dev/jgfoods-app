-- ============================================================
-- Migration 047: Repair invoice delivery dates from the delivery slot
-- JG Foods Admin App
-- ============================================================
-- WHAT WENT WRONG IN 046
--
-- 046 back-filled invoices.delivery_date from invoice_items.delivery_date,
-- then fell back to issued_at::date for anything the line items couldn't
-- answer:
--
--     UPDATE invoices SET delivery_date = issued_at::date  -- <-- the mistake
--
-- On an invoice raised automatically when an order was logged, issued_at WAS
-- the creation timestamp — the very thing we were trying to stop using. So
-- any invoice whose line items had no delivery_date got "fixed" to the day it
-- was typed up. Those still show today's date, which is exactly the symptom
-- Jon reported.
--
-- Line items lose their delivery_date in more cases than I allowed for:
-- invoices raised before migration 036 existed, and any order a customer
-- edited online (edit_my_order rebuilt the lines and dropped the column —
-- 046 fixed that going forward, but the damage was already done).
--
-- THE FIX
--
-- Stop deriving the date from the invoice at all. The authoritative answer
-- has always been the DELIVERY SLOT the order is booked into:
--
--     orders -> delivery_slots.delivery_date
--
-- That's set when Jon picks the delivery day on Log Order, or when a customer
-- picks a slot on the website, and nothing since has been able to corrupt it.
-- This migration re-derives every per-delivery invoice from it, and repairs
-- the line items on the way through so the same fallback can't misfire again.
--
-- An invoice links to its order two ways — invoices.order_id for a plain one,
-- orders.invoice_id for multi-site and weekly. Both are followed.
--
-- SAFE TO RE-RUN. Changes dates only. No amounts, no invoice numbers, no
-- payment records, no statuses.
--
-- Run AFTER 046.
-- ============================================================


-- ── 1. Look before you leap ───────────────────────────────────
-- Run this on its own first if you want to see the damage. Every row it
-- returns is an invoice currently showing the wrong date.
--
--   SELECT i.invoice_number,
--          i.delivery_date          AS showing_now,
--          min(s.delivery_date)     AS should_be,
--          i.created_at::date       AS typed_up_on
--   FROM invoices i
--   JOIN orders o          ON (o.id = i.order_id OR o.invoice_id = i.id)
--   JOIN delivery_slots s  ON s.id = o.delivery_slot_id
--   WHERE i.week_start IS NULL
--   GROUP BY i.id, i.invoice_number, i.delivery_date, i.created_at
--   HAVING i.delivery_date IS DISTINCT FROM min(s.delivery_date)
--   ORDER BY i.created_at DESC;


-- ── 2. Repair the line items first ────────────────────────────
-- These feed the invoice date, the per-delivery grouping on a weekly
-- invoice, and the split function. Wrong here is wrong in three places.
UPDATE invoice_items ii
SET    delivery_date = s.delivery_date
FROM   orders o
JOIN   delivery_slots s ON s.id = o.delivery_slot_id
WHERE  ii.order_id = o.id
  AND  s.delivery_date IS NOT NULL
  AND  ii.delivery_date IS DISTINCT FROM s.delivery_date;


-- ── 3. Repair the invoices themselves ─────────────────────────
-- Earliest delivery on the invoice, straight from the slots. Weekly
-- invoices are skipped — they're headed by their week, not by one date.
WITH from_slots AS (
  SELECT i.id                    AS invoice_id,
         min(s.delivery_date)    AS deliv
  FROM   invoices i
  JOIN   orders o         ON (o.id = i.order_id OR o.invoice_id = i.id)
  JOIN   delivery_slots s ON s.id = o.delivery_slot_id
  WHERE  i.week_start IS NULL
  GROUP  BY i.id
)
UPDATE invoices i
SET    delivery_date = f.deliv
FROM   from_slots f
WHERE  i.id = f.invoice_id
  AND  f.deliv IS NOT NULL
  AND  i.delivery_date IS DISTINCT FROM f.deliv;


-- ── 4. Hand-built invoices with no order behind them ──────────
-- Nothing to re-derive from, so their own line items are the best record —
-- that's the date Jon chose on the invoice generator. Only fills blanks;
-- never overwrites a date that's already there.
UPDATE invoices i
SET    delivery_date = d.first_delivery
FROM ( SELECT invoice_id, min(delivery_date) AS first_delivery
       FROM   invoice_items
       WHERE  delivery_date IS NOT NULL
       GROUP  BY invoice_id ) d
WHERE  i.id = d.invoice_id
  AND  i.delivery_date IS NULL
  AND  i.week_start    IS NULL;

-- Deliberately NO fallback to issued_at here. That was the bug in 046: it
-- turned "we don't know" into a confidently wrong date. An invoice with no
-- delivery date left prints without one, which is honest and visible, rather
-- than quietly showing the day it was typed up.


-- ── 5. Bring issued_at and the 30 days back into line ─────────
UPDATE invoices
SET    issued_at = (delivery_date + time '12:00') AT TIME ZONE 'Europe/London'
WHERE  delivery_date IS NOT NULL
  AND  week_start    IS NULL
  AND  status       <> 'draft';

UPDATE invoices
SET    due_at = ((delivery_date + 30) + time '12:00') AT TIME ZONE 'Europe/London'
WHERE  delivery_date IS NOT NULL
  AND  week_start    IS NULL
  AND  status       <> 'draft'
  AND  invoice_type  = 'invoice'
  AND  due_at IS NOT NULL;


-- ============================================================
-- CHECK IT WORKED
--
--   -- Should now return NOTHING:
--   SELECT i.invoice_number, i.delivery_date, min(s.delivery_date)
--   FROM invoices i
--   JOIN orders o         ON (o.id = i.order_id OR o.invoice_id = i.id)
--   JOIN delivery_slots s ON s.id = o.delivery_slot_id
--   WHERE i.week_start IS NULL
--   GROUP BY i.id, i.invoice_number, i.delivery_date
--   HAVING i.delivery_date IS DISTINCT FROM min(s.delivery_date);
--
--   -- And the dates should read as delivery days, not typing-up days:
--   SELECT invoice_number, delivery_date, created_at::date AS typed_up_on
--   FROM invoices ORDER BY created_at DESC LIMIT 20;
--
--
-- NOTES FOR PHIL
--
-- * Anything still showing NULL delivery_date after this has no delivery slot
--   behind it and no dated line items — almost certainly a very old record.
--   Send me the list and I'll work out where its date should come from.
--
-- * Reusable for other AXRIK clients: when back-filling a date column, derive
--   it from the record that OWNS the fact (here, the delivery slot). Falling
--   back to a created/issued timestamp writes today's date into history and
--   makes a data bug look like a display bug.
-- ============================================================
