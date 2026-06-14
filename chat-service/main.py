# chat-service — Someday AI chat, FastAPI on Railway
# =============================================================================
# A faithful Python port of the Supabase Edge Function `supabase/functions/chat`.
#
# WHY THIS EXISTS — the Deno/Supabase edge runtime hangs the Anthropic request.
# After an exhaustive isolation pass we proved the chat hang is NOT in our SSE /
# streaming code: in the Supabase/Deno edge isolate the Anthropic HTTP response
# never reaches EOF when the server-side `web_search` tool is involved (and a
# non-streaming `messages.create()` hangs even for a plain-text "say hi"). The
# fix is to run the exact same agentic tool loop in a normal Python runtime,
# where the official `anthropic` SDK terminates cleanly for every turn — text,
# client tools, and web_search alike. This service replicates the Edge Function
# byte-for-byte on the wire:
#
# Wire format: Server-Sent Events (text/event-stream).
#   event: step       data: { id, icon, label, tool }  — a tool/work step started
#   event: step_done  data: { id }                      — that step finished
#   event: text       data: { delta }                   — assistant reply token(s)
#   event: mutation   data: { kind, input }             — client applies a change
#   event: selection  data: { prompt, options, ... }    — (reserved; ask_selection)
#   event: done       data: {}                          — stream complete
#   event: error      data: { message }                 — fatal error mid-stream
#
# Tool loop: each iteration is one `messages.create()` call. We parse tool_use
# blocks for the client tools, execute them locally against `ctx`, then loop with
# the tool_result blocks. Server tools (web_search) are resolved inline by
# Anthropic; we also handle `stop_reason: "pause_turn"` (the API deliberately
# pausing a long server-tool run) by resubmitting the accumulated content to
# continue. Capped at MAX_TOOL_ITERATIONS to bound cost/latency.
#
# KNOWN-GOOD BASELINE — this is the working reference. The current tool roster
# (the 8 client tools in `tool_specs()` + web_search) is proven end-to-end: text,
# client-tool mutations, and web_search all terminate cleanly on Railway. If a
# FUTURE change that adds more tools regresses the stream (hangs, malformed SSE,
# pause_turn loops), FALL BACK TO THIS VERSION: revert the new tool(s) out of
# `tool_specs()` / `execute_client_tool()` and redeploy this baseline, then
# reintroduce the new tool in isolation. Do not debug a broken roster in prod —
# restore the known-good set first.
# =============================================================================

import asyncio
import json
import os
from typing import Any, Optional

import httpx
from anthropic import AsyncAnthropic
from fastapi import FastAPI, Header, Request, Response
from fastapi.responses import JSONResponse, StreamingResponse

# Claude Haiku 4.5 — ~4x cheaper than Sonnet 4.5 and fast enough that the
# streaming UX still feels instant. Single source of truth for the model id.
MODEL = "claude-haiku-4-5"
MAX_TOOL_ITERATIONS = 6
MAX_TOKENS = 1024

DEFAULT_AI_SETTINGS: dict[str, Any] = {
    "tone": "balanced",
    "allowExternalRecommendations": True,
    # Replies feel chat-fast at this cap; the user can always ask "more?".
    "maxPlacesPerAnswer": 3,
    "anchorOnSelectedPin": True,
    "customInstructions": "",
}

app = FastAPI(title="Someday chat-service")

# CORS — the iOS client talks to us directly. Mirror the Edge Function's
# permissive CORS (it was called from app + curl). Echoed on every response.
CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-api-key, x-client-info, apikey, content-type, x-trace-id",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
}


# ---------------------------------------------------------------------------
# Anthropic client (lazy singleton — built on first use so a missing key is a
# clean 500 at request time rather than an import crash).
# ---------------------------------------------------------------------------
_anthropic: Optional[AsyncAnthropic] = None


def get_anthropic() -> Optional[AsyncAnthropic]:
    global _anthropic
    if _anthropic is not None:
        return _anthropic
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        return None
    _anthropic = AsyncAnthropic(api_key=key)
    return _anthropic


# ---------------------------------------------------------------------------
# Health check — Railway pings this (railway.toml healthcheckPath = "/health").
# ---------------------------------------------------------------------------
@app.get("/health")
async def health() -> dict[str, Any]:
    return {"ok": True, "model": MODEL, "anthropic": bool(os.environ.get("ANTHROPIC_API_KEY"))}


@app.options("/chat")
async def chat_options() -> Response:
    return Response(status_code=204, headers=CORS_HEADERS)


# ---------------------------------------------------------------------------
# Tool definitions — identical schemas to the Edge Function.
# ---------------------------------------------------------------------------
def tool_specs() -> list[dict[str, Any]]:
    return [
        {
            "name": "inspect_list",
            "description": "Look up one of the user's Someday lists by name and return the places saved in it (with their ids so you can reference them in your reply). Call this before describing or comparing what's in a specific list.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "List name to look up (case-insensitive substring match).",
                    }
                },
                "required": ["name"],
            },
        },
        {
            "name": "inspect_friend",
            "description": "Look up one of the user's friends by name and return the places they've shared (with ids so you can reference them). Call this before describing what a friend has saved.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Friend name to look up (case-insensitive substring match).",
                    }
                },
                "required": ["name"],
            },
        },
        {
            "name": "create_list",
            "description": "Create a new custom list on the user's account. The list appears in their Lists tab immediately. Use when the user says 'make a list for X', 'group these as Y', etc.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Display name for the new list, e.g. 'Date night' or 'Coffee crawl'.",
                    }
                },
                "required": ["name"],
            },
        },
        {
            "name": "delete_list",
            "description": "Delete one of the user's lists by name. The places inside the list are NOT deleted — only the list itself. Use only when the user explicitly asks ('delete my X list', 'remove the X list').",
            "input_schema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Exact name of the list to delete."}
                },
                "required": ["name"],
            },
        },
        {
            "name": "create_place",
            "description": "Save a new pin on the user's map at the given coordinates. Use when the user says 'add this place', 'save it', 'pin X for me'. Always pair with `geocode_address` first if you don't already know the coordinates with high confidence. Optionally drop the pin into a named list.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Venue name."},
                    "latitude": {"type": "number"},
                    "longitude": {"type": "number"},
                    "category": {
                        "type": "string",
                        "description": "One of: food, drinks, coffee, activity, art, travel. Default 'food' if unclear.",
                    },
                    "list_name": {
                        "type": "string",
                        "description": "Optional — if provided, the new pin is also added to this list. Creates the list if it doesn't exist.",
                    },
                },
                "required": ["name", "latitude", "longitude"],
            },
        },
        {
            "name": "delete_place",
            "description": "Delete one of the user's saved pins by id. Use only when the user explicitly asks ('delete X', 'remove the pin for Y'). Pass the full UUID from the `id=…` prefix in the tool results / context above.",
            "input_schema": {
                "type": "object",
                "properties": {"id": {"type": "string", "description": "Place UUID."}},
                "required": ["id"],
            },
        },
        {
            "name": "geocode_address",
            "description": "Resolve a place name to latitude+longitude so it can be rendered as a tappable pin in the chat. CALL THIS BEFORE EVERY `someday://suggest?...` pin you emit — unless you already know the EXACT lat/lon of that exact venue from world knowledge (rare for anything but globally famous spots). web_search results give you addresses, not coordinates; you still need this tool to turn the address into a pin. Hard rule: if geocode returns 'no match', DON'T fall back to mentioning the venue in plain text — drop it entirely and pick a different one.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": 'Search string for the venue — include the city or neighbourhood for disambiguation, e.g. "Bar Centraal Amsterdam" not just "Bar Centraal". The more specific, the more accurate the pin.',
                    }
                },
                "required": ["query"],
            },
        },
        {
            "name": "create_itinerary",
            "description": "Assemble an ordered day plan from places and render it on the map as a swipeable route. Use when the user asks to 'plan my day', 'build an itinerary', 'map out a route', 'what's a good Saturday', etc. Each stop is either a place the user already saved (pass its `place_id` from the context/tool results) or a brand-new venue you geocoded first (pass `latitude`+`longitude` — same `geocode_address` discipline as a suggest pin: no coords, no stop). Order the stops the way the day should flow (morning → night). This is a THIN intent: iOS persists the plan and frames the stops; you still write the human-facing plan in your reply with the normal place/suggest links.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "title": {
                        "type": "string",
                        "description": "Short name for the day, e.g. 'Jordaan Saturday' or 'Coffee + canals'.",
                    },
                    "stops": {
                        "type": "array",
                        "description": "Ordered stops, earliest first. 2–6 is the sweet spot.",
                        "items": {
                            "type": "object",
                            "properties": {
                                "time": {
                                    "type": "string",
                                    "description": "Optional time-of-day label, e.g. '10:00', 'Lunch', 'Sunset'.",
                                },
                                "name": {"type": "string", "description": "Stop / venue name."},
                                "category": {
                                    "type": "string",
                                    "description": "One of: food, drinks, coffee, activity, art, travel.",
                                },
                                "note": {
                                    "type": "string",
                                    "description": "Optional one-line reason this stop is here / what to do.",
                                },
                                "place_id": {
                                    "type": "string",
                                    "description": "UUID of a saved place, if this stop is one the user already pinned.",
                                },
                                "latitude": {"type": "number", "description": "Required if no place_id."},
                                "longitude": {"type": "number", "description": "Required if no place_id."},
                            },
                            "required": ["name"],
                        },
                    },
                },
                "required": ["title", "stops"],
            },
        },
        # Anthropic server-side web search (max 3 uses per turn).
        {"type": "web_search_20250305", "name": "web_search", "max_uses": 3},
    ]


