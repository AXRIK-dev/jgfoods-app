-- ============================================================
-- Migration 019: Switch on customer accounts (safe role split)
-- JG Foods Customer Website
-- ============================================================
-- Turns on real customer sign-in / registration / password reset.
--
-- SAFETY (the gap migration 012 flagged): the signup trigger gave EVERY
-- new auth user role 'driver'. Customers must NOT be 'driver'. This adds
-- a dedicated 'customer' role and routes self-signups to it via signup
-- metadata (account_type = 'customer'). Staff accounts (created by Jon /
-- invited in Supabase, with no such metadata) still default to 'driver'
-- and are promoted to 'admin' as before — unchanged.
--
-- 'customer' is least-privilege: no policy grants it anything except the
-- existing "own record / own orders" policies, which key off
-- customers.user_id = auth.uid(), not the role.
-- ============================================================

-- 1. Allow the new role -------------------------------------------------
ALTER TABLE user_profiles DROP CONSTRAINT IF EXISTS user_profiles_role_check;
ALTER TABLE user_profiles
  ADD CONSTRAINT user_profiles_role_check CHECK (role IN ('admin','driver','customer'));

-- 2. Route self-signups to the customer role (staff stay 'driver') ------
-- Keeps the search_path fix + exception safety net from migration 015.
CREATE OR REPLACE FUNCTION create_user_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.user_profiles (id, full_name, role)
  VALUES (
    NEW.id,
    NEW.raw_user_meta_data->>'full_name',
    CASE WHEN NEW.raw_user_meta_data->>'account_type' = 'customer'
         THEN 'customer' ELSE 'driver' END
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;   -- never block auth user creation over a profile hiccup
END;
$$;

-- 3. Let a logged-in customer create + maintain their OWN linked record -
-- (RLS only allows rows where user_id = their own auth id — they can
--  never touch anyone else's. Read-own already exists from migration 012.)
DROP POLICY IF EXISTS "Account customers insert own record" ON customers;
CREATE POLICY "Account customers insert own record"
  ON customers FOR INSERT
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "Account customers update own record" ON customers;
CREATE POLICY "Account customers update own record"
  ON customers FOR UPDATE
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- ── AFTER RUNNING THIS MIGRATION (Supabase dashboard) ─────────────────
-- 1. Authentication → Providers → Email: make sure it is ENABLED.
-- 2. Authentication → URL Configuration:
--      Site URL                = https://jgfoodsnorthwest.com
--      Additional redirect URLs = https://jgfoodsnorthwest.com/**
--    (so the password-reset link returns customers to the site).
-- 3. (Optional) Authentication → Email Templates → "Reset Password":
--    tweak the wording to sound like Jon if you like.
-- ============================================================
