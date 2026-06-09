// ============================================================
// JG Foods Admin — Pie Supplier Cut-off Alert
// ============================================================
// Checks whether any trade customer orders contain pie items
// for the next applicable delivery day, and whether Jon is
// approaching the 12pm cut-off to place his supplier order.
//
// Drops a banner into any element with id="pie-alert-container".
// Call initPieAlert() on page load for any page that shows orders.
// ============================================================

async function initPieAlert() {
  const container = document.getElementById('pie-alert-container');
  if (!container) return;

  const alert = await buildPieAlert();
  if (alert) {
    container.innerHTML = alert;
  }
}

async function buildPieAlert() {
  const now = new Date();
  const today = now.getDay(); // 0=Sun, 1=Mon, ... 5=Fri, 6=Sat

  // Work out the next delivery day and whether the pie cut-off applies today
  const { deliveryDate, cutoffToday, minutesUntilCutoff } = getNextPieCutoff(now);
  if (!cutoffToday) return null; // no alert needed today

  // Fetch pending pie order items for that delivery date
  const pieItems = await getPieItemsForDelivery(deliveryDate);
  if (!pieItems || pieItems.length === 0) return null; // no pie orders, no alert needed

  // Aggregate by product name
  const totals = {};
  for (const item of pieItems) {
    const name = item.product_name;
    totals[name] = (totals[name] || 0) + Number(item.quantity);
  }

  const urgency = minutesUntilCutoff < 60 ? 'urgent' : 'warning';
  const timeLabel = minutesUntilCutoff < 60
    ? `⚠️ Less than ${minutesUntilCutoff} minutes until cut-off!`
    : `Cut-off at 12pm — ${Math.floor(minutesUntilCutoff / 60)}h ${minutesUntilCutoff % 60}m away`;

  const deliveryLabel = formatDate(deliveryDate);

  const rows = Object.entries(totals)
    .map(([name, qty]) => `<tr><td>${name}</td><td><strong>${qty}</strong></td></tr>`)
    .join('');

  return `
    <div class="pie-alert pie-alert--${urgency}" style="
      background: ${urgency === 'urgent' ? '#fff3cd' : '#e8f4fd'};
      border-left: 4px solid ${urgency === 'urgent' ? '#ffc107' : '#2196F3'};
      border-radius: 6px;
      padding: 14px 18px;
      margin-bottom: 20px;
      font-family: inherit;
    ">
      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;">
        <strong style="font-size:15px;">🥧 Pie supplier order needed — ${deliveryLabel} delivery</strong>
        <span style="font-size:13px; color:#666;">${timeLabel}</span>
      </div>
      <p style="margin:0 0 10px; font-size:13px; color:#444;">
        Place this order with your pie supplier before <strong>12pm today</strong>.
      </p>
      <table style="border-collapse:collapse; font-size:13px; width:auto;">
        <thead>
          <tr style="border-bottom:1px solid #ccc;">
            <th style="text-align:left; padding:4px 16px 4px 0; color:#666; font-weight:500;">Product</th>
            <th style="text-align:left; padding:4px 16px 4px 0; color:#666; font-weight:500;">Total Qty</th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
      </table>
      <button onclick="dismissPieAlert()" style="
        margin-top:10px; padding:6px 14px; font-size:12px;
        background:transparent; border:1px solid #aaa; border-radius:4px;
        cursor:pointer; color:#555;
      ">Dismiss</button>
    </div>
  `;
}

// ---- Cut-off logic ----

function getNextPieCutoff(now) {
  const day = now.getDay();   // 0=Sun ... 6=Sat
  const hour = now.getHours();
  const minute = now.getMinutes();
  const cutoffHour = 12;

  // Delivery days for trade: Mon(1), Tue(2), Thu(4), Fri(5)
  // Pies need to be ordered the day before delivery.
  // Special case: Friday cut-off covers Monday delivery.

  // Is today a day when Jon needs to order pies?
  // i.e. today+1 is a trade delivery day (or today=Fri, Monday delivery)
  const orderDays = {
    0: null,  // Sun — no delivery tomorrow (Mon is domestic, not trade... actually Mon IS trade)
    // Actually Mon is a trade delivery day, so Sun should trigger. But Jon won't be checking Sun.
    // Let's cover: Fri→Mon, Mon→Tue, Wed→Thu, Thu→Fri
    1: 2,   // Mon: order for Tuesday delivery
    3: 4,   // Wed: order for Thursday delivery
    4: 5,   // Thu: order for Friday delivery
    5: 1,   // Fri: order for Monday delivery (next week)
  };

  const deliveryDayOfWeek = orderDays[day];
  if (deliveryDayOfWeek === undefined || deliveryDayOfWeek === null) {
    return { cutoffToday: false };
  }

  // Already past cut-off today?
  const minutesUntilCutoff = (cutoffHour * 60) - (hour * 60 + minute);
  if (minutesUntilCutoff <= 0) {
    return { cutoffToday: false }; // too late, cut-off passed
  }

  // Calculate the delivery date
  const deliveryDate = new Date(now);
  const daysAhead = day === 5
    ? (1 + 7 - 5) % 7 || 3  // Friday → next Monday = 3 days ahead
    : 1;
  deliveryDate.setDate(deliveryDate.getDate() + daysAhead);

  return { deliveryDate, cutoffToday: true, minutesUntilCutoff };
}

// ---- Supabase query ----

async function getPieItemsForDelivery(deliveryDate) {
  const dateStr = deliveryDate.toISOString().split('T')[0];

  const { data, error } = await supabase
    .from('order_items')
    .select(`
      product_name,
      quantity,
      orders!inner(delivery_date, status),
      products!inner(supplier_type)
    `)
    .eq('orders.delivery_date', dateStr)
    .eq('products.supplier_type', 'pie')
    .in('orders.status', ['pending', 'confirmed']);

  if (error) {
    console.error('Pie alert query failed:', error.message);
    return [];
  }
  return data || [];
}

// ---- Helpers ----

function formatDate(date) {
  return date.toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'short' });
}

function dismissPieAlert() {
  const el = document.querySelector('.pie-alert');
  if (el) el.remove();
}

// ---- Auto-init ----
document.addEventListener('DOMContentLoaded', initPieAlert);
