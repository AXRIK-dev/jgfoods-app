-- ============================================================
-- Migration 009: Lock down customer & order data (SECURITY FIX)
-- JG Foods Admin App
-- ============================================================
-- ISSUE FOUND (12 June 2026): with no logged-in session, the public
-- anon key could read `customers` (names, phones, addresses), `orders`
-- and `order_items`. The anon key ships in the website JavaScript, so
-- this exposed customer personal data and order history to anyone.
--
-- Invoices, weekly sheets and temps were correctly locked — only these
-- three tables were affected, so the intended policies from migration
-- 002 were either missing, overridden by a permissive policy, or RLS
-- had been left disabled on them.
--
-- This migration is deterministic: it force-enables RLS and rebuilds the
-- correct policies from a clean slate, so the end state is guaranteed
-- regardless of what is currently on the live database.
--
-- SAFE FOR THE WEBSITE: the public site never reads these tables directly
-- — it places orders through the place_order RPC (SECURITY DEFINER, which
-- bypasses RLS by design). Only products, delivery_slots and app_settings
-- are read by anon, and those are intentionally public and untouched here.
-- ============================================================

-- 1. Force RLS on (covers the "RLS was disabled" case)
ALTER TABLE customers   ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders      ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;

-- 2. Drop every existing policy on these three tables (covers the
--    "a permissive public-read policy was added" case)
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

-- 3. Recreate the intended policies: admin (any logged-in staff user) has
--    full access; account customers may read only their own data; the
--    public/anon role gets nothing.

-- ── customers ────────────────────────────────────────────────
CREATE POLICY "Admin full access to customers"
  ON customers FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Account customers read own record"
  ON customers FOR SELECT
  USING (user_id = auth.uid());

-- ── orders ───────────────────────────────────────────────────
CREATE POLICY "Admin full access to orders"
  ON orders FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Account customers read own orders"
  ON orders FOR SELECT
  USING (
    customer_id IN (SELECT id FROM customers WHERE user_id = auth.uid())
  );

-- ── order_items ──────────────────────────────────────────────
CREATE POLICY "Admin full access to order_items"
  ON order_items FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Account customers read own order_items"
  ON order_items FOR SELECT
  USING (
    order_id IN (
      SELECT o.id FROM orders o
      JOIN customers c ON c.id = o.customer_id
      WHERE c.user_id = auth.uid()
    )
  );

-- ============================================================
-- NOTE / follow-up (not fixed here to avoid breaking current admin access):
-- The "admin" check above is auth.role() = 'authenticated', i.e. ANY
-- logged-in user. Today only staff log in, so this is fine. But once
-- customer website accounts go live (task #4), every logged-in customer
-- would also satisfy 'authenticated' and could read all customers/orders.
-- Before enabling customer accounts, tighten these admin policies to
-- check user_profiles.role = 'admin' (migration 006 already stores roles).
-- ============================================================
