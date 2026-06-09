-- ============================================================
-- Migration 005: Delivery temperature log
-- JG Foods Admin App
-- ============================================================
-- Compliance requirement: Jon logs product temperature at each
-- customer stop during a delivery run. Environmental health
-- requires a monthly printed record.
--
-- Design: when a delivery_slot is confirmed (is_confirmed = true),
-- a trigger auto-inserts one delivery_temps row per customer
-- who has an active order on that slot. Jon opens Today's Temp
-- Log on his phone and taps in readings — no manual list-building.

-- ── delivery_temps ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS delivery_temps (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_slot_id  uuid NOT NULL REFERENCES delivery_slots(id) ON DELETE CASCADE,
  customer_id       uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  customer_name     text NOT NULL,         -- snapshot in case customer record changes
  delivery_date     date NOT NULL,         -- denormalised for fast monthly export queries
  logged_at         timestamptz,           -- when Jon entered the reading (NULL = not yet logged)
  temp_celsius      numeric(4,1),          -- typically −1 to 3°C; NULL = not yet recorded
  notes             text,                  -- e.g. "van door open", "customer not in"
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (delivery_slot_id, customer_id)   -- one reading per customer per run
);

CREATE INDEX IF NOT EXISTS idx_delivery_temps_slot
  ON delivery_temps (delivery_slot_id);

CREATE INDEX IF NOT EXISTS idx_delivery_temps_date
  ON delivery_temps (delivery_date);

CREATE TRIGGER trg_delivery_temps_updated_at
  BEFORE UPDATE ON delivery_temps
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── RLS ──────────────────────────────────────────────────────
ALTER TABLE delivery_temps ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admin full access to delivery_temps"
  ON delivery_temps FOR ALL
  USING (auth.role() = 'authenticated')
  WITH CHECK (auth.role() = 'authenticated');

-- ── Auto-population trigger ──────────────────────────────────
-- When a delivery_slot is confirmed (is_confirmed flipped to true),
-- insert a delivery_temps row for every customer with a non-cancelled
-- order on that slot. Skips customers already in the table (safe to
-- re-confirm without creating duplicates).

CREATE OR REPLACE FUNCTION populate_delivery_temps()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- Only fire when is_confirmed goes from false → true
  IF OLD.is_confirmed = false AND NEW.is_confirmed = true THEN
    INSERT INTO delivery_temps (delivery_slot_id, customer_id, customer_name, delivery_date)
    SELECT
      NEW.id,
      c.id,
      c.name,
      NEW.delivery_date
    FROM orders o
    JOIN customers c ON c.id = o.customer_id
    WHERE o.delivery_slot_id = NEW.id
      AND o.status != 'cancelled'
    ON CONFLICT (delivery_slot_id, customer_id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_populate_delivery_temps
  AFTER UPDATE OF is_confirmed ON delivery_slots
  FOR EACH ROW EXECUTE FUNCTION populate_delivery_temps();

-- ── Monthly compliance view ──────────────────────────────────
-- Powers the printable monthly temp log that Jon files for
-- environmental health. One row per customer, columns = delivery dates.
-- Query this with: SELECT * FROM monthly_temp_summary WHERE month = 'YYYY-MM'
CREATE OR REPLACE VIEW monthly_temp_summary AS
SELECT
  dt.delivery_date,
  dt.customer_name,
  dt.temp_celsius,
  dt.notes,
  dt.logged_at,
  ds.day_label,
  to_char(dt.delivery_date, 'YYYY-MM') AS month
FROM delivery_temps dt
JOIN delivery_slots ds ON ds.id = dt.delivery_slot_id
ORDER BY dt.customer_name, dt.delivery_date;
