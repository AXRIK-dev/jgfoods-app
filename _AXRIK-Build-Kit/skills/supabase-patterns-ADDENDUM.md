# supabase-patterns — recommended additions

Your existing `supabase-patterns` skill is good. These are the JG-Foods-proven additions worth folding in (paste into the skill via Settings → Capabilities). They close the gaps that caused rework on the first build.

## 1. Role-based RLS from day one (replaces the "add roles later" path)

Don't ship the broad `auth.role() = 'authenticated'` policy and harden later — that cost JG Foods four extra migrations. Ship role-based RLS in the **first** RLS migration:

- A `user_profiles` table with a `role` column and a signup trigger (use `COALESCE(raw_user_meta_data->>'full_name','')` — null metadata broke the trigger on JG Foods).
- A `current_user_role()` SECURITY DEFINER STABLE helper that defaults to **least privilege** for unknown users.
- Every policy keyed off `current_user_role()`.
- **Financial tables (`invoices`, payments, sheets) are admin-only from the start** — staff/drivers blocked at the DB level, not just hidden in the UI.

Full reference implementation: `_AXRIK-Build-Kit/starter-kit/supabase/002_roles_and_rls.sql`.

## 2. Triggers to bake into the base schema

- **`orders_count` maintenance must handle order *moves*** between slots (`UPDATE OF status, delivery_slot_id`), not just insert/cancel. Missing the move case was a JG Foods bug fix (migration 010).
- **Order total auto-calc** from `order_items` via a trigger, so totals can never drift.
- **`updated_at`** trigger on every table.

## 3. Self-service user management via a service-role Netlify function

So the client adds/removes their own staff logins and resets passwords without you touching Supabase. Admin-gated, service key server-side only. Reference: `_AXRIK-Build-Kit/starter-kit/netlify-functions/manage-users.js`.

## 4. `app_settings` key/value table

Put client-tweakable config (cut-off times, fees, capacities) in an `app_settings` jsonb table, not code constants — avoids a migration + redeploy every time the client wants a number changed.

## 5. Price snapshots

`order_items` stores `product_name` and `unit_price` at time of order. Never join live `products` to render a historical order — prices change.

## 6. Client-managed categories (don't hard-code taxonomy)

Catalogue sections belong in a `categories` table, not hard-coded in the front end. On JG Foods the list was baked into three places (admin add, admin edit, website filter), so adding a section meant a code change in all three. Bake the table into the base schema:

- `categories (id, name UNIQUE, slug UNIQUE, sort_order, is_active)` — the source of truth for the *list* of categories and their order.
- RLS mirrors `products`: **public read active / staff read all / admin write**.
- Products keep their text `category` column (match by name) — non-breaking, no FK needed. Rename cascades onto products in the admin UI; delete reassigns to `Other`.
- Front end (admin modal + website filter) renders from the table, so the client self-manages add/rename/reorder/hide/delete.

Reference: `_AXRIK-Build-Kit/starter-kit/supabase/001_base_schema.sql` (table) + `002_roles_and_rls.sql` (RLS) + `patterns/category-manager.md` (front end).
