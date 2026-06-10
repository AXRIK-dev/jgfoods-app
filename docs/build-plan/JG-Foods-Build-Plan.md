# JG Foods — Build Plan

*Version 0.8 — 9 June 2026. A working document. Decisions marked **[CONFIRM]** need a quick conversation with Jon before they're locked.*

---

## Current build status

**Phase 1 and 2 core — substantially complete and deployed.**

- Customer website deployed at jgfoodsnorthwest.com — DNS propagating (9 June 2026, both sites still propagating as of today)
- Admin app deployed at admin.jgfoodsnorthwest.com — DNS propagating
- Supabase database connected, all tables created and RLS policies applied
- GitHub: AXRIK-dev · Netlify auto-deploy on push

### What's live and working

**Admin app (admin/index.html):**
- Supabase Auth — login screen, sign in/out, admin role check
- Products load from Supabase on login; price/availability changes save back
- Customers load from Supabase; edits save immediately; new customers insert and get real UUID
- Orders load from Supabase with customer + slot + items; order status updates (confirmed / packed / delivered) persist
- Log Order — 4-step async save: find/create customer, find/create delivery slot, insert order + order items. Wednesday slot added alongside Mon/Thu.
- Customer detail modal — full order history loaded live from Supabase (date, slot, total, status, line items)
- Delivery Runs — Monday, Wednesday, Thursday tabs with live order counts; dynamic pick list aggregated from real orders; route planner (simulated, Google Maps URL generated)
- Quick temps overlay — saves to localStorage and upserts to Supabase delivery_temps
- Full temp log grid — loads from Supabase, inline save with debounce
- Invoice generator — INVOICE_CUSTOMERS rebuilt from live customer data after load
- Weekly finance sheet — saves to Supabase weekly_sheets with upsert on week_ending
- Monthly CSV export — fetches weekly_sheets for current month from Supabase
- Product image upload — FileReader preview + Supabase Storage upload + img_url column update
- Social media post generator, AI order parser (UI built; real Claude API pending)
- VIP list, route planner, Friday checklist, help drawer, GDPR review panel

**Customer website (website/index.html):**
- Fully responsive public site — hero, about, how it works, product showcase, social links, contact
- Static currently — online order form pending Supabase `place_order` RPC (Phase 2 completion)

### Pending — no external service needed

These can be built now:

- Online order form on website → needs `place_order` Supabase RPC + order confirmation flow
- Customer accounts (sign up / sign in / reorder) → Supabase Auth on website side, `user_id` link on customers table
- Invoice save/load from Supabase → invoices table, PDF generation
- Delivery temps auto-population → edge function or trigger when delivery slot confirmed
- Standing delivery slot management (open/close, capacity, cut-off) — UI shell exists, not wired
- Wednesday slots formally added to delivery days

### Pending — external service required

- **EmailJS** (SERVICE_ID + TEMPLATE_ID): invoice send by email, order confirmation email
- **Twilio**: invoice send by SMS, VIP bulk SMS, automated Mon/Wed/Thu reminder messages
- **Claude API via Netlify Function**: AI order parser, VIP message redraft, picking-list AI tip
- **Google Maps Routes API**: real route optimisation (simulated today)
- **Stripe**: online payment at checkout (Phase 4)

### Pending — Jon needs to action

*Holding until DNS has fully propagated and Phil has tested both sites himself.*

1. Invite Jon via Supabase Auth (jongreen347@gmail.com) → Auth → Users → Invite
2. Run SQL to set admin role: `UPDATE user_profiles SET role = 'admin' WHERE user_id = '<Jon UUID>';`
3. Create Supabase Storage bucket named `product-images` (public)
4. Jon logs in and clicks Save on Availability page → seeds products table from defaults
5. Provide delivery postcode list for order form validation
6. Confirm commercial pricing arrangements (trade price per product vs. flat discount)

---

## 1. The business problem

