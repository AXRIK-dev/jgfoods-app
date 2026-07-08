// ============================================================
// Netlify Scheduled Function: daily-summary
// JG Foods — emails Jon a summary of the day's orders after 5pm
// ============================================================
// Runs on the cron set in netlify.toml (16:05 + 17:05 UTC) and only
// sends when it's 5pm in the UK — that keeps it at 5pm year-round
// through the BST/GMT switch.
//
// Email covers every order placed TODAY (any channel — website,
// phone, social, logged by Jon): who ordered, domestic or trade,
// what they ordered, the amount, and the delivery day.
//
// SETUP (one-off, on the Netlify site that hosts these functions —
// set these on ONE site only or Jon gets the email twice):
//   RESEND_API_KEY   = key from resend.com (free tier is plenty)
//   SUMMARY_TO       = where to send it   (default jongreen347@gmail.com)
//   SUMMARY_FROM     = verified sender    (default onboarding@resend.dev —
//                      swap to summary@jgfoodsnorthwest.com once the domain
//                      is verified in Resend)
//   SUPABASE_SERVICE_ROLE_KEY = already set for manage-users
//
// No npm deps — native fetch (Netlify Node 18+).
// ============================================================

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://hnkidhqjsitrqhsxghjd.supabase.co';
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY;
const RESEND_KEY   = process.env.RESEND_API_KEY;
const TO_EMAIL     = process.env.SUMMARY_TO   || 'jongreen347@gmail.com';
const FROM_EMAIL   = process.env.SUMMARY_FROM || 'JG Foods <onboarding@resend.dev>';

// ── UK-local date/time helpers ──────────────────────────────
function ukParts(d = new Date()) {
  const fmt = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London',
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', hour12: false,
  });
  const p = {};
  fmt.formatToParts(d).forEach(x => { p[x.type] = x.value; });
  return { date: `${p.year}-${p.month}-${p.day}`, hour: parseInt(p.hour, 10) };
}

const gbp = n => '£' + (Number(n) || 0).toFixed(2);
const esc = s => String(s == null ? '' : s)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function prettyDay(dateStr, dayLabel) {
  if (!dateStr) return dayLabel || '—';
  const d = new Date(dateStr + 'T12:00:00');
  return `${dayLabel || d.toLocaleDateString('en-GB', { weekday: 'long' })} ${d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' })}`;
}

