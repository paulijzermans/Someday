#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# chat_debug.sh — read the most recent rows from chat_debug_log via the gated
# `read_chat_debug` RPC. This is the read half of the chat observability loop
# (see migration 20260613173000_chat_debug_log.sql + recordChatDebug in
# functions/chat/index.ts).
#
# Usage:
#   CHAT_DEBUG_SECRET=<secret> ./supabase/scripts/chat_debug.sh [limit]
#
# The anon key + project URL are read from Someday/Core/Config/Secrets.plist.
# The secret is NOT stored here — pass it via the env var so this script is
# safe to commit. Requires: jq, plutil (macOS), curl.
# ----------------------------------------------------------------------------
set -euo pipefail

LIMIT="${1:-10}"
SECRET="${CHAT_DEBUG_SECRET:-}"
if [[ -z "$SECRET" ]]; then
  echo "error: set CHAT_DEBUG_SECRET=<secret> (the value baked into read_chat_debug)" >&2
  exit 1
fi

PLIST="$(cd "$(dirname "$0")/../.." && pwd)/Someday/Core/Config/Secrets.plist"
URL="$(plutil -extract SUPABASE_URL raw "$PLIST")"
ANON="$(plutil -extract SUPABASE_ANON_KEY raw "$PLIST")"

curl -s -X POST "$URL/rest/v1/rpc/read_chat_debug" \
  -H "apikey: $ANON" \
  -H "Authorization: Bearer $ANON" \
  -H "Content-Type: application/json" \
  -d "{\"p_secret\":\"$SECRET\",\"p_limit\":$LIMIT}" \
  | jq '.[] | {at: .created_at, msg: .user_message, tools: .tools, selection: .selection, reply: (.reply_text[0:160]), error: .error, meta: .meta}'