JG Foods is a healthy little business. Jon Green runs a mobile butcher round out of a refrigerated van, delivering fresh meat across the North-west to domestic customers and commercial clients — cafes, butchers, hotels, pubs and restaurants. The Facebook page has 579 followers, a 100% recommendation rate across 14 reviews, and a 5-star hygiene rating. After a difficult year the business was rebuilt through leaflets and cold calling, so it is relationship-driven and personal by nature. That is a strength, and the system we build should protect it, not flatten it.

The problem is not demand — it's that **Jon is the order system**. Every week he posts an availability list on Facebook and Instagram (`jgfoodsliverpool`), and orders come back as comments, Messenger replies and texts to his mobile. He then holds all of that in his head or on paper, and sorts it into two piles: a **Monday afternoon** delivery run and a **Thursday afternoon** run (Wednesday being added). There is a cut-off ("get your orders in early for guaranteed delivery"), slots are limited ("only a few slots available for Monday"), and customers "book a slot via direct message".

That works today. But it caps the business. Every order has to pass through Jon's phone, a missed message is a lost sale, there is no record of what each customer usually buys, and the weekly admin is all manual. Growing the round means growing the messaging load one-to-one.

**What we're solving:** take ordering off Jon's phone and into a system, without losing the personal feel — and give Jon back the hours he currently spends collating orders by hand.

---

## 2. What we're building — one system, two ends

The brief describes a "website" and a "web app" as if they were two projects. They aren't. They are two ends of **one system**:

