const CACHE_NAME = "mp3-shelf-v2";
const APP_SHELL = [
  "/",
  "/manifest.webmanifest",
  "/icon-192.png",
  "/icon-512.png",
  "/apple-touch-icon.png",
];

function isCacheable(response) {
  return response && response.ok && response.type !== "opaque";
}

async function cacheResponse(cache, request, response) {
  if (!isCacheable(response)) return;
  try {
    await cache.put(request, response.clone());
  } catch {
    // A full iOS cache must not prevent the network response from being used.
  }
}

async function precacheAppShell() {
  const cache = await caches.open(CACHE_NAME);
  const homeResponse = await fetch("/", { cache: "reload" });

  if (!isCacheable(homeResponse)) throw new Error("Unable to cache the app shell");

  await cache.put("/", homeResponse.clone());
  const html = await homeResponse.text();
  const discoveredAssets = Array.from(
    html.matchAll(/(?:src|href)=["']([^"']+)["']/g),
    (match) => match[1],
  ).filter((url) => url.startsWith("/") && !url.startsWith("//"));

  const urls = [...new Set([...APP_SHELL.slice(1), ...discoveredAssets])];
  await Promise.allSettled(
    urls.map(async (url) => {
      const response = await fetch(url, { cache: "reload" });
      await cacheResponse(cache, url, response);
    }),
  );
}

async function networkFirst(request) {
  const cache = await caches.open(CACHE_NAME);
  try {
    const response = await fetch(request);
    await cacheResponse(cache, request, response);
    return response;
  } catch {
    return (await cache.match(request)) || (await cache.match("/"));
  }
}

async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) return cached;

  const response = await fetch(request);
  const cache = await caches.open(CACHE_NAME);
  await cacheResponse(cache, request, response);
  return response;
}

self.addEventListener("install", (event) => {
  event.waitUntil(precacheAppShell().then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((names) => Promise.all(names.filter((name) => name !== CACHE_NAME).map((name) => caches.delete(name))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET" || request.headers.has("range")) return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin || url.pathname.startsWith("/api/")) return;

  if (request.mode === "navigate") {
    event.respondWith(networkFirst(request));
    return;
  }

  event.respondWith(cacheFirst(request));
});
