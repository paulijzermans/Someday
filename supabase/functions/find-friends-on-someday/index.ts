// find-friends-on-someday Edge Function
// =============================================================================
// "Which of my contacts have a Someday account?"
//
// The iOS client reads the user's address book, normalizes + SHA-256-hashes
// every phone and email locally, then sends the hash arrays here. We match
// them against the indexed `email_hash` / `phone_hash` columns on
// `profiles` and return the matched user rows.
//
// Privacy:
//   • The server NEVER sees raw phone numbers or email addresses from the
//     client's address book. Only opaque hex hashes.
//   • The requesting user is excluded from the result so they don't see
//     themselves listed.
//
// Request:
//   { emailHashes: string[], phoneHashes: string[] }
//
// Response (200):
//   {
//     matches: [
//       { id, name, avatarUrl, matchedBy: "email" | "phone" }
//     ]
//   }
// =============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

interface RequestBody {
  emailHashes?: string[];
  phoneHashes?: string[];
}

interface MatchedProfile {
  id: string;
  name: string;
  avatarUrl: string | null;
  matchedBy: "email" | "phone";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // ----- Auth header passthrough so we know the requesting user -----
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) {
    return json({ error: "Supabase env not configured" }, 500);
  }
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return json({ error: "Missing Authorization header" }, 401);
  }

  // Anon client with the user's JWT — used purely to read the caller's
  // uid so we can exclude them from the match list.
  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) {
    return json({ error: "Unauthorized" }, 401);
  }

  // Service-role client for the actual match query. We rely on the auth
  // check above + the explicit `not eq` filter below for safety.
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // ----- Parse + sanitize input -----
  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  // Hashes are 64-char lowercase hex. Drop anything that isn't.
  // Caps the array size so a malicious client can't dump infinite data.
  const HASH_RE = /^[a-f0-9]{64}$/;
  const MAX_HASHES = 5000;
  const emailHashes = (body.emailHashes ?? [])
    .filter((h): h is string => typeof h === "string" && HASH_RE.test(h))
    .slice(0, MAX_HASHES);
  const phoneHashes = (body.phoneHashes ?? [])
    .filter((h): h is string => typeof h === "string" && HASH_RE.test(h))
    .slice(0, MAX_HASHES);

  if (emailHashes.length === 0 && phoneHashes.length === 0) {
    return json({ matches: [] });
  }

  // ----- Query: union of email + phone matches -----
  // Run the two halves separately so the index on each column stays
  // tight. Dedupe at the end by profile id.
  const matchesById = new Map<string, MatchedProfile>();

  if (emailHashes.length > 0) {
    const { data, error } = await admin
      .from("profiles")
      .select("id, name, avatar_url")
      .in("email_hash", emailHashes)
      .neq("id", user.id);
    if (error) {
      console.error("email_hash query failed:", error);
      return json({ error: "DB query failed" }, 500);
    }
    for (const row of data ?? []) {
      matchesById.set(row.id, {
        id: row.id,
        name: row.name,
        avatarUrl: row.avatar_url ?? null,
        matchedBy: "email",
      });
    }
  }

  if (phoneHashes.length > 0) {
    const { data, error } = await admin
      .from("profiles")
      .select("id, name, avatar_url")
      .in("phone_hash", phoneHashes)
      .neq("id", user.id);
    if (error) {
      console.error("phone_hash query failed:", error);
      return json({ error: "DB query failed" }, 500);
    }
    for (const row of data ?? []) {
      // Phone match wins over email if we somehow have both — it's the
      // stronger signal (people have one phone, multiple emails).
      matchesById.set(row.id, {
        id: row.id,
        name: row.name,
        avatarUrl: row.avatar_url ?? null,
        matchedBy: "phone",
      });
    }
  }

  console.log(
    `find-friends: user=${user.id} email=${emailHashes.length} phone=${phoneHashes.length} matches=${matchesById.size}`,
  );

  return json({ matches: Array.from(matchesById.values()) });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
