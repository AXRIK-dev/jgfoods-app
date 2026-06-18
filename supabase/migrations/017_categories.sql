-- ============================================================
-- Migration 017: Product categories
-- JG Foods Admin App
-- ============================================================
-- Gives Jon a managed list of categories he can add / rename /
-- reorder / hide / delete from the Availability page, instead of
-- the list being hard-coded in three places (admin add, admin
-- edit, website filters).
--
-- Products still store their category as text (products.category)
-- so this is non-breaking. This table is the source of truth for
-- the LIST of categories: what appears in the dropdowns and the
-- website filter chips, and in what order. Renaming a category in
-- the admin cascades the new name onto matching products.
-- ============================================================

-- ── categories ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS categories (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL UNIQUE,          -- shown to customers, stored on products.category
  slug        text NOT NULL UNIQUE,          -- used by the website filter + placeholder styling
  sort_order  integer NOT NULL DEFAULT 0,    -- display order (low = first)
  is_active   boolean NOT NULL DEFAULT true, -- false = hidden from website + add/edit dropdowns
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Seed the six categories the app already ships with (idempotent).
-- Slugs match the existing website CAT_SLUG map and .prod-img styles.
INSERT INTO categories (name, slug, sort_order) VALUES
  ('Chicken',      'chicken', 1),
  ('Steak & Beef', 'steak',   2),
  ('BBQ & Grill',  'bbq',     3),
  ('Kebabs',       'kebab',   4),
  ('Meat Packs',   'pack',    5),
  ('Other',        'other',   6)
ON CONFLICT (name) DO NOTHING;

-- ── Row Level Security ───────────────────────────────────────
-- Same shape as products: public read (storefront), admin write.
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;

-- Public/anon can read active categories (powers the website filters)
DROP POLICY IF EXISTS "Public read active categories" ON categories;
CREATE POLICY "Public read active categories"
  ON categories FOR SELECT
  USING (is_active = true);

-- Admin (any authenticated user) has full access
DROP POLICY IF EXISTS "Admin full access to categories" ON categories;
CREATE POLICY "Admin full access to categories"
  ON categories FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- Helpful index for ordered reads
CREATE INDEX IF NOT EXISTS categories_sort_idx ON categories (sort_order, name);