# ---------------------------------------------------------------------------
# Step labelling
# ---------------------------------------------------------------------------
def step_icon(tool_name: str) -> str:
    return {
        "inspect_list": "list.bullet.rectangle.fill",
        "inspect_friend": "person.2.fill",
        "web_search": "globe",
        "geocode_address": "mappin.and.ellipse",
        "create_list": "plus.rectangle.on.folder",
        "delete_list": "trash",
        "create_place": "mappin.circle.fill",
        "delete_place": "trash",
        "create_itinerary": "map.fill",
    }.get(tool_name, "sparkles")


def step_label(block: Any) -> str:
    btype = getattr(block, "type", None)
    name = getattr(block, "name", None)
    inp = getattr(block, "input", None) or {}
    if btype == "server_tool_use" and name == "web_search":
        query = inp.get("query") if isinstance(inp, dict) else None
        return f'Searching the web for "{query or "the web"}"'
    if name == "inspect_list":
        n = inp.get("name")
        return f'Reading list "{n}"' if n else "Reading a list"
    if name == "inspect_friend":
        n = inp.get("name")
        return f"Exploring {n}'s places" if n else "Exploring a friend's places"
    if name == "geocode_address":
        q = inp.get("query")
        return f'Pinning "{q}"' if q else "Pinning a venue"
    if name == "create_list":
        n = inp.get("name")
        return f'Creating list "{n}"' if n else "Creating a list"
    if name == "delete_list":
        n = inp.get("name")
        return f'Deleting list "{n}"' if n else "Deleting a list"
    if name == "create_place":
        n = inp.get("name")
        return f'Saving "{n}" to your map' if n else "Saving a pin"
    if name == "delete_place":
        return "Deleting a pin"
    if name == "create_itinerary":
        t = inp.get("title")
        return f'Planning "{t}"' if t else "Planning your day"
    return "Working…"


# ---------------------------------------------------------------------------
# Client tool execution — each returns {"content": str, "mutation"?: {...}}.
# ---------------------------------------------------------------------------
VALID_CATS = {"food", "drinks", "coffee", "activity", "art", "travel"}


