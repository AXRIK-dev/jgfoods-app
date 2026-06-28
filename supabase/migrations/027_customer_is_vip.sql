-- ============================================================
-- Migration 027: VIP flag on customers
-- JG Foods
-- ============================================================
-- Powers the ⭐ VIP List page. A VIP is just a customer flagged here, so
-- the list is always in step with the customer records (no separate store).
-- ============================================================

ALTER TABLE customers
  ADD COLUMN IF NOT EXISTS is_vip boolean NOT NULL DEFAULT false;

-- When to run: after the customers table exists. Safe + idempotent.
-- ============================================================
