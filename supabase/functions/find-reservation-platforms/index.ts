// find-reservation-platforms Edge Function
// =============================================================================
// Given a place (name + address + category + coords), ask Claude which booking
// platforms can be used to reserve it. Returns a small list ranked roughly by
// likelihood — OpenTable / Resy / TheFork / the venue's own website / etc.
//
// The iOS side calls this from PlaceCardSheet's Availability CTA and renders
// the result inside the floating AI bar (`AIAvailabilityBar.swift`).
//
// Response shape (matches Swift `AvailabilityResult` exactly):
//   {
//     "summary":   "3 ways to book Le Petit Vendôme",
//     "platforms": [
//       { "name": "OpenTable", "url": "https://...", "note": "30-day window" },
//       { "name": "TheFork",   "url": "https://...", "note": null },
//       { "name": "Venue site","url": null,          "note": "Call for groups" }
//     ]
//   }
//
// Deploy:
//   supabase functions deploy find-reservation-platforms
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
// =============================================================================

import Anthropic from "npm:@anthropic-ai/sdk@0.30.0";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";
import { createLogger, extractTraceId } from "../_shared/observe.ts";

const MODEL = "claude-sonnet-4-5";

// How long a cached AvailabilityResult is considered fresh. Past this we
// re-call Claude so the URLs / platform list stay current. 60 days is a
// pragmatic balance: AI cost stays near zero for the long tail of
// repeated venues, and stale URLs get cleaned up before they become a
// real UX problem. Tune via constant — restart of the function picks it up.
const CACHE_TTL_DAYS = 60;

const SYSTEM_PROMPT = `You are a booking concierge. Given a specific venue
(name, address, category, coordinates), figure out *what kind of place it
actually is* — restaurant, hotel, bar, café, museum, tour, park, etc. —
and then list the real online platforms where the user can book or
reserve a spot for it.

Step 1 — Classify the venue. The provided category is one of
{food, drinks, coffee, activity, art, travel}, which is coarse; look at the
name and address to refine:
- Names with "Hotel", "Inn", "Suites", "Resort", "Hostel", "B&B" → HOTEL
- Names with "Museum", "Gallery", "Galerij", "Musée" → MUSEUM / ATTRACTION
- Names with "Tour", "Cruise", "Experience" → TOUR / ACTIVITY
- Restaurants, bistros, izakayas, ramen shops, brasseries → RESTAURANT
- Bars, cocktail lounges, wine bars, pubs → BAR
- Cafés, coffee shops, bakeries (no full-service dining) → CAFÉ
- Parks, beaches, viewpoints → PUBLIC / NO BOOKING

Step 2 — Use web search (call the search tool) to find the actual booking
URLs for THIS specific venue. Search for things like
"<venue name> <city> reservation", "<venue name> booking",
"<venue name> opentable", "<venue name> resy". Only return URLs you find
in the search results — don't fabricate.

Step 3 — Map to platforms based on type:

RESTAURANT:
- US: OpenTable, Resy, SevenRooms, venue site
- Europe (.eu, .fr, .nl, .de, .es, .it): TheFork, Resy (in some EU cities),
  venue site, sometimes OpenTable
- Asia (Japan, SK): OMakase, TableCheck, venue site
- High-end / hard-to-book: also mention "Tock" or "Resy Priority"

HOTEL:
- Always show: Booking.com, the hotel's own site (direct booking often best
  price)
- For US/global chains: Hotels.com, Expedia
- For boutique / unique: also mention Mr & Mrs Smith, Tablet Hotels

BAR:
- Cocktail bars / speakeasies: Resy, SevenRooms, venue site
- Most bars: "Walk-in only" with a note

CAFÉ:
- Usually "Walk-in only". Add a note like "Busiest 9-11am weekends".

MUSEUM / ATTRACTION:
- Official site (direct, often cheapest)
- Tiqets, GetYourGuide, Viator for combo tickets / tours

TOUR / ACTIVITY:
- GetYourGuide, Viator, Klook, the tour operator's site

PUBLIC / NO BOOKING:
- One entry: name "No booking needed", url null, note like "Free entry"
  or "Open dawn-to-dusk".

Step 4 — Return ONLY a valid JSON object — no prose, no markdown fences:
{
  "summary": "<one-line plain English headline mentioning the venue by name, under 60 chars>",
  "platforms": [
    {
      "name":  "<platform name>",
      "url":   "<direct booking URL you verified via search, or null>",
      "note":  "<optional one-line hint, or null>"
    }
  ]
}

Additionally, if you find the venue's contact email during search (a real
address like "reservations@<venue>.com" or "info@<venue>.com"), include
it as a platform entry:
- name: "Email reservation"
- url:  "mailto:<address>?subject=Reservation%20request"
- note: the bare email address, e.g. "reservations@dekas.nl"
Only do this if you found the address in search results — never guess one.

Hard rules:
- 1 to 5 platforms. Don't pad.
- "url" must be from web search results, not invented. Null if you couldn't
  verify a specific URL for this venue.
- "summary" must mention the venue name and convey what was found
  (e.g. "3 ways to book Le Petit Vendôme", "Berlini doesn't take reservations").
- Don't list more than 4 platforms even when there are more — pick the most
  popular / reliable for the venue's region.`;

