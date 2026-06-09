# JG Foods — Build Plan

*Version 0.4 — 22 May 2026. A working document. Decisions marked **[CONFIRM]** need a quick conversation with Jon before they're locked.*

---

## 1. The business problem

JG Foods is a healthy little business. Jon Green runs a mobile butcher round out of a refrigerated van, delivering fresh meat across the North-west to domestic customers and commercial clients — cafes, butchers, hotels, pubs and restaurants. The Facebook page has 579 followers, a 100% recommendation rate across 14 reviews, and a 5-star hygiene rating. After a difficult year the business was rebuilt through leaflets and cold calling, so it is relationship-driven and personal by nature. That is a strength, and the system we build should protect it, not flatten it.

The problem is not demand — it's that **Jon is the order system**. Every week he posts an availability list on Facebook and Instagram (`jgfoodsliverpool`), and orders come back as comments, Messenger replies and texts to his mobile. He then holds all of that in his head or on paper, and sorts it into two piles: a **Monday afternoon** delivery run and a **Thursday afternoon** run. There is a cut-off ("get your orders in early for guaranteed delivery"), slots are limited ("only a few slots available for Monday"), and customers "book a slot via direct message".

That works today. But it caps the business. Every order has to pass through Jon's phone, a missed message is a lost sale, there is no record of what each customer usually buys, and the weekly admin is all manual. Growing the round means growing the messaging load one-to-one.

**What we're solving:** take ordering off Jon's phone and into a system, without losing the personal feel — and give Jon back the hours he currently spends collating orders by hand.

---

## 2. What we're building — one system, two ends

The brief describes a "website" and a "web app" as if they were two projects. They aren't. They are two ends of **one system**:

