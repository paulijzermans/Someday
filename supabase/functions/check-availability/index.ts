// check-availability Edge Function
// =============================================================================
// "Is there a table tonight?" — answered without spending an AI token.
//
// Flow:
//   1. The iOS client sends `{ name, latitude, longitude, date, partySize }`.
//      Same name+coords shape used by `find-reservation-platforms` so the
//      cache key matches.
//   2. We look up `availability_cache.provider_ids` for that venue. The
//      previous Availability lookup populated it with `{zenchef: "357246"}`
//      etc.
//   3. We dispatch to the first adapter we have a venue ID for (Zenchef
//      first — that's what's implemented).
//   4. We return a slim "open / closed + shifts" payload.
//
// What it does NOT do:
//   • If we have no cached provider IDs, return `{ status: "unknown" }`
//     and let the client fall back to opening the booking URL. We do NOT
//     call Claude here — `find-reservation-platforms` is the AI step.
//   • Specific time-slot availability (e.g. "8pm is taken, 8:30 is free").
//     The summary endpoint tells us whether a shift is open and what
//     party sizes are valid; the actual slot grid lives behind the
//     widget. Good enough for v1.
//
// Deploy:
//   supabase functions deploy check-availability
//   (no secrets required — Zenchef endpoint is unauthenticated)
// =============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

interface RequestBody {
  name: string;
  latitude: number;
  longitude: number;
  /// ISO-8601 date (YYYY-MM-DD). Local to the venue — we don't convert.
  date: string;
  /// Number of guests. Optional; defaults to 2 if missing.
  partySize?: number;
}

/// Slim response shape the iOS client renders.
///   • `status: "open"`      — at least one shift accepting the requested
///                              party size on this date.
///   • `status: "closed"`    — the venue is open elsewhere but every
///                              shift is full / not bookable for this date.
///   • `status: "unknown"`   — we have no provider ID for this venue,
///                              so we can't check. Client falls back to
///                              opening the booking URL.
///   • `status: "error"`     — provider call failed; treat like unknown.
interface AvailabilityCheck {
  status: "open" | "closed" | "unknown" | "error";
  /// Which provider answered. Empty string if status is "unknown".
  provider: string;
  /// Human shift labels for the response. e.g. ["Dinner"] or ["Lunch", "Dinner"].
  shifts: Array<{ name: string; bookableUntil: string | null }>;
  /// Direct booking link, when we have it. Pre-filled with the date +
  /// party size when the provider supports query params.
  bookingURL: string | null;
  /// Echoed back for client-side cache keying.
  date: string;
  partySize: number;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // ----- Parse input -----
  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  if (!body.name || typeof body.name !== "string") {
    return json({ error: "name required" }, 400);
  }
  if (!body.date || !/^\d{4}-\d{2}-\d{2}$/.test(body.date)) {
    return json({ error: "date (YYYY-MM-DD) required" }, 400);
  }
  const partySize = Math.max(1, Math.min(20, body.partySize ?? 2));

  // ----- Cache lookup for provider IDs -----
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    return json({ error: "Supabase env not configured" }, 500);
  }
  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const cacheKey = buildCacheKey(body.name, body.latitude, body.longitude);
  const { data: cacheRow, error: cacheErr } = await supabase
    .from("availability_cache")
    .select("provider_ids, result")
    .eq("cache_key", cacheKey)
    .maybeSingle();

  if (cacheErr) {
    console.error("Cache read failed:", cacheErr);
    return jsonResult(unknownResult(body.date, partySize));
  }

  const providerIds = (cacheRow?.provider_ids ?? {}) as Record<string, string>;

  // ----- Dispatch to first available adapter -----
  // Order = our preference: Zenchef first (richest summary endpoint,
  // works for our target user base). Add more as adapters land.
  if (providerIds.zenchef) {
    try {
      const result = await checkZenchef(providerIds.zenchef, body.date, partySize);
      return jsonResult(result);
    } catch (err) {
      console.error("Zenchef adapter failed:", err);
      return jsonResult(errorResult(body.date, partySize, "zenchef"));
    }
  }

  // No provider IDs we can use. Tell the client to fall back to the
  // booking URL it already has from `find-reservation-platforms`.
  console.log(
    `check-availability: no supported provider for "${body.name}" (ids=${JSON.stringify(providerIds)})`,
  );
  return jsonResult(unknownResult(body.date, partySize));
});

