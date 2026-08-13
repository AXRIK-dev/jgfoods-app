-- ============================================================
-- Migration 039: Order profiles — a customer's usual order
-- JG Foods Admin App
-- ============================================================
-- THE PROBLEM
-- The repeat-order panel offered a customer's last several orders.
-- That works today, but Jon's regulars take three or four deliveries a
-- week — within a couple of months every customer has a list of a
-- hundred near-identical past orders to scroll, and picking the right
-- one gets harder the more successful the business gets.
--
-- What Jon actually worked from before the system was a standing sheet
-- per customer: their usual items, listed in their usual order, with a
-- quantity he overwrites each week. Anything they didn't take that week
-- simply sits at 0. Roses Cafe's sheet is exactly that — County Pork
-- Sausage, Black Pudding, Brookes Rib Free Back Bacon, 1kg Tuna Pouch,
-- 500g Sliced Beef — with zeros against the two they skipped.
--
-- THIS MIGRATION stores that standing list, so Log Order offers two
-- things instead of an ever-growing history:
--
--   "Their usual order"  -> this saved profile, quantities and all
--   "Their last order"   -> the single most recent one
--
-- Either can then be edited freely — change quantities, add lines,
-- remove lines, add one-off items.
--
-- A profile can be held per DELIVERY SITE where a customer has more
-- than one, because Billy Bunters' Russell Road order is not the same
-- as his Dock Road order. site_id NULL = the customer's usual order
-- generally, used when they have a single address or no site-specific
-- profile has been saved.
--
-- SAFE TO RE-RUN. Purely additive — nothing reads this table unless a
-- profile has been saved.
-- ============================================================

CREATE TABLE IF NOT EXISTS customer_order_profiles (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id  uuid NOT NULL REFERENCES customers(id)      ON DELETE CASCADE,
  site_id      uuid          REFERENCES customer_sites(id) ON DELETE CASCADE,
  description  text NOT NULL,
  unit_price   numeric(10,2) NOT NULL DEFAULT 0,
  default_qty  integer       NOT NULL DEFAULT 0,
  sort_order   integer       NOT NULL DEFAULT 0,
  created_at   timestamptz   NOT NULL DEFAULT now(),
  updated_at   timestamptz   NOT NULL DEFAULT now()
);

COMMENT ON TABLE customer_order_profiles IS
  'A customer''s usual order — the standing list Jon works from each week. '
  'default_qty 0 means "they often take this, but not every time": the line '
  'appears on the form as a prompt and simply is not billed unless he types a '
  'quantity in.';

CREATE INDEX IF NOT EXISTS idx_order_profiles_customer
  ON customer_order_profiles (customer_id, site_id, sort_order);

DROP TRIGGER IF EXISTS trg_order_profiles_updated_at ON customer_order_profiles;
CREATE TRIGGER trg_order_profiles_updated_at
  BEFORE UPDATE ON customer_order_profiles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

ALTER TABLE customer_order_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admin full access to order profiles" ON customer_order_profiles;
CREATE POLICY "Admin full access to order profiles"
  ON customer_order_profiles FOR ALL
  USING (current_user_role() = 'admin')
  WITH CHECK (current_user_role() = 'admin');

-- Drivers can read them (the pick list benefits from knowing the usual
-- order), but never change them.
DROP POLICY IF EXISTS "Driver read order profiles" ON customer_order_profiles;
CREATE POLICY "Driver read order profiles"
  ON customer_order_profiles FOR SELECT
  USING (current_user_role() = 'driver');


-- ============================================================
-- save_order_profile — replace a customer's usual order in one go
-- ============================================================
-- Takes the lines as JSON so the admin app can save the whole profile
-- atomically: [{"description":"...","unit_price":12.7,"default_qty":4}, ...]
-- Passing an empty array clears the profile.
CREATE OR REPLACE FUNCTION save_order_profile(
  p_customer_id uuid,
  p_site_id     uuid,
  p_lines       jsonb
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer := 0;
BEGIN
  IF current_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an admin can change a customer''s usual order.';
  END IF;

  DELETE FROM customer_order_profiles
  WHERE customer_id = p_customer_id
    AND site_id IS NOT DISTINCT FROM p_site_id;

  INSERT INTO customer_order_profiles
    (customer_id, site_id, description, unit_price, default_qty, sort_order)
  SELECT
    p_customer_id,
    p_site_id,
    line->>'description',
    COALESCE((line->>'unit_price')::numeric, 0),
    COALESCE((line->>'default_qty')::integer, 0),
    (ord - 1)::integer
  FROM jsonb_array_elements(COALESCE(p_lines, '[]'::jsonb))
       WITH ORDINALITY AS t(line, ord)
  WHERE COALESCE(line->>'description', '') <> '';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION save_order_profile(uuid, uuid, jsonb) TO authenticated;


-- ============================================================
-- NOTES FOR PHIL
--
-- * Nothing uses a profile until Jon saves one. Customers without a
--   profile just get "their last order" as before.
--
-- * A profile is looked up for the chosen SITE first, falling back to
--   the customer-level one. So Billy Bunters can have a different usual
--   order for Russell Road and for the Docks, while a single-site
--   customer like Roses Cafe just has the one.
--
-- * Zero-quantity lines are deliberate. They reproduce Jon's sheet:
--   the item stays on screen as a reminder, and is left off the order
--   unless he types a quantity against it.
--
-- * Reusable for other AXRIK clients: "this customer's standing order"
--   is the single biggest time-saver for any business doing repeat
--   deliveries to the same accounts.
-- ============================================================
