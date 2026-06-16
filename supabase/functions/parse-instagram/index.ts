// parse-instagram Edge Function
// =============================================================================
// Takes an Instagram Reel / post URL and returns the places mentioned in its
// caption as structured JSON. Reels about places typically name the venue
// + city in the caption (so the algorithm picks it up), so caption-only
// extraction covers most real-world cases without needing speech-to-text on
// the video.
//
// Pipeline:
//   1. Call Apify "apify/instagram-scraper" actor → caption + metadata.
//   2. Compose a prompt with caption + hashtags + tagged location.
//   3. Ask Claude to extract specific named places (not generic ones).
//   4. Return the array — iOS geocodes each via CLGeocoder before mapping.
//
// We deliberately do NOT return coordinates here: Claude shouldn't guess them
// (risk of hallucination) and Apify doesn't supply them for ad-hoc captions.
// =============================================================================

import Anthropic from "npm:@anthropic-ai/sdk@0.30.0";
import { corsHeaders } from "../_shared/cors.ts";
import { createLogger, extractTraceId } from "../_shared/observe.ts";
import {
  type CacheableItem,
  lookupExtraction,
  serviceClient,
  storeExtraction,
} from "../_shared/place-cache.ts";

const ACTOR_ID = "apify~instagram-scraper";
const MODEL = "claude-sonnet-4-5";

const SYSTEM_PROMPT = `You extract place mentions from Instagram post / Reel captions.

Return ONLY a valid JSON array — no prose, no markdown fences, no commentary.

Each item: {"name": string, "address": string, "category": string}
- "category" must be one of: food, drinks, coffee, activity, art, travel.
- "address" should combine the strongest location signals available:
  the tagged location, then any city / neighborhood / address tokens visible
  in the caption. If only a city is named, return the city.
- Return ONLY places explicitly named in the caption (or via tagged location).
  Do not invent venues. Do not return generic mentions like "the beach",
  "a great cafe" — only specific, searchable place names.
- If the caption has no specific place mentions, return an empty array [].
- Deduplicate identical mentions.

Output the JSON array directly.`;

interface ExtractedPlace {
  name: string;
  address: string;
  category: string;
  imageUrl?: string;
}

interface ApifyPost {
  caption?: string;
  hashtags?: string[];
  mentions?: string[];
  locationName?: string;
  ownerUsername?: string;
  url?: string;
  type?: string;
  displayUrl?: string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const traceId = extractTraceId(req);
  const log = createLogger("parse-instagram", traceId);

  // -------- 1. Parse request --------
  let url: string;
  try {
    const body = await req.json();
    url = String(body.url ?? "").trim();
  } catch {
    await log.error("invalid JSON body", { event: "bad_request" });
    return json({ error: "Invalid JSON body" }, 400);
  }
  await log.info("request_received", { event: "request_received", data: { url } });
  if (!/instagram\.com/.test(url)) {
    return json({ error: "Provide an Instagram URL (instagram.com/...)" }, 400);
  }

  // -------- 1a. Global place-cache lookup --------
  // Reels are immutable once posted, so a prior extraction of this URL is
  // safe to replay — saving both the Apify scrape AND the Claude call. The
  // cache is owner-agnostic and outlives the original importer's saved copy.
  const supabase = serviceClient();
  const cached = await lookupExtraction(supabase, "instagram", url);
  if (cached) {
    await log.info("cache hit", { event: "cache_hit", data: { places: cached.places.length, url } });
    return json({ places: cached.places, sourceUrl: url, cached: true, note: cached.note });
  }