// ============================================================================
// ADAPTERS
// ============================================================================

// ---------- Zenchef ----------
//
// Public endpoint, no auth: bookings-middleware.zenchef.com.
// Returns one entry per date with `isOpen` and an array of `shifts`
// (lunch / dinner / brunch / etc.) each carrying `possible_guests` —
// the party sizes that can book.
//
// We treat the venue as "open" iff at least one shift on the date
// accepts the requested party size.

async function checkZenchef(
  restaurantId: string,
  date: string,
  partySize: number,
): Promise<AvailabilityCheck> {
  const url = new URL("https://bookings-middleware.zenchef.com/getAvailabilitiesSummary");
  url.searchParams.set("restaurantId", restaurantId);
  url.searchParams.set("date_begin", date);
  url.searchParams.set("date_end", date);

  const resp = await fetch(url.toString(), {
    headers: {
      accept: "application/json",
      // Origin spoof — Zenchef's middleware doesn't enforce CORS here,
      // but sending the origin the widget uses is the polite default
      // and avoids any future tightening.
      origin: "https://bookings.zenchef.com",
    },
  });
  if (!resp.ok) {
    throw new Error(`Zenchef ${resp.status}: ${await resp.text()}`);
  }
  const payload = await resp.json() as Array<{
    date: string;
    isOpen: boolean;
    bookable_to: string | null;
    shifts: Array<{
      name: string;
      possible_guests: number[];
      closed: boolean;
      bookable_to: string | null;
    }>;
  }>;

  const day = payload[0];
  // Pre-filled booking URL — opens the Zenchef widget already focused
  // on the user's intended date + party size, so the user lands on the
  // slot grid in one tap rather than configuring the picker.
  const bookingURL =
    `https://bookings.zenchef.com/results?rid=${restaurantId}&day=${date}&pax=${partySize}`;

  if (!day || !day.isOpen) {
    return {
      status: "closed",
      provider: "zenchef",
      shifts: [],
      bookingURL,
      date,
      partySize,
    };
  }

  const matchingShifts = day.shifts.filter((s) =>
    !s.closed && s.possible_guests.includes(partySize)
  );

  return {
    status: matchingShifts.length > 0 ? "open" : "closed",
    provider: "zenchef",
    shifts: matchingShifts.map((s) => ({
      name: s.name,
      bookableUntil: s.bookable_to,
    })),
    bookingURL,
    date,
    partySize,
  };
}

// ============================================================================
// HELPERS
// ============================================================================

/// Mirror of the cache-key builder in `find-reservation-platforms`.
/// MUST stay in sync — otherwise we'd miss the cache row populated by
/// the platforms lookup. Two slightly-different copies are easier to
/// audit than a shared module across functions.
function buildCacheKey(name: string, lat: number, lng: number): string {
  const normName = name
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
  const latS = Number.isFinite(lat) ? lat.toFixed(4) : "0";
  const lngS = Number.isFinite(lng) ? lng.toFixed(4) : "0";
  return `${normName}@${latS},${lngS}`;
}

function unknownResult(date: string, partySize: number): AvailabilityCheck {
  return {
    status: "unknown",
    provider: "",
    shifts: [],
    bookingURL: null,
    date,
    partySize,
  };
}

function errorResult(date: string, partySize: number, provider: string): AvailabilityCheck {
  return {
    status: "error",
    provider,
    shifts: [],
    bookingURL: null,
    date,
    partySize,
  };
}

function jsonResult(r: AvailabilityCheck) {
  return json(r);
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
