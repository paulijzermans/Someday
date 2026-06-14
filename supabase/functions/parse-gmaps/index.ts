// parse-gmaps Edge Function
// =============================================================================
// Takes a Google Maps URL (saved list, single place, or share link) and
// returns the places it contains as structured JSON.
//
// Implementation: calls the Apify "compass/google-maps-extractor" actor,
// which runs a real headless Chrome on Apify's infrastructure, lets Google
// load the list's JS-rendered content, then scrapes structured place data.
// We get back name + address + lat/lon + categories already structured —
// no LLM parsing needed for this path.
//
// Why this lives server-side:
//   1. Apify API token authorizes spending on your account — never in the app.
//   2. We may later cache results so repeat shares of the same list cost ~$0.
// =============================================================================

import { corsHeaders } from "../_shared/cors.ts";
import { createLogger, extractTraceId } from "../_shared/observe.ts";

const ACTOR_ID = "compass~google-maps-extractor";  // ~ is API form of /
const MAX_PLACES = 100;
// run-sync-get-dataset-items waits up to ~5 min for the actor to finish.
// Most short share-list scrapes complete in well under a minute.

interface ExtractedPlace {
  name: string;
  address: string;
  latitude: number;
  longitude: number;
  category: string;
  imageUrl?: string;
  /// "venue" (default) or "region". Set when the Google Maps share
  /// resolves to a country / city / administrative area rather than a
  /// real venue — the iOS client surfaces these with a "this is not a
  /// single place" notice instead of dropping a normal pin.
  kind?: "venue" | "region";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const traceId = extractTraceId(req);
  const log = createLogger("parse-gmaps", traceId);

  // -------- 1. Parse the request --------
  let url: string;
  try {
    const body = await req.json();
    url = String(body.url ?? "").trim();
  } catch {
    await log.error("invalid JSON body", { event: "bad_request" });
    return json({ error: "Invalid JSON body" }, 400);
  }
  await log.info("request_received", { event: "request_received", data: { url } });
  if (!url || !/^https?:\/\//i.test(url)) {
    return json({ error: "Missing or invalid 'url'" }, 400);
  }

  // -------- 2. Check API token is configured --------
  const apifyToken = Deno.env.get("APIFY_TOKEN");
  if (!apifyToken) {
    console.error("APIFY_TOKEN not set in function secrets.");
    return json({ error: "Server not configured" }, 500);
  }

  // -------- 3. Run the Apify actor synchronously --------
  // run-sync-get-dataset-items kicks off a run AND streams back the dataset
  // when it finishes. Saves us from polling on /runs/{id}/dataset.
  const apifyUrl =
    `https://api.apify.com/v2/acts/${ACTOR_ID}/run-sync-get-dataset-items` +
    `?token=${encodeURIComponent(apifyToken)}` +
    `&clean=1&format=json`;

  const actorInput = {
    startUrls: [{ url }],
    maxCrawledPlacesPerSearch: MAX_PLACES,
    language: "en",
    // Don't follow into reviews / images / etc. — keeps each place cheap.
    scrapePlaceDetailPage: false,
    skipClosedPlaces: false,
  };

  let dataset: unknown;
  try {
    const apifyRes = await fetch(apifyUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(actorInput),
    });

    if (!apifyRes.ok) {
      const errText = await apifyRes.text();
      await log.error("apify error", { event: "apify_failed", data: { status: apifyRes.status, detail: errText.slice(0, 400), url } });
      return json(
        { error: `Apify returned ${apifyRes.status}`, detail: errText.slice(0, 400) },
        502,
      );
    }
    dataset = await apifyRes.json();
  } catch (err) {
    await log.error("apify fetch failed", { event: "apify_unreachable", data: { error: String(err), url } });
    return json({ error: "Could not reach scraping service" }, 502);
  }

  // -------- 4. Map the actor's items to our Place shape --------
  if (!Array.isArray(dataset)) {
    console.warn("Apify returned non-array dataset:", JSON.stringify(dataset).slice(0, 200));
    return json({ places: [], sourceUrl: url });
  }

  const places = (dataset as ApifyPlaceItem[])
    .map(toExtractedPlace)
    .filter((p): p is ExtractedPlace => p !== null);

  await log.info("parsed places", { event: "completed", data: { places: places.length, rawItems: dataset.length, url } });
  return json({ places, sourceUrl: url });
});

