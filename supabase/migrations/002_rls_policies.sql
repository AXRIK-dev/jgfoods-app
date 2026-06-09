-- ============================================================
-- Migration 002: Row Level Security policies
-- JG Foods Admin App
-- ============================================================
-- Shape: public storefront writing into an admin-managed system.
-- - products + delivery_slots: public read, admin write
-- - orders + customers: admin read/write; account customers read their own
-- - Place order via RPC only (no direct anon insert on orders)

-- ── Enable RLS on all tables ─────────────────────────────────
ALTER TABLE products        ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers       ENABLE ROW LEVEL SECURITY;
ALTER TABLE delivery_slots  ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders          ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items     ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoices        ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoice_items   ENABLE ROW LEVEL SECURITY;
ALTER TABLE weekly_sheets   ENABLE ROW LEVEL SECURITY;

-- ── products ─────────────────────────────────────────────────
-- Public can read available products (powers the website catalogue)
CREATE POLICY "Public read available products"
  ON products FOR SELECT
  USING (is_available = true);

-- Admin can read all products (including unavailable)
CREATE POLICY "Admin full access to products"
  ON products FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ── delivery_slots ───────────────────────────────────────────
-- Public can read open slots (order form needs this)
CREATE POLICY "Public read open slots"
  ON delivery_slots FOR SELECT
  USING (is_open = true AND cutoff_at > now());

-- Admin full access
CREATE POLICY "Admin full access to delivery_slots"
  ON delivery_slots FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ── orders ───────────────────────────────────────────────────
-- No public read. Admin sees all. Account customers see their own.
CREATE POLICY "Admin full access to orders"
  ON orders FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Account customers read own orders"
  ON orders FOR SELECT
  USING (
    customer_id IN (
      SELECT id FROM customers WHERE user_id = auth.uid()
    )
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

-- ── customers ────────────────────────────────────────────────
CREATE POLICY "Admin full access to customers"
  ON customers FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Account customers read own record"
  ON customers FOR SELECT
  USING (user_id = auth.uid());

-- ── invoices ─────────────────────────────────────────────────
CREATE POLICY "Admin full access to invoices"
  ON invoices FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY "Account customers read own invoices"
  ON invoices FOR SELECT
  USING (
    customer_id IN (
      SELECT id FROM customers WHERE user_id = auth.uid()
    )
  );

-- ── invoice_items ────────────────────────────────────────────
CREATE POLICY "Admin full access to invoice_items"
  ON invoice_items FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ── weekly_sheets ─────────────────────────────────────────────
CREATE POLICY "Admin full access to weekly_sheets"
  ON weekly_sheets FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');
