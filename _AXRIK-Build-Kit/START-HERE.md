# START HERE — How to use the AXRIK Build Kit

You did the hard part once (JG Foods). This kit means you never do that part again. There are two stages: **set it up once**, then **a short checklist each new client**.

---

## STAGE 1 — One-time setup (do this once, ~15 min)

### 1. Install the three skills
In the `install-skills/` folder there are three files ending in `.skill`. When I present them in chat, each has a **Save skill** button — click it. Or go to **Settings → Capabilities → add skill** and pick each file:

- `axrik-project-kickoff.skill` — the build workflow
- `axrik-ai-features.skill` — AI features + fallbacks
- `axrik-deliverables.skill` — all the client paperwork

Once installed, they trigger automatically. From then on, just say *"new AXRIK client"* and the workflow kicks in — you don't have to remember any of this.

### 2. Fold the Supabase additions into your existing skill
Open `skills/supabase-patterns-ADDENDUM.md`, copy it into your existing **supabase-patterns** skill (Settings → Capabilities → edit). That's the day-one RLS, trigger fixes and self-service-users patterns.

### 3. Park the starter-kit repo where you can clone it
The `starter-kit/` folder is now a git repo. Push it to GitHub as a **template repo** so you can clone it per client:

```bash
cd "<wherever you keep the kit>/starter-kit"
git remote add origin git@github-axrik:AXRIK-dev/axrik-starter-kit.git
git push -u origin main
```
Then on GitHub: repo **Settings → Template repository → tick it**.

### 4. Move the whole kit out of the JG Foods folder
Right now `_AXRIK-Build-Kit/` lives inside the JG Foods project. Move it to your shared **AXRIK** folder so it's not tied to one client.

---

## STAGE 2 — Each new client (the actual time-saver)

You barely touch the kit directly — you tell me, and the installed skills do the steering. The flow:

### 1. Kick off (discovery first)
In a new project for the client, say:

> **New AXRIK client: [name], a [type of business] in [location].** Here are their order messages / spreadsheets / invoice format [attach them]. Follow the kickoff workflow — propose the data model first, then the build phases. Don't write screens until I've confirmed the schema.

(That's prompt #1 in `prompts/AXRIK-Prompt-Library.md`. The kickoff skill does the rest.)

### 2. Clone the backend
```bash
# create the new repo from the template, then:
git clone git@github-axrik:AXRIK-dev/[client]-app.git
cp config.example.js config.js   # add the client's Supabase URL + anon key + branding
```
Tell me the client's delivery days, order channels, whether they invoice — I customise the three SQL files (the `>>>` markers), you run them in Supabase `001 → 002 → 003`, then run the "promote owner to admin" snippet.

### 3. Build on the shells
The `website/` and `admin/` shells already do auth, the role gate, the live catalogue and ordering. You build features by saying *"add a [feature] page to the admin"* — prompt #4. AI features come last, each with a fallback — prompt #5.

### 4. Go live + hand over
> **[Client] is ready for go-live.** Produce the go-live checklist, the testing worksheet, and refresh the build summary.

(Prompt #7. The deliverables skill produces all of it in AXRIK navy/gold, in your voice.)

### 5. End every session with the hygiene sweep
> Before we finish: any leftover placeholders, any table missing RLS, any AI button without a fallback, what's still stubbed?

(Prompt #9 — this kills the "fix" commits that ate time on JG Foods.)

---

## The one-line version

**Set up once:** install 3 skills, fold in the Supabase addendum, push the starter kit as a GitHub template.
**Each client:** say "new AXRIK client", confirm the schema, clone the template, build on the shells, hand over from templates. Target: ~15–18h instead of 35.

Everything referenced here is in this folder: `starter-kit/` (the code), `skills/` (sources) + `install-skills/` (the clickable installs), `prompts/AXRIK-Prompt-Library.md`, and `AXRIK-Build-Efficiency-Playbook.html` (the why).
