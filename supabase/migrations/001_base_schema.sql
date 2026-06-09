-- ============================================================
-- Migration 001: Base schema
-- JG Foods Admin App
-- ============================================================

-- ── Extensions ──────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ── products ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS products (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  description   text,
  category      text NOT NULL DEFAULT 'Other',
  price         numeric(10,2) NOT NULL CHECK (price >= 0),
  trade_price   numeric(10,2),                        -- NULL = use standard price for trade customers
  unit          text NOT NULL DEFAULT 'pack',         -- 'pack', 'kg', 'each'
  is_available  boolean NOT NULL DEFAULT true,        -- weekly on/off toggle
  img_url       text,                                 -- Supabase Storage path
  sort_order    integer NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- ── customers ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS customers (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid REFERENCES auth.users(id) ON DELETE SET NULL, -- NULL = guest / no account
  customer_type   text NOT NULL DEFAULT 'domestic' CHECK (customer_type IN ('domestic','commercial')),
  name            text NOT NULL,
  business_name   text,
  price_tier      text NOT NULL DEFAULT 'standard' CHECK (price_tier IN ('standard','trade')),
  billing         text NOT NULL DEFAULT 'per_delivery' CHECK (billing IN ('per_delivery','on_account')),
  email           text,
  phone           text,
  address_line_1  text,
  address_line_2  text,
  city            text,
  postcode        text,
  notes           text,
  invoice_prefix  text,                               -- e.g. 'INV-CP', 'RC' — per Jon's spreadsheet
  cash_tab        boolean NOT NULL DEFAULT false,
  tab_settle_day  text,                               -- e.g. 'Friday'
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ── delivery_slots ──────────────────────────────────────────
-- The spine of the system. One row per delivery run.
CREATE TABLE IF NOT EXISTS delivery_slots (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_date   date NOT NULL,
  day_label       text NOT NULL CHECK (day_label IN ('Monday','Wednesday','Thursday')),
  capacity        integer NOT NULL DEFAULT 50,
  orders_count    integer NOT NULL DEFAULT 0,
  cutoff_at       timestamptz,
  is_open         boolean NOT NULL DEFAULT true,
  is_confirmed    boolean NOT NULL DEFAULT false,     -- when confirmed, temps are auto-populated
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (delivery_date)
);

-- ── orders ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS orders (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id       uuid NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
  delivery_slot_id  uuid NOT NULL REFERENCES delivery_slots(id) ON DELETE RESTRICT,
  channel           text NOT NULL DEFAULT 'website' CHECK (channel IN ('website','facebook','instagram','phone','whatsapp')),
  status            text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','confirmed','packed','delivered','cancelled')),
  total_amount      numeric(10,2) NOT NULL DEFAULT 0,
  payment_method    text CHECK (payment_method IN ('cash','card','bacs','account')),
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- ── order_items ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS order_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id      uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id    uuid REFERENCES products(id) ON DELETE SET NULL,
  product_name  text NOT NULL,                        -- snapshot at time of order
  unit_price    numeric(10,2) NOT NULL,               -- snapshot at time of order
  quantity      integer NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit          text NOT NULL DEFAULT 'pack',
  line_total    numeric(10,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- ── invoices ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS invoices (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_number  text NOT NULL UNIQUE,
  customer_id     uuid NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
  order_id        uuid REFERENCES orders(id) ON DELETE SET NULL,
  invoice_type    text NOT NULL DEFAULT 'invoice' CHECK (invoice_type IN ('invoice','receipt')),
  status          text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','sent','paid','overdue')),
  issued_at       timestamptz,
  due_at          timestamptz,
  paid_at         timestamptz,
  subtotal        numeric(10,2) NOT NULL DEFAULT 0,
  vat_amount      numeric(10,2) NOT NULL DEFAULT 0,
  total_amount    numeric(10,2) NOT NULL DEFAULT 0,
  notes           text,
  pdf_url         text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ── invoice_items ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS invoice_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id    uuid NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  description   text NOT NULL,
  unit_price    numeric(10,2) NOT NULL,
  quantity      integer NOT NULL DEFAULT 1,
  line_total    numeric(10,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- ── weekly_sheets ────────────────────────────────────────────
-- Jon's weekly reconciliation — mirrors JG Foods Weekly Sales_Purchases.xlsx
CREATE TABLE IF NOT EXISTS weekly_sheets (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  week_ending     date NOT NULL UNIQUE,
  carried_forward numeric(10,2) NOT NULL DEFAULT 0,
  sales_total     numeric(10,2) NOT NULL DEFAULT 0,
  banked          numeric(10,2) NOT NULL DEFAULT 0,
  purchases       jsonb NOT NULL DEFAULT '[]',        -- [{supplier, total, cash, bank}]
  expenses        jsonb NOT NULL DEFAULT '[]',        -- [{label, net, vat}]
  notes           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ── updated_at triggers ──────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

CREATE TRIGGER trg_products_updated_at       BEFORE UPDATE ON products       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_customers_updated_at      BEFORE UPDATE ON customers      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_delivery_slots_updated_at BEFORE UPDATE ON delivery_slots FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_orders_updated_at         BEFORE UPDATE ON orders         FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_invoices_updated_at       BEFORE UPDATE ON invoices       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_weekly_sheets_updated_at  BEFORE UPDATE ON weekly_sheets  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── orders_count trigger ─────────────────────────────────────
-- Keeps delivery_slots.orders_count accurate automatically
CREATE OR REPLACE FUNCTION update_slot_orders_count()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.status != 'cancelled' THEN
    UPDATE delivery_slots SET orders_count = orders_count + 1 WHERE id = NEW.delivery_slot_id;
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.status != 'cancelled' AND NEW.status = 'cancelled' THEN
      UPDATE delivery_slots SET orders_count = orders_count - 1 WHERE id = NEW.delivery_slot_id;
    ELSIF OLD.status = 'cancelled' AND NEW.status != 'cancelled' THEN
      UPDATE delivery_slots SET orders_count = orders_count + 1 WHERE id = NEW.delivery_slot_id;
    END IF;
  ELSIF TG_OP = 'DELETE' AND OLD.status != 'cancelled' THEN
    UPDATE delivery_slots SET orders_count = orders_count - 1 WHERE id = OLD.delivery_slot_id;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_slot_orders_count
AFTER INSERT OR UPDATE OF status OR DELETE ON orders
FOR EACH ROW EXECUTE FUNCTION update_slot_orders_count();

-- ── order total trigger ──────────────────────────────────────
-- Recalculates orders.total_amount when items change
CREATE OR REPLACE FUNCTION update_order_total()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_order_id uuid;
BEGIN
  v_order_id := COALESCE(NEW.order_id, OLD.order_id);
  UPDATE orders
  SET total_amount = COALESCE((SELECT SUM(line_total) FROM order_items WHERE order_id = v_order_id), 0)
  WHERE id = v_order_id;
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_order_total
AFTER INSERT OR UPDATE OR DELETE ON order_items
FOR EACH ROW EXECUTE FUNCTION update_order_total();
