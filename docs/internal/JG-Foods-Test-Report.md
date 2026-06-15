# JG Foods — Test Report

**Run:** 15 June 2026 · unattended code + live smoke test
**Scope:** Static review of website + admin, migrations/RLS security logic, live smoke test of the deployed sites. No login-gated or order-placing tests (those need me present to approve browser access and sign in).

---

## Headline

Both sites are live and serving correctly at `jgfoodsnorthwest.com` and `admin.jgfoodsnorthwest.com`. The code is in good shape — order flow, RLS lockdown and role handling are sound. Nothing here is on fire. The items below are worth clearing before customer accounts go live and before the next round of marketing.

## Must-fix before customer accounts go live

**Admin RLS is still "any logged-in user", not "admin only" — on customers/orders/order_items.**
Migration 009 rebuilt these three tables' policies from scratch and (deliberately) left the admin check as `auth.role() = 'authenticated'`. Migration 006 already tightened the *financial* tables to `current_user_role() = 'admin'`, but not these. Today that's fine because only staff log in. The moment website customer accounts go live, every signed-in customer also satisfies `'authenticated'` and could read **all** customers and **all** orders. This is flagged in the code itself (009, lines 87–95) and in the build notes as the #1 prerequisite. Fix: switch the admin policies on customers/orders/order_items to `current_user_role() = 'admin'` before shipping accounts. The `current_user_role()` helper and roles already exist (006).

## Should-fix (real bugs, low effort)

**Wrong domain in the VIP Christmas message.** The admin VIP message template points customers to `jgfoods.co.uk` — but the live site is `jgfoodsnorthwest.com`. If sent as-is, VIPs get a dead/wrong link. Same stale `jgfoods.co.uk` appears in the client-facing Build Summary. Search-and-replace to `jgfoodsnorthwest.com`.

**Typo in the Go-Live checklist CORS step.** The checklist tells you to whitelist `jgfoodnorthwest.com` and `admin.jgfoodnorthwest.com` in Supabase allowed origins — missing the "s" (should be `jgfoods…`). Following it literally would whitelist the wrong domain and cause CORS errors. Fix the checklist text.

**Stale "Mon or Thu" copy in the social meta tags.** The Twitter/social card description still says "Order for Mon or Thu delivery." The on-page copy was switched to flexible days, but this meta tag wasn't. It's what shows when the site is shared on social. Update to match the flexible-days messaging.

## Minor / code-quality notes (no rush)

- **Admin reassigns `window.supabase`** (`admin/index.html:1612`) to the client instance, overwriting the library object. The website does this more safely with `window.sbClient` (`website:1009`). Works today, but fragile — if any later code expects the library it'll break. Worth aligning both files on the `sbClient` pattern.
- **`reorderUsual()`** (`website:1669`) calls `addToBasket()` without the `unit` argument, so reordered items default to "pack". Harmless now; tidy when accounts go live.
- **Duplicate account badge** — `showSignedInState()` uses `insertAdjacentHTML('afterend', …)` for the account-type badge every time the panel opens, so opening it repeatedly stacks badges. Replace-in-place instead.
- **`place_order` capacity check isn't atomic** — the slot capacity/cut-off check and the insert aren't wrapped in a row lock, so two simultaneous orders could both pass on the last slot. Very low risk at this volume; note it if volume grows. Add `SELECT … FOR UPDATE` on the slot row if it ever matters.
- **Customer matching** in `place_order` matches on email OR phone — a shared phone (e.g. a couple) could attach an order to the wrong existing customer. Edge case.
- **Legacy day bucketing** — admin maps any non-Mon/Thu delivery day to the "wed" bucket for the old dashboard view. Cosmetic with flexible days; the real Delivery Runs board is date-based and correct.

## Confirmed working / not an issue

- Live Supabase URL (`hnkidhqjsitrqhsxghjd`) is correct in both website and admin. The `udwnvezlxdscpvsyuyhe` URL only appears in the portal-update scripts — that's the separate AXRIK portal project, so it's correct there.
- `place_order` is `SECURITY DEFINER`, validates slot existence/open/cut-off/capacity, and is granted to `anon` only — the public site never touches locked tables directly. Sound design.
- Migration 009 correctly force-enables RLS and rebuilds policies deterministically; the anon-read hole on customers/orders/order_items is closed.
- Driver role is blocked from financial tables at the database level (006), not just hidden in the UI.
- Both deployed sites return 200 and render full markup; DNS has propagated.

---

# Live browser test — 15 June 2026 (evening)

Driven in Chrome on the live sites, with Phil present.

## Order flow — works end to end ✅

- **Products load from Supabase** on `jgfoodsnorthwest.com` — no console errors. **But only one product is currently live**: "Chicken 5kg" at £40.50. Worth Jon flagging more products as available — a one-item shop is a weak shopfront. (Data, not a bug.)
- **Flexible delivery days are live** — banner and slot picker showed Wed 17, Thu 18, Mon 22 Jun with correct "Order by …" cut-off labels. Wednesday pre-selected by default.
- **Basket + totals correct** — item added, subtotal/total £40.50, no delivery charge (over the £20 minimum), as designed.
- **Order placed successfully** — submitted a marked test order through the real `place_order` RPC; confirmation screen returned reference **JGF-0223A9**. Full path (form → RPC → confirmation) works.
- The post-order "Save your details for next time?" account prompt appears as expected — still the demo/local flow, not yet wired to Supabase Auth.

### ⚠️ Test order to delete
A test order is now in Jon's admin: name **TEST PLEASE IGNORE**, ref **JGF-0223A9**, on the **Wed 17 Jun** run, notes marked "automated test order… safe to delete". Delete it via admin → Delivery Runs → Wed 17 Jun → the card → Delete. (It will also have created a customer record "TEST PLEASE IGNORE" — remove that too if you want a clean list.)

## Admin

- **Login screen renders and correctly gates the app** — content sits behind the login, not accessible without signing in.
- **New bug — JS error on load:** `renderInvoices()` (admin `index.html:2879`) calls `list.innerHTML = …` with no null guard, and it's invoked once on page load before the `invoiceList` element exists, throwing `TypeError: Cannot set properties of null`. Non-fatal (login still works), but it fires every load and would also throw for a driver who has no finance page. **Fix:** add `if (!list) return;` immediately after line 2879.
- Admin behind-login behaviour (role restrictions, finance, invoices, route planner) **not tested** — needs Jon's credentials and a signed-in session.

## Still not tested
Admin behind-login behaviour, invoice/PDF generation, and the stubbed external services (EmailJS, Claude API parsing, Google Maps routing, Twilio, Stripe) — all known to be not yet wired. Happy to test the admin side with you signed in.
