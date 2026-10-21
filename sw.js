// VerifiCrédito · service worker: permite abrir la app sin señal.
// Los datos (Supabase) NO pasan por aquí: la app los guarda en el teléfono y envía los cambios al volver la conexión.
const V = 'verificredito-v3';
const CDN = /^(cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com|fonts\.googleapis\.com|fonts\.gstatic\.com|unpkg\.com)$/;

self.addEventListener('install', e => {
  e.waitUntil(caches.open(V).then(c => c.addAll(['./', './index.html', './manifest.json', './icon-192.png', './icon-512.png', 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2']).catch(() => {})));
  self.skipWaiting();
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
const conLimite = (p, ms) => Promise.race([p, new Promise((_, ko) => setTimeout(() => ko(new Error('timeout')), ms))]);

self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const u = new URL(r.url);
  if (u.hostname.endsWith('supabase.co') || u.hostname.endsWith('supabase.in')) return;   // datos en vivo
  if (u.searchParams.has('vc')) return;   // revisión de versión nueva: siempre directo a la red
  // La app (index.html y archivos propios): red primero, con límite de 5 s; si falla, la copia guardada
  if (r.mode === 'navigate' || u.origin === location.origin){
    // la app siempre se revalida con el servidor (no usa la copia vieja del navegador)
    const req = r.mode === 'navigate' ? new Request(r.url, { cache: 'no-cache', credentials: 'same-origin' }) : r;
    e.respondWith(conLimite(fetch(req), 5000).then(res => {
      if (res.ok) { const cp = res.clone(); caches.open(V).then(c => c.put(r.mode === 'navigate' ? './index.html' : r, cp)); }
      return res;
    }).catch(() => caches.match(r.mode === 'navigate' ? './index.html' : r).then(x => x || caches.match('./index.html'))));
    return;
  }
  // Librerías y tipografías: copia guardada primero y se actualiza en segundo plano
  if (CDN.test(u.hostname)){
    e.respondWith(caches.open(V).then(c => c.match(r).then(hit => {
      const red = fetch(r).then(res => { if (res.ok || res.type === 'opaque') c.put(r, res.clone()); return res; }).catch(() => hit);
      return hit || red;
    })));
    return;
  }
  // Mapas (OpenStreetMap): guarda las zonas ya vistas
  if (u.hostname.endsWith('tile.openstreetmap.org')){
    e.respondWith(caches.open(V + '-mapa').then(c => c.match(r).then(hit => hit || fetch(r).then(res => { c.put(r, res.clone()); return res; }).catch(() => hit))));
  }
});

// Notificaciones push: llegan aunque la app esté cerrada
self.addEventListener('push', e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch(_) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'VerifyCredit', {
    body: d.body || '', tag: d.tag || 'vc', renotify: true, icon: 'icon-192.png', badge: 'icon-192.png', data: { id: d.id || null } }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const id = e.notification.data && e.notification.data.id;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(cs => {
    const c = cs.find(x => x.focused) || cs[0];
    if (c){ if (id) c.postMessage({ abrir: id }); return c.focus(); }
    return self.clients.openWindow('./' + (id ? '?sol=' + id : ''));
  }));
});
