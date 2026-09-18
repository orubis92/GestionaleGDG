// Service worker GestionaleGDG - network-first per l'app; notifiche push
const CACHE = 'gdg-v1.7.2';
const ASSETS = ['./', './index.html', './manifest.json', './icons/icon-192.png', './icons/icon-512.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET') return;
  if (url.origin !== location.origin) return; // API Supabase e CDN: sempre rete
  e.respondWith(fetch(e.request).then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); return r; }).catch(() => caches.match(e.request).then(r => r || caches.match('./index.html'))));
});

// ---- Notifiche push (Web Push) ----
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { title: 'GestionaleGDG', body: e.data ? e.data.text() : '' }; }
  const title = d.title || 'GestionaleGDG';
  const opts = {
    body: d.body || '',
    icon: './icons/icon-192.png',
    badge: './icons/icon-192.png',
    tag: d.id || undefined,          // stessa notifica aperta su più dispositivi: non si duplica
    data: { url: (d.url || './') + '#n=' + (d.id || ''), id: d.id, dati: d.dati || {} },
    vibrate: [100, 50, 100]
  };
  e.waitUntil(self.registration.showNotification(title, opts));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const target = (e.notification.data && e.notification.data.url) || './';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
    for (const c of list) { if ('focus' in c) { c.navigate ? c.navigate(target) : null; return c.focus(); } }
    return self.clients.openWindow(target);
  }));
});
