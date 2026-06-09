-- ============================================================
-- JG Foods — Pie Supplier Cut-off Feature
-- Migration: pie_supplier_cutoffs
-- ============================================================
-- Adds supplier_type to products and creates a supplier_cutoffs
-- config table so the admin dashboard can enforce different order
-- deadlines for pies vs meat.
-- ============================================================


-- 1. Add supplier_type column to products
-- Default is 'meat' so existing products are unaffected.
ALTER TABLE products
  ADD COLUMN IF NOT EXISTS supplier_type text NOT NULL DEFAULT 'meat'
  CONSTRAINT products_supplier_type_check CHECK (supplier_type IN ('meat', 'pie'));

COMMENT ON COLUMN products.supplier_type IS
  'Which supplier this product comes from. Controls cut-off logic in the admin dashboard.';


-- 2. Supplier cut-off config table
-- Stores the ordering rules for each supplier type.
-- Easy to extend: add a row for a new supplier without touching code.

CREATE TABLE IF NOT EXISTS supplier_cutoffs (
  supplier_type          text PRIMARY KEY,
  label                  text NOT NULL,
  cutoff_hour            integer NOT NULL DEFAULT 12,  -- 24h clock, e.g. 12 = noon
  days_before_delivery   integer NOT NULL DEFAULT 1,   -- how many days before delivery to order
  friday_covers_monday   boolean NOT NULL DEFAULT false -- true = Friday cut-off covers Monday delivery
);

COMMENT ON TABLE supplier_cutoffs IS
  'Ordering deadlines per supplier type. Read by the dashboard alert logic.';

ALTER TABLE supplier_cutoffs ENABLE ROW LEVEL SECURITY;

-- Only Jon (admin) can read and modify these rules
CREATE POLICY "Admins have full access"
  ON supplier_cutoffs FOR ALL
  USING  ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin')
  WITH CHECK ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin');


-- 3. Seed the two supplier types

INSERT INTO supplier_cutoffs
  (supplier_type, label, cutoff_hour, days_before_delivery, friday_covers_monday)
VALUES
  ('pie',  'Pie Supplier',  12, 1, true),   -- order by noon, 1 day before; Friday covers Monday
  ('meat', 'Meat Supplier', 17, 0, false)   -- can order same day, later in the afternoon
ON CONFLICT (supplier_type) DO NOTHING;


-- ============================================================
-- How to use this in the frontend
-- ============================================================
-- When loading products, select supplier_type alongside other fields.
-- The dashboard alert logic (see pie-alert.js) queries:
--   1. supplier_cutoffs to get the cut-off rules
--   2. order_items joined to products where supplier_type = 'pie'
--      and delivery_date = next applicable delivery day
-- It then shows a banner if the cut-off is approaching and
-- lists the aggregated pie quantities Jon needs to order.
-- ============================================================