interface RequestBody {
  name: string;
  address: string;
  category: string;
  latitude: number;
  longitude: number;
}

interface AvailabilityResult {
  summary: string;
  platforms: Array<{ name: string; url: string | null; note: string | null }>;
}

Deno.serve(async (req) => {
  // -------- CORS preflight (matches the other functions in this project) --
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const traceId = extractTraceId(req);
  const log = createLogger("find-reservation-platforms", traceId);

  // -------- 1. Parse + validate input ---------------------------------------
  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    await log.error("invalid JSON body", { event: "bad_request" });
    return json({ error: "Invalid JSON body" }, 400);
  }
  if (!body.name || typeof body.name !== "string") {
    await log.error("name required", { event: "bad_request" });
    return json({ error: "name required" }, 400);
  }
  await log.info("request_received", { event: "request_received", data: { name: body.name, category: body.category } });

  // -------- 2. Env --------------------------------------------------------
  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!anthropicKey) {
    return json({ error: "ANTHROPIC_API_KEY not configured" }, 500);
  }
  // Supabase URL + service role key are injected automatically into every
  // Edge Function environment. We use the service role so reads/writes to
  // `availability_cache` bypass RLS — the table is locked down from
  // direct client access by design.
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const supabase = supabaseUrl && serviceKey
    ? createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    })
    : null;

  // -------- 2a. Shared cache lookup ---------------------------------------
  // Stable key derived from name + rounded coords. Two different users
  // looking up the same restaurant land on the same row, even if their
  // pin drops differ by a few metres.
  const cacheKey = buildCacheKey(body);
  if (supabase) {
    try {
      const { data, error } = await supabase
        .from("availability_cache")
        .select("result, created_at, hit_count")
        .eq("cache_key", cacheKey)
        .maybeSingle();
      if (error) throw error;
      if (data && isFresh(data.created_at)) {
        await log.info("cache hit", { event: "cache_hit", data: { name: body.name, cacheKey } });
        // Fire-and-forget hit-count increment. We don't await it — the
        // user shouldn't wait on telemetry. Errors here are harmless.
        supabase
          .from("availability_cache")
          .update({
            hit_count: (data.hit_count ?? 0) + 1,
            updated_at: new Date().toISOString(),
          })
          .eq("cache_key", cacheKey)
          .then(() => {}, () => {});
        return json(data.result);
      }
    } catch (err) {
      // Cache lookup failed — log and fall through to live AI call.
      // The user still gets a real answer, just at full cost.
      console.warn("Cache lookup failed:", err);
    }
  }

  // -------- 3. Compose the user prompt ------------------------------------
  // Keep it terse — Claude does best with a structured block of facts rather
  // than a chatty paragraph.
  const userPrompt = [
    `Venue: ${body.name}`,
    body.address ? `Address / area: ${body.address}` : null,
    `Category: ${body.category}`,
    `Coordinates: ${body.latitude}, ${body.longitude}`,
    ``,
    `List the booking platforms for this venue. Respond with the JSON object only.`,
  ].filter(Boolean).join("\n");

  // -------- 4. Ask Claude (with web search) -------------------------------
  // The `web_search_20250305` tool runs server-side on Anthropic's infra:
  // Claude does the searching, returns the final answer once it's verified
  // URLs. `max_uses: 3` caps the search cost per Availability tap at ~$0.03.
  const anthropic = new Anthropic({ apiKey: anthropicKey });
  let raw: string;
  try {
    const message = await anthropic.messages.create({
      model: MODEL,
      max_tokens: 2048,
      system: SYSTEM_PROMPT,
      tools: [
        {
          type: "web_search_20250305",
          name: "web_search",
          max_uses: 3,
        },
      ] as any,
      messages: [{ role: "user", content: userPrompt }],
    });

    // Claude may emit multiple content blocks (tool_use, tool_result,
    // text). The final `text` block is the JSON we want. Walk the array
    // backwards so we always land on the LAST text — anything before
    // is reasoning + search-tool plumbing.
    const finalText = [...message.content]
      .reverse()
      .find((b) => b.type === "text") as { type: "text"; text: string } | undefined;
    if (!finalText) {
      return json({ error: "Unexpected model response shape" }, 502);
    }
    raw = finalText.text;
  } catch (err) {
    await log.error("claude call failed", { event: "llm_failed", data: { name: body.name, error: String(err) } });
    return json({ error: "AI lookup failed" }, 502);
  }

  // -------- 5. Parse Claude output ----------------------------------------
  const result = extractResult(raw, body.name);
  await log.info("ai miss", { event: "completed", data: { name: body.name, platforms: result.platforms.length, cached: false } });

  // Extract per-provider venue IDs from the URLs Claude returned. Lets
  // the new `check-availability` function hit each provider's JSON API
  // directly — no AI cost, sub-second response.
  const providerIds = extractProviderIds(result);

  // -------- 6. Persist to the shared cache --------------------------------
  // Upsert so a concurrent miss for the same venue (two users tapping
  // Availability at the same time) doesn't blow up on the PK. Fire-and-
  // forget — we don't make the user wait for the write. Errors are
  // logged but don't fail the response: a write hiccup just means the
  // next user re-pays the AI cost, not a broken UX.
  if (supabase) {
    supabase
      .from("availability_cache")
      .upsert({
        cache_key: cacheKey,
        venue_name: body.name,
        latitude: body.latitude,
        longitude: body.longitude,
        result: result,
        provider_ids: providerIds,
        hit_count: 0,
        updated_at: new Date().toISOString(),
        created_at: new Date().toISOString(),
      }, { onConflict: "cache_key" })
      .then(
        () => console.log(`Availability: cached "${body.name}"`),
        (err) => console.warn("Cache write failed:", err),
      );
  }

  return json(result);
});

