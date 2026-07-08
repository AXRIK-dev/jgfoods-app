-- ============================================================
-- Migration 033: Trade accounts — trade-only availability,
--                per-client pricing, invoice address override
-- JG Foods
-- ============================================================
-- WHAT THIS ADDS
--  1. products.trade_only — Jon marks an item "trade only" on the
--     Availability page. Trade-only items are hidden from guests and
--     domestic customers (enforced by RLS, not just the UI) and shown
--     to APPROVED trade accounts alongside the normal domestic range.
--  2. customers.trade_status — website trade signups land as 'pending';
--     Jon approves them from the customer's profile. Only 'approved'
--     trade accounts see the trade range.
--  3. customers.show_trade_prices — per-client toggle. Off (default):
--     the trade client sees NO prices, just "speak to Jon" messaging.
--     On: they see their agreed prices from trade_prices.
--  4. trade_prices — Jon's agreed per-client, per-product prices.
--  5. customers.invoice_address — optional override printed on that
--     customer's invoices instead of their normal address (e.g. the
--     trade client who wants his home address on his invoices).
--  6. SECURITY FIX (found while wiring this): the 'Admin full access'
--     policies from migration 002 on products / delivery_slots /
--     invoices / invoice_items / weekly_sheets still used
--     auth.role() = 'authenticated' — meaning ANY signed-in customer
--     could WRITE to those tables. Migration 012 fixed customers/orders/
--     order_items but not these. Now that trade customers get logins,
--     this must be closed: writes are admin-only, matching 012.
--
-- Safe + idempotent. Run in the Supabase SQL editor.
-- ============================================================

-- 1. New columns --------------------------------------------------------
ALTER TABLE products
  ADD COLUMN IF NOT EXISTS trade_only boolean NOT NULL DEFAULT false;

ALTER TABLE customers
  ADD COLUMN IF NOT EXISTS trade_status      text CHECK (trade_status IN ('pending','approved')),
  ADD COLUMN IF NOT EXISTS show_trade_prices boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS invoice_address   text;

-- 2. Helper: is the caller an APPROVED trade customer? -------------------
CREATE OR REPLACE FUNCTION is_approved_trade()
RETURNS boolean
LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM customers
    WHERE user_id = auth.uid()
      AND customer_type = 'trade'
      AND trade_status  = 'approved'
  );
$$;

-- 3. Products: hide trade-only items from the public ---------------------
-- Guests + domestic accounts: available AND not trade-only.
-- Approved trade accounts: available items including trade-only.
-- Staff (admin/driver): everything, including hidden items.
DROP POLICY IF EXISTS "Public read available products" ON products;
CREATE POLICY "Public read available products"
  ON products FOR SELECT
  USING (is_available = true AND (trade_only = false OR is_approved_trade()));

DROP POLICY IF EXISTS "Staff read all products" ON products;
CREATE POLICY "Staff read all products"
  ON products FOR SELECT
  -- auth.uid() check matters: current_user_role() falls back to 'driver'
  -- for callers with no profile, which includes ANONYMOUS visitors (034).
  USING (auth.uid() IS NOT NULL AND current_user_role() IN ('admin','driver'));

-- 4. Security fix: writes are admin-only (was: any signed-in user) -------
DROP POLICY IF EXISTS "Admin full access to products" ON products;
CREATE POLICY "Admin full access to products"
  ON products FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

DROP POLICY IF EXISTS "Admin full access to delivery_slots" ON delivery_slots;
CREATE POLICY "Admin full access to delivery_slots"
  ON delivery_slots FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

DROP POLICY IF EXISTS "Admin full access to invoices" ON invoices;
CREATE POLICY "Admin full access to invoices"
  ON invoices FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

DROP POLICY IF EXISTS "Admin full access to invoice_items" ON invoice_items;
CREATE POLICY "Admin full access to invoice_items"
  ON invoice_items FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

DROP POLICY IF EXISTS "Admin full access to weekly_sheets" ON weekly_sheets;
CREATE POLICY "Admin full access to weekly_sheets"
  ON weekly_sheets FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

-- (Website order placement is unaffected — it goes through the
--  place_order RPC which is SECURITY DEFINER. Customer "read own
--  invoices/orders" SELECT policies from 002/012 are untouched.)

-- 5. trade_prices — Jon's agreed per-client prices ------------------------
CREATE TABLE IF NOT EXISTS trade_prices (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id  uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  product_id   uuid NOT NULL REFERENCES products(id)  ON DELETE CASCADE,
  price        numeric(10,2) NOT NULL CHECK (price >= 0),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (customer_id, product_id)
);

ALTER TABLE trade_prices ENABLE ROW LEVEL SECURITY;

DROP TRIGGER IF EXISTS trg_trade_prices_updated_at ON trade_prices;
CREATE TRIGGER trg_trade_prices_updated_at
  BEFORE UPDATE ON trade_prices
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

DROP POLICY IF EXISTS "Admin full access to trade_prices" ON trade_prices;
CREATE POLICY "Admin full access to trade_prices"
  ON trade_prices FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

-- A trade customer can read THEIR OWN prices, and only once Jon has
-- flipped "show prices" on for them. Until then the website shows the
-- "speak to Jon about pricing" message instead.
DROP POLICY IF EXISTS "Customers read own trade prices when shown" ON trade_prices;
CREATE POLICY "Customers read own trade prices when shown"
  ON trade_prices FOR SELECT
  USING (
    customer_id IN (
      SELECT id FROM customers
      WHERE user_id = auth.uid() AND show_trade_prices = true
    )
  );

-- 6. Stop self-service accounts granting themselves trade access ---------
-- Customers can insert/update their own customers row (migration 019).
-- Without this, someone could set trade_status='approved' or flip
-- show_trade_prices themselves. Non-admins always land as 'pending'
-- and can never change the protected columns.
CREATE OR REPLACE FUNCTION protect_customer_trade_fields()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF current_user_role() = 'admin' THEN
    RETURN NEW;   -- Jon's admin app manages these freely
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.trade_status      := CASE WHEN NEW.customer_type = 'trade' THEN 'pending' ELSE NULL END;
    NEW.show_trade_prices := false;
    NEW.invoice_address   := NULL;
  ELSE
    NEW.trade_status      := OLD.trade_status;
    NEW.show_trade_prices := OLD.show_trade_prices;
    NEW.invoice_address   := OLD.invoice_address;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_customer_trade_fields ON customers;
CREATE TRIGGER trg_protect_customer_trade_fields
  BEFORE INSERT OR UPDATE ON customers
  FOR EACH ROW EXECUTE FUNCTION protect_customer_trade_fields();
