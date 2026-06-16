// ============================================================
// Netlify Function: ai
// JG Foods Admin — generic Claude proxy
// ============================================================
// A small, reusable proxy to the Anthropic API so the key never
// touches the browser. Send { system, prompt, max_tokens } and get
// back { text }. Used by the VIP "Redraft with AI" button and the
// "paste a message → extract order" feature. Same key/setup as
// generate-post (ANTHROPIC_API_KEY on the admin Netlify site).
//
// If the key is missing it returns 503 with fallback:true so the
// admin can quietly use its built-in fallback.
//
// No npm dependencies — native fetch (Netlify Node 18+).
// ============================================================

const MODEL = 'claude-haiku-4-5-20251001';

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return json(405, { error: 'Method not allowed' });
  }

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    return json(503, { error: 'AI not configured', fallback: true });
  }

  let body;
  try { body = JSON.parse(event.body || '{}'); }
  catch { return json(400, { error: 'Invalid JSON' }); }

  const system = (body.system || '').toString().slice(0, 4000);
  const prompt = (body.prompt || '').toString().slice(0, 6000);
  const maxTokens = Math.min(Math.max(parseInt(body.max_tokens, 10) || 600, 64), 1500);

  if (!prompt) return json(400, { error: 'Missing prompt' });

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
        max_tokens: maxTokens,
        ...(system ? { system } : {}),
        messages: [{ role: 'user', content: prompt }],
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
    return json(200, { text });
  } catch (err) {
    console.error('ai function error', err);
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
