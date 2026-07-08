// ============================================================
// Netlify Function: trade-alert
// JG Foods — emails Jon the moment a trade account is requested
// ============================================================
// The website calls this right after a trade signup so Jon never
// misses a potential customer. It does NOT trust anything in the
// request beyond the customer id: it looks the record up in Supabase
// with the service key and only sends if that customer really is a
// trade account still waiting for approval. So the worst a prankster
// could do is re-send Jon an alert about a genuine pending signup.
//
// Uses the same env vars as daily-summary (set on the ADMIN site):
//   RESEND_API_KEY, SUMMARY_FROM, SUMMARY_TO, SUPABASE_SERVICE_ROLE_KEY
// The website calls this function on the admin site's URL because
// that's where the keys live.
// ============================================================

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://hnkidhqjsitrqhsxghjd.supabase.co';
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY;
const RESEND_KEY   = process.env.RESEND_API_KEY;
const TO_EMAIL     = process.env.SUMMARY_TO   || 'jongreen347@gmail.com';
const FROM_EMAIL   = process.env.SUMMARY_FROM || 'JG Foods <onboarding@resend.dev>';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

const esc = s => String(s == null ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

exports.handler = async (event) => {
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: CORS, body: '' };
  if (event.httpMethod !== 'POST')    return json(405, { error: 'Method not allowed' });
  if (!SERVICE_KEY || !RESEND_KEY)    return json(200, { skipped: 'Not configured on this site' });

  let customerId = '';
  try { customerId = (JSON.parse(event.body || '{}').customer_id || '').trim(); } catch (e) {}
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(customerId)) {
    return json(400, { error: 'Bad customer id' });
  }

  // Look the record up ourselves — only alert for a REAL pending trade signup
  const url = `${SUPABASE_URL}/rest/v1/customers?id=eq.${customerId}` +
    `&customer_type=eq.trade&trade_status=eq.pending` +
    `&select=name,business_name,phone,email,address_line_1,postcode,notes`;
  const r = await fetch(url, { headers: { apikey: SERVICE_KEY, authorization: `Bearer ${SERVICE_KEY}` } });
  if (!r.ok) return json(502, { error: 'Lookup failed' });
  const rows = await r.json();
  if (!rows.length) return json(200, { skipped: 'No matching pending trade customer' });

  const c = rows[0];
  const biz = c.business_name || c.name || 'New trade customer';

  const html = `
  <div style="font-family:Segoe UI,Arial,sans-serif;max-width:560px;margin:0 auto;background:#f7f3ea;padding:22px">
    <div style="background:#0d1726;border-radius:10px;padding:18px 22px;margin-bottom:16px">
      <h1 style="color:#fff;font-size:19px;margin:0">🤝 New trade account request</h1>
      <p style="color:#e0bd72;font-size:13px;margin:6px 0 0">${esc(biz)}</p>
    </div>
    <table style="width:100%;border-collapse:collapse;background:#fff;border:1px solid #e8e2d6;border-radius:8px">
      ${[['Business', biz], ['Contact', c.notes && /^Contact:/.test(c.notes) ? c.notes.replace(/^Contact:\s*/, '').split('\n')[0] : c.name],
         ['Phone', c.phone], ['Email', c.email],
         ['Address', [c.address_line_1, c.postcode].filter(Boolean).join(', ')]]
        .filter(([, v]) => v)
        .map(([k, v]) => `
        <tr>
          <td style="padding:10px 12px;border-bottom:1px solid #e8e2d6;font-size:12px;color:#8a7f6f;width:90px">${k}</td>
          <td style="padding:10px 12px;border-bottom:1px solid #e8e2d6;font-size:13px;color:#262019;font-weight:600">${esc(v)}</td>
        </tr>`).join('')}
    </table>
    <p style="font-size:13px;color:#5c5343;line-height:1.6;margin-top:16px">
      They've created a trade login on the website and are waiting for your approval.<br>
      <b>To approve:</b> open your admin app → <b>Customers</b> → tap them at the top of the list → <b>✓ Approve trade access</b>.
      Then give them a ring to sort their pricing.
    </p>
    <p style="font-size:11px;color:#8a7f6f;margin-top:18px">Sent automatically by your JG Foods admin system.</p>
  </div>`;

  const send = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${RESEND_KEY}` },
    body: JSON.stringify({
      from: FROM_EMAIL,
      to: [TO_EMAIL],
      subject: `🤝 New trade account request — ${biz}`,
      html,
    }),
  });
  if (!send.ok) return json(502, { error: 'Send failed' });
  return json(200, { sent: true });
};

function json(status, body) {
  return { statusCode: status, headers: { 'Content-Type': 'application/json', ...CORS }, body: JSON.stringify(body) };
}
