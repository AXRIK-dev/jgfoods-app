-- ============================================================
-- Migration 004: Split payments & cash tab support
-- JG Foods Admin App
-- ============================================================

-- ── invoice_payments ────────────────────────────────────────
-- Each row = one payment entry against an invoice.
-- An invoice is "paid" when SUM(amount) >= invoice total.

CREATE TABLE IF NOT EXISTS invoice_payments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id   uuid NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  method       text NOT NULL CHECK (method IN ('cash','bacs')),
  amount       numeric(10,2) NOT NULL CHECK (amount > 0),
  note         text,
  paid_at      timestamptz NOT NULL DEFAULT now(),
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- Index for fast lookup by invoice
CREATE INDEX IF NOT EXISTS idx_invoice_payments_invoice
  ON invoice_payments (invoice_id);

-- RLS
ALTER TABLE invoice_payments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can manage payments"
  ON invoice_payments
  FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ── customers: cash tab fields ───────────────────────────────
-- cash_tab      : true if this customer pays their running weekly total on a set day
-- tab_settle_day: day name they pay on, e.g. 'Friday'

ALTER TABLE customers
  ADD COLUMN IF NOT EXISTS cash_tab       boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS tab_settle_day text;

-- ── cash_tab_entries ─────────────────────────────────────────
-- Tracks individual deliveries for tab customers.
-- Entries are "unsettled" until the customer pays their weekly total.

CREATE TABLE IF NOT EXISTS cash_tab_entries (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id  uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  delivery_date date NOT NULL,
  amount       numeric(10,2) NOT NULL CHECK (amount > 0),
  items        text,
  settled      boolean NOT NULL DEFAULT false,
  settled_at   timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cash_tab_entries_customer
  ON cash_tab_entries (customer_id, settled);

ALTER TABLE cash_tab_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can manage tab entries"
  ON cash_tab_entries
  FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ── Helper view: invoice payment totals ─────────────────────
CREATE OR REPLACE VIEW invoice_payment_summary AS
SELECT
  i.id                                          AS invoice_id,
  i.total_amount,
  COALESCE(SUM(p.amount), 0)                    AS paid_total,
  i.total_amount - COALESCE(SUM(p.amount), 0)   AS balance,
  CASE
    WHEN COALESCE(SUM(p.amount), 0) <= 0 THEN 'unpaid'
    WHEN COALESCE(SUM(p.amount), 0) >= i.total_amount THEN 'paid'
    ELSE 'part_paid'
  END                                           AS payment_status,
  bool_or(p.method = 'cash')                    AS has_cash,
  bool_or(p.method = 'bacs')                    AS has_bacs
FROM invoices i
LEFT JOIN invoice_payments p ON p.invoice_id = i.id
GROUP BY i.id, i.total_amount;

-- ── Helper view: unsettled tab totals per customer ──────────
CREATE OR REPLACE VIEW unsettled_tab_totals AS
SELECT
  c.id          AS customer_id,
  c.name        AS customer_name,
  c.tab_settle_day,
  COUNT(e.id)   AS entry_count,
  COALESCE(SUM(e.amount), 0) AS tab_total
FROM customers c
LEFT JOIN cash_tab_entries e ON e.customer_id = c.id AND NOT e.settled
WHERE c.cash_tab = true
GROUP BY c.id, c.name, c.tab_settle_day;