- **The front end (public website)** — where a customer sees what's available this week and places an order.
- **The back end (Jon's app)** — where Jon sees those orders, manages his delivery runs, keeps customer records, and controls what's on offer.

An order goes in the front and Jon works it at the back. They share one database. This is why we're scoping the data model first — if the order form and Jon's app disagree about what an "order" looks like, we rebuild one of them.

The spine of the whole system is **scheduled delivery**: fixed delivery days, limited slots, an order cut-off, and a weekly availability list Jon controls. Get that right and everything else hangs off it cleanly.

### Accommodating social media orders

Assume Jon will keep getting orders via Facebook and Instagram even after launch — and that's fine. The system should **absorb** those orders, not fight them. Every order carries a `channel` field (`website`, `facebook`, `instagram`, `phone`). Jon can key a Facebook order into his app in seconds and it lands in exactly the same Monday/Wednesday/Thursday run as a website order. One source of truth, regardless of how the order arrived.

### Serving commercial clients

Commercial clients — pubs, restaurants, cafes, hotels and shops — are a major part of JG Foods, not an afterthought, and they behave differently from a family ordering a BBQ pack. A pub kitchen tends to order the same core items week after week, in larger quantities, often expects trade pricing, and won't want to tap in card details at the door every delivery. The system treats commercial ordering as a first-class case:

- **Trade pricing.** Commercial clients can see trade prices rather than retail. The data model supports this with a price tier on the customer record and an optional trade price per product — so one catalogue serves both audiences without being duplicated.
- **Repeat / "your usual" orders.** A saved regular order that can be re-placed in one tap — and, optionally, a standing order that repeats automatically against each delivery run. For Jon's commercial base this is the single biggest time-saver: a weekly phone call becomes a tap.
- **Ordering on account.** Rather than paying per delivery, commercial clients can order on account and be invoiced (for example, monthly). The order flow simply skips the payment step; billing is handled separately.
- **A trade-appropriate tone.** The website speaks to both audiences — warm and approachable for domestic customers, with a clear "trade / wholesale" path for commercial clients that leads with reliability, consistent supply and trade pricing.

Because the exact commercial arrangements still need confirming with Jon (section 6), the build is designed to **flex**: trade pricing and repeat orders are built in from the start, but can be simplified down if his commercial clients turn out to order much like domestic ones.

---

## 3. Build phases

### Phase 1 — Foundation + customer website ✅ Core complete
The visible win, and the data foundation underneath it.

- ✅ Supabase project, schema and RLS policies
- ✅ Public website: who JG Foods is, the hygiene/reviews credibility, and a "this week's availability" page. Fully responsive.
- ⏳ Online order form: pick products, pick a delivery slot (Mon/Wed/Thu), enter contact and address details, submit. Needs `place_order` RPC.
- ⏳ Order confirmation email to the customer and a notification to Jon (EmailJS).
- ✅ Admin order list so Jon can see website orders coming in from day one.

*Outcome:* a customer can order online without messaging Jon, and Jon can see the order.

### Phase 2 — Jon's order-management app + finance ✅ Core complete
The real time-saver — and Jon's operational hub.

- ✅ Login for Jon (admin role)
- ✅ Delivery-run views: Monday, Wednesday and Thursday — every order for that run, grouped and ready to pack
- ✅ Order statuses: pending → confirmed → packed → delivered, persisting to Supabase
- ✅ Customer records: history (full order history from Supabase), domestic vs commercial, notes
- ✅ Weekly availability control: Jon toggles products on/off and edits prices
- ✅ Manual order entry: key in a Facebook/phone order in seconds, tagged by channel
- ⏳ Delivery-slot management UI: open/close slots, set capacity and cut-off times (shell built)
- ✅ Finance dashboard: weekly sheet, carried forward, banked, purchases, expenses
- ⏳ Invoice generation: PDF creation and send — UI built, EmailJS + PDF lib pending
- ✅ Paid / unpaid tracking in invoice list
- ⏳ Monthly statements: trade clients consolidated statement

*Outcome:* Jon stops collating orders by hand. The runs assemble themselves. He knows exactly who owes him money.

### Phase 3 — AI + efficiency layer
Once orders are flowing and there's history to work with.

- ✅ Auto-generated picking lists from live order data (dynamic, updates per tab)
- ✅ Weekly Facebook/Instagram post drafting from live product list (social generator built)
- ✅ Paste-to-parse: Jon pastes a Messenger thread; AI extracts structured order (UI built, Claude API pending)
- ⏳ Customer communication drafts (order confirmed, out for delivery)
- ⏳ Demand forecasting

*Outcome:* the weekly admin shrinks to a review-and-send.

### Phase 4 — Online payments + growth tools
When the business is ready for the next level.

- Stripe payment integration, customer loyalty programme, referral scheme, promotional codes, email/SMS marketing, new area expansion tools.

### Phase 5 — Scale: second driver + route intelligence
When demand justifies expanding the operation.

- Second driver management, route optimisation (Google Maps), multi-driver picking lists, wholesale tier, PWA.

---

## 4. Data model

Five core tables. They follow the standard patterns (UUID keys, `created_at`/`updated_at`, soft deletes), with a few JG Foods-specific points flagged.

### `products` — the catalogue
The weekly availability list. Jon switches items on and off here.

| Column | Notes |
|---|---|
| `id`, `created_at`, `updated_at` | Standard |
| `name` | e.g. "5kg Chicken Fillets", "BBQ Pack", "Ribeye Steak (5)" |
| `description` | What's in a pack |
| `category` | Chicken, Steak, BBQ, Kebabs, Burgers & Sausages, Meat Packs |
| `price` | Standard (retail) price, `NUMERIC(10,2)` |
| `trade_price` | Optional trade price for commercial clients; `NULL` = no trade rate, fall back to standard |
| `unit` | 'pack', 'kg', 'each' |
| `is_available` | The weekly on/off toggle — powers the public site |
| `sort_order` | Display order |
| `img_url` | Supabase Storage URL for product photo |

### `customers` — domestic and commercial
| Column | Notes |
|---|---|
| `id`, `created_at`, `updated_at` | Standard |
| `user_id` | Nullable FK → auth.users — set only when the customer registers an account; guest customers have none |
| `customer_type` | 'domestic' or 'commercial' |
| `name` | Contact name |
| `business_name` | For commercial clients (pubs, cafes, hotels, shops) |
| `price_tier` | 'standard' or 'trade' — decides which price the customer sees |
| `billing` | 'per_delivery' or 'on_account' — on-account clients are invoiced, not charged each order |
| `email`, `phone` | Contact |
| `address_line_1/2`, `city`, `postcode` | Delivery address |
| `notes` | Free text — "leave with neighbour", standing order, etc. |
| `cash_tab`, `tab_settle_day` | For customers who pay their full week's cash in one go |
| `is_active` | Soft delete |

### `delivery_slots` — the spine
This is the JG Foods-specific table and the reusable bit for any scheduled-delivery business.

| Column | Notes |
|---|---|
| `id`, `created_at`, `updated_at` | Standard |
| `delivery_date` | The actual date |
| `day_label` | 'Monday' / 'Wednesday' / 'Thursday' — for display |
| `capacity` | Max orders for that run |
| `orders_count` | Running count, kept current by a trigger |
| `cutoff_at` | Timestamp after which the slot closes to new orders |
| `is_open` | Manual override so Jon can close a run early |

### `orders`
| Column | Notes |
|---|---|
| `id`, `created_at`, `updated_at` | Standard |
| `customer_id` | FK → customers |
| `delivery_slot_id` | FK → delivery_slots |
| `channel` | 'website', 'facebook', 'instagram', 'phone' — absorbs social orders |
| `status` | pending / confirmed / packed / delivered / cancelled |
| `total_amount` | Kept current by a trigger off `order_items` |
| `notes` | Customer's note at checkout |

### `order_items`
| Column | Notes |
|---|---|
| `id`, `created_at` | Standard |
| `order_id` | FK → orders, `ON DELETE CASCADE` |
| `product_name` | **Snapshot** of the name at time of order |
| `unit_price` | **Snapshot** of the price at time of order |
| `quantity`, `unit` | |
| `line_total` | `GENERATED ALWAYS AS (quantity * unit_price)` |

Snapshotting name and price matters: if Jon changes a price next week, last week's orders must still show what the customer actually paid.

### `invoices` — financial records (Phase 2)

Every delivered order generates a record here, whether trade or domestic. Trade orders produce a proper invoice; domestic orders produce a receipt. Both are PDF-exportable and emailable from the app.

| Column | Notes |
|---|---|
| `id`, `created_at`, `updated_at` | Standard |
| `invoice_number` | Human-readable sequential ref (e.g. INV-0041 / RCP-0041) |
| `customer_id` | FK → customers |
| `invoice_type` | 'invoice' (trade, payment due later) or 'receipt' (domestic, paid on delivery) |
| `status` | 'draft' / 'sent' / 'paid' / 'overdue' |
| `issued_at` | When it was sent |
| `due_at` | Payment due date (for invoices) |
| `paid_at` | Nullable — when payment was confirmed |
| `subtotal`, `total` | `NUMERIC(10,2)` |
| `notes` | Internal notes or payment reference |
| `pdf_url` | Supabase Storage path to generated PDF |

### `standing_orders` — repeat commercial orders (Phase 2)
A saved order that repeats on a cadence. Each week, a Supabase edge function drafts a new `order` from this template and surfaces it for Jon to confirm or adjust before it goes live on the run.

| Column | Notes |
|---|---|
| `customer_id` | FK → customers |
| `cadence` | 'monday', 'wednesday', 'thursday', 'both' |
| `items` | JSONB snapshot of the usual order lines |
| `is_active` | Jon can pause without deleting |
| `last_generated_at` | Prevents duplicate generation |

### `delivery_temps` — temperature log (compliance)

Environmental health compliance: Jon logs the temperature of goods at each customer delivery using a digital gauge in the van.

| Column | Notes |
|---|---|
| `id`, `created_at` | Standard |
| `delivery_slot_id` | FK → delivery_slots |
| `customer_id` | FK → customers |
| `customer_name` | Snapshot |
| `delivery_date` | Date of delivery |
| `logged_at` | Timestamp when Jon entered the reading |
| `temp_celsius` | `NUMERIC(4,1)` |
| `notes` | Optional flag |

### RLS policies needed

- **`products`, `delivery_slots`** — public read. Admin-only write.
- **`orders`, `order_items`, `customers`** — admin-only by default. Account customers get "read your own" policy matched on `customers.user_id = auth.uid()`.
- **Order submission** — one `place_order` Postgres function (`SECURITY DEFINER`, callable by the anon role) handles atomic order creation, slot capacity check, and cut-off enforcement.

---

## 5. AI opportunities

- ✅ **Weekly social post drafting** — built, generates from live product list
- ✅ **Picking lists** — dynamic, built from live orders
- ✅ **Paste-to-parse social orders** — UI built, Claude API integration pending
- ⏳ **Customer communication drafts** — order confirmed, out for delivery
- ⏳ **Demand forecasting** — once order history accumulates
- ⏳ **VIP message redraft** — UI built, Claude API pending

---

## 6. Decisions to confirm with Jon

1. **Payment.** Pay-on-delivery recommended for launch. Stripe in Phase 4.
2. **Customer accounts.** Both guest and registered. Guest is default.
3. **Delivery area.** Which postcodes does Jon cover? Needed for order form validation.
4. **Delivery days & cut-offs.** Monday + Wednesday (domestic) + Thursday. Confirm exact cut-off times.
5. **How commercial clients actually work.** Trade pricing, standing orders, on-account invoicing — need detail.
6. **Minimum order value**, if any.
7. **Full product list with current prices.**

---

## 7. Financial management — detail

Jon currently has no real financial overview of the business. The finance module in Phase 2 solves this without requiring Jon to understand accounting software.

### Invoice generation
Every time an order is marked as delivered, the system creates a draft invoice or receipt automatically. Jon opens it, checks it, and presses **Send** — the customer receives a branded PDF by email or WhatsApp.

### Payment tracking
Jon taps **Mark as paid** when a trade client settles. Overdue invoices appear highlighted in the finance dashboard.

### AI chasing
When an invoice is overdue, the app offers a **Chase** button that drafts a polite but firm message in Jon's natural tone — ready to send by email or WhatsApp.

### Monthly statements
Trade clients on account can receive a consolidated statement at end of month — one click per client, or bulk-send to all active trade accounts.

### Stripe (Phase 4)
Pay-on-delivery at launch. Stripe designed in but not switched on. One config flag enables it — no rebuild.

### Export
Invoices and payment records export to CSV for Jon's accountant / QuickBooks import.

---

## 8. Growth strategy

### 8.1 Make the website do the selling (SEO + content)
- Google Business Profile integration via schema markup
- Short SEO content articles (meat delivery Ormskirk, mobile butcher West Lancashire)
- SEO-optimised trade landing page targeting pub and restaurant buyers

### 8.2 Convert existing customers into recurring revenue
- Domestic standing orders (subscription model)
- Account notifications when availability goes live
- "Your usual" prompt at checkout for returning customers

### 8.3 Expand the delivery area
- Postcode-based order validation
- Add zones to the delivery slot system — no code change

### 8.4 Commercial client growth
- Trade-dedicated landing page and quote request form
- Standing order automation — one weekly tap instead of a phone call

---

## 9. AXRIK template notes

This build is the first AXRIK portfolio project. The following patterns are reusable:

- **Scheduled-delivery spine** (`delivery_slots` + `orders` + `place_order` RPC): any business with fixed delivery days — farm boxes, dairy rounds, meal prep.
- **Social order absorption** (`channel` field + paste-to-parse AI): any business where customers still contact by phone or DM.
- **Dynamic pick list**: any fulfilment business needing daily pack sheets.
- **Temp log / compliance screen**: any food business with temperature recording obligations.
- **Trade / domestic split** (price tiers, on-account billing): any B2B2C storefront.
