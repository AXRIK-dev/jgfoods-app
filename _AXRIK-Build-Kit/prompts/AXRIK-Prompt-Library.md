# AXRIK Prompt Library

Copy-paste prompts for the recurring moments in an AXRIK build. They assume the project folder is set up with the skills installed (`axrik-project-kickoff`, `axrik-ai-features`, `axrik-deliverables`, `supabase-patterns`) and the starter kit cloned. Replace `[CLIENT]` and the bracketed bits.

---

## 1. New project kickoff

> New AXRIK client: **[CLIENT]**, a [type of business] in [location]. Here are their current order messages / spreadsheets / invoice format [attach]. Following the `axrik-project-kickoff` workflow, propose the data model first (start from the starter kit and tell me what to customise), then the build phases. Don't write screens yet — confirm the schema with me first.

## 2. Stand up the backend

> Clone the starter-kit migrations for **[CLIENT]**. Customise the `>>>`-marked CHECK constraints: delivery days are [days], order channels are [channels], reference prefix [XX]. [Keep / drop] invoicing. Give me the final `001`/`002`/`003` SQL ready to run, the run order, and the exact "promote owner to admin" snippet with [owner email].

## 3. Customer website

> Build the **[CLIENT]** customer website as a single responsive HTML file in their branding [colours/logo]. Lead with the business problem and outcomes, not tech. Sections: hero, about, how it works, product showcase pulled live from Supabase `products`, trade/wholesale path, contact form (EmailJS). Wire the order form to the `place_order` RPC with the slot picker.

## 4. Admin app screen

> Add a **[feature]** page to the **[CLIENT]** admin app, following the existing `showPage()` shell. It should render from a single live Supabase fetch on open, respect the admin/staff RLS roles, and read any config from `app_settings`. Match the look of the existing pages. Also add a matching entry to the in-admin HELP_PAGES guide.

## 5. Add an AI feature

> Add an AI **[order-parse / message-redraft / social-post / summary]** feature to **[CLIENT]**, following `axrik-ai-features`. Route it through the existing `/.netlify/functions/ai` proxy, and build a non-AI fallback so the button always works if the key is missing. Keep the client in control — AI drafts, they confirm before send/save.

## 6. Update the build summary (matches the project rule)

> Update build summary: [what was done this session].
> (This replaces the build summary in place AND posts to the AXRIK portal via the portal-update script — same filenames, never numbered versions.)

## 7. Go-live + handover pack

> **[CLIENT]** is ready for go-live. Following `axrik-deliverables`, produce: the go-live checklist (DNS, Supabase auth invite + admin promotion, storage buckets, Netlify env vars, EmailJS IDs, data cleanup, smoke tests), a client-runnable testing worksheet, and refresh the build summary. AXRIK navy/gold branding, first-person as me, UK English.

## 8. Client update email

> Draft a short update email to **[CLIENT]** about [what's new]. First person as me, warm, UK English, lead with the outcome, flag anything I need from them, end with what's next. No jargon.

## 9. End-of-session hygiene (avoid the JG Foods "fix" commits)

> Before we finish: scan the build for leftover placeholders or stale integration notes (e.g. unconfigured providers), confirm every table has RLS, confirm every AI feature has a fallback, and list anything still stubbed so it doesn't surprise me next session.
