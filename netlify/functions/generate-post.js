// ============================================================
// Netlify Function: generate-post
// JG Foods Admin — AI social post generator
// ============================================================
// Proxies a request to the Anthropic API so the API key never
// touches the browser. Takes Jon's rough notes + this week's
// availability + a few recent posts (style examples) + his house
// style, and returns one clean post for Facebook & Instagram.
//
// Lives at the repo root under netlify/functions/ because the admin
// Netlify site uses base directory "/" with functions directory
// "netlify/functions". Served at /.netlify/functions/generate-post.
//
// SETUP (one-off):
//   1. Anthropic console → create an API key (+ a little credit).
//   2. Netlify → the ADMIN site → Site configuration → Environment
//      variables → add  ANTHROPIC_API_KEY = <your key>.
//   3. Trigger deploy.
// If the key is missing the function returns 503 and the admin
// quietly falls back to its built-in template generator.
//
// No npm dependencies — uses native fetch (Netlify Node 18+).
// ============================================================

const MODEL = 'claude-haiku-4-5-20251001';

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return json(405, { error: 'Method not allowed' });
  }

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    // Not configured yet — tell the client to use its fallback.
    return json(503, { error: 'AI not configured', fallback: true });
  }

  let body;
  try { body = JSON.parse(event.body || '{}'); }
  catch { return json(400, { error: 'Invalid JSON' }); }

  const notes       = (body.notes || '').toString().slice(0, 2000);
  const availability = (body.availability || '').toString().slice(0, 2000);
  const examples    = Array.isArray(body.examples) ? body.examples.slice(0, 5) : [];
  const style       = body.style || {};

  const exampleBlock = examples.length
    ? `\n\nHere are a few of Jon's recent posts — match this voice and rhythm (do NOT copy them):\n\n${examples.map((e, i) => `--- Example ${i + 1} ---\n${e}`).join('\n\n')}`
    : '';

  const system = [
    `You write social media posts for JG Foods, a mobile butcher delivering fresh meat to homes and food businesses around North Liverpool, Ormskirk and West Lancashire, run by Jon Green.`,
    `Write ONE post that works for both Facebook and Instagram. Warm, friendly, local, down-to-earth — never corporate or salesy. Use UK English.`,
    `Use light, tasteful emojis. Keep it scannable with short lines. End with the call-to-action line and sign-off exactly as given, then the hashtags.`,
    `Output ONLY the finished post text — no preamble, no explanation, no quotation marks around it.`,
    style.channels ? `Call-to-action line to include near the end: ${style.channels}` : '',
    style.signoff  ? `Sign-off: ${style.signoff}` : '',
    style.hashtags ? `Hashtags to end with: ${style.hashtags}` : '',
  ].filter(Boolean).join('\n');

  const userMsg = [
    `Jon's notes for this post:\n${notes || '(no notes — write a general "diary is open this week" post)'}`,
    availability ? `\nThis week's availability to weave in (use these exact names and prices):\n${availability}` : '',
    exampleBlock,
  ].join('\n');

  try {
    const resp = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 700,
        system,
        messages: [{ role: 'user', content: userMsg }],
      }),
    });

    if (!resp.ok) {
      const detail = await resp.text();
      console.error('Anthropic API error', resp.status, detail);
      return json(502, { error: 'AI request failed', fallback: true });
    }

    const data = await resp.json();
    const text = (data.content || [])
      .filter(b => b.type === 'text')
      .map(b => b.text)
      .join('')
      .trim();

    if (!text) return json(502, { error: 'Empty AI response', fallback: true });
    return json(200, { post: text });
  } catch (err) {
    console.error('generate-post error', err);
    return json(502, { error: 'AI request failed', fallback: true });
  }
};

function json(statusCode, obj) {
  return {
    statusCode,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(obj),
  };
}
