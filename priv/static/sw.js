// Minimal service worker: makes the app installable and keeps the shell
// (CSS, JS, icons) available offline. Pages and the LiveView socket always go
// to the network so savings data is never stale or cached.
const CACHE = "w52-static-v3";
const OFFLINE = new Response(
  "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Offline</title>" +
  "<body style='font:16px system-ui;display:grid;place-content:center;height:100vh;text-align:center;padding:24px'>" +
  "<h1>You're offline</h1><p>Reconnect to see your savings. Nothing has been lost.</p>",
  { headers: { "Content-Type": "text/html; charset=utf-8" } }
);

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  const url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== location.origin) return;

  if (req.mode === "navigate") {
    e.respondWith(fetch(req).catch(() => OFFLINE.clone()));
    return;
  }
  if (/^\/(assets|icons|vendor)\//.test(url.pathname)) {
    e.respondWith(
      fetch(req)
        .then((res) => { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); return res; })
        .catch(() => caches.match(req))
    );
  }
});

// Web Push: show the notification the server sent, open the app when tapped.
self.addEventListener("push", (e) => {
  let data = {};
  try { data = e.data ? e.data.json() : {}; } catch (_) { data = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil(
    self.registration.showNotification(data.title || "Time to save", {
      body: data.body || "",
      icon: "/icons/icon-192.png",
      badge: "/icons/icon-192.png",
      tag: data.tag || "savings",
      data: { url: data.url || "/" }
    })
  );
});

self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "/";
  e.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      for (const c of list) { if ("focus" in c) { c.navigate(url); return c.focus(); } }
      return clients.openWindow(url);
    })
  );
});