// ---------------------- cache helpers ----------------------

/// Build a stable cache key from the venue's identifying fields. The key
/// must be deterministic across users and across small coordinate jitter
/// — two users dropping a pin within ~11m of each other on the same
/// restaurant should hit the same row.
///
/// Format: `<normalised-name>@<lat4>,<lng4>`
///   • name lower-cased, diacritics stripped, non-alphanumerics collapsed
///   • lat/lng rounded to 4 decimal places (~11m at the equator)
function buildCacheKey(body: RequestBody): string {
  const normName = body.name
    .toLowerCase()
    .normalize("NFD")
    // strip accents — "Vendôme" → "vendome". `̀-ͯ` is the
    // Unicode combining-diacritical block, exposed after `normalize("NFD")`.
    .replace(/[̀-ͯ]/g, "")
    // collapse runs of non-alphanumerics into single dashes
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
  const lat = Number.isFinite(body.latitude) ? body.latitude.toFixed(4) : "0";
  const lng = Number.isFinite(body.longitude) ? body.longitude.toFixed(4) : "0";
  return `${normName}@${lat},${lng}`;
}

/// True if a cached row is still within the TTL window.
function isFresh(createdAt: string): boolean {
  const created = new Date(createdAt).getTime();
  if (!Number.isFinite(created)) return false;
  const ageDays = (Date.now() - created) / (1000 * 60 * 60 * 24);
  return ageDays < CACHE_TTL_DAYS;
}

// ---------------------- provider ID extraction ----------------------
//
// Each booking platform exposes a public JSON availability endpoint
// keyed by a numeric venue ID. We can scrape that ID out of the URL
// Claude returned, then use it later to query the platform directly
// without paying for another AI call.
//
// Add new providers here as adapters land in `check-availability`.