  // -------- 2. Check secrets --------
  const apifyToken = Deno.env.get("APIFY_TOKEN");
  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apifyToken || !anthropicKey) {
    console.error("APIFY_TOKEN or ANTHROPIC_API_KEY missing");
    return json({ error: "Server not configured" }, 500);
  }

  // -------- 3. Scrape via Apify --------
  const apifyUrl =
    `https://api.apify.com/v2/acts/${ACTOR_ID}/run-sync-get-dataset-items` +
    `?token=${encodeURIComponent(apifyToken)}&clean=1&format=json`;

  const actorInput = {
    directUrls: [url],
    resultsType: "details",
    resultsLimit: 1,
    addParentData: false,
  };

  let post: ApifyPost;
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
    const data = await apifyRes.json();
    if (!Array.isArray(data) || data.length === 0) {
      // Apify returned nothing — Reel might be private or not exist.
      return json({ places: [], sourceUrl: url, note: "No data returned for that URL" });
    }
    post = data[0];
  } catch (err) {
    await log.error("apify fetch failed", { event: "apify_unreachable", data: { error: String(err), url } });
    return json({ error: "Could not reach scraping service" }, 502);
  }

  // -------- 4. Compose Claude input from caption + metadata --------
  const caption = (post.caption ?? "").trim();
  const hashtags = (post.hashtags ?? []).join(", ");
  const mentions = (post.mentions ?? []).join(", ");
  const tagged = post.locationName ?? "";

  if (!caption && !tagged) {
    // Deterministic emptiness — the reel simply has nothing to extract. Cache
    // it so we never re-scrape this URL hoping for a different answer.
    const note = "Post has no caption or location";
    storeExtraction(supabase, "instagram", url, [], note);
    return json({ places: [], sourceUrl: url, note });
  }

  const claudeInput =
    `Tagged location: ${tagged || "(none)"}\n` +
    `Hashtags: ${hashtags || "(none)"}\n` +
    `Mentions: ${mentions || "(none)"}\n` +
    `\nCaption:\n${caption || "(empty)"}`;

  // -------- 5. Ask Claude --------
  const anthropic = new Anthropic({ apiKey: anthropicKey });

  let raw: string;
  try {
    const message = await anthropic.messages.create({
      model: MODEL,
      max_tokens: 2048,
      system: SYSTEM_PROMPT,
      messages: [{ role: "user", content: claudeInput }],
    });
    const first = message.content[0];
    if (first.type !== "text") {
      return json({ error: "Unexpected model response shape" }, 502);
    }
    raw = first.text;
  } catch (err) {
    await log.error("claude call failed", { event: "llm_failed", data: { error: String(err), url } });
    return json({ error: "Extraction failed" }, 502);
  }

  // -------- 6. Parse Claude output --------
  // The Reel itself has one thumbnail — attach it to every extracted
  // place. Better than nothing for a quick visual cue per pin.
  const displayUrl = post.displayUrl;
  const places = extractPlaces(raw).map((p) =>
    displayUrl ? { ...p, imageUrl: displayUrl } : p
  );
  await log.info("parsed places", { event: "completed", data: { places: places.length, url } });

  // Populate the global cache (fire-and-forget). These places have no
  // coordinates yet (iOS geocodes them), so their identity key falls back to
  // name + address — still enough to dedupe and to replay this reel for free.
  storeExtraction(
    supabase,
    "instagram",
    url,
    places.map((p): CacheableItem => ({
      payload: p,
      name: String(p.name ?? ""),
      category: typeof p.category === "string" ? p.category : undefined,
      address: typeof p.address === "string" ? p.address : undefined,
      imageUrl: typeof p.imageUrl === "string" ? p.imageUrl : undefined,
    })),
  );

  return json({ places, sourceUrl: url });
});

// ---------------------- helpers ----------------------

function extractPlaces(raw: string): ExtractedPlace[] {
  // Direct parse
  try {
    const direct = JSON.parse(raw);
    if (Array.isArray(direct)) return direct.filter(isPlausible);
  } catch { /* fall through */ }

  // Strip ```json ... ``` fences
  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fenced) {
    try {
      const inner = JSON.parse(fenced[1].trim());
      if (Array.isArray(inner)) return inner.filter(isPlausible);
    } catch { /* fall through */ }
  }

  // Largest [...] block
  const start = raw.indexOf("[");
  const end = raw.lastIndexOf("]");
  if (start !== -1 && end > start) {
    try {
      const parsed = JSON.parse(raw.slice(start, end + 1));
      if (Array.isArray(parsed)) return parsed.filter(isPlausible);
    } catch { /* fall through */ }
  }

  console.warn("Could not parse model output:", raw.slice(0, 300));
  return [];
}

function isPlausible(p: unknown): p is ExtractedPlace {
  if (typeof p !== "object" || p === null) return false;
  const x = p as Record<string, unknown>;
  return typeof x.name === "string" && x.name.length > 0 &&
    typeof x.category === "string";
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
