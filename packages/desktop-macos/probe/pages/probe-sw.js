// The worker service-worker.html registers. It takes control at once and
// answers one path itself, so the page can tell a fetch that went through it.
self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('fetch', (event) => {
  if (new URL(event.request.url).pathname.endsWith('/sw-echo')) {
    event.respondWith(new Response('from the service worker'));
  }
});
