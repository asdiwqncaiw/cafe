// Сервис-воркер «Склад кафе», версия 4.
// Сайт всегда берётся из сети с проверкой свежести (cache: 'no-cache'),
// поэтому после выкладки на GitHub Pages телефоны сразу получают новый код.
// Копия в кэше нужна только, когда интернета нет совсем.
// Данные из базы (Supabase) сюда не попадают, только сам сайт.
const CACHE = 'cafe-shell-v62';
const SHELL = ['./', 'index.html', 'config.js', 'manifest.webmanifest', 'icon-192.png', 'icon-512.png'];

self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(
    caches.open(CACHE).then(c => Promise.all(
      SHELL.map(u => c.add(new Request(u, {cache: 'reload'})).catch(() => {}))
    ))
  );
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('message', e => {
  if (e.data === 'skipWaiting') self.skipWaiting();
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const u = new URL(req.url);
  // Библиотека Supabase с jsDelivr: адрес с номером версии не меняется, берём из кэша.
  if (u.hostname === 'cdn.jsdelivr.net') { e.respondWith(cacheFirst(req)); return; }
  // Supabase и всё чужое не трогаем.
  if (u.origin !== location.origin) return;
  e.respondWith(networkFirst(req));
});

// Ответ после переадресации нельзя отдавать на переход по странице (Safari ругается), пересобираем его.
async function clean(res){
  if (!res.redirected) return res;
  const body = await res.blob();
  return new Response(body, {status: res.status, statusText: res.statusText, headers: res.headers});
}

async function networkFirst(req){
  const cache = await caches.open(CACHE);
  const nav = req.mode === 'navigate';
  try{
    let res = nav
      ? await fetch(req.url, {cache: 'no-cache', credentials: 'same-origin'})
      : await fetch(req, {cache: 'no-cache'});
    if (nav) res = await clean(res);
    if (res && res.ok && res.type === 'basic') cache.put(req, res.clone()).catch(() => {});
    return res;
  }catch(err){
    const hit = await cache.match(req, {ignoreSearch: true});
    if (hit) return hit;
    if (nav) return (await cache.match('./')) || (await cache.match('index.html')) || Response.error();
    return Response.error();
  }
}

async function cacheFirst(req){
  const cache = await caches.open(CACHE);
  const hit = await cache.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  if (res && (res.ok || res.type === 'opaque')) cache.put(req, res.clone()).catch(() => {});
  return res;
}
