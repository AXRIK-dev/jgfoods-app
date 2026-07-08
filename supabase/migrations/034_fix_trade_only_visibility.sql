-- ============================================================
-- Migration 034: Fix — trade-only products visible to everyone
-- JG Foods
-- ============================================================
-- BUG (found in testing, 8 Jul): trade-only items showed on the
-- public website even when not signed in.
--
-- CAUSE: current_user_role() (migration 012) returns 'driver' as its
-- FALLBACK when the caller has no user profile — and an anonymous
-- website visitor has no profile, so anon counts as 'driver'.
-- Migration 033's "Staff read all products" policy allowed
-- role IN ('admin','driver') … which therefore included every
-- anonymous visitor, letting them read ALL products (trade-only and
-- hidden ones included).
--
-- FIX: staff must actually be SIGNED IN (auth.uid() IS NOT NULL).
-- Signed-in customers have role 'customer', so they're still excluded.
--
-- Safe + idempotent. Run in the Supabase SQL editor.
-- ============================================================

DROP POLICY IF EXISTS "Staff read all products" ON products;
CREATE POLICY "Staff read all products"
  ON products FOR SELECT
  USING (auth.uid() IS NOT NULL AND current_user_role() IN ('admin','driver'));

-- Quick check afterwards (optional): run this while NOT signed in
-- (or via the anon key) — it should return zero rows:
--   SELECT name FROM products WHERE trade_only = true;
