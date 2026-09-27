// SPDX-License-Identifier: GPL-3.0-or-later
/* REPIX WITHOUT THE NETWORK. Installed from the site, the program must open
   with no connection too: the page, its description and its icons are kept
   here. What is kept is shown at once; meanwhile a fresh copy is fetched, so
   an update comes with the next opening — never a wait at the start. */
const KEPT = 'repix';
const FILES = ['./', 'manifest.webmanifest',
               'icon-192.png', 'icon-512.png', 'icon-maskable.png', 'icon-apple.png'];

/* ONE KEY PER FILE. A link with a tail (…/repix/?from=chat) and the page's
   own name (index.html) are the same page: they are kept and looked up under
   one key, or an old copy stored under another name would be served for good
   while the updates were written past it. */
const keyOf = url => {
  const u = new URL(url);
  u.search = ''; u.hash = '';
  if (u.pathname.endsWith('/index.html')) u.pathname = u.pathname.slice(0, -'index.html'.length);
  return u.href;
};
const kept = new Set(FILES.map(f => keyOf(new URL(f, self.registration.scope))));

self.addEventListener('install', e => {
  e.waitUntil(caches.open(KEPT).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});
// What an earlier version kept under other keys is thrown out: it is never
// served again and would only take room.
self.addEventListener('activate', e => {
  e.waitUntil(caches.open(KEPT)
    .then(c => c.keys().then(ks => Promise.all(ks.filter(r => !kept.has(r.url)).map(r => c.delete(r)))))
    .then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const key = keyOf(req.url);
  if (!kept.has(key)) return;                    // only the site's own files
  const fresh = fetch(req).then(r => {
    // The fresh copy is written before the worker may rest: the waiting
    // covers the writing, not just the answer.
    const saved = r.ok ? caches.open(KEPT).then(c => c.put(key, r.clone())) : Promise.resolve();
    return saved.then(() => r);
  });
  e.respondWith(caches.open(KEPT).then(c => c.match(key)).then(k => k || fresh));
  e.waitUntil(fresh.catch(() => {}));
});
