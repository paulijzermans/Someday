// _shared/place-cache.ts
// =============================================================================
// Shared read/write helpers for the GLOBAL place cache (see the migration
// 20260616120000_add_place_cache.sql for the rationale).
//
// Two tables back this:
//   • place_cache       — one row per place IDENTITY, owner-agnostic, never
//                         deleted when a user deletes their saved copy.
//   • extraction_index  — url → the place_cache keys that URL resolved to, so a
//                         REPEAT import of the same URL skips the paid scrape.
//
// Both are service-role only. These helpers no-op gracefully when the service
// client can't be built (e.g. missing env in a misconfigured deploy) — the
// caller just pays full price, exactly like the availability_cache helper.
// =============================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";

/** Places are stable but not eternal — re-fetch after 90 days. */
const FRESH_DAYS = 90;

/** The place object an Edge Function returns to iOS, plus the extra signals we
 *  need to compute a stable identity. `placeId`/coords are stripped before the
 *  payload is served — they only feed the cache key. */
export interface CacheableItem {
  /** The exact object to return to the client (and replay on a cache hit). */
  payload: Record<string, unknown>;
  name: string;
  category?: string;
  address?: string;
  imageUrl?: string;
  kind?: string;
  latitude?: number;
  longitude?: number;
  /** Google Maps placeId, when the source provides one. */
  placeId?: string;
}

/** Build the service-role client, or null if env is missing. Mirrors the
 *  pattern in find-reservation-platforms / check-availability. */
export function serviceClient(): SupabaseClient | null {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return null;
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** lowercase, ascii-fold-ish, collapse to a hyphen slug. */
function slug(s: string): string {
  return (s ?? "")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")   // strip combining diacritics
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64);
}

/** Per-place identity key. placeId wins; then name+coords; then name+address. */
export function placeCacheKey(item: CacheableItem): string {
  if (item.placeId) return `gmaps:${item.placeId}`;
  if (typeof item.latitude === "number" && typeof item.longitude === "number") {
    return `geo:${slug(item.name)}:${item.latitude.toFixed(4)}:${item.longitude.toFixed(4)}`;
  }
  return `name:${slug(item.name)}:${slug(item.address ?? "")}`;
}

/** Normalise a source URL so trivially-different links share one index row:
 *  drop the fragment, strip tracking params, lowercase the host, no trailing
 *  slash. We intentionally keep the path + meaningful query (Google Maps packs
 *  place data into both). */
export function normalizeUrl(raw: string): string {
  try {
    const u = new URL(raw.trim());
    u.hash = "";
    u.hostname = u.hostname.toLowerCase();
    const drop = ["utm_source", "utm_medium", "utm_campaign", "utm_term",
      "utm_content", "fbclid", "gclid", "igshid", "igsh", "si"];
    for (const p of drop) u.searchParams.delete(p);
    let s = u.toString();
    if (s.endsWith("/")) s = s.slice(0, -1);
    return s;
  } catch {
    return raw.trim();
  }
}

function isFresh(createdAt: string): boolean {
  const ageMs = Date.now() - new Date(createdAt).getTime();
  return ageMs < FRESH_DAYS * 24 * 60 * 60 * 1000;
}

/** Look up a previously-extracted URL. Returns the array of place payloads to
 *  replay, or null on any miss (no index row, stale, or an evicted member —
 *  all of which should fall through to a live fetch). `note` carries through
 *  an empty-but-valid result (e.g. "post has no caption"). */
export async function lookupExtraction(
  supabase: SupabaseClient | null,
  source: string,
  url: string,
): Promise<{ places: Record<string, unknown>[]; note?: string } | null> {
  if (!supabase) return null;
  try {
    const key = normalizeUrl(url);
    const { data: idx, error } = await supabase
      .from("extraction_index")
      .select("place_keys, note, created_at, hit_count")
      .eq("url", key)
      .eq("source", source)
      .maybeSingle();
    if (error) throw error;
    if (!idx || !isFresh(idx.created_at)) return null;

    const keys: string[] = idx.place_keys ?? [];
    let places: Record<string, unknown>[] = [];
    if (keys.length > 0) {
      const { data: rows, error: rowsErr } = await supabase
        .from("place_cache")
        .select("cache_key, payload")
        .in("cache_key", keys);
      if (rowsErr) throw rowsErr;
      // If any member was evicted since we indexed it, treat the whole import
      // as a miss — better to re-scrape than to silently drop places.
      if (!rows || rows.length !== keys.length) return null;
      // Preserve the original order recorded in place_keys.
      const byKey = new Map(rows.map((r) => [r.cache_key, r.payload]));
      places = keys.map((k) => byKey.get(k) as Record<string, unknown>);
    }

    // Fire-and-forget hit-count bump on the index row.
    supabase
      .from("extraction_index")
      .update({ hit_count: (idx.hit_count ?? 0) + 1, updated_at: new Date().toISOString() })
      .eq("url", key)
      .then(() => {}, () => {});

    return { places, note: idx.note ?? undefined };
  } catch (err) {
    console.warn("place-cache lookup failed:", err);
    return null;
  }
}

/** Persist a fresh extraction: upsert each place into the global store, then
 *  record the URL → keys membership. Fire-and-forget for the caller — we never
 *  make the user wait on the cache write, and a hiccup just means the next
 *  import re-pays. */
export async function storeExtraction(
  supabase: SupabaseClient | null,
  source: string,
  url: string,
  items: CacheableItem[],
  note?: string,
): Promise<void> {
  if (!supabase) return;
  try {
    const now = new Date().toISOString();
    const keys: string[] = [];
    const rows = items.map((it) => {
      const key = placeCacheKey(it);
      keys.push(key);
      return {
        cache_key: key,
        place_id: it.placeId ?? null,
        name: it.name,
        category: it.category ?? "food",
        latitude: it.latitude ?? null,
        longitude: it.longitude ?? null,
        address: it.address ?? "",
        image_url: it.imageUrl ?? null,
        source,
        kind: it.kind ?? "venue",
        payload: it.payload,
        updated_at: now,
      };
    });

    if (rows.length > 0) {
      await supabase.from("place_cache").upsert(rows, { onConflict: "cache_key" });
    }
    await supabase.from("extraction_index").upsert({
      url: normalizeUrl(url),
      source,
      place_keys: keys,
      note: note ?? null,
      hit_count: 0,
      updated_at: now,
      created_at: now,
    }, { onConflict: "url" });
  } catch (err) {
    // Non-fatal: the user already has their places; the next importer re-pays.
    console.warn("place-cache store failed:", err);
  }
}
