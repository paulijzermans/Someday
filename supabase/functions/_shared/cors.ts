// Standard CORS headers shared across all Someday Edge Functions.
// The iOS app calls these directly via the Supabase Swift SDK, which
// runs over native URLSession (not a browser), so CORS isn't strictly
// required — but enabling it lets us debug locally with `curl` and
// future-proofs in case we ever call functions from a web client.

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};
