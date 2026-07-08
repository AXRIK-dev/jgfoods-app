---
name: axrik-project-kickoff
description: The standard AXRIK build workflow for a new bespoke web-app client. Use at the START of any new AXRIK client project, or when Phil mentions a new client, a new niche build, scoping a web app, kicking off a project, or "doing another one like JG Foods". Covers the discovery-first sequence, the proven build phase order, the reusable starter kit, and the admin-app shell pattern that keep a build lean and avoid the rework seen on the first project.
---

# AXRIK Project Kickoff

AXRIK builds bespoke web apps for small, niche businesses on a fixed lean stack: vanilla HTML/JS, Supabase (Postgres + RLS + Auth), Netlify, EmailJS. Every build should become cheaper and faster than the last by reusing a common spine. This skill is the playbook for starting one.

Use it alongside `supabase-patterns` (DB/RLS), `axrik-ai-features` (AI features) and `axrik-deliverables` (client docs).

## Golden rule: discovery before code, schema before screens

JG Foods (the first build) cost ~35 hours over 7 sessions and ~16 migrations, with roughly half the migrations being rework. The biggest savings for the next build come from getting the data model and security right **once**, before any screens exist.

The two ends — public website and admin app — are **one system sharing one database**. Scope the data model first. If the order form and the admin app disagree about what an "order" is, you rebuild one of them.

## Build phase order (do not reorder)

1. **Discovery.** Get the client's real artefacts — their spreadsheets, their order messages, their invoice format, their delivery days. Model the schema from *their* reality, not assumptions. Ask: how do orders arrive, what are the delivery/collection days, who else needs a login, do they invoice, do they have trade pricing.
2. **Schema + RLS + Auth — all at once, day one.** Start from the `starter-kit/supabase` migrations. Write role-based RLS immediately (admin / staff / account / public). Never "add security later" — that was four extra migrations on JG Foods.
3. **Customer website + online ordering.** The visible win. Catalogue + slot picker + `place_order` RPC.
4. **Admin app screens.** Catalogue, orders, delivery runs, customers, finance — built on the shell pattern below.
5. **AI features.** Layer on last, each with a non-AI fallback (see `axrik-ai-features`).
6. **Go-live + handover.** Use the `axrik-deliverables` checklist, testing worksheet and build summary.

## Start from the starter kit

A reusable starter kit lives at `_AXRIK-Build-Kit/starter-kit` (clone it per client):
genericised base schema, day-one role-based RLS, `place_order` RPC, the generic Claude proxy, and the self-service user-management function. For a scheduled-delivery/ordering business this is ~60% of the backend before you write a line of new code. Customise the `>>>`-marked CHECK constraints to the client's reality.

## Admin-app shell pattern

JG Foods' admin is a single 6,200-line HTML file with a `showPage('...')` router across ~12 sections (dashboard, orders, runs, customers, finance, invoices, social, etc.). Single-file is the deliberate AXRIK choice (no build step, one file to host and maintain). To keep it lean on the next build:

- **Keep the `showPage()` router**, one `<section>` per page, hidden/shown by id. It's simple and the client never sees it.
- **Each page renders from a single fetch** of live Supabase data on open — don't scatter data loads.
- **Build config into an `app_settings` table**, not constants, so the client can change cut-offs/fees without a redeploy.
- **Reuse the JG Foods sections wholesale** where the niche matches: dashboard, orders, runs/pick-list, customers, finance/weekly sheet, invoice generator, user management, help drawer.
- **Build an in-admin help guide** (the JG Foods `HELP_PAGES` pattern) so the non-technical client is self-sufficient.

## Per-client customisation checklist

- Delivery/collection days and cut-off rules → `delivery_slots` + `app_settings`
- Order channels the client actually uses → `orders.channel` CHECK
- Trade pricing? → `products.trade_price` + `customers.price_tier`
- Catalogue sections the client manages themselves → `categories` table seed + `patterns/category-manager.md` (never hard-code the list)
- Invoicing/VAT? → keep or drop `invoices`; set VAT handling per client
- Branding (colours, logo, domain) and copy → website + admin + PDF
- Roles beyond admin/staff? → extend `current_user_role()` and policies

## Watch-outs (real bugs from JG Foods, now pre-solved in the kit)

- Slot `orders_count` must update when an order is **moved** between slots, not just created/cancelled — fixed in `001_base_schema.sql`.
- The signup trigger breaks if `raw_user_meta_data` is null — fixed in `002_roles_and_rls.sql`.
- Don't hard-code catalogue categories — JG Foods had them baked into three places (admin add, admin edit, website filter) and adding one meant a code change. Use the `categories` table + `patterns/category-manager.md` so the client self-manages them.
- Strip placeholder/integration notes (e.g. leftover SMS-provider copy) before handover — they caused confusing "fix" commits.