// =============================================================================
// Apify item -> our Place mapping
// =============================================================================

/** Subset of fields we care about from Apify's Google Maps Extractor actor.
 *  See https://apify.com/compass/google-maps-extractor#api-output for the
 *  full schema — most fields (reviews, photos, etc.) we ignore here. */
interface ApifyPlaceItem {
  title?: string;
  address?: string;
  street?: string;
  neighborhood?: string;
  city?: string;
  location?: { lat?: number; lng?: number };
  categoryName?: string;
  categories?: string[];
  placeId?: string;
  imageUrl?: string;
  imageUrls?: string[];
}

function toExtractedPlace(item: ApifyPlaceItem): ExtractedPlace | null {
  const name = (item.title ?? "").trim();
  const lat = item.location?.lat;
  const lng = item.location?.lng;

  if (!name) return null;
  if (typeof lat !== "number" || !Number.isFinite(lat) || Math.abs(lat) > 90) return null;
  if (typeof lng !== "number" || !Number.isFinite(lng) || Math.abs(lng) > 180) return null;

  const address =
    item.address ??
    [item.street, item.neighborhood, item.city].filter(Boolean).join(", ") ??
    "";

  return {
    name,
    address,
    latitude: lat,
    longitude: lng,
    category: mapCategory(item),
    imageUrl: item.imageUrl ?? item.imageUrls?.[0],
    kind: classifyKind(item),
  };
}

/// Detect "this isn't a venue, it's a country/city/region" from the
/// Apify category strings. Google's place types for these areas show
/// up in `categoryName` (e.g. "Country", "City", "Region") and
/// `categories` (e.g. ["administrative area"]). When we see one,
/// flag the row as a region so the iOS client can show the right
/// notice instead of pretending it's a real pin.
function classifyKind(item: ApifyPlaceItem): "venue" | "region" {
  const haystack = [
    item.categoryName ?? "",
    ...(item.categories ?? []),
  ].join(" ").toLowerCase();

  const regionPatterns = [
    /\bcountry\b/,
    /\bcontinent\b/,
    /\bcity\b/,
    /\bstate\b/,
    /\bprovince\b/,
    /\bregion\b/,
    /\bdistrict\b/,
    /\bprefecture\b/,
    /\bcounty\b/,
    /\bmunicipality\b/,
    /\bborough\b/,
    /\badministrative\s+area\b/,
    /\bisland\b/,
    /\barchipelago\b/,
  ];
  return regionPatterns.some((re) => re.test(haystack)) ? "region" : "venue";
}

/** Boil Google's hundreds of place categories down to our six.
 *  Order matters — more specific matches first, so `coffee` wins over `food`
 *  for "Coffee shop". */
function mapCategory(item: ApifyPlaceItem): string {
  const haystack = [
    item.categoryName ?? "",
    ...(item.categories ?? []),
  ].join(" ").toLowerCase();

  const rules: Array<[string, RegExp]> = [
    ["coffee",   /\b(coffee|cafe|café|espresso|tea house)\b/],
    ["drinks",   /\b(bar|pub|brewery|cocktail|wine|nightclub|lounge)\b/],
    ["food",     /\b(restaurant|food|pizz|sushi|bakery|deli|burger|ramen|noodle|taco|diner)\b/],
    ["art",      /\b(museum|gallery|exhibit|theater|theatre|cinema|art)\b/],
    ["activity", /\b(park|hike|trail|gym|yoga|climb|ski|surf|beach|spa|sport|stadium|tour)\b/],
    ["travel",   /\b(hotel|hostel|airport|station|resort|lodging|inn|guest house|guesthouse)\b/],
  ];

  for (const [category, pattern] of rules) {
    if (pattern.test(haystack)) return category;
  }
  return "food"; // Reasonable default — most Google Maps lists are food-heavy.
}

// -------- helpers --------

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