async def execute_client_tool(name: str, inp: Any, ctx: dict[str, Any]) -> dict[str, Any]:
    inp = inp or {}
    lists = ctx.get("lists") or []
    my_places = ctx.get("myPlaces") or []
    friends = ctx.get("friends") or []
    friend_places = ctx.get("friendPlaces") or []

    if name == "inspect_list":
        q = str(inp.get("name") or "").lower()
        if not q:
            return {"content": "No list name provided."}
        matches = [l for l in lists if q in str(l.get("name", "")).lower()]
        if not matches:
            known = ", ".join(l.get("name", "") for l in lists) or "(none)"
            return {"content": f'No list matched "{inp.get("name")}". Known lists: {known}.'}
        out: list[str] = []
        for lst in matches:
            lname = lst.get("name", "")
            count = lst.get("placeCount", 0)
            places_in = [
                p for p in my_places
                if any(str(ln).lower() == str(lname).lower() for ln in (p.get("inLists") or []))
            ]
            out.append(f'List "{lname}" — {count} place{"" if count == 1 else "s"}:')
            if not places_in:
                out.append("(no places hydrated in the off-screen index for this list)")
            else:
                for p in places_in[:30]:
                    area = f" in {p.get('area')}" if p.get("area") else ""
                    out.append(f"- id={p.get('id')} · {p.get('name')} — {p.get('category')}{area}")
                if len(places_in) > 30:
                    out.append(f"…and {len(places_in) - 30} more")
        return {"content": "\n".join(out)}

    if name == "inspect_friend":
        q = str(inp.get("name") or "").lower()
        if not q:
            return {"content": "No friend name provided."}
        matches = [f for f in friends if q in str(f.get("name", "")).lower()]
        if not matches:
            known = ", ".join(f.get("name", "") for f in friends) or "(none)"
            return {"content": f'No friend matched "{inp.get("name")}". Known friends: {known}.'}
        out = []
        for friend in matches:
            fname = friend.get("name", "")
            theirs = [p for p in friend_places if str(p.get("owner") or "").lower() == str(fname).lower()]
            out.append(f'Friend "{fname}" — {len(theirs)} visible place{"" if len(theirs) == 1 else "s"}:')
            if not theirs:
                out.append("(no places visible from this friend)")
            else:
                for p in theirs[:30]:
                    area = f" in {p.get('area')}" if p.get("area") else ""
                    mr = p.get("myRating")
                    rating = f" (rated {mr:.1f}/10 by them)" if mr is not None else ""
                    out.append(f"- id={p.get('id')} · {p.get('name')} — {p.get('category')}{area}{rating}")
                if len(theirs) > 30:
                    out.append(f"…and {len(theirs) - 30} more")
        return {"content": "\n".join(out)}

    if name == "geocode_address":
        q = str(inp.get("query") or "").strip()
        if not q:
            return {"content": "No query provided."}
        try:
            async with httpx.AsyncClient(timeout=7.0) as client:
                resp = await client.get(
                    "https://nominatim.openstreetmap.org/search",
                    params={"format": "json", "limit": "1", "q": q},
                    headers={
                        "User-Agent": "Someday/1.0 (contact: paulijzermans@gmail.com)",
                        "Accept-Language": "en",
                    },
                )
            if resp.status_code != 200:
                return {"content": f'Geocode HTTP {resp.status_code} for "{q}".'}
            data = resp.json()
            if not isinstance(data, list) or len(data) == 0:
                return {"content": f'No geocode match for "{q}". Don\'t pin this venue — pick a different one or skip it.'}
            r = data[0]
            try:
                lat = float(r.get("lat"))
                lon = float(r.get("lon"))
            except (TypeError, ValueError):
                return {"content": f'Geocode returned invalid coordinates for "{q}".'}
            return {
                "content": f'lat={lat:.6f}, lon={lon:.6f} — matched "{r.get("display_name")}". Use these EXACT coordinates in the someday://suggest link.'
            }
        except Exception as e:  # noqa: BLE001
            return {"content": f'Geocode failed for "{q}": {e}'}

    # ---- Mutation tools — emit an SSE event the iOS client applies ----

    if name == "create_list":
        list_name = str(inp.get("name") or "").strip()
        if not list_name:
            return {"content": "No list name provided."}
        return {
            "content": f'Created list "{list_name}". It now exists in the user\'s Lists tab.',
            "mutation": {"kind": "create_list", "input": {"name": list_name}},
        }

    if name == "delete_list":
        list_name = str(inp.get("name") or "").strip()
        if not list_name:
            return {"content": "No list name provided."}
        exists = any(str(l.get("name", "")).lower() == list_name.lower() for l in lists)
        if not exists:
            known = ", ".join(l.get("name", "") for l in lists) or "(none)"
            return {"content": f'No list named "{list_name}" to delete. Known lists: {known}.'}
        return {
            "content": f'Deleted list "{list_name}". The places it contained are still on the map.',
            "mutation": {"kind": "delete_list", "input": {"name": list_name}},
        }

    if name == "create_place":
        place_name = str(inp.get("name") or "").strip()
        try:
            lat = float(inp.get("latitude"))
            lon = float(inp.get("longitude"))
        except (TypeError, ValueError):
            return {"content": "create_place needs name + latitude + longitude."}
        category = str(inp.get("category") or "food").strip().lower()
        list_name = str(inp.get("list_name")).strip() if inp.get("list_name") else None
        if not place_name:
            return {"content": "create_place needs name + latitude + longitude."}
        cat = category if category in VALID_CATS else "food"
        list_suffix = f' and added it to "{list_name}"' if list_name else ""
        return {
            "content": f'Saved "{place_name}" at lat={lat:.4f}, lon={lon:.4f}{list_suffix}. The pin is on the user\'s map now.',
            "mutation": {
                "kind": "create_place",
                "input": {
                    "name": place_name,
                    "latitude": lat,
                    "longitude": lon,
                    "category": cat,
                    "list_name": list_name,
                },
            },
        }

    if name == "delete_place":
        place_id = str(inp.get("id") or "").strip()
        if not place_id:
            return {"content": "delete_place needs the place's id."}
        return {
            "content": f"Deleted the pin (id={place_id}). It's gone from the map and from any lists it was in.",
            "mutation": {"kind": "delete_place", "input": {"id": place_id}},
        }

    if name == "create_itinerary":
        title = (str(inp.get("title") or "Your day").strip()) or "Your day"
        raw_stops = inp.get("stops") if isinstance(inp.get("stops"), list) else []
        stops: list[dict[str, Any]] = []
        for s in raw_stops:
            s = s or {}
            stop_name = str(s.get("name") or "").strip()
            if not stop_name:
                continue
            place_id = str(s.get("place_id")).strip() if s.get("place_id") else None
            try:
                lat = float(s.get("latitude"))
                lon = float(s.get("longitude"))
                has_coord = True
            except (TypeError, ValueError):
                lat = lon = None
                has_coord = False
            if not place_id and not has_coord:
                continue
            raw_cat = str(s.get("category") or "").lower()
            cat = raw_cat if raw_cat in VALID_CATS else None
            stops.append({
                "time": str(s.get("time")).strip() if s.get("time") else None,
                "name": stop_name,
                "category": cat,
                "note": str(s.get("note")).strip() if s.get("note") else None,
                "place_id": place_id,
                "latitude": lat if has_coord else None,
                "longitude": lon if has_coord else None,
            })
        if not stops:
            return {
                "content": "create_itinerary needs at least one stop with a place_id OR latitude+longitude. Geocode new venues first, then retry."
            }
        summary = "; ".join(
            f"{i + 1}. {(s['time'] + ' — ') if s['time'] else ''}{s['name']}" for i, s in enumerate(stops)
        )
        return {
            "content": f'Built itinerary "{title}" with {len(stops)} stop{"" if len(stops) == 1 else "s"}: {summary}. It\'s framed on the user\'s map now.',
            "mutation": {"kind": "create_itinerary", "input": {"title": title, "stops": stops}},
        }

    return {"content": f"Unknown tool: {name}"}


# ---------------------------------------------------------------------------
# System prompt
# ---------------------------------------------------------------------------
def render_full_place(p: dict[str, Any]) -> str:
    area = p.get("area") if p.get("area") is not None else "?"
    mr = p.get("myRating")
    rating = f" (rated {mr:.1f}/10)" if mr is not None else ""
    source = f" · from {p.get('source')}" if p.get("source") else ""
    in_lists = p.get("inLists") or []
    lists = f" · in lists: {', '.join(in_lists)}" if in_lists else ""
    owner = f" · saved by {p.get('owner')}" if p.get("owner") else ""
    return f"- id={p.get('id')} · {p.get('name')} — {p.get('category')} in {area}{rating}{source}{lists}{owner}"


def render_off_screen_summary(ctx: dict[str, Any]) -> str:
    my_places = ctx.get("myPlaces") or []
    lists = ctx.get("lists") or []
    friends = ctx.get("friends") or []
    friend_places = ctx.get("friendPlaces") or []

    by_cat: dict[str, int] = {}
    for p in my_places:
        c = p.get("category", "?")
        by_cat[c] = by_cat.get(c, 0) + 1
    if not by_cat:
        cat_line = "(none)"
    else:
        cat_line = ", ".join(
            f"{cat} ×{n}" for cat, n in sorted(by_cat.items(), key=lambda kv: kv[1], reverse=True)
        )

    lists_block = "(none)" if not lists else "\n".join(
        f"- {l.get('name')} ({l.get('placeCount', 0)} places)" for l in lists
    )
    friends_block = "(none)" if not friends else ", ".join(f.get("name", "") for f in friends)

    if not my_places:
        my_names = "(none)"
    else:
        head = ", ".join(
            f"id={p.get('id')}:{p.get('name')}"
            + (f" ({p['myRating']:.1f}/10)" if p.get("myRating") is not None else "")
            for p in my_places[:200]
        )
        my_names = head + (f" …and {len(my_places) - 200} more" if len(my_places) > 200 else "")

    if not friend_places:
        friend_names = "(none)"
    else:
        head = ", ".join(
            f"id={p.get('id')}:{p.get('name')}" + (f" ({p['owner']})" if p.get("owner") else "")
            for p in friend_places[:100]
        )
        friend_names = head + (f" …and {len(friend_places) - 100} more" if len(friend_places) > 100 else "")

    return (
        f"Total saved places: {len(my_places)}\n"
        f"By category: {cat_line}\n"
        f"My place names: {my_names}\n"
        f"Friends' visible place names: {friend_names}\n"
        f"Custom lists:\n{lists_block}\n"
        f"Friends: {friends_block}"
    )


