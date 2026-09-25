const CACHE_NAME = 'outreach-v234';
const ASSETS = [
  './',
  './index.html',
  './manifest.json',
  'https://fonts.googleapis.com/css2?family=Cinzel:wght@400;700;900&family=Great+Vibes&family=Playfair+Display:ital,wght@0,400;0,700;1,400&family=Lato:wght@300;400;700&display=swap'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE_NAME).then(c => c.addAll(ASSETS)));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  // Never cache API requests
  if (e.request.url.includes('script.google.com')) return;

  // Network-first for HTML
  if (e.request.mode === 'navigate' || e.request.url.endsWith('.html')) {
    // The app is one page: every ?venue=ID deep link shares the index.html entry,
    // and other pages (reports) are keyed without their query string
    const url = new URL(e.request.url);
    const scope = new URL(self.registration.scope);
    const isShell = url.origin === scope.origin &&
      (url.pathname === scope.pathname || url.pathname === scope.pathname + 'index.html');
    const key = isShell ? scope.pathname + 'index.html' : url.origin + url.pathname;
    e.respondWith(
      fetch(e.request).then(resp => {
        // Only cache real pages: never a 404/500, and never a redirected response
        // (browsers refuse to serve those for a later navigation)
        if (resp.ok && resp.type === 'basic' && !resp.redirected) {
          const clone = resp.clone();
          caches.open(CACHE_NAME).then(c => c.put(key, clone));
        }
        return resp;
      }).catch(() => caches.match(key, { ignoreSearch: true }))
    );
    return;
  }

  // Cache-first for static assets
  e.respondWith(
    caches.match(e.request).then(cached => cached || fetch(e.request))
  );
});
