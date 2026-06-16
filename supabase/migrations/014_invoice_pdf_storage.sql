-- ============================================================
-- Migration 014: Storage bucket for invoice / receipt PDFs
-- JG Foods Admin App
-- ============================================================
-- When Jon sends a receipt/invoice by WhatsApp or email, the app builds
-- the branded PDF, uploads it here, and drops a tap-to-open link into the
-- message. This means he never has to attach a file by hand — important
-- because he works from a phone/tablet on the road.
--
-- The bucket is PUBLIC so the link opens with no login. Filenames include
-- a random suffix so they can't be guessed. (Receipts contain a name,
-- address and items — acceptable for this use, like most invoice links,
-- but worth knowing.) Upload is restricted to the admin (Jon); customers
-- never upload.
-- ============================================================

-- 1. Create the bucket (idempotent) -----------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('invoice-pdfs', 'invoice-pdfs', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- 2. Policies on storage.objects for this bucket ----------------------
-- Public read is served by the public bucket endpoint, but we add an
-- explicit SELECT policy too for completeness.

DROP POLICY IF EXISTS "Public read invoice pdfs" ON storage.objects;
CREATE POLICY "Public read invoice pdfs"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'invoice-pdfs');

DROP POLICY IF EXISTS "Admin upload invoice pdfs" ON storage.objects;
CREATE POLICY "Admin upload invoice pdfs"
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'invoice-pdfs' AND public.current_user_role() = 'admin');

DROP POLICY IF EXISTS "Admin update invoice pdfs" ON storage.objects;
CREATE POLICY "Admin update invoice pdfs"
  ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'invoice-pdfs' AND public.current_user_role() = 'admin')
  WITH CHECK (bucket_id = 'invoice-pdfs' AND public.current_user_role() = 'admin');

DROP POLICY IF EXISTS "Admin delete invoice pdfs" ON storage.objects;
CREATE POLICY "Admin delete invoice pdfs"
  ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'invoice-pdfs' AND public.current_user_role() = 'admin');

-- Depends on current_user_role() from migration 006 / 012. Run those first.
