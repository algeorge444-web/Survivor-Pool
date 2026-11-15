// Survivor Pool service worker.
// Lets Android phones install the site as an app. It caches nothing: the page
// itself is always fetched fresh, so players get the newest version right away.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", (e) => {
  if (e.request.mode === "navigate") {
    e.respondWith(fetch(e.request, { cache: "no-store" }).catch(() => fetch(e.request)));
  }
});

// Chat notifications.
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { d = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || "Survivor Pool", {
    body: d.body || "New message in your pool chat",
    icon: "icon-192.png",
    badge: "icon-192.png",
    tag: d.tag || "chat",
    renotify: true,
    data: { url: d.url || "./" },
  }));
});
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || "./";
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of all) {
      if ("focus" in c) { try { await c.navigate(url); } catch {} return c.focus(); }
    }
    return self.clients.openWindow(url);
  })());
});
