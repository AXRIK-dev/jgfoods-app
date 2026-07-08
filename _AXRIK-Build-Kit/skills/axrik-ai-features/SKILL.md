---
name: axrik-ai-features
description: Drop-in AI feature patterns for AXRIK web-app builds — a single Claude proxy Netlify function plus reusable feature recipes (parse a messy order from a pasted message, draft/redraft customer messages, generate social posts, summarise data). Use when adding any AI feature to an AXRIK client app, when Phil mentions AI order parsing, message drafting, social post generation, demand summaries, or "save the client time with AI", or when wiring the Anthropic API into a Supabase/Netlify app. Always pairs each AI feature with a non-AI fallback.
---

# AXRIK AI Features

AXRIK's pitch includes AI that saves the client time. JG Foods shipped three live AI features through **one** Netlify function. Reuse that architecture rather than rebuilding per feature.

## The architecture: one proxy, many features

Never call the Anthropic API from the browser (the key would leak). All AI goes through one generic Netlify function — `starter-kit/netlify-functions/ai.js` — that takes `{ system, prompt, max_tokens }` and returns `{ text }`. Every feature is just a different `system` + `prompt` built on the client side.

Model default: `claude-haiku-4-5-20251001` — cheap and fast, fine for these tasks. Bump the model only for genuinely hard reasoning.

## Non-negotiable: every AI feature has a fallback

`ai.js` returns `503/502 { fallback: true }` when the key is missing or the call fails. The front-end must catch that and use a built-in non-AI path (a template, a manual form). **The client must never see a broken button** because an API key wasn't set or a request timed out. This is what makes AI safe to ship to a non-technical client.

```js
async function callAI(system, prompt, max_tokens = 600) {
  try {
    const r = await fetch('/.netlify/functions/ai', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ system, prompt, max_tokens }),
    });
    const data = await r.json();
    if (!r.ok || data.fallback || !data.text) return null; // -> caller uses fallback
    return data.text;
  } catch { return null; }
}
```

## Reusable feature recipes

**1. Parse a messy order from a pasted message.** The client pastes a Facebook/WhatsApp/text order; AI returns structured line items to pre-fill the Log Order form. System prompt: "You extract a delivery order from a casual customer message. Return JSON lines of {product_name, quantity, unit}. If unsure, leave it out." Fallback: empty form for manual entry. This directly attacks the "client is the order system" problem.

**2. Draft / redraft a customer message.** VIP message, apology, "your usual is ready" nudge. System prompt sets the client's tone (warm, personal, UK English). Fallback: a fixed template with merge fields.

**3. Generate a social post.** Feed rough notes + this week's availability + a few of the client's recent posts (as voice examples — instruct "match the voice, do not copy"). Returns one post for Facebook/Instagram. Fallback: a template generator that slots availability into a fixed structure.

**4. Summarise / forecast.** Weekly order summary, "what to prep this week", demand hints from recent orders. Read-only, low-risk; always show the underlying numbers too so the client can sanity-check.

## Guardrails

- Cap input lengths server-side (already done in `ai.js`) to control cost and abuse.
- Keep the client in control: AI **drafts**, the client confirms before anything is sent or saved.
- For voice-matching, pass the client's own recent posts as examples and explicitly forbid copying them.
- Log failures server-side (`console.error`) but degrade quietly client-side.

## Setup per client

Add `ANTHROPIC_API_KEY` to the Netlify site's environment variables and a little credit on the Anthropic console. If it's not set, every feature silently uses its fallback — so the app works from day one and AI "switches on" when the key lands.
