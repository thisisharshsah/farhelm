/** The Workers edge cache, or nothing where there is none (some tests). */
export async function edgeCache(name: string): Promise<Cache | null> {
  return typeof caches === "undefined" ? null : caches.open(name);
}

/**
 * A cached answer, as a response the app may still change. The Cache API
 * hands back responses with immutable headers, and middleware (security
 * headers, cache-control) adds headers to every answer: returned as is, a
 * cache hit would fail with a 500.
 */
export async function cachedCopy(cache: Cache | null, key: Request): Promise<Response | null> {
  const hit = await cache?.match(key);
  return hit ? new Response(hit.body, hit) : null;
}
