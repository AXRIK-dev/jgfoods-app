-- ============================================================
-- Migration 031: Expenses & Purchases ledger (+ receipt photos)
-- JG Foods
-- ============================================================
-- A complete, ongoing record of every business cost — entered once
-- as its own line, with the receipt photo attached. This is the
-- single source of truth: the Weekly sheet and Monthly accountant
-- export add up from it, so Jon enters a cost once and never retypes.
--
--   kind            'purchase' (stock from a supplier) or 'expense' (overhead)
--   payee           who it was paid to (supplier / payee)
--   category        Fuel, Van, Stock, Insurance, … (matches the weekly lists)
--   amount          gross amount paid
--   vat_amount      VAT element (0 if none / not known)
--   payment_method  cash / bank / card / other
--   receipt_url     photo of the receipt (in the 'receipts' bucket)
--
-- Reusable AXRIK pattern: a simple bookkeeping ledger any future
-- client can use. Safe + idempotent.
-- ============================================================

CREATE TABLE IF NOT EXISTS expenses (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_date     date NOT NULL DEFAULT current_date,
  payee          text,
  category       text,
  kind           text NOT NULL DEFAULT 'expense' CHECK (kind IN ('purchase','expense')),
  amount         numeric(10,2) NOT NULL DEFAULT 0,
  vat_amount     numeric(10,2) NOT NULL DEFAULT 0,
  payment_method text CHECK (payment_method IN ('cash','bank','card','other')),
  receipt_url    text,
  notes          text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_expenses_date ON expenses (entry_date);

DROP TRIGGER IF EXISTS trg_expenses_updated_at ON expenses;
CREATE TRIGGER trg_expenses_updated_at
  BEFORE UPDATE ON expenses
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── RLS: admin only (financial data) ────────────────────────
ALTER TABLE expenses ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Admin all expenses" ON expenses;
CREATE POLICY "Admin all expenses" ON expenses FOR ALL
  USING (public.current_user_role() = 'admin')
  WITH CHECK (public.current_user_role() = 'admin');

-- ── Receipt photo storage bucket ────────────────────────────
-- Public bucket (like invoice-pdfs) so the photo opens with a plain
-- <img>; filenames are random + dated so links aren't guessable.
INSERT INTO storage.buckets (id, name, public)
VALUES ('receipts', 'receipts', true)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "Public read receipts" ON storage.objects;
CREATE POLICY "Public read receipts" ON storage.objects FOR SELECT
  USING (bucket_id = 'receipts');

DROP POLICY IF EXISTS "Admin upload receipts" ON storage.objects;
CREATE POLICY "Admin upload receipts" ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'receipts' AND public.current_user_role() = 'admin');

DROP POLICY IF EXISTS "Admin update receipts" ON storage.objects;
CREATE POLICY "Admin update receipts" ON storage.objects FOR UPDATE
  USING (bucket_id = 'receipts' AND public.current_user_role() = 'admin')
  WITH CHECK (bucket_id = 'receipts' AND public.current_user_role() = 'admin');

DROP POLICY IF EXISTS "Admin delete receipts" ON storage.objects;
CREATE POLICY "Admin delete receipts" ON storage.objects FOR DELETE
  USING (bucket_id = 'receipts' AND public.current_user_role() = 'admin');

-- When to run: after 006 (roles / current_user_role) and 001. Idempotent.
-- ============================================================
