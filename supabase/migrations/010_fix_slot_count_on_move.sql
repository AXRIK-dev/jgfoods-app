-- ============================================================
-- Migration 010: Keep delivery_slots.orders_count correct when an
-- order is MOVED to a different day
-- JG Foods Admin App
-- ============================================================
-- BUG FOUND (12 June 2026): the orders_count trigger from migration 001
-- only adjusted counts on INSERT, on status change to/from 'cancelled',
-- and on DELETE. When an order was moved between delivery days (its
-- delivery_slot_id changed — e.g. rebooking a customer off a day off),
-- the old day's count was never decremented and the new day's never
-- incremented. Result: a day you'd cleared still showed "1 order booked".
--
-- This migration replaces the trigger function to also handle a change of
-- delivery_slot_id, and re-fires the trigger on that column. It then
-- reconciles every slot's orders_count from the actual orders, fixing any
-- counts that have already drifted.
-- ============================================================

CREATE OR REPLACE FUNCTION update_slot_orders_count()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'cancelled' THEN
      UPDATE delivery_slots SET orders_count = orders_count + 1 WHERE id = NEW.delivery_slot_id;
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'cancelled' THEN
      UPDATE delivery_slots SET orders_count = orders_count - 1 WHERE id = OLD.delivery_slot_id;
    END IF;

  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.delivery_slot_id IS DISTINCT FROM OLD.delivery_slot_id THEN
      -- Order moved to a different day: take it off the old day, add to the new
      IF OLD.status <> 'cancelled' THEN
        UPDATE delivery_slots SET orders_count = orders_count - 1 WHERE id = OLD.delivery_slot_id;
      END IF;
      IF NEW.status <> 'cancelled' THEN
        UPDATE delivery_slots SET orders_count = orders_count + 1 WHERE id = NEW.delivery_slot_id;
      END IF;
    ELSE
      -- Same day: only adjust when cancelled state flips
      IF OLD.status <> 'cancelled' AND NEW.status = 'cancelled' THEN
        UPDATE delivery_slots SET orders_count = orders_count - 1 WHERE id = NEW.delivery_slot_id;
      ELSIF OLD.status = 'cancelled' AND NEW.status <> 'cancelled' THEN
        UPDATE delivery_slots SET orders_count = orders_count + 1 WHERE id = NEW.delivery_slot_id;
      END IF;
    END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- Re-create the trigger so it also fires when delivery_slot_id changes
DROP TRIGGER IF EXISTS trg_slot_orders_count ON orders;
CREATE TRIGGER trg_slot_orders_count
AFTER INSERT OR UPDATE OF status, delivery_slot_id OR DELETE ON orders
FOR EACH ROW EXECUTE FUNCTION update_slot_orders_count();

-- One-time reconciliation: recompute every slot's count from real orders,
-- fixing any drift that has already happened (e.g. the stuck Tuesday count).
UPDATE delivery_slots ds
SET orders_count = (
  SELECT count(*) FROM orders o
  WHERE o.delivery_slot_id = ds.id
    AND o.status <> 'cancelled'
);