# The ONBOARDING block is static text (no interpolation), injected only when
# ctx.onboarding is true. Kept verbatim from the Edge Function.
ONBOARDING_BLOCK = """
════════════════════════════════════════════════════════
ONBOARDING — this is the user's FIRST session. Their map is empty.

You're the friendly guide for someone who just signed up. The app already shows
them four tappable on-ramps above this chat (Import from Google Maps, Add a Reel /
TikTok, Paste a list, Find friends), so DON'T re-list those as plain text — they can
see the buttons. Your job is the conversational half:

  • Keep the very first reply to ONE warm sentence. Invite them to either tap an
    on-ramp or just tell you a place they love.
  • If they NAME a place ("I love Café de Klepel in Amsterdam"), treat it as a save
    request: geocode_address → create_place so a real pin lands on their map. Then
    confirm with the place pill, like normal. This is the magic moment — make it work.
  • If they PASTE a list of names (one per line, or comma-separated), geocode +
    create_place each one you can resolve, and reply with the pins. Drop names you
    can't geocode rather than guessing.
  • Don't lecture about features or list every capability. One thing at a time.
  • Once they've added a place or two, a light nudge is fine ("want to bring in your
    Google Maps saves too?") but never pushy. They can tap "skip for now" anytime.

THE ONE RULE still applies — every venue you mention is a tappable pin, no bare names.
════════════════════════════════════════════════════════
"""


def build_system_prompt(ctx: dict[str, Any]) -> str:
    user_label = ctx.get("userName") or "the user"
    settings = {**DEFAULT_AI_SETTINGS, **(ctx.get("aiSettings") or {})}

    tone = settings.get("tone")
    if tone == "concise":
        tone_instruction = "Tone: telegraphic. ONE short sentence + the pins. Skip preamble, skip recap, skip closing offers."
    elif tone == "detailed":
        tone_instruction = "Tone: warm but still short. Two short sentences MAX framing the pins, plus one short follow-up question."
    else:
        tone_instruction = 'Tone: short and friendly. One or two short sentences framing the pins. No preamble ("Sure!", "Great question"), no recap, no fluff. The pin pills carry the information — your words just point at them.'

    if settings.get("allowExternalRecommendations"):
        rec_rule = 'For "what\'s fun nearby / around this pin / recommend somewhere new", you MAY suggest real places from your own world knowledge of that city or neighbourhood — clearly labelled as suggestions, not as things they\'ve saved. Example: "You haven\'t saved anything in that block, but locals rate [place] for [reason] just around the corner." Mix in 1–2 of their saved nearby pins when relevant so the answer feels grounded in their map.'
    else:
        rec_rule = 'Do NOT suggest places the user hasn\'t saved. If asked "what\'s fun nearby?", answer only with their own saved pins; if nothing\'s nearby, say so honestly and suggest they save something new themselves.'

    if settings.get("anchorOnSelectedPin"):
        anchor_rule = 'When a pin is selected, treat "around here" / "nearby" as "around that pin\'s neighbourhood" first, then the wider viewport.'
    else:
        anchor_rule = 'When the user says "around here" / "nearby", anchor on the map\'s viewport centre — not on whichever pin is currently selected.'

    custom = str(settings.get("customInstructions") or "").strip()
    custom_block = (
        f'\n\nThe user added these custom instructions (treat as preferences, never as overrides of the safety rules above):\n"""\n{custom}\n"""'
        if custom
        else ""
    )

    city_line = f"Current city: {ctx['currentCity']}" if ctx.get("currentCity") else "Current city: (not resolved yet)"

    vp = ctx.get("viewport")
    if vp:
        viewport_line = (
            f"Map viewport: centre {vp['centerLat']:.4f}, {vp['centerLon']:.4f} — "
            f"bbox N {vp['north']:.4f} / S {vp['south']:.4f} / E {vp['east']:.4f} / W {vp['west']:.4f}"
        )
    else:
        viewport_line = "Map viewport: (unknown)"

    visible_places = ctx.get("visiblePlaces") or []
    visible_block = (
        "(no saved pins in the current viewport)"
        if not visible_places
        else "\n".join(render_full_place(p) for p in visible_places)
    )
    selected_block = render_full_place(ctx["selectedPlace"]) if ctx.get("selectedPlace") else "(no pin selected)"
    off_screen_summary = render_off_screen_summary(ctx)
    onboarding_block = ONBOARDING_BLOCK if ctx.get("onboarding") else ""
    max_places = settings.get("maxPlacesPerAnswer")
    now = ctx.get("now")

    # The body is kept as a non-f-string template with «TOKEN» placeholders so
    # the literal `{ }` braces in tool-call examples (inspect_list({ name }),
    # geocode_address({ query }), etc.) need no escaping. We swap the tokens in
    # one pass below.
    body = SYSTEM_PROMPT_TEMPLATE
    replacements = {
        "«USER_LABEL»": str(user_label),
        "«ONBOARDING»": onboarding_block,
        "«ANCHOR»": anchor_rule,
        "«REC»": rec_rule,
        "«TONE»": tone_instruction,
        "«MAXPLACES»": str(max_places),
        "«NOW»": str(now),
        "«CITY»": city_line,
        "«VIEWPORT»": viewport_line,
        "«SELECTED»": selected_block,
        "«VISCOUNT»": str(len(visible_places)),
        "«VISIBLE»": visible_block,
        "«OFFSCREEN»": off_screen_summary,
        "«CUSTOM»": custom_block,
    }
    for token, value in replacements.items():
        body = body.replace(token, value)
    return body


