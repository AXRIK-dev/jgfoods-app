-- ============================================================
-- Migration 012: Harden admin RLS — role='admin' not 'authenticated'
-- JG Foods Admin App
-- ============================================================
-- WHY (deferred hardening flagged in migration 009):
-- The admin policies on customers / orders / order_items currently use
--   auth.role() = 'authenticated'  -> ANY logged-in user.
-- That is safe today because only staff log in. But the moment customer
-- website accounts go live (next build task), every signed-in customer
-- also satisfies 'authenticated' and could read EVERY customer record and
-- order. This migration closes that gap by switching those policies to
--   current_user_role() = 'admin'  (helper + roles from migration 006).
--
-- DETERMINISTIC + SAFE: like migration 009 this rebuilds the policies from
-- a clean slate so the end state is guaranteed regardless of current state.
--
-- LOCK-OUT SAFETY: switching to role='admin' would lock Jon out if his
-- account is still the default 'driver'. Section 1 below backfills missing
-- profiles and, if no admin exists yet, promotes all current users to
-- admin. At this point only staff have accounts (customer accounts are not
-- live), so this is correct and safe — it cannot promote a customer.
--
-- WEBSITE UNAFFECTED: the public site never reads these tables directly; it
-- places orders through the place_order RPC (SECURITY DEFINER, bypasses RLS).
-- ============================================================

-- 0. Make sure the role helper exists (idempotent; created in 006) ----------
CREATE OR REPLACE FUNCTION current_user_role()
RETURNS text LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT COALESCE(
    (SELECT role FROM user_profiles WHERE id = auth.uid()),
    'driver'
  );
$$;

-- 1. Lock-out safety — guarantee at least one admin before tightening -------
-- 1a. Backfill a profile for any auth user that doesn't have one yet
INSERT INTO user_profiles (id)
SELECT u.id FROM auth.users u
LEFT JOIN user_profiles p ON p.id = u.id
WHERE p.id IS NULL;

-- 1b. If nobody is admin yet, promote all existing users (staff-only at this
--     point — customer accounts are not live, so this cannot hit a customer)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_profiles WHERE role = 'admin') THEN
    UPDATE user_profiles SET role = 'admin';
  END IF;
END $$;

-- 2. Rebuild policies on the three PII / order tables ----------------------
ALTER TABLE customers   ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders      ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE pol record;
BEGIN
  FOR pol IN
    SELECT policyname, tablename
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('customers','orders','order_items')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol.policyname, pol.tablename);
  END LOOP;
END $$;

-- ── customers ────────────────────────────────────────────────
CREATE POLICY "Admin full access to customers"
  ON customers FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

CREATE POLICY "Account customers read own record"
  ON customers FOR SELECT
  USING (user_id = auth.uid());

-- ── orders ───────────────────────────────────────────────────
CREATE POLICY "Admin full access to orders"
  ON orders FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

CREATE POLICY "Account customers read own orders"
  ON orders FOR SELECT
  USING (
    customer_id IN (SELECT id FROM customers WHERE user_id = auth.uid())
  );

-- ── order_items ──────────────────────────────────────────────
CREATE POLICY "Admin full access to order_items"
  ON order_items FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

CREATE POLICY "Account customers read own order_items"
  ON order_items FOR SELECT
  USING (
    order_id IN (
      SELECT o.id FROM orders o
      JOIN customers c ON c.id = o.customer_id
      WHERE c.user_id = auth.uid()
    )
  );

-- 3. Quick check (optional) — run this after to confirm Jon is admin:
--    SELECT u.email, p.role FROM user_profiles p
--    JOIN auth.users u ON u.id = p.id ORDER BY p.role;

-- ============================================================
-- FOLLOW-UP BEFORE CUSTOMER ACCOUNTS GO LIVE (next build task):
--
-- 1. The signup trigger (create_user_profile, migration 006) gives EVERY
--    new auth user role 'driver' by default. Once customers can sign up,
--    they would become 'driver' too. There are currently no driver-read
--    policies on customers/orders (009 removed them), so that is not an
--    active leak — but DO NOT re-add broad "driver read" policies until
--    customer signups are separated from the staff 'driver' role
--    (e.g. add a 'customer' role, or gate the delivery friend differently).
--
-- 2. These tables still use auth.role() = 'authenticated' (any logged-in
--    user can WRITE): products, delivery_slots, app_settings,
--    delivery_temps, social_posts. Harmless today (staff-only logins), but
--    tighten the write side to current_user_role() = 'admin' before
--    customer accounts launch so customers can't edit them. Public anon
--    READ of products/delivery_slots/app_settings stays as-is (intended).
-- ============================================================
