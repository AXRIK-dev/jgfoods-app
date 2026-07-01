-- ============================================================
-- Migration 032: Multi-site customers (e.g. Billy Bunters — two
-- Birkenhead addresses, one combined invoice)
-- JG Foods Admin App
-- ============================================================
-- Some trade (and occasionally domestic) customers have more than
-- one delivery address, but want ONE invoice covering all of them,
-- with a subtotal per site and a grand total — exactly like Jon's
-- old spreadsheet for Billy Bunters (North West) Ltd.
--
-- This is purely ADDITIVE. A customer with zero rows in
-- customer_sites behaves EXACTLY as before: one order → one
-- invoice/receipt immediately, no site grouping shown anywhere.
-- Nothing changes for the ~100% of customers with a single address.
--
-- Available to ANY customer_type (trade or domestic) — it's a
-- property of "does this customer have more than one address",
-- not of how they're billed.
-- ============================================================

-- ── customer_sites ────────────────────────────────────────────
-- A customer's extra delivery addresses. The customer's own
-- address_line_1/postcode etc. on `customers` still count as their
-- main address — these are ADDITIONAL sites.
CREATE TABLE IF NOT EXISTS customer_sites (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id     uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  label           text NOT NULL,                      -- e.g. "4a Russell Road, Birkenhead"
  address_line_1  text,
  address_line_2  text,
  city            text,
  postcode        text,
  sort_order      integer NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_customer_sites_updated_at
  BEFORE UPDATE ON customer_sites
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX IF NOT EXISTS idx_customer_sites_customer_id ON customer_sites(customer_id);

ALTER TABLE customer_sites ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admin full access to customer_sites"
  ON customer_sites FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

-- Drivers can read sites (need the address for the pick list),
-- same access level they already have on customers/orders.
CREATE POLICY "Driver read customer_sites"
  ON customer_sites FOR SELECT
  USING (current_user_role() = 'driver');

-- ── orders.site_id ───────────────────────────────────────────
-- Which of the customer's sites this delivery is for. NULL for
-- every single-site customer (i.e. almost everyone) — no change
-- in behaviour.
ALTER TABLE orders ADD COLUMN IF NOT EXISTS site_id uuid REFERENCES customer_sites(id) ON DELETE SET NULL;

-- ── orders.invoice_id ─────────────────────────────────────────
-- Which invoice this order ended up on. For single-site customers
-- this is always the one invoice create_invoice_for_order makes for
-- that order (same as invoices.order_id, kept for backward compat).
-- For multi-site customers, several orders can share one invoice_id
-- (the running/"draft" invoice) before Jon finalises it.
ALTER TABLE orders ADD COLUMN IF NOT EXISTS invoice_id uuid REFERENCES invoices(id) ON DELETE SET NULL;

-- ── invoice_items.site_label ──────────────────────────────────
-- Snapshot of which site a line belongs to (text, not a FK — so a
-- past invoice never changes if a site is later renamed/removed).
-- NULL = ungrouped, renders exactly like today's flat invoice.
ALTER TABLE invoice_items ADD COLUMN IF NOT EXISTS site_label text;

-- ── invoice_items.order_id ─────────────────────────────────────
-- Which order a line came from. Existing rows (created before this
-- migration) stay NULL — harmless, they're only ever touched as a
-- whole via invoices.order_id (the classic 1:1 case), never by
-- order_id lookups. NEW rows always set it, which is what lets the
-- admin app edit/delete ONE order's lines on a shared multi-site
-- invoice without disturbing another order's lines on that same
-- invoice.
ALTER TABLE invoice_items ADD COLUMN IF NOT EXISTS order_id uuid REFERENCES orders(id) ON DELETE SET NULL;

-- ── Recalculate an invoice's totals from its current line items ─
-- Used whenever we append more lines to a running/draft invoice.
CREATE OR REPLACE FUNCTION recalc_invoice_totals(p_invoice_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_total numeric(10,2);
BEGIN
  SELECT COALESCE(SUM(line_total), 0) INTO v_total
  FROM invoice_items WHERE invoice_id = p_invoice_id;

  UPDATE invoices
  SET subtotal = v_total, total_amount = v_total
  WHERE id = p_invoice_id;
END;
$$;

-- ── create_invoice_for_order — multi-site aware ────────────────
-- Same behaviour as migration 013 for every single-site customer
-- (one invoice per order, created immediately). NEW: if the
-- customer has one or more rows in customer_sites, orders are
-- collected onto a single running 'draft' invoice — grouped by
-- site_label — until Jon finalises it from the Invoices page
-- (see admin app: "Finalise & send"). That finalise action simply
-- updates invoices.status; no SQL change needed for it.
CREATE OR REPLACE FUNCTION create_invoice_for_order(p_order_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order      record;
  v_cust       record;
  v_site       record;
  v_existing   uuid;
  v_invoice    uuid;
  v_open_inv   uuid;
  v_type       text;
  v_prefix     text;
  v_number     text;
  v_total      numeric(10,2);
  v_site_count integer;
BEGIN
  -- idempotent: one invoice per order, same as before
  SELECT id INTO v_existing FROM invoices WHERE order_id = p_order_id LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;
  -- also idempotent against the multi-site path (order already linked)
  SELECT invoice_id INTO v_existing FROM orders WHERE id = p_order_id;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO v_order FROM orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_cust FROM customers WHERE id = v_order.customer_id;

  SELECT count(*) INTO v_site_count FROM customer_sites WHERE customer_id = v_cust.id;

  -- receipt for domestic, invoice for everyone else (commercial/trade)
  v_type := CASE WHEN v_cust.customer_type = 'domestic' THEN 'receipt' ELSE 'invoice' END;

  -- prefix: the customer's set prefix, else initials of their name
  v_prefix := COALESCE(
    NULLIF(v_cust.invoice_prefix, ''),
    NULLIF(upper(array_to_string(ARRAY(
      SELECT left(w, 1)
      FROM unnest(regexp_split_to_array(trim(v_cust.name), '\s+')) AS w
      LIMIT 3
    ), '')), ''),
    'INV'
  );

  -- total from order items (authoritative); fall back to the order total
  SELECT COALESCE(SUM(line_total), 0) INTO v_total
  FROM order_items WHERE order_id = p_order_id;
  IF v_total = 0 THEN
    v_total := COALESCE(v_order.total_amount, 0);
  END IF;

  -- site label for this order's lines, if it has a site
  v_site := NULL;
  IF v_order.site_id IS NOT NULL THEN
    SELECT * INTO v_site FROM customer_sites WHERE id = v_order.site_id;
  END IF;

  IF v_site_count = 0 THEN
    -- ── Single-site customer: unchanged behaviour ──
    v_number := v_prefix || '-' || lpad(nextval('invoice_number_seq')::text, 4, '0');

    INSERT INTO invoices (
      invoice_number, customer_id, order_id, invoice_type, status,
      issued_at, due_at, paid_at, subtotal, vat_amount, total_amount
    ) VALUES (
      v_number, v_cust.id, p_order_id, v_type,
      CASE WHEN v_type = 'receipt' THEN 'paid' ELSE 'sent' END,
      now(),
      CASE WHEN v_type = 'invoice' THEN now() + interval '30 days' ELSE NULL END,
      CASE WHEN v_type = 'receipt' THEN now() ELSE NULL END,
      v_total, 0, v_total
    ) RETURNING id INTO v_invoice;

    INSERT INTO invoice_items (invoice_id, order_id, description, unit_price, quantity)
    SELECT v_invoice, p_order_id, product_name, unit_price, quantity
    FROM order_items WHERE order_id = p_order_id;

    UPDATE orders SET invoice_id = v_invoice WHERE id = p_order_id;

    RETURN v_invoice;
  END IF;

  -- ── Multi-site customer: collect onto one running (draft) invoice ──
  SELECT id INTO v_open_inv
  FROM invoices
  WHERE customer_id = v_cust.id AND status = 'draft'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_open_inv IS NULL THEN
    v_number := v_prefix || '-' || lpad(nextval('invoice_number_seq')::text, 4, '0');
    INSERT INTO invoices (
      invoice_number, customer_id, order_id, invoice_type, status,
      issued_at, subtotal, vat_amount, total_amount
    ) VALUES (
      v_number, v_cust.id, NULL, v_type, 'draft',
      now(), 0, 0, 0
    ) RETURNING id INTO v_open_inv;
  END IF;

  INSERT INTO invoice_items (invoice_id, order_id, description, unit_price, quantity, site_label)
  SELECT v_open_inv, p_order_id, product_name, unit_price, quantity,
         COALESCE(v_site.label, 'Main site')
  FROM order_items WHERE order_id = p_order_id;

  PERFORM recalc_invoice_totals(v_open_inv);

  UPDATE orders SET invoice_id = v_open_inv WHERE id = p_order_id;

  RETURN v_open_inv;
END;
$$;

GRANT EXECUTE ON FUNCTION create_invoice_for_order(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION recalc_invoice_totals(uuid) TO authenticated;

-- ============================================================
-- NOTES
-- • Finalising a multi-site running invoice (draft → sent, or
--   draft → paid) is done from the admin app's Invoices page —
--   "Finalise & send" — a plain status update, no SQL needed.
--   Once finalised, the NEXT order for that customer starts a
--   fresh draft invoice automatically (the WHERE status = 'draft'
--   lookup above won't find the finalised one any more).
-- • A customer becomes "multi-site" the moment Jon adds a second
--   address for them in the admin app (Customer edit → Delivery
--   sites). Existing single-site customers are completely
--   unaffected — this whole branch never runs for them.
-- • Backfill: not needed. Nothing retroactively changes; this only
--   affects orders logged AFTER a customer gets 2+ sites.
-- ============================================================