const PROVIDER_PATTERNS: Array<{
  provider: string;
  // Regex applied to the URL. Capture group 1 = the venue ID.
  pattern: RegExp;
}> = [
  // Zenchef: https://bookings.zenchef.com/results?rid=357246
  // Also matches the older module.zenchef.com format.
  { provider: "zenchef", pattern: /(?:bookings|module)\.zenchef\.com\/[^?]*\?(?:[^&]*&)*rid=(\d+)/i },
  // TheFork:  https://www.thefork.com/restaurant/le-petit-vendome-r30078
  // The numeric ID is suffixed with `-r<digits>` at the end of the slug.
  { provider: "thefork", pattern: /thefork\.com\/restaurant\/[^/]*-r(\d+)/i },
  // OpenTable: https://www.opentable.com/r/le-petit-vendome-paris?...
  //            also /booking/restaurant-profile/<id>
  // The numeric venue ID isn't always in the URL — we capture what we
  // can. If absent, OpenTable lookups stay AI-only for that venue.
  { provider: "opentable", pattern: /opentable\.com\/(?:.*[?&]rid=|booking\/restaurant-profile\/)(\d+)/i },
  // Resy:     https://resy.com/cities/<city>/venues/<slug>
  // Resy doesn't put numeric IDs in URLs — slug-based lookup happens in
  // the adapter itself, so we capture the slug instead.
  { provider: "resy", pattern: /resy\.com\/cities\/[^/]+\/venues\/([^/?#]+)/i },
];

/// Walk the `result.platforms` URLs, run each against the provider
/// pattern table, return a `{provider → id}` map. Empty map if nothing
/// matches — perfectly fine, `check-availability` then has no work to
/// do for that venue.
function extractProviderIds(result: AvailabilityResult): Record<string, string> {
  const ids: Record<string, string> = {};
  for (const platform of result.platforms) {
    if (!platform.url) continue;
    for (const { provider, pattern } of PROVIDER_PATTERNS) {
      // First match wins per provider — Claude usually only returns one
      // URL per platform, but if it duplicates we keep the first.
      if (ids[provider]) continue;
      const m = platform.url.match(pattern);
      if (m && m[1]) {
        ids[provider] = m[1];
      }
    }
  }
  return ids;
}

// ---------------------- helpers ----------------------

/// Parse the AI response, tolerant of markdown fences / leading prose, and
/// normalise it into the strict `AvailabilityResult` shape the iOS side
/// decodes. Falls back to a safe default if parsing fails so the client
/// always gets a usable response.
function extractResult(raw: string, venueName: string): AvailabilityResult {
  const fallback: AvailabilityResult = {
    summary: `Couldn't find booking info for ${venueName}`,
    platforms: [],
  };

  const candidates = [
    raw,
    raw.match(/```(?:json)?\s*([\s\S]*?)```/i)?.[1] ?? "",
    extractObject(raw),
  ];

  for (const c of candidates) {
    if (!c) continue;
    try {
      const parsed = JSON.parse(c) as unknown;
      if (isResult(parsed)) {
        // Normalise: trim, coerce empty-string urls to null.
        return {
          summary: String(parsed.summary).slice(0, 120),
          // Bumped to 5 so an Email-reservation row can fit alongside up
          // to 4 booking platforms. `mailto:` and `tel:` schemes are
          // allowed alongside `http(s)` — the iOS client routes them to
          // the right system handler.
          platforms: parsed.platforms.slice(0, 5).map((p) => ({
            name: String(p.name).slice(0, 60),
            url: p.url && typeof p.url === "string" && isAllowedScheme(p.url) ? p.url : null,
            note: p.note && typeof p.note === "string" ? p.note.slice(0, 120) : null,
          })),
        };
      }
    } catch { /* try next candidate */ }
  }
  console.warn("Could not parse model output:", raw.slice(0, 300));
  return fallback;
}

/// Whitelist of URL schemes we let through to the iOS client. http(s)
/// are the standard booking-page links; `mailto:` powers the new Email-
/// reservation row; `tel:` powers the existing phone CTA. Anything else
/// (javascript:, file:, etc.) gets coerced to null for safety.
function isAllowedScheme(url: string): boolean {
  const lower = url.toLowerCase();
  return lower.startsWith("http://") ||
    lower.startsWith("https://") ||
    lower.startsWith("mailto:") ||
    lower.startsWith("tel:");
}

/// Pull the largest {…} block out of arbitrary text. Used when the model
/// wraps its JSON in commentary despite the prompt asking it not to.
function extractObject(raw: string): string {
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  return start !== -1 && end > start ? raw.slice(start, end + 1) : "";
}

function isResult(x: unknown): x is AvailabilityResult {
  if (typeof x !== "object" || x === null) return false;
  const o = x as Record<string, unknown>;
  return typeof o.summary === "string" &&
    Array.isArray(o.platforms) &&
    o.platforms.every((p) =>
      typeof p === "object" && p !== null &&
      typeof (p as Record<string, unknown>).name === "string"
    );
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
