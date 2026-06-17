-- ============================================================
-- Migration 016: daily_sales — persist the Daily Sales tab
-- JG Foods Admin App
-- ============================================================
-- The Daily Sales tab on the Finance page was in-memory only (lost on
-- refresh). This table persists each delivery day's takings (bank + cash)
-- and backs the spreadsheet import, so Jon can load his historical
-- figures and they stick.
--
-- One row per date (sale_date is unique) so imports/edits upsert rather
-- than duplicate. Admin-only (finance data).
-- ============================================================

CREATE TABLE IF NOT EXISTS daily_sales (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sale_date   date NOT NULL UNIQUE,
  bank        numeric(10,2) NOT NULL DEFAULT 0,
  cash        numeric(10,2) NOT NULL DEFAULT 0,
  is_holiday  boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_daily_sales_updated_at ON daily_sales;
CREATE TRIGGER trg_daily_sales_updated_at
  BEFORE UPDATE ON daily_sales
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE daily_sales ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin manages daily_sales" ON daily_sales;
CREATE POLICY "Admin manages daily_sales"
  ON daily_sales FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

-- Depends on set_updated_at() (migration 001) and current_user_role() (006/012/015).
