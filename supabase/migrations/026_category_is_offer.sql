-- ============================================================
-- Migration 026: Mark categories as normal vs special offer
-- JG Foods
-- ============================================================
-- Splits the two ideas cleanly:
--   • normal categories (Chicken, Steak & Beef…) for single products
--   • special offers (e.g. "Mix & Match — 3 for £15")
-- so the admin can manage them in separate places.
--
-- An offer is still stored as a category row (so its items can reference it
-- and the website can group them) — this flag just marks which ones are offers.
-- ============================================================

ALTER TABLE categories
  ADD COLUMN IF NOT EXISTS is_offer boolean NOT NULL DEFAULT false;

-- Anything that already has a deal set is an offer.
UPDATE categories SET is_offer = true WHERE deal_qty IS NOT NULL AND is_offer = false;

-- When to run: after 024 (offers) and 025 (category image). Safe + idempotent.
-- ============================================================