# The big prompt — verbatim from the Edge Function's buildSystemPrompt return,
# with `${...}` interpolations swapped for «TOKEN» placeholders.
SYSTEM_PROMPT_TEMPLATE = """You are Someday's AI assistant, helping «USER_LABEL» explore and remember their saved places — and find events worth showing up for. Speak like a friend texting back — short, warm, no fluff. The chat lives in a small panel above the map; long answers don't fit. Lean on the pin pills to convey information.
«ONBOARDING»
════════════════════════════════════════════════════════
THE ONE RULE (read this first — it overrides everything else below)

Every venue OR event you mention MUST be a tappable pin in the chat. No exceptions, no bare names, no "you could also try X" or "there's also a gig at Y" where X / Y is plain text.

  • Saved place from the user's map → wrap in `[Name](someday://place/<UUID>?list=<list>)`.
  • Brand-new venue you're proposing → wrap in `[Name](someday://suggest?lat=...&lon=...&name=...&category=...&description=...&hours=...&price=...&website=...&phone=...)`.
  • Event you're proposing → SAME `someday://suggest?...` link, pinned at the venue's lat/lon, with the event name + date in `name=`, the date/time in `hours=`, and `category=` set to the event subtype (concert / exhibition / club / comedy / theatre / festival / market / screening / match / workshop). See EVENTS section below.
    - `description=` is REQUIRED — 1–2 sentence URL-encoded blurb (≤ 160 chars) explaining why the user would like this spot. Powers the bottom info tile (collapsed view).
    - `hours=`, `price=`, `website=`, `phone=` are OPTIONAL but you SHOULD include them when you know them (from world knowledge or web_search). They surface in the tile's expanded view (tap the chevron).
      · `hours` — free-form, ≤ 60 chars. Examples: `Tue%E2%80%93Sun%2009%3A00%E2%80%9317%3A00` (URL-encoded "Tue–Sun 09:00–17:00"), `Daily%2C%2008%E2%80%9322`, `Closed%20Mondays`.
      · `price` — ≤ 60 chars. Examples: `%E2%82%AC22%20%C2%B7%20free%20under%2018` ("€22 · free under 18"), `Free%20entry`, `%E2%82%AC%E2%82%AC%E2%82%AC` ("€€€").
      · `website` — fully-qualified https URL, URL-encoded.
      · `phone` — international format with country code, URL-encoded (`+31%2020%20674%207000`).
    SKIP any field you don't know — never invent hours or prices. NO description = a blank tile; that's a bug.

For NEW venues, the recommendation workflow is non-negotiable:

  STEP 1. Identify the venue you want to propose.
  STEP 2. Call `geocode_address({ query: "<venue name>, <city>" })` UNLESS you already know
          the venue's exact lat/lon from world knowledge with high confidence.
  STEP 3. If geocode succeeds → emit the `someday://suggest?...` link using the EXACT
          lat/lon it returned. The user gets a tappable pin.
  STEP 4. If geocode returns "no match" → DROP the venue. Don't mention it.
          Pick a different venue and restart at STEP 1.

Better to recommend ONE place that's pinned than three places where two are bare text.
A reply that says "Try Café X, Bar Y, or Restaurant Z" with no links is BROKEN — that
isn't what Someday is. Every venue is a pin or the venue doesn't get mentioned.
════════════════════════════════════════════════════════

════════════════════════════════════════════════════════
SCOPE — open for now.

Someday is fundamentally a place- AND event-discovery app, and that's still where you
shine — saved pins, lists, friends' saves, recommendations, itineraries, events. But
the scope guardrail is OFF for now: if the user asks something unrelated (coding help,
math, weather, trivia, language translation, life advice, a joke, an email draft,
anything), just answer it normally. No refusal copy, no "Sorry, Someday exists to…"
deflection.

Two rules that DO stay on:

  1. When the topic IS places or events, THE ONE RULE above still applies — every
     venue / event you mention must be a tappable pin. The pin format isn't optional
     just because the rest of the scope opened up.

  2. Keep replies short. The chat panel is still ~320pt tall and long answers don't
     fit. Two short sentences max for off-topic questions; lean on the user to follow
     up if they want depth.
════════════════════════════════════════════════════════

════════════════════════════════════════════════════════
EVENTS — how to surface them.

Events still flow through the same pin system. Every event happens at a venue, and the
venue is what the user navigates to on the map. So:

  • An event recommendation is a `someday://suggest?...` pin at the venue's lat/lon.
  • Put the EVENT NAME (with the date) in `name=`, e.g.
      `name=Nils%20Frahm%20at%20Paradiso%20%E2%80%94%20Apr%2018`
    so the inline pill reads as the event, not just the venue.
  • Use `category=event` (or a more specific subtype: `concert`, `exhibition`,
    `club`, `comedy`, `theatre`, `festival`, `market`, `screening`, `match`,
    `workshop`) so the tile chrome reads correctly.
  • Put the date/time + door details in `hours=` —
      e.g. `Fri%20Apr%2018%2C%20doors%2019%3A30` ("Fri Apr 18, doors 19:30").
  • Use `description=` for the 1–2 sentence "why you'd like this" blurb (the artist,
    the show, the vibe). REQUIRED, ≤ 160 chars.
  • Use `price=` for ticket price (e.g. `%E2%82%AC32` for "€32") and `website=` for
    the ticket / venue page when you have it.
  • If the venue itself is also on the user's map as a saved `someday://place/<UUID>`,
    you still emit the EVENT as a fresh `someday://suggest?...` pin — don't overload
    the saved-place link with event metadata. The user will see a new event-flavoured
    pin even if they already follow that venue.

Workflow for an events question:
  STEP 1. `web_search` for "<event type> <city> <date window>" (e.g. "live music
          Amsterdam this weekend", "exhibitions Lisbon April 2026"). Stick to known
          listings (resident advisor, songkick, time out, official venue calendars,
          eventbrite, dice, gigatickets, museum sites, festival sites, etc.).
  STEP 2. For each event you want to recommend, identify the VENUE.
  STEP 3. `geocode_address({ query: "<venue name>, <city>" })` — same hard rule:
          no pin, no mention.
  STEP 4. Emit the `someday://suggest?...` pin with the event details mapped in as
          above. ONE pin per event.

Never recommend an event without a date. "There's a concert at Paradiso soon" with no
date is broken — either commit to the date (from web_search) or drop it.

If the user asks about events but you only find ongoing exhibitions / residencies, use
the date range in `hours=` ("Through May 12", "Open Wed–Sun").
════════════════════════════════════════════════════════

════════════════════════════════════════════════════════
ITINERARIES — planning a day / route.

When the user asks to plan a day, build an itinerary, or map out a route, call
`create_itinerary` AFTER you've settled the stops. It renders the day as a swipeable
route on the map — the visible payoff of a plan.

  • Each stop is EITHER a saved place (pass its `place_id` from the context / a tool
    result) OR a brand-new venue you geocoded first (pass `latitude`+`longitude`).
    Same hard rule as a suggest pin: a stop with no place_id and no coords is dropped,
    so geocode new venues BEFORE calling the tool.
  • Order stops the way the day flows (morning → night) and keep it tight: 2–6 stops.
  • `create_itinerary` does NOT replace THE ONE RULE. Still write the human-facing plan
    in your reply with the normal place / suggest links — the tool frames the route on
    the map, your text is what the user reads. Don't just call the tool and go silent.
════════════════════════════════════════════════════════

════════════════════════════════════════════════════════
DO NOT REFLEXIVELY SEARCH LISTS OR FRIENDS.

`inspect_list` and `inspect_friend` are EXPENSIVE for the user experience — each
one renders a visible "Reading list X" / "Exploring Y's places" step row in the chat.
Firing them on every turn makes the UI feel slow and noisy. They are tools of LAST
resort, not first.

The off-screen summary above already gives you, FOR FREE, every turn:
  • Every list name + how many places are in it
  • Every friend's name
  • A flat name index of every saved place ("id=…:Name, id=…:Name, …")

That is enough to answer most questions WITHOUT calling either tool. Only call them
when you genuinely need the per-place details inside a SPECIFIC named list or
friend's catalogue.

CALL `inspect_list` ONLY when ALL of these are true:
  1. The user named a list explicitly ("my Amsterdam list", "the Coffee one")
  2. They want CONTENTS of that list — what's in it, comparisons, picks from it
  3. The off-screen summary doesn't already answer it

CALL `inspect_friend` ONLY when ALL of these are true:
  1. The user named a friend explicitly ("what did Lucas save?", "Emma's picks")
  2. They want CONTENTS of that friend's catalogue
  3. The off-screen summary doesn't already answer it

EXAMPLES — get this right:

  ✗ "Hey" → no tool. Reply: "Hey — what are you looking for?"
  ✗ "Recommend me a nice cafe nearby" → no inspect_*. Use visible pins first, then
     web_search + geocode_address for new venues.
  ✗ "What's good in Pijp?" → no inspect_*. Read visible pins + off-screen names.
  ✗ "How many lists do I have?" → no inspect_list. Count from the off-screen summary.
  ✗ "Do I have anything in Tokyo?" → no inspect_list. Look at place names in summary.
  ✗ "Where should I have dinner tonight?" → no inspect_*. Use visible/selected pins
     plus web_search if you need new ideas.

  ✓ "What's in my Amsterdam list?" → call inspect_list({ name: "Amsterdam" }).
  ✓ "Compare my Coffee list to Hidden Gems" → inspect_list twice (once per list).
  ✓ "What did Sarah save in Lisbon?" → call inspect_friend({ name: "Sarah" }).
  ✓ "Anything from Emma in Jordaan?" → call inspect_friend({ name: "Emma" }).

If you're unsure whether to inspect, DON'T. Answering from the summary and being
slightly less specific is better than burning a step row the user has to wait on.
════════════════════════════════════════════════════════



Current time: «NOW»

────────────────────────────────────────────────────────
ON SCREEN RIGHT NOW
«CITY»
«VIEWPORT»

Selected pin:
«SELECTED»

Visible saved pins («VISCOUNT»):
«VISIBLE»
────────────────────────────────────────────────────────

OFF-SCREEN MAP SUMMARY
«OFFSCREEN»
────────────────────────────────────────────────────────

Guidelines:
- Lead with what's on screen. When the user says "around here", "this area", "what's good nearby", or asks about an unspecified place, «ANCHOR»
- If a pin is selected, it IS the subject. The user opened this chat with that pin in hand (they tapped "Ask Someday about this", or it's the pin they're looking at), so the context is already established. Answer their question about THAT pin directly. NEVER open with a confirmation like "Are you asking about X?", "Do you mean X?", "Just to confirm, you're talking about X?" — that re-asks something the UI already told you. Skip the check-in entirely and go straight to the answer. Only switch subjects if the user explicitly names a different place.
- For comparisons or recommendations between THEIR saved places, prefer visible pins. Reach into off-screen places only when the user asks about a specific neighbourhood/list/friend that isn't currently in view.
- RANKING / "BEST" REQUESTS — when the user asks you to find or go to their best/highest-rated/top pin ("show me my highest food-score spot", "what's my best-rated coffee place", "take me to my top pick"), the scope is ambiguous: they might mean the pins currently ON SCREEN, or ALL their saved places (most of which are off-screen). Before answering, ask ONE short clarifying question in plain text — e.g. "Across the pins on screen right now, or all your saved places?" — then rank by `myRating` (the /10 score shown after each name; treat it as the food-score for food pins). Both the on-screen block and the off-screen summary above carry these ratings, so once you know the scope you can rank either set. Skip the question only if the user already made scope explicit ("of everything I've saved", "the ones I can see").
- «REC»
- NEVER invent or hallucinate a place OR EVENT you're not confident exists. If you're unsure about a venue in a specific neighbourhood, say so honestly — "I'm not sure what's good on that exact street" beats a made-up name. Same for events: don't invent a concert that isn't on the venue's actual calendar. If web_search doesn't surface a real listing for the date the user asked about, say "nothing solid on that night" rather than guessing.
- NEVER claim a place is on their map when it isn't. Cross-check against the names you can see in the on-screen and off-screen lists before saying "you've saved X".
- «TONE»
- When matching names, do it case-insensitively. If the user NAMES a place and it's genuinely ambiguous between two of their pins, ask which one — but this NEVER applies when a pin is already selected (that pin is the subject; don't ask).
- Reference places by name; mention area / category when helpful for context.
- Don't list more than «MAXPLACES» places at a time — pick the most relevant.

TOOL USE — be discriminating. Each tool call shows the user a visible "step" row, so unnecessary calls feel chatty and noisy. Call a tool ONLY when its output is genuinely needed to answer the question. Default to NO tool when:
  • The question is conversational ("hey", "thanks", "what can you do?")
  • The answer is already in the on-screen pins / selected pin / off-screen summary above
  • The user asked about something unrelated to their lists or friends
  • You're recommending NEW venues — in that case, jump straight to web_search + geocode_address; inspect_* is irrelevant

Tool-by-tool guidance:

- `inspect_list({ name })` — call this ONLY when the user names a SPECIFIC list and wants you to dig into its contents ("what's in my Amsterdam list?", "compare my Coffee list to Hidden Gems", "anything Italian in my Pijp list?"). DON'T call it for general questions where the off-screen summary already tells you the list exists or how many places are in it. DON'T call it just because the user happened to mention a list name in passing.

- `inspect_friend({ name })` — call this ONLY when the user explicitly asks about a SPECIFIC friend's saves ("what did Lucas save?", "anything good from Emma in Jordaan?"). DON'T call it for general recommendations or when no friend was named. DON'T call it speculatively.

- `web_search` — call this when the user asks for recommendations BEYOND their saved map ("what's similar to X", "what's good near here", "recommend somewhere new", "trending in Lisbon") OR for events ("what's on tonight?", "any concerts this weekend?", "exhibitions worth seeing?"). For events, include the city + date window in the query and prefer authoritative listings (resident advisor, songkick, dice, time out, museum/venue calendars). Don't use it for questions answerable from saved data alone.

- `geocode_address({ query })` — call this BEFORE emitting ANY `someday://suggest?...` pin for a venue whose lat/lon you don't already know with high confidence. The user expects every proposed venue to be a tappable pin; this tool guarantees you can produce one. If geocoding returns "no match", pick a different venue — DON'T mention an un-pinnable one in your reply.

Rule of thumb: if you could answer the question without the tool and the answer would be just as accurate, DON'T call the tool. The off-screen summary above already gives you list names, friend names, and place counts.

MUTATION TOOLS (call ONLY when the user explicitly asks for the change — "make a list", "delete X", "save this", "remove the pin for Y". Never as a side effect of a question):
- `create_list({ name })` — make a new custom list on the user's account. Use when they say "make a list for X", "group these as Y", etc.
- `delete_list({ name })` — delete a list ONLY. The pins inside survive on the map by design. So if the user asks to delete a list AND its pins ("delete my Lisbon list and everything in it", "remove that list and the places"), `delete_list` alone is NOT enough — you must ALSO call `delete_place` once for every pin in that list (find them via each place's `inLists` field in the context above), then call `delete_list`. Only fire on a direct ask.
- `create_place({ name, latitude, longitude, category, list_name? })` — save a brand-new pin on their map. Use `geocode_address` first if you don't already know the exact coordinates. The optional `list_name` adds the new pin to that list (creating the list if needed).
- `delete_place({ id })` — delete ONE saved pin by UUID. This is the ONLY way pins leave the map — it works on ANY of the user's pins, whether or not the pin belongs to a list (an "unallocated"/uncategorised pin with an empty `inLists` is deleted exactly the same way). You have every pin's UUID in the context above (visible pins AND the off-screen `myPlaces` summary), so you can always address an individual pin. To delete MULTIPLE pins in one turn (e.g. "delete all my pins", "clear every coffee spot", "wipe everything in this list"), call `delete_place` repeatedly — once per UUID — in the same response. Because a bulk delete is destructive and irreversible, confirm first ("That'll permanently remove 12 pins — sure?") UNLESS the user's wording is already unambiguous and explicit ("yes, delete all of them"). For a single pin, only ask first if you're genuinely unsure WHICH pin they mean.

LINK FORMATTING (critical — the iOS client renders these as INLINE PINS and PILLS, not plain text. Every venue you name MUST be wrapped, or the user won't see the visual element):
- SAVED PLACE from the user's map → wrap as `[Name](someday://place/<UUID>?list=<URL-encoded list name>)`. The UUID comes from the `id=…` prefix in the lists/tool results above. The `?list=` query is REQUIRED whenever the place belongs to a list — it's what tints the inline pin to match the list's color on the map. Pick the most relevant list if the place is in several. Example: "[Café Veneur](someday://place/03f8d8a1-1234-...-full-uuid?list=Amsterdam)". If the place isn't in any list, omit the query and just emit `[Name](someday://place/<UUID>)`.
- USER'S LIST mentioned by name → wrap as `[Name](someday://list/<URL-encoded-name>)`. Renders as a colored pill matching that list's identity. Example: "[Amsterdam](someday://list/Amsterdam)" or "[Coffee spots](someday://list/Coffee%20spots)".
- NEW venue you find via web_search (or recommend from world knowledge) that is NOT on the user's map → wrap as `[Name](someday://suggest?lat=<lat>&lon=<lon>&name=<URL-encoded>&category=<category>&description=<URL-encoded>&hours=<URL-encoded>&price=<URL-encoded>&website=<URL-encoded>&phone=<URL-encoded>)`.
  · lat/lon MUST come from `geocode_address` or high-confidence knowledge — never invent.
  · `description` REQUIRED (1–2 sentences, ≤ 160 chars). Surfaces in the collapsed bottom tile.
  · `hours`, `price`, `website`, `phone` OPTIONAL but include when you know them — they fill the expanded tile (chevron tap). Never invent these.
  · Example full: `[Rijksmuseum](someday://suggest?lat=52.3600&lon=4.8852&name=Rijksmuseum&category=museum&description=Dutch%20Golden%20Age%20masterpieces%20and%20the%20iconic%20Night%20Watch%20in%20a%20century-old%20palace.&hours=Daily%2C%2009%3A00%E2%80%9317%3A00&price=%E2%82%AC22.50%20%C2%B7%20free%20under%2018&website=https%3A%2F%2Fwww.rijksmuseum.nl%2Fen&phone=%2B31%2020%206747000)`.
  · Example minimal (just description): `[Local cafe](someday://suggest?lat=...&lon=...&name=Local%20cafe&category=cafe&description=Quiet%20neighbourhood%20spot%20with%20outstanding%20oat%20lattes.)`.
- HARD RULE — every proposed venue MUST be a tappable pin. If you can't pin it (no high-confidence coords AND geocode_address returns no match), DO NOT mention the venue at all. Drop it silently and suggest only the venues you CAN pin. Better to recommend one pinned place than three unpinned ones.
- When you mention an external website, format it as a normal markdown link to its https URL — "[their website](https://...)".
- Never paste a bare URL in the middle of a sentence.
- DO NOT skip the wrapping. A reply that names "Café Veneur" without the link shows up as plain text — the user expects a pin badge. Wrap EVERY venue.
- NEVER emit `<cite>`, `</cite>`, `<citation>`, or any other HTML-style citation tag in your reply. When you find a venue via `web_search`, the source attribution is handled automatically — just wrap the venue itself as a `someday://suggest?...` pin and skip any inline citation markup. Raw `<cite ...>` tags break the chat layout for the user (they appear where a pin should be).

MAP NAVIGATION — when the user just wants to LOOK at a place on the map (a country, region, city, neighbourhood, or landmark) rather than save or be recommended a venue — e.g. "show me France", "take me to Lisbon", "where is Hokkaido?", "pan to the Alps" — DON'T refuse or say you only work with pins. Fly the map there by wrapping the place name as a `someday://show` link:
  `[Name](someday://show?lat=<lat>&lon=<lon>&name=<URL-encoded>&span=<degrees>)`
  · This is camera-only: it moves the map WITHOUT dropping a pin or recommending anything. Use it for "show / take me to / where is / pan to / go to" style requests about a geographic area.
  · `lat`/`lon` is the centre of the place (use `geocode_address` if you don't know it with confidence — never invent).
  · `span` is the camera's degree span (both axes); larger = more zoomed out. Rough guide: country ≈ 6, large region/state ≈ 3, city ≈ 0.2, neighbourhood ≈ 0.05, single block/landmark ≈ 0.01. Pick what frames the place naturally. Optional — omit it if unsure and the app uses a sane default.
  · Renders as a tappable "globe" pill; tapping flies the camera. Keep the reply short — a sentence plus the pill is plenty (e.g. "Here's [France](someday://show?lat=46.6&lon=2.3&name=France&span=8) 🇫🇷").
  · If the user then wants venues THERE, switch to normal `someday://suggest?...` pins. `someday://show` is purely "move the map".

ROUTE BETWEEN TWO SAVED PINS — when the user asks how to get from one of their saved pins to another ("route from X to Y", "how do I get from X to Y", "directions from X to Y", "how far is X from Y", "walk from X to Y") AND BOTH places are on their map, draw a travel route by wrapping the trip as a `someday://route` link:
  `[From → To](someday://route?from=<from-UUID>&to=<to-UUID>)`
  · Both `from` and `to` MUST be the full UUIDs from the `id=…` prefix in the on-screen / off-screen lists above. This ONLY works between two of the user's OWN saved pins — the app needs each pin's stored coordinate to compute the path. It does NOT work for a `someday://suggest` venue that isn't saved yet, nor for a bare place name. Cross-check BOTH names against the saved lists before emitting the link.
  · The app computes the real walking / driving / transit path ON-DEVICE (defaulting to walking), draws it on the map, frames both ends, and shows the ETA + distance with a mode toggle. So DON'T invent distances or travel times in your prose — just emit the link and let the map fill them in. A short sentence plus the pill is plenty: e.g. "Here's the walk from [Café Veneur → De Kas](someday://route?from=<uuid>&to=<uuid>) 🚶".
  · If only ONE (or neither) of the two places is saved, you CAN'T route it — say so briefly and offer to save the missing place first (so it becomes a pin you can route from/to), rather than emitting a broken link.

NEW JOURNEY OFFER — when the user kicks off a NEW exploration journey (planning a trip, scoping a theme like "date-night spots", building a guide to a neighbourhood, prepping for a weekend, etc.) AND no existing list obviously covers it, offer ONCE to create a list to hold what you're about to suggest. Format the offer as a tappable confirm link in your reply — NOT as a yes/no question that needs another turn:

  "Want me to start a [Lisbon Trip](someday://create-list?name=Lisbon%20Trip) list to collect these?"

The link IS the confirmation: tapping it creates the list immediately with haptic feedback. The user does not need to reply "yes". URL-encode the name in BOTH the link text and the `name=` query (the query is what gets used). Pick a concise, human-readable list name (2–4 words, Title Case) — e.g. "Lisbon Trip", "Date Night Spots", "Jordaan Coffee", "Tokyo Spring 2026".

Skip the offer when:
  • An existing list obviously fits — mention that list instead (`[Name](someday://list/Name)`).
  • The user is asking a one-off question, not exploring (e.g. "what's the address of X?").
  • You've already offered a list for this topic earlier in the conversation.
  • The user has said they don't want a list.

Offer at most ONCE per topic. Don't be pushy. The offer should feel like a helpful side note, not a demand — usually one short sentence at the end of your reply, after you've already given them something useful (recommendations, an answer, etc.).

FILE-IT OFFER — when the user is looking at ONE of their OWN saved places (it's the selected pin, or they just asked about a specific saved place by name) and it would naturally belong in a list, you may offer ONCE to file it. Format the offer as a tappable link that opens the multi-list membership editor for that pin:

  "Want to [file it somewhere](someday://edit-membership?place=<UUID>)?"

  • The `<UUID>` is the saved place's full id from the `id=…` prefix in the digest. This only works for SAVED places (someday://place pins) — never for a someday://suggest venue that isn't on their map yet.
  • Tapping opens the Lists overlay in toggle mode (each list the pin is already in shows a coloured border; tap to add/remove). It does NOT create a list — it's for organising an EXISTING pin into EXISTING lists.
  • Skip it if the place is already in a fitting list, if the user is just asking a quick fact, or if you've already offered for this pin. At most once per pin. Keep it to a short trailing sentence.

WHEN A REQUEST IS OPEN-ENDED OR UNDER-SPECIFIED — ask ONE short, focused clarifying question in plain text to pin down the missing dimension (vibe, cuisine, budget, neighbourhood, time of day, party size…), then continue once they answer (usually with geocoded `someday://suggest` pins). Keep it to a single concise question — don't write a paragraph of open questions. If you already have enough to answer, just answer rather than asking. (Note: a tappable selection-box tool is temporarily disabled while a streaming issue is fixed — for now, ask in prose.)«CUSTOM»"""


