-- ============================================================
-- Migration 042: Minimum-order charge exemption (make the tick box real)
-- JG Foods Admin App
-- ============================================================
--
-- The customer record has had an "Exempt from minimum order charge" tick box
-- since the early build, but there was never a column behind it — ticking it
-- looked right until the next refresh, then silently reverted. Any customer
-- Jon thought he'd exempted was still being charged the £5.
--
-- Design note: the exemption is a plain per-customer setting Jon controls, NOT
-- a rule hardcoded to account type. Trade accounts start exempt because that's
-- almost always right, but he can untick any of them — a small trade account he
-- does want to charge delivery on is a normal thing to want, and hardcoding
-- "trade = always free" would take that decision off him.

ALTER TABLE customers
  ADD COLUMN IF NOT EXISTS exempt_min_charge boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN customers.exempt_min_charge IS
  'Never apply the £5 small-order charge to this customer. Set true by default '
  'for new trade accounts (see trg_default_min_charge_exemption), but Jon can '
  'change it on any customer, trade or domestic.';

-- Backfill: every existing trade/commercial account starts exempt.
UPDATE customers
   SET exempt_min_charge = true
 WHERE customer_type IN ('trade', 'commercial')
   AND exempt_min_charge = false;


-- ── New trade accounts start exempt ──────────────────────────
-- Trade customers can arrive without going through the admin app — they sign
-- up on the website themselves (migration 033) and land as pending. Without
-- this they'd default to false and get charged the £5 until Jon noticed.
--
-- INSERT only, deliberately. It sets the starting value and then never touches
-- the column again, so once Jon unticks a trade customer it stays unticked.
--
-- It also skips admin inserts. When Jon adds a trade customer himself the form
-- sends what he actually chose, and if he's deliberately unticked the box the
-- trigger must not overrule him. Only self-signups off the website — where
-- nothing sets the column at all — get the default applied.
CREATE OR REPLACE FUNCTION default_min_charge_exemption()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.customer_type IN ('trade', 'commercial')
     AND NEW.exempt_min_charge IS NOT TRUE
     AND current_user_role() IS DISTINCT FROM 'admin' THEN
    NEW.exempt_min_charge := true;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_default_min_charge_exemption ON customers;
CREATE TRIGGER trg_default_min_charge_exemption
  BEFORE INSERT ON customers
  FOR EACH ROW EXECUTE FUNCTION default_min_charge_exemption();

-- No RLS change needed: migration 012 already gives admin full access to
-- customers, and account customers can read their own record (which is how
-- the website knows not to add the charge at checkout).
