-- ============================================================
-- Migration 015: Fix "Database error creating new user"
-- JG Foods Admin App
-- ============================================================
-- Creating a user in Supabase failed with "Database error creating
-- new user". Cause: the create_user_profile() trigger (migration 006)
-- runs as SECURITY DEFINER but has no SET search_path, so when Supabase
-- creates a user as the auth-admin role, the unqualified table name
-- `user_profiles` can't be resolved and the trigger errors — which
-- aborts the whole auth.users INSERT.
--
-- Fix: pin search_path to public, fully-qualify the table, and add a
-- safety net so a profile hiccup can never block user creation again
-- (a missing profile just defaults to 'driver' and can be backfilled).
--
-- Also re-hardens current_user_role() the same way (defensive).
-- ============================================================

CREATE OR REPLACE FUNCTION create_user_profile()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.user_profiles (id, full_name)
  VALUES (NEW.id, NEW.raw_user_meta_data->>'full_name')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Never block auth user creation because of a profile issue.
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION current_user_role()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT role FROM public.user_profiles WHERE id = auth.uid()),
    'driver'
  );
$$;

-- Backfill a profile for any auth user that doesn't have one yet
-- (e.g. if an earlier attempt half-created something).
INSERT INTO public.user_profiles (id)
SELECT u.id FROM auth.users u
LEFT JOIN public.user_profiles p ON p.id = u.id
WHERE p.id IS NULL;