exports.handler = async (event) => {
  if (!SERVICE_KEY) return json(503, { error: 'Missing SUPABASE_SERVICE_ROLE_KEY' });
  if (!RESEND_KEY)  return json(200, { skipped: 'RESEND_API_KEY not set on this site' });

  // Only send at 5pm UK time (cron fires at 16:05 + 17:05 UTC; exactly one
  // of those is 17:xx in Europe/London, whatever the season). A manual test
  // call with ?force=1 skips the check.
  const force = event?.queryStringParameters?.force === '1';
  const { date: today, hour } = ukParts();
  if (!force && hour !== 17) return json(200, { skipped: `UK hour is ${hour}, not 17` });

  // ── Everything ordered today (created today, UK time) ──────
  // Orders are stored in UTC; UK midnight today in UTC is close enough to
  // query from `${today}T00:00:00` — worst case around the clock change a
  // pre-1am order shifts a day, which is fine for a daily digest.
  const select = 'id,total_amount,status,channel,notes,created_at,' +
    'customers(name,customer_type,phone),' +
    'delivery_slots(delivery_date,day_label),' +
    'order_items(product_name,quantity,unit_price)';
  const url = `${SUPABASE_URL}/rest/v1/orders?select=${encodeURIComponent(select)}` +
    `&created_at=gte.${today}T00:00:00Z&order=created_at.asc`;

  const r = await fetch(url, { headers: { apikey: SERVICE_KEY, authorization: `Bearer ${SERVICE_KEY}` } });
  if (!r.ok) return json(502, { error: 'Supabase query failed: ' + (await r.text()) });
  const orders = (await r.json()).filter(o => o.status !== 'cancelled');

  // Trade signups still waiting for approval — belt-and-braces reminder
  // (Jon also gets an instant email when each one signs up)
  let pendingTrade = [];
  try {
    const pr = await fetch(
      `${SUPABASE_URL}/rest/v1/customers?customer_type=eq.trade&trade_status=eq.pending&select=name,phone`,
      { headers: { apikey: SERVICE_KEY, authorization: `Bearer ${SERVICE_KEY}` } });
    if (pr.ok) pendingTrade = await pr.json();
  } catch (e) {}

  const isTrade = o => ['trade', 'commercial'].includes(o.customers?.customer_type);
  const domestic = orders.filter(o => !isTrade(o));
  const trade    = orders.filter(isTrade);

  const dateNice = new Date().toLocaleDateString('en-GB', {
    timeZone: 'Europe/London', weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
  });

  const orderRow = (o) => {
    const items = (o.order_items || [])
      .map(i => `${esc(i.product_name)} ×${i.quantity}`).join(', ') || 'No items';
    const unpriced = (o.order_items || []).some(i => !(parseFloat(i.unit_price) > 0));
    const amount = isTrade(o) && unpriced
      ? '<b style="color:#b06000">TBC — price up</b>'
      : `<b>${gbp(o.total_amount)}</b>`;
    return `
      <tr>
        <td style="padding:9px 10px;border-bottom:1px solid #e8e2d6;font-size:13px">
          <b>${esc(o.customers?.name || 'Unknown')}</b>
          <span style="color:#8a7f6f;font-size:11px"> · ${esc(o.channel || '')}</span><br>
          <span style="color:#5c5343;font-size:12px">${items}</span>
          ${o.notes ? `<br><span style="color:#8a7f6f;font-size:11px">📝 ${esc(o.notes)}</span>` : ''}
        </td>
        <td style="padding:9px 10px;border-bottom:1px solid #e8e2d6;font-size:13px;white-space:nowrap;text-align:right;vertical-align:top">
          ${amount}<br>
          <span style="color:#5c5343;font-size:11.5px">🚚 ${esc(prettyDay(o.delivery_slots?.delivery_date, o.delivery_slots?.day_label))}</span>
        </td>
      </tr>`;
  };

  const section = (title, list) => !list.length ? '' : `
    <h3 style="font-size:13px;letter-spacing:1px;text-transform:uppercase;color:#16273f;margin:22px 0 6px">${title} (${list.length})</h3>
    <table style="width:100%;border-collapse:collapse;background:#fff;border:1px solid #e8e2d6;border-radius:8px">
      ${list.map(orderRow).join('')}
    </table>`;

  const pricedTotal = orders.reduce((s, o) => s + (parseFloat(o.total_amount) || 0), 0);

  const html = `
  <div style="font-family:Segoe UI,Arial,sans-serif;max-width:620px;margin:0 auto;background:#f7f3ea;padding:22px">
    <div style="background:#0d1726;border-radius:10px;padding:18px 22px;margin-bottom:16px">
      <h1 style="color:#fff;font-size:20px;margin:0">JG Foods — Daily order summary</h1>
      <p style="color:#e0bd72;font-size:13px;margin:6px 0 0">${dateNice}</p>
    </div>
    ${pendingTrade.length ? `
    <div style="background:#fdf3e3;border:1px solid #fcd299;border-radius:8px;padding:12px 15px;margin-bottom:14px;font-size:13px;color:#b06000">
      🤝 <b>${pendingTrade.length === 1 ? 'A trade account is' : pendingTrade.length + ' trade accounts are'} still waiting for your approval:</b>
      ${pendingTrade.map(p => esc(p.name) + (p.phone ? ' (' + esc(p.phone) + ')' : '')).join(', ')}.
      Open your admin app → Customers to approve ${pendingTrade.length === 1 ? 'them' : 'each one'}.
    </div>` : ''}
    ${orders.length === 0
      ? `<p style="font-size:14px;color:#5c5343">No orders came in today.</p>`
      : `
    <table style="width:100%;border-collapse:collapse;margin-bottom:4px">
      <tr>
        <td style="background:#fff;border:1px solid #e8e2d6;border-radius:8px;padding:12px;text-align:center;font-size:13px">
          <b style="font-size:19px;color:#16273f">${orders.length}</b><br>orders today</td>
        <td style="width:8px"></td>
        <td style="background:#fff;border:1px solid #e8e2d6;border-radius:8px;padding:12px;text-align:center;font-size:13px">
          <b style="font-size:19px;color:#16273f">${gbp(pricedTotal)}</b><br>order value*</td>
        <td style="width:8px"></td>
        <td style="background:#fff;border:1px solid #e8e2d6;border-radius:8px;padding:12px;text-align:center;font-size:13px">
          <b style="font-size:19px;color:#16273f">${domestic.length} / ${trade.length}</b><br>domestic / trade</td>
      </tr>
    </table>
    <p style="font-size:10.5px;color:#8a7f6f;margin:4px 0 0">*Trade orders waiting on agreed prices count as £0 until you price them up.</p>
    ${section('🏠 Domestic orders', domestic)}
    ${section('🤝 Trade orders', trade)}
    `}
    <p style="font-size:11px;color:#8a7f6f;margin-top:20px">Sent automatically at 5pm each day by your JG Foods admin system.</p>
  </div>`;

  const send = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${RESEND_KEY}` },
    body: JSON.stringify({
      from: FROM_EMAIL,
      to: [TO_EMAIL],
      subject: `📦 ${orders.length} order${orders.length === 1 ? '' : 's'} today (${gbp(pricedTotal)}) — JG Foods daily summary`,
      html,
    }),
  });
  if (!send.ok) return json(502, { error: 'Resend send failed: ' + (await send.text()) });

  return json(200, { sent: true, orders: orders.length });
};

function json(status, body) {
  return { statusCode: status, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
}
