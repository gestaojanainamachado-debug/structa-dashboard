const CACHE = 'structa-v16';
const ASSETS = [
  '/',
  '/index.html',
  '/Inter-VariableFont_opsz,wght.ttf',
  '/Inter-Italic-VariableFont_opsz,wght.ttf',
  '/icon-192.png',
  '/icon-512.png',
  '/apple-touch-icon.png',
  'https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.min.js'
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  // Cache-first para assets locais, network-first para navegação
  const url = new URL(e.request.url);
  const isLocal = url.origin === self.location.origin;
  const isNavigate = e.request.mode === 'navigate';

  if (isNavigate) {
    e.respondWith(
      fetch(e.request).catch(() => caches.match('/index.html'))
    );
    return;
  }

  if (isLocal || url.hostname === 'cdnjs.cloudflare.com') {
    e.respondWith(
      caches.match(e.request).then(cached => {
        if (cached) return cached;
        return fetch(e.request).then(res => {
          if (res.ok) {
            const clone = res.clone();
            caches.open(CACHE).then(c => c.put(e.request, clone));
          }
          return res;
        });
      })
    );
  }
});
