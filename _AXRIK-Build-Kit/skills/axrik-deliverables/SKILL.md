---
name: axrik-deliverables
description: The standard set of client-facing and internal documents an AXRIK web-app build produces, with their structure, branding and voice rules. Use when writing any AXRIK project document — pitch, proposal, build plan, build summary, "project by the numbers", testing worksheet, go-live checklist, admin setup guide, or a client update email. Also use when Phil says "build summary", "pitch", "go-live checklist", "handover pack", or "write to the client". Captures the reusable templates so each build's paperwork is fast and consistent.
---

# AXRIK Deliverables

Every AXRIK build produces roughly the same documents. JG Foods (the first build) created and refined them; this skill turns them into reusable templates so the next build's paperwork is near-instant. Each is a single-file HTML or Markdown doc generated into the project folder.

## Branding rules (important)

- **Internal & AXRIK-branded docs** (pitch, build plan, build summary, project-by-the-numbers, testing worksheet, go-live checklist, client update emails) use the **AXRIK** brand — navy (`#0d1726` / `#111f33`) with a gold accent. AXRIK is the author/agency.
- **Client-facing *customer* docs** (anything the client's own customers see — the website, receipts, the in-app help) use the **client's** branding, not AXRIK's.
- Match the hex values to the AXRIK logo file in the project assets; don't guess if the asset is present.

## Voice rules

- Write **as if Phil wrote it himself** — first person ("I've built…", "I'll demo the app"), never third person ("Phil will show you").
- UK English throughout (organise, licence, colour, behaviour).
- **Lead with the business problem and the outcome, not the technology.** "Take ordering off your phone and give you your evenings back" beats "Supabase-backed order pipeline".
- Professional and warm, credible builder — not hobbyist, not corporate-stiff.

## The document set

**Pitch / proposal** (`*-Pitch`). Opens with the client's problem in their own words, then the one-system solution (website + admin), then what they get and why it beats generic SaaS (built for them, near-zero monthly cost). Outcome-led.

**Build plan** (`*-Build-Plan`). Working document. The business problem, the one-system framing, phased build (foundation+website → admin → AI → go-live), data-model notes, and open decisions flagged `[CONFIRM]` for the client.

**Build summary** (`*-Build-Summary`). The running record of what's been built, updated each session. **Always replace the old summary in place — same filename, never numbered versions.** Keep an internal version (AXRIK-branded, full detail) and a client-friendly version.

**Project by the numbers** (`*-By-The-Numbers`). One-page AXRIK marketing artefact: build hours, sessions, features shipped, monthly running cost, and the headline (agency-grade scope delivered in a fraction of the time/cost via an AI-accelerated workflow). Reusable as the AXRIK sales proof for the next prospect.

**Testing worksheet** (`*-Testing-Worksheet`). Plain-English, client-runnable test checklist — every feature, a tick box, space for notes. So the client validates the build without you driving.

**Go-live checklist** (`*-Go-Live-Checklist`). The launch runbook: DNS, Supabase auth invite + admin promotion, storage buckets, Netlify env vars, EmailJS IDs, final data cleanup, smoke tests.

**Admin setup guide** (`*-Setup-Guide` / in-admin help). How the non-technical client runs the app day to day. Mirror it as an in-admin help drawer (the `HELP_PAGES` pattern) and **update it whenever an admin feature changes**.

**Client update email** (`Email-to-Client-<date>`). Short, first-person, outcome-led: what's new this session, anything you need from them, what's next. No jargon.

## How to produce them

Research/gather the real content first (the client's data, what was actually built from git history), then use the `docx`, `pdf` or HTML output skills to render. Don't start from the format skill — start from the facts. Reuse the JG Foods files in `docs/` as structural templates; swap client name, branding, and specifics.
