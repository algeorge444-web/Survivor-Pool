// Survivor Pool service worker.
// Lets Android phones install the site as an app. It deliberately caches
// nothing, so players always get the latest picks, scores and standings.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