- **The front end (public website)** — where a customer sees what's available this week and places an order.
- **The back end (Jon's app)** — where Jon sees those orders, manages his two delivery runs, keeps customer records, and controls what's on offer.

An order goes in the front and Jon works it at the back. They share one database. This is why we're scoping the data model first — if the order form and Jon's app disagree about what an "order" looks like, we rebuild one of them.

The spine of the whole system is **scheduled delivery**: fixed delivery days, limited slots, an order cut-off, and a weekly availability list Jon controls. Get that right and everything else hangs off it cleanly.

### Accommodating social media orders

Assume Jon will keep getting orders via Facebook and Instagram even after launch — and that's fine. The system should **absorb** those orders, not fight them. Every order carries a `channel` field (`website`, `facebook`, `instagram`, `phone`). Jon can key a Facebook order into his app in seconds and it lands in exactly the same Monday/Thursday run as a website order. One source of truth, regardless of how the order arrived.

### Serving commercial clients

Commercial clients — pubs, restaurants, cafes, hotels and shops — are a major part of JG Foods, not an afterthought, and they behave differently from a family ordering a BBQ pack. A pub kitchen tends to order the same core items week after week, in larger quantities, often expects trade pricing, and won't want to tap in card details at the door every delivery. The system treats commercial ordering as a first-class case:

- **Trade pricing.** Commercial clients can see trade prices rather than retail. The data model supports this with a price tier on the customer record and an optional trade price per product — so one catalogue serves both audiences without being duplicated.
- **Repeat / "your usual" orders.** A saved regular order that can be re-placed in one tap — and, optionally, a standing order that repeats automatically against each delivery run. For Jon's commercial base this is the single biggest time-saver: a weekly phone call becomes a tap.
- **Ordering on account.** Rather than paying per delivery, commercial clients can order on account and be invoiced (for example, monthly). The order flow simply skips the payment step; billing is handled separately.
- **A trade-appropriate tone.** The website speaks to both audiences — warm and approachable for domestic customers, with a clear "trade / wholesale" path for commercial clients that leads with reliability, consistent supply and trade pricing.

Because the exact commercial arrangements still need confirming with Jon (section 6), the build is designed to **flex**: trade pricing and repeat orders are built in from the start, but can be simplified down if his commercial clients turn out to order much like domestic ones.

---

## 3. Build phases

### Phase 1 — Foundation + customer website
The visible win, and the data foundation underneath it.

- Supabase project, schema and RLS policies (section 4).
- Public website: who JG Foods is, the hygiene/reviews credibility, and a **"this week's availability"** page driven live from the product catalogue. Fully responsive — works on phone, tablet and desktop.
- Online order form: pick products, pick a delivery slot (Mon or Thu), enter contact and address details, submit.
- Order confirmation email to the customer and a notification to Jon (EmailJS).
- A minimal admin order list so Jon can see website orders coming in from day one.

*Outcome:* a customer can order online without messaging Jon, and Jon can see the order.

### Phase 2 — Jon's order-management app + finance
The real time-saver — and Jon's operational hub.

- Login for Jon (admin role).
- **Delivery-run views:** a Monday list and a Thursday list — every order for that run, grouped and ready to pack.
- Order statuses: pending → confirmed → packed → delivered (and cancelled).
- Customer records: history, usual orders, domestic vs commercial, notes.
- **Weekly availability control:** Jon toggles products on/off and edits prices for the week.
- **Manual order entry:** key in a Facebook/phone order in seconds, tagged by channel.
- Delivery-slot management: open/close slots, set capacity and cut-off times.
- **Finance dashboard:** revenue at a glance — this week, month to date, all time.
- **Invoice generation:** every delivered order creates a record. One click generates a branded PDF invoice (trade) or receipt (domestic). Jon reviews and sends by email or WhatsApp directly from the app — no separate tool needed.
- **Paid / unpaid tracking:** outstanding invoices highlighted, overdue ones flagged red. AI-drafted chasing messages for overdue accounts.
- **Monthly statements:** trade clients can receive a consolidated monthly statement in one click.

*Outcome:* Jon stops collating orders by hand. The two runs assemble themselves. He knows exactly who owes him money.

### Phase 3 — AI + efficiency layer
Once orders are flowing and there's history to work with.

- Auto-generated picking lists and delivery run sheets.
- Customer communication drafts (order confirmed, out for delivery, delivery reminder).
- Weekly Facebook/Instagram post drafting from the live product list.
- Demand forecasting — how much to buy in for the coming week based on order history.
- Paste-to-parse: Jon pastes a Messenger thread or Facebook comment string; AI extracts a structured order for him to confirm.

*Outcome:* the weekly admin shrinks to a review-and-send.

### Phase 4 — Online payments + growth tools
When the business is ready for the next level.

- **Stripe payment integration:** domestic customers can optionally pay online at checkout rather than on delivery. Trade clients remain on account/invoice. A single config flag enables this — no rebuild.
- **Customer loyalty programme:** accumulated spend unlocks a discount tier. Rewards regular domestic customers and encourages repeat orders without discounting by default.
- **Referral scheme:** a shareable referral link for customers. Every successful referral earns both parties a discount on their next order.
- **Promotional codes and seasonal bundles:** Jon can create a promo code (e.g. "SUMMER10") and attach it to a specific product or order total. Bundles can be built from existing products and given their own landing-page entry.
- **Email / SMS marketing to the customer list:** opt-in marketing emails (product announcements, seasonal specials, back-in-stock alerts) sent directly from the app. SMS is the simpler, higher-open-rate option for this audience.
- **New area expansion tools:** Jon adds a new postcode zone, assigns it a delivery day, and the website's order form validates against it. No code change.

*Outcome:* JG Foods starts acquiring customers automatically, not just serving the existing base.

### Phase 5 — Scale: second driver + route intelligence
When demand justifies expanding the operation.

- **Second driver management:** a second Supabase user with a `driver` role. Jon assigns postcode zones and/or individual orders to each driver. Each driver sees only their assigned run, not the full order list or customer database.
- **Route optimisation:** integrate Google Maps Directions API to sort the delivery run by optimal road order. Produces a sequenced run sheet for each driver, cutting time and fuel on every round.
- **Multi-driver picking lists:** when two drivers run simultaneously, the picking list is split — Driver 1's pack vs Driver 2's pack — so preparation at the start of the day is clear.
- **Wholesale / new client types:** adds a `wholesale` tier for shops, delis and farm shops ordering larger quantities at cost-plus pricing. Different order form, different invoice layout, same underlying system.
- **Progressive Web App (PWA):** the customer website is upgraded to installable on a phone's home screen, with offline browsing of the current week's availability. No app store required.

*Outcome:* Jon can run twice the volume with another person, without the coordination becoming unmanageable.

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
| `is_active` | Soft delete |

Customers can **optionally** register an account (see section 6). When they do, `user_id` links their customer record to an auth user; guest customers simply have no `user_id`. Either way it's the same row Jon manages — an account just lets the customer sign back in to reorder and see their order history.

### `delivery_slots` — the spine
This is the JG Foods-specific table and the reusable bit for any scheduled-delivery business.

| Column | Notes |
|---|---|
| `id`, `created_at`, `updated_at` | Standard |
| `delivery_date` | The actual date |
| `day_label` | 'Monday' / 'Thursday' — for display |
| `capacity` | Max orders for that run (Jon's "only a few slots left") |
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
| `payment_method` | **[CONFIRM]** — see section 6 |
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

`invoice_items` mirrors `order_items` — product name snapshot, unit price, quantity, line total. Linked to the parent `invoices` row and optionally to the source `order_id` so there's a full audit trail from order placed → invoice sent → paid.

### `standing_orders` — repeat commercial orders (Phase 2)
A saved order that repeats on a cadence. Each week, a Supabase edge function drafts a new `order` from this template and surfaces it for Jon to confirm or adjust before it goes live on the run.

| Column | Notes |
|---|---|
| `customer_id` | FK → customers |
| `cadence` | 'monday', 'thursday', 'both' |
| `items` | JSONB snapshot of the usual order lines |
| `is_active` | Jon can pause without deleting |
| `last_generated_at` | Prevents duplicate generation |

### `delivery_temps` — temperature log (compliance)

Environmental health compliance: Jon logs the temperature of goods at each customer delivery using a digital gauge in the van. This screen must be usable on his phone while doing the round.

**Key design decision:** when a delivery run is created or confirmed, the system auto-populates a temp log for that date — one row per customer on the run, in run order. Jon opens "Today's Temp Log" on his phone and sees exactly the customers he's visiting, ready to tap in a °C reading as he goes. No hunting for dates, no manual list-building.

| Column | Notes |
|---|---|
| `id`, `created_at` | Standard |
| `delivery_slot_id` | FK → delivery_slots — links the log to the specific run |
| `customer_id` | FK → customers — auto-populated from the run's order list |
| `customer_name` | Snapshot — in case customer record changes |
| `logged_at` | Timestamp when Jon entered the reading |
| `temp_celsius` | `NUMERIC(4,1)` — typically −1 to 3°C |
| `notes` | Optional flag (e.g. "van door open longer than usual") |

The monthly compliance export (printed and filed for environmental health) pulls directly from this table — one grid of customer × delivery date, matching Jon's existing spreadsheet format exactly.

Auto-population trigger: when a `delivery_slot` is confirmed (or on a schedule the night before), a Supabase edge function inserts a `delivery_temps` row for each customer with an order on that slot. Jon never has to build the list himself.

### `drivers` — second driver (Phase 5)
| Column | Notes |
|---|---|
| `id`, `created_at` | Standard |
| `user_id` | FK → auth.users (driver has their own login) |
| `name`, `phone` | |
| `assigned_zones` | Array of postcode prefixes (e.g. ['L39', 'L40', 'PR8']) |
| `is_active` | |

### Commercial clients — schema notes

The commercial path is mostly carried by columns already shown above: `customers.price_tier` selects retail or trade pricing, `customers.billing` selects pay-per-delivery or on-account, and `products.trade_price` holds the trade rate.

Phase 1 can launch domestic-first with the full schema in place, so switching the commercial and financial paths on fully later needs no migration.

### RLS policies needed

JG Foods isn't the usual "users see their own rows" app. It's a **public storefront writing into an admin-managed system**. That changes the RLS shape:

- **`products`, `delivery_slots`** — public read (the website needs them, no login). Admin-only write.
- **`orders`, `order_items`, `customers`** — admin-only read and update by default; the public must **not** be able to read other people's orders. **Account customers** additionally get a "read your own" policy matched on `customers.user_id = auth.uid()`, so a signed-in customer sees only their own record and order history.
- **Order submission** — the public needs to *create* an order without being able to *read* the orders table. Don't solve this by opening up table-level anon insert. Instead, expose **one `place_order` Postgres function** (`SECURITY DEFINER`, callable by the anon role) that:
  1. takes the cart, customer details and chosen slot;
  2. checks the slot is still open and under capacity, and the cut-off hasn't passed;
  3. creates the customer (or matches an existing one by email/phone), the order and the items, atomically;
  4. returns just a confirmation reference.

This keeps every table locked to admin while still letting the website place orders. It's also the natural seam for slot-capacity enforcement and, later, payment. **This `place_order` RPC pattern is reusable for every storefront-style template** (section 7).

Triggers: standard `updated_at`; recalculate `orders.total_amount` when items change; increment/decrement `delivery_slots.orders_count` when an order is placed or cancelled.

---

## 5. AI opportunities

Concrete, time-saving uses — not AI for its own sake. Most belong in Phase 3, but the data model in Phase 1 should not block them.

**Picking & run sheets (highest value).** From a delivery run, auto-generate two things: a **picking list** — every product totalled across all orders, so Jon knows to pack 14 BBQ packs and 40kg of chicken — and a **delivery run sheet** — a per-customer card with address, items and notes, ordered sensibly by postcode for the afternoon round.

**Customer communication drafts.** "Order confirmed", "out for delivery this afternoon", "this week's availability is up" — drafted in Jon's friendly voice for him to glance at and send. Keeps the personal feel without the typing.

**Weekly social post drafting.** Turn the current week's available products into a ready-to-post Facebook/Instagram update in the style Jon already uses ("Hi Everyone 👋 ..."). One of the most repetitive jobs he does now.

**Paste-to-parse social orders.** Jon pastes a Messenger thread or a string of Facebook comments; the AI extracts structured line items and pre-fills a manual order for him to confirm. This is the cleanest way to honour the "accommodate social media" requirement — and it's highly reusable.

**Demand forecasting.** Once there's order history, predict how much of each product to buy in for the coming week, factoring in things like the bank-holiday BBQ spikes already visible in Jon's posts.

---

## 6. Decisions to confirm with Jon

These shape Phase 1 and shouldn't be guessed:

1. **Payment.** Take payment online (Stripe) or pay-on-delivery (cash/card at the door)? *Recommendation: pay-on-delivery for launch* — it matches how Jon works now, removes a barrier to ordering, and avoids card fees and refund admin. Online payment can be a later phase.
2. **Customer accounts.** *Decision: offer both.* Guest checkout stays the default and the fast path — nobody is forced to register. Customers can optionally create an account to save their details, reorder in one tap and see their order history. Worth confirming with Jon how hard to nudge accounts (e.g. a gentle "save these details for next time?" after a guest order).
3. **Delivery area.** Which postcodes does Jon cover? A postcode check on the order form prevents orders he can't fulfil. Need the list.
4. **Delivery days & cut-offs.** Confirm it's always Monday and Thursday afternoons, and the exact cut-off time for each run.
5. **How commercial clients actually work.** Since commercial is a big part of the business, this needs detail: Do pubs/restaurants/shops pay trade prices? Do they place repeat or standing orders? Do they want to order on account and be invoiced monthly, or pay per delivery? The answers decide how much of the commercial path (section 2) is built in Phase 1 versus Phase 2.
6. **Minimum order value**, if any.
7. **Full product list with current prices**, so the catalogue starts accurate.

---

---

## 7. Financial management — detail

Jon currently has no real financial overview of the business. Invoices are ad hoc. There is no easy way to know what he's owed. The finance module in Phase 2 solves this without requiring Jon to understand accounting software.

### Invoice generation
Every time an order is marked as delivered, the system creates a draft invoice or receipt automatically. Jon opens it, checks it, and presses **Send** — the customer receives a branded PDF by email. For WhatsApp (Jon's natural channel), the app provides a one-tap link that opens WhatsApp with the invoice pre-attached.

Invoice PDF layout includes: JG Foods branding, Jon's contact details, customer address, itemised order with quantities and prices, delivery date, total, payment terms (on-account: net 7 or net 14), and a payment reference number. Domestic receipts are simpler: a confirmation that payment was received.

### Payment tracking
Jon taps **Mark as paid** when a trade client settles. The invoice status updates instantly. Overdue invoices (past their due date, unpaid) appear in a highlighted alert panel on the finance dashboard so Jon can see at a glance who owes him money.

### AI chasing
When an invoice is overdue, the app offers a **Chase** button that drafts a polite but firm message to the customer in Jon's natural tone — ready to send by email or WhatsApp. Jon reviews, edits if needed, and sends. No typing from scratch.

### Monthly statements
Trade clients on account can receive a consolidated statement at end of month — one document showing all deliveries, any payments made, and the balance outstanding. One click per client, or bulk-send to all active trade accounts simultaneously.

### Stripe (Phase 4)
The payment model at launch is pay-on-delivery. Stripe is designed in but not switched on. When Jon is ready, enabling it requires one config flag — the checkout form already has the Stripe.js embed commented in. This means domestic customers can optionally pay online when the time comes, without a redesign.

### Export
The invoices table and payment records export to CSV at any time for Jon's accountant, or for importing into accounting software (Xero, QuickBooks, FreeAgent). No bookkeeper needs to chase Jon for a spreadsheet.

---

## 8. Growth strategy

The app and website are not just tools for running today's business — they are a growth engine if we build them right. The following are concrete, realistic opportunities for JG Foods, ordered by ease of implementation.

### 8.1 Make the website do the selling (SEO + content)

Jon's Facebook page reaches people who already know JG Foods. The website reaches people who don't yet. To do that, it needs to rank in search results for terms like *"meat delivery Ormskirk"*, *"mobile butcher West Lancashire"*, *"fresh meat box delivery Liverpool"*.

- **Google Business Profile integration:** structured data (schema markup) on the website makes JG Foods appear in Google Maps results and the local business panel. Customers searching "butcher near me" can find Jon without visiting Facebook. This is free and impactful.
- **Content / blog:** short, useful articles ("How to cook bavette steak", "What's in a family meat pack", "BBQ prep guide for 20 people") drive organic search traffic and establish Jon as the local expert. The app can draft these using the same AI that writes the weekly Facebook post.
- **SEO-optimised trade landing page:** a dedicated page targeting pub and restaurant buyers ("fresh meat supplier for pubs and restaurants in West Lancashire") — Jon's competition on this term is weak. A well-structured page with trade pricing and a contact form will surface in commercial catering searches.

### 8.2 Convert existing customers into recurring revenue

Jon's delivery list is the most valuable asset he has. The app turns it into a retention engine:

- **Domestic standing orders (subscription model):** a customer can choose to repeat their order every Monday or every Thursday automatically. They receive a confirmation email each week with the option to modify or skip before the cut-off. This smooths Jon's demand forecasting and guarantees a baseline of orders each week.
- **Account notifications:** when this week's availability goes live, registered customers get an email/SMS alert with a link directly to the order form. First-movers fill the slots; urgency is genuine.
- **"Your usual" prompt at checkout:** returning customers see a one-tap "reorder last time" option. The friction of choosing again disappears.

### 8.3 Grow the customer base through referrals

A referral programme requires zero marketing spend:

- Every customer gets a unique referral link (auto-generated, stored against their record).
- When a new customer places their first order using that link, both the referrer and the new customer get a credit (e.g. £5 off) on their next order.
- The app dashboard shows Jon how many referrals are active and the revenue they've generated.

This is how Jon's personal, relationship-driven approach scales without him making more cold calls.

### 8.4 Grow trade revenue

Commercial clients represent larger order values and higher loyalty. The system helps Jon win more of them:

- **Trade enquiry form:** a specific form on the trade landing page captures a lead — business name, type of establishment, rough weekly requirements, and best contact. Jon receives a notification and can respond with a trade quote. Leads are stored in the customer database even before the first order.
- **Standing orders for commercial clients:** once a pub or restaurant is set up, the standing order feature means Jon doesn't have to chase them and they don't have to remember. The order arrives automatically. Churn for this segment will be near zero.
- **Referral between trade clients:** encourage a satisfied pub kitchen to recommend JG Foods to nearby establishments. The same referral mechanism works here.

### 8.5 New delivery areas

As demand grows, Jon may want to expand his delivery zone. The system supports this cleanly:

- Add new postcode prefixes to the `delivery_slots` zone config.
- The order form validates against the updated list automatically.
- A new Thursday run could cover a different area from the existing Thursday run — each run is a row in `delivery_slots` with its own zone assignment.
- When a second driver is on board (Phase 5), their zone is separate from Jon's — the app handles the split without confusion.

### 8.6 Seasonal and occasion-based revenue

Butchers have natural seasonal peaks. The system can exploit them:

- **Christmas in advance:** pre-orders for Christmas turkeys and hampers open months early, with a separate order flow and full payment required upfront (first use of Stripe, low risk). Builds working capital in advance.
- **BBQ season bundle deals:** Jon creates a seasonal product (e.g. "BBQ Blowout Pack — limited supply") that appears on the site for a fixed period, with a countdown. Scarcity is real because Jon controls stock.
- **Valentine's / Father's Day / summer steak promotions:** a dated promo code unlocks a discount on a specific product for 48 hours. Jon sets it up in two minutes; the app handles the rest.

---

## 9. Reusable template notes (AXRIK)

This is the first build for **AXRIK** — Phil's web app venture — so what's generic gets flagged for reuse:

- **The whole shape** — public catalogue + slot-based ordering + admin app — is a **"scheduled-delivery business" template**. It drops onto bakers, farm shops, veg-box rounds, milk rounds, mobile fishmongers, mobile grocers — any route-based business with fixed delivery days. JG Foods is template #1.
- **`delivery_slots`** is the reusable heart. Most order systems assume "deliver whenever"; scheduled-delivery businesses don't. This table plus the cut-off/capacity logic is the niche-specific asset that justifies the AXRIK rate.
- **The finance module** — auto-invoicing, paid/unpaid tracking, monthly statements — is reusable for any service or delivery business that bills after fulfilment. It's a selling point in itself.
- **The `place_order` RPC** — public can write an order, public cannot read the orders table — is a reusable security pattern for any storefront-style app.
- **The `channel` field + paste-to-parse tool** — absorbing orders from social media rather than fighting them — will be true for nearly every small business Phil targets. Worth building well once.
- **The second-driver model** (Phase 5) is reusable for any service with multiple mobile workers — cleaners, mobile mechanics, dog groomers, farm deliveries.
- **The growth tools** (referral, standing orders, SEO content, seasonal promos) are almost entirely reusable across niches with minimal copy changes.
- Keep JG Foods-specific copy, branding and product categories in clearly separated config so cloning for client #2 is a content swap, not a code rewrite.

---

## 10. Decisions still to confirm with Jon

0. **How Jon currently manages orders.** We don't know what system, if any, he already uses — spreadsheet, an app, Facebook tools, something else. Understanding this shapes how we position what we're replacing or improving, and may surface requirements we haven't thought of. Ask before assuming it's all manual.

1. **Payment.** Confirmed: pay-on-delivery at launch. Stripe enabled in Phase 4 when Jon is ready.
2. **Customer accounts.** Offer both guest and account checkout. Confirm how hard to nudge account creation after a guest order.
3. **Delivery postcodes.** Need the full list Jon currently covers to build the postcode validation.
4. **Delivery days and cut-offs.** Confirm Monday and Thursday afternoons and the exact cut-off time.
5. **Commercial arrangements.** Trade pricing, standing orders, on-account billing — confirm the specifics with Jon's actual commercial clients in mind.
6. **Minimum order value**, if any.
7. **Full product list with current prices.**
8. **Invoice payment terms.** Net 7, net 14, or end of month for trade accounts?
9. **Email address for sending invoices.** Will Jon send from a JG Foods branded address or his personal Gmail?

---

## 11. Suggested next steps

1. **Pitch meeting with Jon (w/c 25 May):** walk through the prototype, confirm the scope, agree on pricing.
2. **If green-lit:** answers to section 10 in a 15-minute call. Start with the Supabase schema (tables, RLS, triggers, `place_order` RPC) — the foundation everything else sits on.
3. **Phase 1 build:** public website + order form. Goal: a real customer can place a real order within 4 weeks of green-light.
4. **Phase 2 build:** Jon's admin app — delivery runs, weekly availability, finance dashboard, invoice generation.
5. **Post-launch review:** gather real usage data, then prioritise Phase 3 (AI) vs Phase 4 (payments + growth tools) based on what Jon actually needs most.
