-- ============================================================
-- Migration 025: Optional image on a category (used by offers)
-- JG Foods
-- ============================================================
-- Lets Jon put ONE picture on a mix & match offer (e.g. a photo of the
-- "3 for £15" selection) instead of a photo per item. Stored as a public
-- URL, same as products.img_url. NULL = no image.
--
-- Safe + idempotent. RLS is unchanged (categories already allow public
-- read of active rows and admin write).
-- ============================================================

ALTER TABLE categories
  ADD COLUMN IF NOT EXISTS image_url text;

-- When to run: after 017 (categories) and 024 (offers). Safe to run any time.
-- ============================================================
