# JG Foods — Supabase SQL Run Order

Run these migrations in the Supabase SQL editor **in the order listed below**.
Each one depends on the previous, so don't skip or reorder.

---

## How to run them

1. Go to [https://udwnvezlxdscpvsyuyhe.supabase.co](https://udwnvezlxdscpvsyuyhe.supabase.co)
2. Left sidebar → **SQL Editor**
3. Open each file below, copy the entire contents, paste into the editor, click **Run**
4. Wait for "Success" before moving to the next one

---

## Migration order

### 1. `001_base_schema.sql`
**What it does:** Creates every core table the system needs.

Tables created:
- `products` — the weekly availability catalogue
- `customers` — domestic and commercial, with cash tab support
- `delivery_slots` — the Monday / Wednesday / Thursday run schedule
- `orders` — every order, whatever channel it came from
- `order_items` — the individual lines within each order (prices snapshotted at time of order)
- `invoices` — trade invoices and domestic receipts
- `invoice_items` — line items within each invoice
- `weekly_sheets` — Jon's weekly reconciliation record

Also creates: `updated_at` triggers on all tables, slot capacity counter, and order total auto-calculation.

---

### 2. `002_rls_policies.sql`
**What it does:** Locks down who can see and edit what.

- Public (website visitors): can read available products and open delivery slots — nothing else
- Admin (Jon, logged in): full access to everything
- Account customers (registered website users): can see only their own orders, customer record, and invoices
- Nobody can read other people's orders

Run this immediately after 001 — without it the tables are wide open.

---

### 3. `003_place_order_rpc.sql`
**What it does:** Creates the `place_order` database function.

Website visitors submit orders through this function rather than writing directly to any table. It:
- Checks the slot is open, under capacity, and within the cut-off time
- Finds or creates the customer record (matched by email or phone)
- Inserts the order and all items atomically
- Returns a human-readable reference (e.g. JGF-4A2F1C)

Without this, the customer website cannot place orders.

---

### 4. `004_split_payments_and_cash_tabs.sql`
**What it does:** Adds split payment and cash tab support.

- `invoice_payments` table — tracks individual payments against an invoice (cash, BACS, or both)
- `cash_tab_entries` table — tracks daily deliveries for customers who pay as a weekly lump sum
- Two helper views: `invoice_payment_summary` and `unsettled_tab_totals`
- Adds `cash_tab` and `tab_settle_day` columns to the `customers` table

---

### 5. `005_delivery_temps.sql`
**What it does:** Creates the temperature log, linked to delivery runs.

- `delivery_temps` table — one row per customer per delivery run
- Auto-population trigger: when Jon confirms a delivery slot (`is_confirmed = true`), rows are automatically created for every customer with an order on that run
- `monthly_temp_summary` view — powers the monthly compliance export for environmental health
- Jon never builds the temp list manually — it comes from the delivery run

---

### 6. `006_user_roles.sql`
**What it does:** Adds role-based access control — admin (Jon) and driver (delivery friend).

- `user_profiles` table — stores each user's role
- Auto-creates a profile row for every new Supabase Auth user, defaulting to `driver`
- Updates RLS on all financial tables so drivers are blocked at the database level — invoices, finance, weekly sheets, cash tabs, and payment data are admin-only
- Drivers can read orders, customers, delivery slots, and temp log — enough to do the job, nothing more

**After running this migration**, set Jon's role to admin:
```sql
UPDATE user_profiles
SET role = 'admin'
WHERE id = (
  SELECT id FROM auth.users WHERE email = 'jons-email@example.com'
);
```
Replace with Jon's actual email. Every other user defaults to `driver` automatically — no action needed for the delivery friend's account.

---

### 7. `007_pie_supplier_cutoffs.sql`
**What it does:** Adds pie/meat supplier split logic.

- Adds `supplier_type` column to `products` table (`meat` or `pie`, defaults to `meat`)
- Creates `supplier_cutoffs` config table with cut-off rules per supplier
- Seeds pie (12pm, order day before, Friday covers Monday) and meat (5pm, same day)
- Powers the pie order alert banner on the admin dashboard

**When to run:** Any time after 001. Safe to run after go-live if you want to add this feature later.

---

## After running all migrations

### Add the anon key to the admin app

1. In Supabase: go to **Settings → API**
2. Copy the **anon / public** key
3. Open `admin/index.html`
4. Find the line: `const SUPABASE_ANON_KEY = 'REPLACE_WITH_ANON_KEY';`
5. Replace `REPLACE_WITH_ANON_KEY` with the key you copied
6. Save the file

The admin app is now connected to the live database.

### Do the same for the customer website

The website (`website/index.html`) will need the same Supabase URL and anon key wired in when that file is connected.

---

## Supabase project details

- **Project URL:** `https://udwnvezlxdscpvsyuyhe.supabase.co`
- **Region:** (check dashboard)
- **Migrations folder:** `supabase/migrations/`

---

## If something goes wrong

If a migration fails partway through, check the error message in the SQL editor — it'll tell you which line failed. Common causes:

- Running out of order (e.g. 002 before 001) — tables won't exist yet
- Running a migration twice — most statements use `IF NOT EXISTS` so this is usually safe
- 004 failing — it references `invoices` and `customers` which come from 001, so 001 must be run first
