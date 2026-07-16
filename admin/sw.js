/* JG Foods Admin — service worker (network-first)
 * The installed app always shows the LIVE admin: every request tries the
 * network first, so a new deploy is picked up instantly. A cached copy is
 * only used as a fallback when the device is offline. HTML is never
 * pre-cached, so there is no stale-version trap after a deploy.
 * Bump CACHE to retire the old runtime cache on the next visit.
 */
const CACHE = 'jgadmin-v1';

self.addEventListener('install', () => {
  // Take over straight away rather than waiting for old tabs to close.
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return; // leave POST/PUT etc. to the browser

  event.respondWith(
    fetch(req)
      .then((res) => {
        // Keep a fresh offline fallback of successful same-origin GETs.
        if (res && res.ok && new URL(req.url).origin === self.location.origin) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy));
        }
        return res;
      })
      .catch(() => caches.match(req)) // offline: serve last-seen copy if we have it
  );
});