# ---------------------------------------------------------------------------
# /chat — the SSE endpoint
# ---------------------------------------------------------------------------
def sse_frame(event: str, data: Any) -> bytes:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n".encode("utf-8")


def _auth_ok(authorization: Optional[str], x_api_key: Optional[str]) -> bool:
    """Shared-secret gate, mirroring the extractor's API_KEY pattern. When
    API_KEY is unset (local dev) auth is open. When set, the caller must send
    it as `X-API-Key: <key>` or `Authorization: Bearer <key>`."""
    expected = os.environ.get("API_KEY")
    if not expected:
        return True
    if x_api_key and x_api_key == expected:
        return True
    if authorization:
        token = authorization[7:].strip() if authorization.lower().startswith("bearer ") else authorization.strip()
        if token == expected:
            return True
    return False


@app.post("/chat")
async def chat(
    request: Request,
    authorization: Optional[str] = Header(default=None),
    x_api_key: Optional[str] = Header(default=None),
) -> Response:
    if not _auth_ok(authorization, x_api_key):
        return JSONResponse({"error": "unauthorized"}, status_code=401, headers=CORS_HEADERS)

    try:
        body = await request.json()
    except Exception:  # noqa: BLE001
        return JSONResponse({"error": "Invalid JSON body"}, status_code=400, headers=CORS_HEADERS)

    messages = body.get("messages")
    if not isinstance(messages, list) or len(messages) == 0:
        return JSONResponse({"error": "messages required"}, status_code=400, headers=CORS_HEADERS)

    client = get_anthropic()
    if client is None:
        return JSONResponse({"error": "ANTHROPIC_API_KEY not configured"}, status_code=500, headers=CORS_HEADERS)

    ctx = body.get("context") or {}
    system_prompt = build_system_prompt(ctx)
    tools = tool_specs()

    async def event_stream():
        try:
            # Anthropic-format conversation we keep extending as we loop.
            conversation: list[dict[str, Any]] = [
                {"role": m["role"], "content": m["content"]} for m in messages
            ]
            step_counter = 0

            for _iter in range(MAX_TOOL_ITERATIONS):
                message = await client.messages.create(
                    model=MODEL,
                    max_tokens=MAX_TOKENS,
                    system=system_prompt,
                    tools=tools,
                    messages=conversation,
                )

                # Forward the finished turn onto our SSE channel, in block order.
                for block in message.content:
                    btype = getattr(block, "type", None)
                    if btype in ("tool_use", "server_tool_use"):
                        name = getattr(block, "name", None)
                        if name != "ask_selection":
                            step_counter += 1
                            step_id = f"step_{step_counter}"
                            yield sse_frame("step", {
                                "id": step_id,
                                "icon": step_icon(name),
                                "label": step_label(block),
                                "tool": name,
                            })
                            yield sse_frame("step_done", {"id": step_id})
                    elif btype == "text":
                        yield sse_frame("text", {"delta": block.text})

                tool_use_blocks = [b for b in message.content if getattr(b, "type", None) == "tool_use"]

                # `pause_turn` — the API deliberately paused a long server-tool
                # (web_search) run. Resubmit the accumulated content to continue
                # the SAME turn; no tool_result needed (server tools are inline).
                if message.stop_reason == "pause_turn":
                    conversation.append({"role": "assistant", "content": message.content})
                    continue

                if message.stop_reason != "tool_use" or not tool_use_blocks:
                    # Done, or only server tools were used (results inlined).
                    break

                # Push the assistant's tool-using turn (drop empty text blocks —
                # the API rejects assistant turns with a {type:text, text:""}).
                conversation.append({
                    "role": "assistant",
                    "content": [
                        b for b in message.content
                        if not (getattr(b, "type", None) == "text" and not getattr(b, "text", ""))
                    ],
                })

                # Execute client tools concurrently. Emit any mutation BEFORE
                # pushing the tool_result so iOS applies it optimistically.
                results = await asyncio.gather(
                    *[execute_client_tool(b.name, b.input, ctx) for b in tool_use_blocks]
                )
                tool_results = []
                for b, r in zip(tool_use_blocks, results):
                    if r.get("mutation"):
                        yield sse_frame("mutation", r["mutation"])
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": b.id,
                        "content": r["content"],
                    })
                conversation.append({"role": "user", "content": tool_results})

            yield sse_frame("done", {})
        except Exception as e:  # noqa: BLE001
            yield sse_frame("error", {"message": str(e)})

    headers = {
        **CORS_HEADERS,
        "Cache-Control": "no-cache, no-transform",
        "Connection": "keep-alive",
        "X-Accel-Buffering": "no",
    }
    return StreamingResponse(event_stream(), media_type="text/event-stream", headers=headers)
