# JG Foods — Supabase SQL Run Order

Run these migrations in the Supabase SQL editor **in the order listed below**.
Each one depends on the previous, so don't skip or reorder.

---

## How to run them

1. Go to [https://hnkidhqjsitrqhsxghjd.supabase.co](https://hnkidhqjsitrqhsxghjd.supabase.co)
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

### 8. `008_flexible_delivery_days.sql`
**What it does:** Lets Jon deliver on any day and take days off.

- Relaxes the `delivery_slots.day_label` rule so any weekday is allowed (not just Mon/Wed/Thu) — Jon can add a one-off Friday run, etc.
- Adds an `app_settings` table holding Jon's **usual days** (Mon/Wed/Thu by default), default run capacity, and default cut-off rule
- The admin app reads these to auto-open Jon's usual days each week, while letting him close any day off or add one-off days

**When to run:** Any time after 001 and 002. Safe to run on a live database.

---

### 9. `009_lockdown_customer_order_rls.sql`
**What it does:** SECURITY FIX — locks down customer and order data.

A check on 12 June 2026 found that the public anon key could read the `customers`, `orders` and `order_items` tables without logging in — exposing customer names, phones, addresses and order history. This migration force-enables RLS on those three tables, clears any stray policies, and rebuilds the correct ones (admin full access; account customers read only their own; public gets nothing).

Safe for the website — it places orders via the `place_order` RPC, not direct table access.

**When to run:** As soon as possible. Safe on the live database.

---

### 10. `010_fix_slot_count_on_move.sql`
**What it does:** Fixes delivery-day order counts when an order is moved.

The order-count trigger didn't adjust when an order was moved between days (e.g. rebooking a customer off a day off), so a cleared day could still show "1 order booked." This updates the trigger to handle moves and reconciles every slot's count from the actual orders, fixing any counts that already drifted.

**When to run:** As soon as possible. Safe on the live database.

---

### 11. `011_social_posts.sql`
**What it does:** Backs the Social Posts tab (AI post generator).

- `social_posts` table — stores each generated Facebook/Instagram post and its history
- Post history doubles as house-style examples fed back to the AI on future generations
- Admin-only access

**When to run:** Any time after 001 and 006. Safe on the live database.

---

### 12. `012_harden_admin_rls.sql`
**What it does:** SECURITY HARDENING — switches admin access on `customers`, `orders` and `order_items` from "any logged-in user" (`auth.role() = 'authenticated'`) to genuine admin-only (`current_user_role() = 'admin'`). This is the deferred follow-up noted in migration 009.

It first backfills any missing `user_profiles` rows and, if no admin exists yet, promotes all current (staff-only) accounts to admin — so running it **cannot lock Jon out**. It then rebuilds the three tables' policies from a clean slate (admin full access; account customers read only their own; public gets nothing).

After running it, confirm Jon is admin:
```sql
SELECT u.email, p.role FROM user_profiles p
JOIN auth.users u ON u.id = p.id ORDER BY p.role;
```

**Important:** the migration's footer lists two things to resolve **before customer website accounts go live** — the `driver` default role on signup, and the remaining tables still on `authenticated` write access. Read it before building customer accounts.

**When to run:** Before giving anyone other than Jon a login, and before customer accounts. Safe on the live database.

---

### 13. `013_auto_invoice_on_order.sql`
**What it does:** Makes every order create its own record automatically — a **receipt** for domestic customers, an **invoice** for trade — with the line items copied across. It's idempotent (one invoice per order) and covers both the website (`place_order` RPC, updated here) and manual Log Order.

It also fixes a quiet bug: the admin app saves trade customers as `customer_type = 'trade'`, but the original rule only allowed `domestic`/`commercial`, so those saves were failing silently. This relaxes the rule to allow all three.

Invoice numbers use the customer's `invoice_prefix` (or their initials) + a sequence, e.g. `TCP-1000`.

After running, you can optionally back-fill records for orders that already exist (SQL is in the migration's footer notes).

**When to run:** After 012. Safe on the live database. Test with one order afterwards (see go-live steps).

---

### 14. `014_invoice_pdf_storage.sql`
**What it does:** Creates a public Storage bucket (`invoice-pdfs`) so that when Jon sends a receipt/invoice, the app uploads the branded PDF and puts a tap-to-open link in the WhatsApp/email message — no attaching files by hand (important on a phone). Upload is admin-only; filenames carry a random suffix so links can't be guessed.

Depends on `current_user_role()` (migrations 006/012), so run those first.

**When to run:** After 012 and 013. Safe on the live database.

---

### 15. `015_fix_user_profile_trigger.sql`
**What it does:** Fixes "Database error creating new user" in Supabase. The profile-creation trigger was missing a `search_path`, so creating a user failed. This pins it, adds a safety net, and backfills any missing profile rows.

**When to run:** Before creating any user in Supabase. Safe on the live database. (Run it, then Authentication → Users → Add user works.)

---

### 16. `016_daily_sales.sql`
**What it does:** Adds the `daily_sales` table so the Finance → Daily Sales tab persists (it was in-memory before) and the spreadsheet import has somewhere to save to. One row per date, admin-only.

**When to run:** After 015. Safe on the live database.

### 17. `017_categories.sql`
**What it does:** Adds the `categories` table and seeds the six existing categories, so Jon can add / rename / reorder / hide / delete categories from the Availability page instead of them being hard-coded. Public read (active only) + admin full access. Products keep their text `category` column, so this is non-breaking.

**When to run:** After 016. Safe on the live database — idempotent and seeds match the current hard-coded list.

---

### 18. `018_cutoff_5pm.sql`
**What it does:** Moves the delivery cut-off from 23:59 to **5pm the day before** each delivery. Migration 008 seeded the cut-off as 23:59, and that stored setting overrides the app's code default — so this update is required for the change to take effect. It updates the `default_cutoff` setting (used for newly-opened days) and shifts every existing future delivery slot to 5pm the day before.

**When to run:** After 008. Safe on the live database — idempotent.

---

### 19. `019_customer_accounts.sql`
**What it does:** Switches on real customer accounts (sign-in, registration, **password reset**). Adds a dedicated `customer` role so self-signups are kept separate from the staff `driver` role — closing the gap migration 012 flagged. Self-signups carry an `account_type=customer` flag that routes them to the `customer` role; staff accounts (no flag) still default to `driver`. Also lets a logged-in customer create and update **their own** linked customer record (RLS-restricted to their own `user_id`).

**After running, in the Supabase dashboard:** (1) Authentication → Providers → Email is enabled; (2) Authentication → URL Configuration → Site URL = `https://jgfoodsnorthwest.com` and add redirect URL `https://jgfoodsnorthwest.com/**`; (3) optionally reword the "Reset Password" email template.

**When to run:** After 012 and 015. Safe on the live database — idempotent.

---

### 20. `020_social_graphics.sql`
**What it does:** Backs the new **Graphics** page (brand graphics studio). Adds a `social_graphics` table (the editable graphic + a link to the exported PNG, admin-only) and a public-read `social-graphics` storage bucket for the saved images.

**When to run:** After 012 and 015. Safe on the live database — idempotent.

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

- **Project URL:** `https://hnkidhqjsitrqhsxghjd.supabase.co`
- **Region:** (check dashboard)
- **Migrations folder:** `supabase/migrations/`

---

## If something goes wrong

If a migration fails partway through, check the error message in the SQL editor — it'll tell you which line failed. Common causes:

- Running out of order (e.g. 002 before 001) — tables won't exist yet
- Running a migration twice — most statements use `IF NOT EXISTS` so this is usually safe
- 004 failing — it references `invoices` and `customers` which come from 001, so 001 must be run first
