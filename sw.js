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
