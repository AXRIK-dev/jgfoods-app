// ============================================================
// Netlify Function: route
// JG Foods Admin — optimised delivery route via Google Routes API
// ============================================================
// Send { origin, destination, addresses:[...] } and get back
// { order:[indices], distanceMeters, durationSeconds } where `order`
// is the optimal visiting order of the addresses (Jon's stops).
//
// The Google key never touches the browser — it lives in the Netlify
// env var GOOGLE_MAPS_API_KEY on the admin site.
//
// If the key is missing/!ok it returns 503 with fallback:true so the
// admin quietly falls back to its own simple ordering.
//
// No npm dependencies — native fetch (Netlify Node 18+).
// ============================================================

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') return json(405, { error: 'Method not allowed' });

  const apiKey = process.env.GOOGLE_MAPS_API_KEY;
  if (!apiKey) return json(503, { error: 'Route optimisation not configured', fallback: true });

  let body;
  try { body = JSON.parse(event.body || '{}'); }
  catch { return json(400, { error: 'Invalid JSON' }); }

  const origin = (body.origin || 'Ormskirk, Lancashire').toString();
  const destination = (body.destination || origin).toString();
  const addresses = Array.isArray(body.addresses)
    ? body.addresses.map(a => (a || '').toString().trim()).filter(Boolean)
    : [];

  // Need at least 2 stops for optimisation to mean anything.
  if (addresses.length < 2) return json(200, { order: addresses.map((_, i) => i), distanceMeters: 0, durationSeconds: 0 });

  try {
    const resp = await fetch('https://routes.googleapis.com/directions/v2:computeRoutes', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': apiKey,
        'X-Goog-FieldMask': 'routes.optimizedIntermediateWaypointIndex,routes.distanceMeters,routes.duration',
      },
      body: JSON.stringify({
        origin: { address: origin },
        destination: { address: destination },
        intermediates: addresses.map(a => ({ address: a })),
        travelMode: 'DRIVE',
        optimizeWaypointOrder: true,
      }),
    });

    if (!resp.ok) {
      const detail = await resp.text();
      console.error('Routes API error', resp.status, detail);
      return json(502, { error: 'Route request failed', fallback: true });
    }

    const data = await resp.json();
    const r = (data.routes || [])[0];
    if (!r) return json(502, { error: 'No route returned', fallback: true });

    const order = Array.isArray(r.optimizedIntermediateWaypointIndex)
      ? r.optimizedIntermediateWaypointIndex
      : addresses.map((_, i) => i);
    const durationSeconds = r.duration ? parseInt(String(r.duration).replace(/[^0-9]/g, ''), 10) || 0 : 0;

    return json(200, { order, distanceMeters: r.distanceMeters || 0, durationSeconds });
  } catch (err) {
    console.error('route function error', err);
    return json(502, { error: 'Route request failed', fallback: true });
  }
};

function json(statusCode, obj) {
  return { statusCode, headers: { 'content-type': 'application/json' }, body: JSON.stringify(obj) };
}
