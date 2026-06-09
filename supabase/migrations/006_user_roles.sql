-- ============================================================
-- Migration 006: User roles — admin and driver
-- JG Foods Admin App
-- ============================================================
-- Jon is 'admin' — full access to everything.
-- Jon's delivery friend is 'driver' — can see orders, delivery
-- runs, customers (contact details only), and temp log.
-- Drivers cannot see invoices, finance, weekly sheets, cash tabs,
-- or any payment data.
--
-- Role is stored in user_profiles, created automatically when a
-- new Supabase Auth user is created (via trigger).
-- Default role is 'driver' — Jon's account must be set to 'admin'
-- manually after running this migration (see instructions below).

-- ── user_profiles ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS user_profiles (
  id          uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role        text NOT NULL DEFAULT 'driver' CHECK (role IN ('admin', 'driver')),
  full_name   text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_user_profiles_updated_at
  BEFORE UPDATE ON user_profiles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── Auto-create profile on signup ────────────────────────────
-- Every new auth user gets a user_profiles row with role 'driver'.
-- Jon's profile must then be manually updated to 'admin' (see below).
CREATE OR REPLACE FUNCTION create_user_profile()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO user_profiles (id, full_name)
  VALUES (NEW.id, NEW.raw_user_meta_data->>'full_name')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_create_user_profile
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION create_user_profile();

-- ── Helper function: get current user's role ──────────────────
-- Used in RLS policies. Returns 'driver' if no profile exists
-- (fail-safe: unknown users get least privilege).
CREATE OR REPLACE FUNCTION current_user_role()
RETURNS text LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT COALESCE(
    (SELECT role FROM user_profiles WHERE id = auth.uid()),
    'driver'
  );
$$;

-- ── RLS on user_profiles ──────────────────────────────────────
ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;

-- Users can read their own profile (so the app can check their role)
CREATE POLICY "Users read own profile"
  ON user_profiles FOR SELECT
  USING (id = auth.uid());

-- Only admin can read all profiles and update roles
CREATE POLICY "Admin manages all profiles"
  ON user_profiles FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

-- ── Tighten existing RLS policies for financial tables ────────
-- Replace the broad "authenticated" policies on financial tables
-- with admin-only policies so drivers are blocked at the database level.

-- invoices
DROP POLICY IF EXISTS "Admin full access to invoices" ON invoices;
CREATE POLICY "Admin full access to invoices"
  ON invoices FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

DROP POLICY IF EXISTS "Account customers read own invoices" ON invoices;
CREATE POLICY "Account customers read own invoices"
  ON invoices FOR SELECT
  USING (
    customer_id IN (
      SELECT id FROM customers WHERE user_id = auth.uid()
    )
  );

-- invoice_items
DROP POLICY IF EXISTS "Admin full access to invoice_items" ON invoice_items;
CREATE POLICY "Admin full access to invoice_items"
  ON invoice_items FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

-- weekly_sheets
DROP POLICY IF EXISTS "Admin full access to weekly_sheets" ON weekly_sheets;
CREATE POLICY "Admin full access to weekly_sheets"
  ON weekly_sheets FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

-- invoice_payments
DROP POLICY IF EXISTS "Authenticated users can manage payments" ON invoice_payments;
CREATE POLICY "Admin manages invoice_payments"
  ON invoice_payments FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

-- cash_tab_entries
DROP POLICY IF EXISTS "Authenticated users can manage tab entries" ON cash_tab_entries;
CREATE POLICY "Admin manages cash_tab_entries"
  ON cash_tab_entries FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

-- ── Driver access — delivery-focused tables ───────────────────
-- Drivers can read orders and order_items (to know what to deliver)
-- Existing admin policies stay in place; these add driver read access.

CREATE POLICY "Driver read orders"
  ON orders FOR SELECT
  USING (current_user_role() = 'driver');

CREATE POLICY "Driver read order_items"
  ON order_items FOR SELECT
  USING (current_user_role() = 'driver');

-- Drivers can read and update delivery_temps (to log temperatures)
CREATE POLICY "Driver read and update delivery_temps"
  ON delivery_temps FOR SELECT
  USING (current_user_role() = 'driver');

CREATE POLICY "Driver update delivery_temps"
  ON delivery_temps FOR UPDATE
  USING (current_user_role() = 'driver')
  WITH CHECK (current_user_role() = 'driver');

-- Drivers can read customers (name, phone, address — for delivery)
-- but the app restricts which fields are shown in the UI
CREATE POLICY "Driver read customers"
  ON customers FOR SELECT
  USING (current_user_role() = 'driver');

-- ── AFTER RUNNING THIS MIGRATION ─────────────────────────────
-- Set Jon's account to admin. Run this in the SQL editor,
-- replacing the email with Jon's actual email address:
--
-- UPDATE user_profiles
-- SET role = 'admin'
-- WHERE id = (
--   SELECT id FROM auth.users WHERE email = 'jon@example.com'
-- );
--
-- Every other user will default to 'driver' automatically.
-- To create the delivery friend's account:
-- Supabase → Authentication → Users → Invite user → their email.
-- They set their own password. Their role will be 'driver' by default.
-- No further action needed.
