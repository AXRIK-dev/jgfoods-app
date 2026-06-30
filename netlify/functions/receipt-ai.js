// ============================================================
// Netlify Function: receipt-ai
// JG Foods Admin — read a receipt photo into expense fields
// ============================================================
// Send { image_base64, media_type } and get back structured fields
// { payee, entry_date, amount, vat_amount, category, kind } so the
// Expenses form pre-fills itself from a photo. The Anthropic key
// never touches the browser. Always editable; the admin keeps a
// plain manual entry path when this isn't available.
//
// Missing key → 503 { fallback:true } so the admin quietly falls
// back to manual entry. No npm dependencies (native fetch).
// ============================================================

const MODEL = 'claude-haiku-4-5-20251001';

const SYSTEM = `You read a photo of a UK purchase receipt or invoice for a mobile butcher business and extract its key details. Reply with ONLY a JSON object, no prose, using exactly these keys:
{"payee": string, "entry_date": "YYYY-MM-DD" or "", "amount": number, "vat_amount": number, "category": string, "kind": "purchase" or "expense"}
Rules:
- payee: the shop/supplier name at the top of the receipt.
- entry_date: the receipt date in YYYY-MM-DD; "" if you cannot read it.
- amount: the GROSS total paid (a number, no currency symbol).
- vat_amount: the VAT shown; 0 if none shown.
- kind: "purchase" if it's stock/food for resale (a butcher/wholesaler/food supplier), otherwise "expense".
- category: a short label, e.g. Stock, Fuel, Van, Packaging, Insurance, Stationery, Other.
If the image is not a readable receipt, return all fields empty/zero.`;

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') return json(405, { error: 'Method not allowed' });

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) return json(503, { error: 'AI not configured', fallback: true });

  let body;
  try { body = JSON.parse(event.body || '{}'); }
  catch { return json(400, { error: 'Invalid JSON' }); }

  const image = (body.image_base64 || '').toString();
  const mediaType = (body.media_type || 'image/jpeg').toString();
  if (!image) return json(400, { error: 'Missing image' });

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
        max_tokens: 400,
        system: SYSTEM,
        messages: [{
          role: 'user',
          content: [
            { type: 'image', source: { type: 'base64', media_type: mediaType, data: image } },
            { type: 'text', text: 'Extract the receipt details as JSON.' },
          ],
        }],
      }),
    });

    if (!resp.ok) {
      const detail = await resp.text();
      console.error('Anthropic API error', resp.status, detail);
      return json(502, { error: 'AI request failed', fallback: true });
    }

    const data = await resp.json();
    const text = (data.content && data.content[0] && data.content[0].text) || '';
    const parsed = safeParse(text);
    if (!parsed) return json(502, { error: 'Could not read receipt', fallback: true });

    return json(200, {
      payee:      typeof parsed.payee === 'string' ? parsed.payee.slice(0, 120) : '',
      entry_date: /^\d{4}-\d{2}-\d{2}$/.test(parsed.entry_date) ? parsed.entry_date : '',
      amount:     toNum(parsed.amount),
      vat_amount: toNum(parsed.vat_amount),
      category:   typeof parsed.category === 'string' ? parsed.category.slice(0, 60) : '',
      kind:       parsed.kind === 'purchase' ? 'purchase' : 'expense',
    });
  } catch (err) {
    console.error('receipt-ai error', err);
    return json(502, { error: 'AI request failed', fallback: true });
  }
};

function safeParse(text) {
  try { return JSON.parse(text); }
  catch {
    const m = text && text.match(/\{[\s\S]*\}/);
    if (m) { try { return JSON.parse(m[0]); } catch { return null; } }
    return null;
  }
}
function toNum(v) { const n = parseFloat(v); return isFinite(n) && n >= 0 ? Math.round(n * 100) / 100 : 0; }
function json(status, obj) {
  return { statusCode: status, headers: { 'content-type': 'application/json' }, body: JSON.stringify(obj) };
}
