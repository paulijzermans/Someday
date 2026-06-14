#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# debug_log.sh — read the unified cross-surface trace stream via the gated
# `read_debug_log` RPC. This is the read half of the observability loop
# (see migration 20260614100000_debug_log.sql + _shared/observe.ts).
#
# This generalises chat_debug.sh: where that reads chat-only per-turn rows,
# this reads breadcrumbs from EVERY surface (ios, chat, parse-gmaps, …) and
# can filter to a single request's whole journey by trace id.
#
# Usage:
#   CHAT_DEBUG_SECRET=<secret> ./supabase/scripts/debug_log.sh [options]
#
# Options:
#   --trace <id>      only rows for this X-Trace-Id (the killer feature: one
#                     request's full path across every surface)
#   --surface <name>  only rows from this surface (ios|chat|parse-gmaps|…)
#   --limit <n>       max rows (default 50, capped at 500 server-side)
#
# Examples:
#   # last 50 rows across everything (newest first)
#   CHAT_DEBUG_SECRET=… ./supabase/scripts/debug_log.sh
#   # everything that touched one request, oldest-first for readability
#   CHAT_DEBUG_SECRET=… ./supabase/scripts/debug_log.sh --trace 1234-… --limit 200
#   # just the chat function's recent rows
#   CHAT_DEBUG_SECRET=… ./supabase/scripts/debug_log.sh --surface chat
#
# The anon key + project URL are read from Someday/Core/Config/Secrets.plist.
# The secret is NOT stored here — pass it via the env var so this script is
# safe to commit. Requires: jq, plutil (macOS), curl.
# ----------------------------------------------------------------------------
set -euo pipefail

SECRET="${CHAT_DEBUG_SECRET:-}"
if [[ -z "$SECRET" ]]; then
  echo "error: set CHAT_DEBUG_SECRET=<secret> (the value baked into read_debug_log)" >&2
  exit 1
fi

LIMIT=50
TRACE="null"
SURFACE="null"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --trace)   TRACE="\"$2\""; shift 2 ;;
    --surface) SURFACE="\"$2\""; shift 2 ;;
    --limit)   LIMIT="$2"; shift 2 ;;
    *) echo "error: unknown option '$1'" >&2; exit 1 ;;
  esac
done

PLIST="$(cd "$(dirname "$0")/../.." && pwd)/Someday/Core/Config/Secrets.plist"
URL="$(plutil -extract SUPABASE_URL raw "$PLIST")"
ANON="$(plutil -extract SUPABASE_ANON_KEY raw "$PLIST")"

curl -s -X POST "$URL/rest/v1/rpc/read_debug_log" \
  -H "apikey: $ANON" \
  -H "Authorization: Bearer $ANON" \
  -H "Content-Type: application/json" \
  -d "{\"p_secret\":\"$SECRET\",\"p_limit\":$LIMIT,\"p_trace_id\":$TRACE,\"p_surface\":$SURFACE}" \
  | jq 'sort_by(.created_at) | .[] | {at: .created_at, surface: .surface, level: .level, event: .event, msg: .message, ms: .duration_ms, trace: .trace_id, data: .data}'
