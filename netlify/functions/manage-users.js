// ============================================================
// Netlify Function: manage-users
// JG Foods Admin — lets Jon (admin) manage staff logins himself
// ============================================================
// Holds the Supabase SERVICE ROLE key (admin powers) server-side so it
// never touches the browser. Every request must carry the caller's login
// token; the function verifies that caller is an 'admin' before doing
// anything. Drivers/customers can't use it even if they call it directly.
//
// Actions (POST body { action, ... }):
//   list                      -> all logins with their role
//   create  {email,password,role,full_name}
//   setRole {userId, role}
//   resetPassword {userId, password}
//   delete  {userId}
//
// SETUP (one-off): Netlify → the ADMIN site → Site configuration →
// Environment variables → add:
//   SUPABASE_SERVICE_ROLE_KEY = <Supabase → Settings → API → service_role key>
// (SUPABASE_URL defaults to the project URL below; override via env if needed.)
//
// No npm deps — native fetch (Netlify Node 18+).
// ============================================================

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://hnkidhqjsitrqhsxghjd.supabase.co';
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY;

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') return json(405, { error: 'Method not allowed' });
  if (!SERVICE_KEY) return json(503, { error: 'User management not configured (missing service role key).' });

  // 1. Identify the caller from their bearer token
  const auth = event.headers.authorization || event.headers.Authorization || '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  if (!token) return json(401, { error: 'Not signed in' });

  let caller;
  try {
    const r = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SERVICE_KEY, authorization: `Bearer ${token}` },
    });
    if (!r.ok) return json(401, { error: 'Invalid session' });
    caller = await r.json();
  } catch { return json(401, { error: 'Invalid session' }); }

  // 2. Confirm the caller is an admin
  const role = await getRole(caller.id);
  if (role !== 'admin') return json(403, { error: 'Admins only' });

  let body;
  try { body = JSON.parse(event.body || '{}'); }
  catch { return json(400, { error: 'Invalid JSON' }); }

  const action = body.action;
  try {
    if (action === 'list')          return json(200, { users: await listUsers() });
    if (action === 'create')        return json(200, await createUser(body));
    if (action === 'setRole')       return json(200, await setRole(body.userId, body.role));
    if (action === 'resetPassword') return json(200, await adminUpdate(body.userId, { password: body.password }));
    if (action === 'delete') {
      if (body.userId === caller.id) return json(400, { error: "You can't delete your own login." });
      return json(200, await deleteUser(body.userId));
    }
    return json(400, { error: 'Unknown action' });
  } catch (err) {
    console.error('manage-users error', err);
    return json(502, { error: err.message || 'Request failed' });
  }
};

// ── helpers ──────────────────────────────────────────────────
const adminHeaders = { apikey: SERVICE_KEY, authorization: `Bearer ${SERVICE_KEY}`, 'content-type': 'application/json' };

async function getRole(id) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/user_profiles?id=eq.${id}&select=role`, { headers: adminHeaders });
  if (!r.ok) return 'driver';
  const rows = await r.json();
  return (rows[0] && rows[0].role) || 'driver';
}

async function listUsers() {
  // Auth users (paginated; one page of 200 is plenty here)
  const r = await fetch(`${SUPABASE_URL}/auth/v1/admin/users?per_page=200`, { headers: adminHeaders });
  if (!r.ok) throw new Error('Could not list users');
  const data = await r.json();
  const users = data.users || data || [];
  // Roles
  const pr = await fetch(`${SUPABASE_URL}/rest/v1/user_profiles?select=id,role`, { headers: adminHeaders });
  const roles = pr.ok ? await pr.json() : [];
  const roleMap = Object.fromEntries(roles.map(x => [x.id, x.role]));
  return users.map(u => ({ id: u.id, email: u.email, role: roleMap[u.id] || 'driver', created_at: u.created_at }));
}

async function createUser({ email, password, role, full_name }) {
  if (!email || !password) throw new Error('Email and password are required');
  const r = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
    method: 'POST', headers: adminHeaders,
    body: JSON.stringify({ email, password, email_confirm: true, user_metadata: full_name ? { full_name } : {} }),
  });
  const u = await r.json();
  if (!r.ok) throw new Error(u.msg || u.error_description || u.error || 'Could not create user');
  // The signup trigger makes a 'driver' profile; set the chosen role.
  await setRole(u.id, role === 'admin' ? 'admin' : 'driver');
  return { ok: true, id: u.id };
}

async function setRole(userId, role) {
  if (!userId) throw new Error('Missing user');
  const safeRole = role === 'admin' ? 'admin' : 'driver';
  // Upsert the profile row (in case it doesn't exist yet)
  const r = await fetch(`${SUPABASE_URL}/rest/v1/user_profiles?id=eq.${userId}`, {
    method: 'PATCH', headers: { ...adminHeaders, prefer: 'return=representation' },
    body: JSON.stringify({ role: safeRole }),
  });
  if (!r.ok) throw new Error('Could not set role');
  const rows = await r.json();
  if (!rows.length) {
    // No row to patch — insert one
    await fetch(`${SUPABASE_URL}/rest/v1/user_profiles`, {
      method: 'POST', headers: adminHeaders,
      body: JSON.stringify({ id: userId, role: safeRole }),
    });
  }
  return { ok: true };
}

async function adminUpdate(userId, fields) {
  if (!userId) throw new Error('Missing user');
  const r = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${userId}`, {
    method: 'PUT', headers: adminHeaders, body: JSON.stringify(fields),
  });
  if (!r.ok) { const e = await r.json().catch(() => ({})); throw new Error(e.msg || 'Could not update user'); }
  return { ok: true };
}

async function deleteUser(userId) {
  if (!userId) throw new Error('Missing user');
  const r = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${userId}`, { method: 'DELETE', headers: adminHeaders });
  if (!r.ok) throw new Error('Could not delete user');
  return { ok: true };
}

function json(statusCode, obj) {
  return { statusCode, headers: { 'content-type': 'application/json' }, body: JSON.stringify(obj) };
}
