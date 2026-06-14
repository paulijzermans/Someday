// chat Edge Function — STREAMING + agentic tool loop
// =============================================================================
// Context-aware AI chatbot for the user's Someday map.
//
// Wire format: Server-Sent Events (text/event-stream). The function streams
// the assistant's progress to the iOS client in real time so the UI can show
// "Searching the web for…", "Reading list 'Amsterdam'", etc. as honest
// per-step rows above the final reply.
//
// Event types:
//   event: step       data: { id, icon, label }      — a tool/work step started
//   event: step_done  data: { id }                   — that step finished
//   event: text       data: { delta }                — assistant reply token(s)
//   event: done       data: {}                       — stream complete
//   event: error      data: { message }              — fatal error mid-stream
//
// Tools the model can call:
//   • inspect_list({ name })   — server-implemented; returns the matching
//                                 list's places from the request context.
//                                 Each call surfaces a "📋 Reading list X" step.
//   • inspect_friend({ name }) — server-implemented; returns a friend's
//                                 visible places. Surfaces a "👥 Exploring …" step.
//   • web_search               — Anthropic server-side tool (max 3 uses).
//                                 Surfaces a "🔎 Searching the web…" step.
//
// Tool loop: we stream `messages.stream()`, parse out tool_use blocks for
// the two client tools, execute them locally against `ctx`, then resume the
// stream with the tool_result blocks. Capped at MAX_TOOL_ITERATIONS to bound
// cost/latency.
//
// Reuses the same `ANTHROPIC_API_KEY` env var the other functions use.
// =============================================================================

import Anthropic from "npm:@anthropic-ai/sdk@0.65.0";
import { createClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";
import { createLogger, extractTraceId } from "../_shared/observe.ts";

// Claude Haiku 4.5 — ~4x cheaper than Sonnet 4.5 on both input and output
// tokens, and fast enough that the streaming UX still feels instant.
// Tool calling reliability is good in practice for our format (the system
// prompt is strict about pin-wrapping and tool gating). If we notice
// regressions on the agentic loop (geocode → suggest), the next step is
// to either fall back to Sonnet for tool-heavy turns or strengthen the
// prompt rules further. Single source of truth — the rest of the file
// reads from this constant.
const MODEL = "claude-haiku-4-5";
const MAX_TOOL_ITERATIONS = 6;

interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

interface PlaceDigest {
  id: string;
  name: string;
  category: string;
  inLists: string[];
  area?: string | null;
  latitude?: number | null;
  longitude?: number | null;
  myRating?: number | null;
  source?: string | null;
  owner?: string | null;
}

interface ViewportDigest {
  centerLat: number;
  centerLon: number;
  north: number;
  south: number;
  east: number;
  west: number;
}

interface ListDigest { name: string; placeCount: number; }
interface FriendDigest { name: string; }

type AIAssistantTone = "concise" | "balanced" | "detailed";
interface AISettings {
  tone: AIAssistantTone;
  allowExternalRecommendations: boolean;
  maxPlacesPerAnswer: number;
  anchorOnSelectedPin: boolean;
  customInstructions: string;
}

interface ChatContext {
  userName: string;
  now: string;
  aiSettings?: AISettings | null;
  currentCity?: string | null;
  viewport?: ViewportDigest | null;
  visiblePlaces?: PlaceDigest[];
  selectedPlace?: PlaceDigest | null;
  myPlaces: PlaceDigest[];
  friendPlaces: PlaceDigest[];
  lists: ListDigest[];
  friends: FriendDigest[];
  /** True during the user's first-run, chat-driven onboarding. Flips the
   *  system prompt into ONBOARDING mode. Optional for forward-compat. */
  onboarding?: boolean;
}

const DEFAULT_AI_SETTINGS: AISettings = {
  tone: "balanced",
  allowExternalRecommendations: true,
  // Lowered from 5 → 3. Replies feel chat-fast at this cap and the user
  // can always ask "more?" if they want to see further options.
  maxPlacesPerAnswer: 3,
  anchorOnSelectedPin: true,
  customInstructions: "",
};

interface RequestBody {
  messages: ChatMessage[];
  context: ChatContext;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  // -------- 1. Parse input ----------------------------------------------
  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return json({ error: "messages required" }, 400);
  }

  // -------- Trace --------------------------------------------------------
  // Pull the X-Trace-Id the iOS client minted for this user action (or mint
  // one) and drop an immediate, AWAITED breadcrumb into the unified stream
  // BEFORE the SSE stream starts. This matters specifically because chat can
  // hang mid-stream (see the Accept-Encoding note below): the per-turn
  // `recordChatDebug` write lives in the stream's `finally`, which never runs
  // during a hang — but this entry row always lands, so a stalled turn shows
  // up as "chat request_received with trace X, no completion" in read_debug_log.
  const traceId = extractTraceId(req);
  const log = createLogger("chat", traceId);
  await log.info("request_received", {
    event: "request_received",
    data: { messages: body.messages.length },
  });

  // -------- 2. Env -------------------------------------------------------
  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!anthropicKey) {
    return json({ error: "ANTHROPIC_API_KEY not configured" }, 500);
  }

  // -------- 3. Build system prompt --------------------------------------
  const systemPrompt = buildSystemPrompt(body.context);
  // `Accept-Encoding: identity` — force an UNCOMPRESSED response. In the
  // Supabase/Deno edge runtime, the default gzip response stream from the
  // Anthropic API strands its final decompressed bytes: Deno's streaming
  // gunzip holds the tail of the gzip member until more data (or EOF) arrives,
  // but the API keeps the SSE socket alive after `message_stop`, so EOF never
  // comes. The result was that the LAST few stream events (content_block_stop
  // / message_delta / message_stop) never surfaced and our consume loop hung
  // forever — stranding the tool loop, the `selection` event, `done`, and the
  // debug-row write. Asking for an identity (raw) body means each SSE event is
  // delivered the instant its bytes hit the wire, so the stream terminates
  // cleanly. (We still belt-and-suspenders stop on `message_delta` below.)
  const anthropic = new Anthropic({
    apiKey: anthropicKey,
    defaultHeaders: { "accept-encoding": "identity" },
  });

  // -------- 3b. Identify the caller for usage attribution ---------------
  // The platform verifies the JWT before we run, so the `sub` claim is a
  // trustworthy user id. We only decode it (no extra round-trip) to know
  // which `user_usage` row to bump after the turn. Failure here is
  // non-fatal — usage accounting must never break the chat reply.
  const callerUserID = userIDFromAuthHeader(req.headers.get("Authorization"));

  // -------- 4. SSE stream + agentic tool loop ---------------------------
  const encoder = new TextEncoder();
  const ctx = body.context;

  const stream = new ReadableStream({
    async start(controller) {
      const send = (event: string, data: unknown) => {
        try {
          controller.enqueue(
            encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`),
          );
        } catch (_e) {
          // Controller already closed/errored — drop the event rather than throw.
        }
      };

      // SAFETY NET: if any detached promise in this turn rejects in a way our
      // local try/catch can't see, an unhandled rejection would tear down the
      // whole isolate — the client would see the stream just *die* (no `error`
      // event, no `done`, no debug row). This global handler captures it,
      // surfaces it to the client, and prevents the isolate crash so the
      // `finally` (and the debug-row write) still runs. Removed in `finally`.
      // deno-lint-ignore no-explicit-any
      const onUnhandled = (ev: any) => {
        const reason = ev?.reason ?? ev?.error ?? ev;
        const msg = `unhandledrejection: ${String(reason?.stack ?? reason?.message ?? reason)}`;
        send("error", { message: msg });
        try { ev?.preventDefault?.(); } catch (_e) { /* noop */ }
      };
      globalThis.addEventListener("unhandledrejection", onUnhandled);

      try {
        // Anthropic-format conversation we keep extending as we loop.
        // Starts from the iOS-supplied history; we push assistant +
        // user (tool_result) turns each iteration that uses a client tool.
        // deno-lint-ignore no-explicit-any
        const conversation: Array<{ role: "user" | "assistant"; content: any }> =
          body.messages.map((m) => ({ role: m.role, content: m.content }));

        let stepCounter = 0;

        // Running total of AI tokens this turn (input + output, summed
        // across every loop iteration). Flushed once to `user_usage` after
        // the loop so a multi-tool turn counts as one cumulative write.
        let tokensThisTurn = 0;

        // -------- observability accumulators (chat_debug_log) --------
        // We collect a per-turn trace as the stream runs, then write ONE
        // row to `chat_debug_log` in the finally below (best-effort, never
        // breaks the reply). This is the queryable "what did the model
        // actually do" feed — see migration 20260613173000_chat_debug_log.
        const dbgTools: string[] = [];
        let dbgReplyText = "";
        // deno-lint-ignore no-explicit-any
        let dbgSelection: any = null;
        let dbgError: string | null = null;
        let dbgIterations = 0;
        const dbgUserMessage =
          [...body.messages].reverse().find((m) => m.role === "user")?.content ?? null;

        // NOTE: we used to emit two unconditional "scoping" steps
        // here — "Searching your lists" with every list pill and
        // "Searching friends' lists" with every friend avatar —
        // before the model loop ran. They fired on EVERY prompt
        // regardless of whether the model actually intended to dig
        // into a list or a friend's saves, which made every reply
        // look like the AI was poking through your private data
        // even when it was just answering "what time is it?". That
        // was both misleading (the model often skipped the tools
        // entirely) and visually noisy. Removed.
        //
        // Per-tool steps still fire from the streamEvent handler
        // below when the model genuinely calls `inspect_list` /
        // `inspect_friend`, so the user sees real work as it
        // happens — and nothing when there isn't any.

        for (let iter = 0; iter < MAX_TOOL_ITERATIONS; iter++) {
          dbgIterations = iter + 1;
          // Per-iteration map: block index → step ID. We use it to emit
          // step_done events at the end of the iteration when we know the
          // model has finished writing this tool call.
          const stepIDByBlockIndex = new Map<number, string>();

          // NOTE: we ask the SDK only to BUILD + SEND the request (auth, URL,
          // the big tools array) via `.asResponse()`, which hands back the raw
          // `Response` WITHOUT the SDK consuming/parsing the SSE body. We then
          // parse the event stream by hand below. This is deliberate: neither
          // the `messages.stream()` helper (its `finalMessage()` never
          // resolves) NOR the low-level async-iterable (`for await` /
          // `.next()`) terminate in the Supabase/Deno edge runtime — the
          // Anthropic API keeps the SSE socket alive after `message_stop`, and
          // the SDK's line-buffering decoder strands its final event(s) waiting
          // for an EOF / next chunk that never comes. That single hang
          // stranded EVERYTHING after the text: the tool loop, the `selection`
          // event, `done`, and the debug-row write (the chat only LOOKED alive
          // because text streams before the block). Reading the raw body
          // ourselves, we process each complete `\n\n`-delimited event the
          // instant its bytes arrive and stop the moment we see the terminal
          // `message_delta`/`message_stop` — never issuing the read that hangs.
          const response = await anthropic.messages.create({
            model: MODEL,
            max_tokens: 1024,
            stream: true,
            system: systemPrompt,
            tools: [
              {
                name: "inspect_list",
                description:
                  "Look up one of the user's Someday lists by name and return the places saved in it (with their ids so you can reference them in your reply). Call this before describing or comparing what's in a specific list.",
                input_schema: {
                  type: "object",
                  properties: {
                    name: {
                      type: "string",
                      description:
                        "List name to look up (case-insensitive substring match).",
                    },
                  },
                  required: ["name"],
                },
              },
              {
                name: "inspect_friend",
                description:
                  "Look up one of the user's friends by name and return the places they've shared (with ids so you can reference them). Call this before describing what a friend has saved.",
                input_schema: {
                  type: "object",
                  properties: {
                    name: {
                      type: "string",
                      description:
                        "Friend name to look up (case-insensitive substring match).",
                    },
                  },
                  required: ["name"],
                },
              },
              {
                name: "create_list",
                description:
                  "Create a new custom list on the user's account. The list appears in their Lists tab immediately. Use when the user says 'make a list for X', 'group these as Y', etc.",
                input_schema: {
                  type: "object",
                  properties: {
                    name: {
                      type: "string",
                      description:
                        "Display name for the new list, e.g. 'Date night' or 'Coffee crawl'.",
                    },
                  },
                  required: ["name"],
                },
              },
              {
                name: "delete_list",
                description:
                  "Delete one of the user's lists by name. The places inside the list are NOT deleted — only the list itself. Use only when the user explicitly asks ('delete my X list', 'remove the X list').",
                input_schema: {
                  type: "object",
                  properties: {
                    name: {
                      type: "string",
                      description: "Exact name of the list to delete.",
                    },
                  },
                  required: ["name"],
                },
              },
              {
                name: "create_place",
                description:
                  "Save a new pin on the user's map at the given coordinates. Use when the user says 'add this place', 'save it', 'pin X for me'. Always pair with `geocode_address` first if you don't already know the coordinates with high confidence. Optionally drop the pin into a named list.",
                input_schema: {
                  type: "object",
                  properties: {
                    name: { type: "string", description: "Venue name." },
                    latitude: { type: "number" },
                    longitude: { type: "number" },
                    category: {
                      type: "string",
                      description:
                        "One of: food, drinks, coffee, activity, art, travel. Default 'food' if unclear.",
                    },
                    list_name: {
                      type: "string",
                      description:
                        "Optional — if provided, the new pin is also added to this list. Creates the list if it doesn't exist.",
                    },
                  },
                  required: ["name", "latitude", "longitude"],
                },
              },
              {
                name: "delete_place",
                description:
                  "Delete one of the user's saved pins by id. Use only when the user explicitly asks ('delete X', 'remove the pin for Y'). Pass the full UUID from the `id=…` prefix in the tool results / context above.",
                input_schema: {
                  type: "object",
                  properties: {
                    id: { type: "string", description: "Place UUID." },
                  },
                  required: ["id"],
                },
              },
              {
                name: "geocode_address",
                description:
                  "Resolve a place name to latitude+longitude so it can be rendered as a tappable pin in the chat. CALL THIS BEFORE EVERY `someday://suggest?...` pin you emit — unless you already know the EXACT lat/lon of that exact venue from world knowledge (rare for anything but globally famous spots). web_search results give you addresses, not coordinates; you still need this tool to turn the address into a pin. Hard rule: if geocode returns 'no match', DON'T fall back to mentioning the venue in plain text — drop it entirely and pick a different one.",
                input_schema: {
                  type: "object",
                  properties: {
                    query: {
                      type: "string",
                      description:
                        "Search string for the venue — include the city or neighbourhood for disambiguation, e.g. \"Bar Centraal Amsterdam\" not just \"Bar Centraal\". The more specific, the more accurate the pin.",
                    },
                  },
                  required: ["query"],
                },
              },
              {
                name: "create_itinerary",
                description:
                  "Assemble an ordered day plan from places and render it on the map as a swipeable route. Use when the user asks to 'plan my day', 'build an itinerary', 'map out a route', 'what's a good Saturday', etc. Each stop is either a place the user already saved (pass its `place_id` from the context/tool results) or a brand-new venue you geocoded first (pass `latitude`+`longitude` — same `geocode_address` discipline as a suggest pin: no coords, no stop). Order the stops the way the day should flow (morning → night). This is a THIN intent: iOS persists the plan and frames the stops; you still write the human-facing plan in your reply with the normal place/suggest links.",
                input_schema: {
                  type: "object",
                  properties: {
                    title: {
                      type: "string",
                      description:
                        "Short name for the day, e.g. 'Jordaan Saturday' or 'Coffee + canals'.",
                    },
                    stops: {
                      type: "array",
                      description:
                        "Ordered stops, earliest first. 2–6 is the sweet spot.",
                      items: {
                        type: "object",
                        properties: {
                          time: {
                            type: "string",
                            description:
                              "Optional time-of-day label, e.g. '10:00', 'Lunch', 'Sunset'.",
                          },
                          name: { type: "string", description: "Stop / venue name." },
                          category: {
                            type: "string",
                            description:
                              "One of: food, drinks, coffee, activity, art, travel.",
                          },
                          note: {
                            type: "string",
                            description:
                              "Optional one-line reason this stop is here / what to do.",
                          },
                          place_id: {
                            type: "string",
                            description:
                              "UUID of a saved place, if this stop is one the user already pinned.",
                          },
                          latitude: { type: "number", description: "Required if no place_id." },
                          longitude: { type: "number", description: "Required if no place_id." },
                        },
                        required: ["name"],
                      },
                    },
                  },
                  required: ["title", "stops"],
                },
              },
              {
                name: "ask_selection",
                description:
                  "Ask the user a short question by showing them tappable option BUTTONS instead of expecting them to type a free-text reply. Use this WHENEVER a request is open-ended or under-specified and the missing information is a small, listable set of choices — vibe, cuisine, budget band, neighbourhood, party size, time of day, indoor/outdoor, etc. (e.g. 'where should I go tonight?', 'recommend a place', 'surprise me', 'I'm bored'). This renders an interactive selection box in the chat; the user's pick(s) come back as their next message, after which you continue (usually with geocoded `someday://suggest` pins). Prefer this over writing an open-ended question in prose. Call it on its own turn — a one-line lead-in of text is fine, but the buttons ARE the question, so don't also list the options as text. Don't use it when you already have enough to answer, or when a pin is selected and the user asked a direct factual question about it.",
                input_schema: {
                  type: "object",
                  properties: {
                    prompt: {
                      type: "string",
                      description:
                        "The question shown above the buttons, e.g. 'What kind of evening are you after?'.",
                    },
                    options: {
                      type: "array",
                      description:
                        "2–6 SHORT option labels (a few words each), e.g. ['Cocktail bar','Natural wine','Cosy pub','Late-night eats'].",
                      items: { type: "string" },
                    },
                    multi: {
                      type: "boolean",
                      description:
                        "true → the user can pick SEVERAL options and tap a button to submit (use when answers combine, e.g. which vibes appeal). false → single-choice: tapping one option submits instantly (use for mutually-exclusive questions). Default false.",
                    },
                    submit_label: {
                      type: "string",
                      description:
                        "Only used when multi=true: the commit button label, e.g. 'Show picks' or 'Next'. Defaults to 'Next'.",
                    },
                  },
                  required: ["prompt", "options"],
                },
              },
              {
                type: "web_search_20250305",
                name: "web_search",
                max_uses: 3,
                // deno-lint-ignore no-explicit-any
              } as any,
            ],
            messages: conversation,
          }).asResponse();

          // --- Parse the raw SSE body ourselves and assemble the final
          // assistant message. We reconstruct exactly what `finalMessage()`
          // would have returned: the ordered content blocks (text + tool_use,
          // with their input JSON re-parsed from the streamed
          // `input_json_delta` fragments), the stop_reason, and token usage.
          // deno-lint-ignore no-explicit-any
          const blocks: any[] = []; // indexed by event.index
          const partialJSON: Record<number, string> = {};
          let stopReason: string | null = null;
          let inputTokens = 0;
          let outputTokens = 0;

          // Process one decoded Anthropic stream event. Returns true when the
          // turn is terminal (`message_delta` — which carries the final
          // stop_reason + usage — or `message_stop`), so the reader below can
          // stop the INSTANT it has what it needs and never issue the read
          // that would hang on the kept-alive socket.
          // deno-lint-ignore no-explicit-any
          const handleEvent = (event: any): boolean => {
            if (event.type === "message_stop") return true;
            if (event.type === "message_start") {
              inputTokens += event.message?.usage?.input_tokens ?? 0;
              outputTokens += event.message?.usage?.output_tokens ?? 0;
            } else if (event.type === "content_block_start") {
              // Shallow copy so we can mutate text/input as deltas arrive.
              const block = { ...event.content_block };
              blocks[event.index] = block;
              if (block?.type === "tool_use" || block?.type === "server_tool_use") {
                // Trace EVERY tool the model reaches for (incl. ask_selection,
                // whose step we suppress) for the debug log.
                if (block?.name) dbgTools.push(block.name);
                partialJSON[event.index] = "";
                if (block?.name !== "ask_selection") {
                  // `ask_selection` has no "work" to show — the selection box
                  // it produces IS the visible output, so a "✓ …" step above
                  // it would just be noise. Skip the step for it.
                  stepCounter += 1;
                  const stepID = `step_${stepCounter}`;
                  stepIDByBlockIndex.set(event.index, stepID);
                  send("step", {
                    id: stepID,
                    icon: stepIcon(block.name),
                    label: stepLabel(block),
                    tool: block.name,
                  });
                }
              }
            } else if (event.type === "content_block_delta") {
              const d = event.delta;
              if (d?.type === "text_delta") {
                const b = blocks[event.index];
                if (b && b.type === "text") b.text = (b.text ?? "") + d.text;
                dbgReplyText += d.text;
                send("text", { delta: d.text });
              } else if (d?.type === "input_json_delta") {
                partialJSON[event.index] = (partialJSON[event.index] ?? "") +
                  (d.partial_json ?? "");
              }
            } else if (event.type === "content_block_stop") {
              const b = blocks[event.index];
              if (b && (b.type === "tool_use" || b.type === "server_tool_use")) {
                const raw = partialJSON[event.index] ?? "";
                if (raw.trim().length > 0) {
                  try {
                    b.input = JSON.parse(raw);
                  } catch (_e) {
                    // Truncated/invalid tool input — leave the block's initial
                    // input ({}) so the handler degrades gracefully.
                  }
                }
              }
            } else if (event.type === "message_delta") {
              if (event.delta?.stop_reason) stopReason = event.delta.stop_reason;
              outputTokens += event.usage?.output_tokens ?? 0;
              // Terminal: everything we need is in hand.
              return true;
            }
            return false;
          };

          // Hand-rolled SSE reader. We split the raw body on the `\n\n` event
          // boundary and parse each event's `data:` JSON as soon as a chunk
          // delivers it — no SDK line-buffer lag — and stop the moment
          // `handleEvent` reports the turn is terminal, WITHOUT a trailing read
          // (the read that would block forever on the kept-alive socket).
          let done = false;
          try {
            const body = response.body;
            if (!body) throw new Error("no response body");
            const reader = body.getReader();
            const decoder = new TextDecoder();
            let buf = "";
            while (!done) {
              const { value, done: readerDone } = await reader.read();
              if (readerDone) break;
              buf += decoder.decode(value, { stream: true });
              let nl: number;
              while ((nl = buf.indexOf("\n\n")) !== -1) {
                const rawEvent = buf.slice(0, nl);
                buf = buf.slice(nl + 2);
                // Concatenate any `data:` lines (SSE allows multi-line data).
                const dataStr = rawEvent
                  .split("\n")
                  .filter((l) => l.startsWith("data:"))
                  .map((l) => l.slice(5).trimStart())
                  .join("");
                if (!dataStr) continue;
                // deno-lint-ignore no-explicit-any
                let evt: any;
                try {
                  evt = JSON.parse(dataStr);
                } catch (_e) {
                  continue; // skip non-JSON keep-alive/comment frames
                }
                if (evt?.type === "error") {
                  throw new Error(
                    `anthropic stream error: ${JSON.stringify(evt.error ?? evt)}`,
                  );
                }
                if (handleEvent(evt)) {
                  done = true;
                  break;
                }
              }
            }
            // Release the upstream socket without awaiting — we have everything
            // we need; `cancel()` may hang on the kept-alive socket otherwise.
            reader.cancel().catch(() => {});
          } catch (streamErr) {
            dbgError = dbgError ?? `stream: ${String(streamErr)}`;
            send("error", { message: dbgError });
            break;
          }

          const message = {
            // Compact out any holes left by the index-keyed array.
            // deno-lint-ignore no-explicit-any
            content: blocks.filter((b: any) => b != null),
            stop_reason: stopReason,
            usage: { input_tokens: inputTokens, output_tokens: outputTokens },
          };

          // Accumulate token spend for this turn.
          tokensThisTurn += (message.usage?.input_tokens ?? 0) +
            (message.usage?.output_tokens ?? 0);

          // Tick every step we surfaced this iteration. By the time
          // finalMessage() resolves, all server tools (web_search) have
          // executed and all client tool_use blocks have been fully
          // written by the model. We're about to execute client tools
          // below; the user sees the ✓ exactly when the work is real.
          for (const stepID of stepIDByBlockIndex.values()) {
            send("step_done", { id: stepID });
          }

          // Client tools the model wants us to run.
          const toolUseBlocks = message.content.filter(
            // deno-lint-ignore no-explicit-any
            (b: any) => b.type === "tool_use",
            // deno-lint-ignore no-explicit-any
          ) as any[];

          if (
            message.stop_reason !== "tool_use" ||
            toolUseBlocks.length === 0
          ) {
            // Either the model is done, or only server tools were used
            // (web_search results already inlined into the same stream).
            break;
          }

          // `ask_selection` is TERMINAL. Instead of feeding a tool_result and
          // looping, we emit the structured selection box to the client and
          // end the turn — the box waits for the user, whose tap arrives as
          // their next message (a fresh turn). Because iOS sends text-only
          // history, the dangling tool_use never needs a matching
          // tool_result. If the model bundled other tools this turn, we
          // ignore them: the box is the whole point of the turn.
          // deno-lint-ignore no-explicit-any
          const selectionBlock = toolUseBlocks.find((b: any) => b.name === "ask_selection");
          if (selectionBlock) {
            const inp = selectionBlock.input ?? {};
            const options = Array.isArray(inp.options)
              ? inp.options.map((o: unknown) => String(o)).filter((o: string) => o.trim().length > 0)
              : [];
            if (options.length >= 2) {
              const selectionPayload = {
                prompt: typeof inp.prompt === "string" ? inp.prompt : null,
                options,
                multi: inp.multi === true,
                submitLabel: typeof inp.submit_label === "string" && inp.submit_label.length > 0
                  ? inp.submit_label
                  : "Next",
              };
              dbgSelection = selectionPayload;
              send("selection", selectionPayload);
            }
            // Terminal either way — a malformed call (no valid options) just
            // ends the turn rather than crashing the unknown-tool path.
            break;
          }

          // Push the assistant's tool-using turn into the conversation,
          // then a user turn with all tool_result blocks. Loop again.
          // Drop any empty text blocks first — the API rejects assistant
          // turns that contain a `{type:"text", text:""}` block (which a
          // tool-only turn can produce), and they carry no information.
          conversation.push({
            role: "assistant",
            // deno-lint-ignore no-explicit-any
            content: message.content.filter((b: any) =>
              !(b.type === "text" && (!b.text || b.text.length === 0))
            ),
          });
          // `executeClientTool` is now async (geocode_address hits
          // Nominatim, the mutation tools emit SSE events back). Each
          // call returns `{ content, mutation? }`. We emit any
          // mutation onto the SSE stream BEFORE pushing the
          // tool_result back — so the iOS side starts applying the
          // mutation immediately (optimistic UI) while the model
          // continues thinking on the same turn.
          const settled = await Promise.all(
            toolUseBlocks.map(async (tb) => {
              // OBSERVE (AI_STRATEGY.md §4): one structured log line per
              // tool call. Supabase captures console output in the
              // function logs, so this is a zero-migration telemetry feed
              // of "what the model tried, and whether it worked" — the raw
              // material the flywheel summarizes into the next backlog.
              // We log the input KEYS, not values, to avoid dumping user
              // content (place names, queries) into logs.
              const startedAt = Date.now();
              try {
                const result = await executeClientTool(tb.name, tb.input, ctx);
                logToolCall({
                  tool: tb.name,
                  ok: true,
                  ms: Date.now() - startedAt,
                  mutated: !!result.mutation,
                  inputKeys: Object.keys(tb.input ?? {}),
                });
                return { tb, result };
              } catch (err) {
                logToolCall({
                  tool: tb.name,
                  ok: false,
                  ms: Date.now() - startedAt,
                  error: String(err),
                  inputKeys: Object.keys(tb.input ?? {}),
                });
                throw err; // preserve existing "a throw aborts the turn" semantics
              }
            }),
          );
          for (const { result } of settled) {
            if (result.mutation) send("mutation", result.mutation);
          }
          const toolResults = settled.map(({ tb, result }) => ({
            type: "tool_result" as const,
            tool_use_id: tb.id,
            content: result.content,
          }));
          conversation.push({ role: "user", content: toolResults });
        }

        send("done", {});
      } catch (err) {
        console.error("Chat stream failed:", err);
        dbgError = String(err);
        send("error", { message: String(err) });
      } finally {
        // Flush token usage for this turn. Best-effort and awaited inside
        // the finally so it runs whether the turn completed or errored
        // mid-stream (the user still spent those tokens). Never throws —
        // `recordTokenUsage` swallows its own failures.
        await recordTokenUsage(callerUserID, tokensThisTurn);
        // Write the per-turn observability row. Best-effort, never throws.
        await recordChatDebug({
          userID: callerUserID,
          userMessage: dbgUserMessage,
          tools: dbgTools,
          selection: dbgSelection,
          replyText: dbgReplyText,
          error: dbgError,
          meta: { traceId, tokens: tokensThisTurn, iterations: dbgIterations, model: MODEL },
        });
        // Mirror the turn outcome into the unified cross-surface stream so a
        // chat trace reads out alongside iOS + other-function breadcrumbs.
        // (Best-effort; on a mid-stream hang this finally never runs and the
        // entry `request_received` row is what flags the stall.)
        await (dbgError
          ? log.error("chat turn failed", { event: "turn_failed", userId: callerUserID, data: { error: dbgError, tools: dbgTools, iterations: dbgIterations } })
          : log.info("chat turn complete", { event: "completed", userId: callerUserID, data: { tools: dbgTools, iterations: dbgIterations, tokens: tokensThisTurn, hadSelection: dbgSelection != null } }));
        globalThis.removeEventListener("unhandledrejection", onUnhandled);
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      ...corsHeaders,
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      "Connection": "keep-alive",
      // Disable Supabase Edge buffering — without this, events queue up
      // until the function returns instead of streaming live to the client.
      "X-Accel-Buffering": "no",
    },
  });
});

// ---------------------- usage accounting ----------------------

/// Decode the `sub` (user id) claim from a `Bearer <jwt>` header without
/// verifying the signature — the platform already verified the JWT before
/// invoking the function, so by the time we're here the token is trusted.
/// Returns null for anonymous/service-role calls or a malformed header, in
/// which case we simply skip usage attribution.
function userIDFromAuthHeader(header: string | null): string | null {
  if (!header) return null;
  const token = header.replace(/^Bearer\s+/i, "").trim();
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    // Base64URL → JSON. atob handles standard base64; swap the URL-safe
    // chars and pad before decoding.
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const pad = b64.length % 4 === 0 ? "" : "=".repeat(4 - (b64.length % 4));
    const payload = JSON.parse(atob(b64 + pad));
    const sub = payload?.sub;
    return typeof sub === "string" && sub.length > 0 ? sub : null;
  } catch {
    return null;
  }
}

/// Add `tokens` to the user's lifetime `tokens_used` counter, creating the
/// row on first use. Uses the service-role key so it can write past RLS
/// (ordinary clients have no INSERT/UPDATE policy on `user_usage`). Fully
/// best-effort: any missing env, missing user, or network error is logged
/// and swallowed so chat replies never depend on the accounting write.
async function recordTokenUsage(userID: string | null, tokens: number): Promise<void> {
  if (!userID || tokens <= 0) return;
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return;
  try {
    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    // Read-modify-write the single row. Tokens-per-turn is low-frequency
    // per user, so the race window is negligible; the import path's
    // `increment_usage` RPC is the atomic option if contention ever shows.
    const { data, error: readErr } = await admin
      .from("user_usage")
      .select("tokens_used")
      .eq("user_id", userID)
      .maybeSingle();
    if (readErr) throw readErr;
    const next = (data?.tokens_used ?? 0) + tokens;
    const { error: upErr } = await admin
      .from("user_usage")
      .upsert(
        { user_id: userID, tokens_used: next, updated_at: new Date().toISOString() },
        { onConflict: "user_id" },
      );
    if (upErr) throw upErr;
  } catch (err) {
    console.error("recordTokenUsage failed:", err);
  }
}

/// Write one per-turn row to `chat_debug_log` for the observability loop.
/// Uses the service-role key so it can INSERT past RLS (the table has no
/// client write policy). Fully best-effort: any missing env or error is
/// logged and swallowed so chat replies never depend on the debug write.
/// See migration 20260613173000_chat_debug_log.sql.
async function recordChatDebug(entry: {
  userID: string | null;
  userMessage: string | null;
  tools: string[];
  // deno-lint-ignore no-explicit-any
  selection: any;
  replyText: string;
  error: string | null;
  // deno-lint-ignore no-explicit-any
  meta: any;
}): Promise<void> {
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return;
  try {
    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { error } = await admin.from("chat_debug_log").insert({
      user_id: entry.userID,
      user_message: entry.userMessage,
      tools: entry.tools,
      selection: entry.selection,
      reply_text: entry.replyText,
      error: entry.error,
      meta: entry.meta,
    });
    if (error) throw error;
  } catch (err) {
    console.error("recordChatDebug failed:", err);
  }
}

// ---------------------- telemetry (OBSERVE) ----------------------

// One structured line per tool execution. Emitted to stdout, which
// Supabase captures in the function logs — so we get a queryable feed of
// "what the model tried, whether it worked, and how long it took" with
// zero schema/migration. This is the OBSERVE stage of the improvement
// flywheel (AI_STRATEGY.md §4): grep / export these to spot tools the
// model reaches for, tools that fail, and capabilities users want that no
// tool covers yet. Promote to a `tool_events` table later if we need
// per-user attribution and SQL aggregation.
interface ToolCallLog {
  tool: string;
  ok: boolean;
  ms: number;
  mutated?: boolean;
  error?: string;
  inputKeys?: string[];
}

function logToolCall(entry: ToolCallLog): void {
  // Prefix lets us filter the log stream to just tool telemetry.
  console.log(`tool_event ${JSON.stringify({ t: new Date().toISOString(), ...entry })}`);
}

// ---------------------- step labelling ----------------------

function stepIcon(toolName: string): string {
  switch (toolName) {
    case "inspect_list": return "list.bullet.rectangle.fill";
    case "inspect_friend": return "person.2.fill";
    case "web_search": return "globe";
    case "geocode_address": return "mappin.and.ellipse";
    case "create_list": return "plus.rectangle.on.folder";
    case "delete_list": return "trash";
    case "create_place": return "mappin.circle.fill";
    case "delete_place": return "trash";
    case "create_itinerary": return "map.fill";
    default: return "sparkles";
  }
}

// deno-lint-ignore no-explicit-any
function stepLabel(block: any): string {
  if (block.type === "server_tool_use" && block.name === "web_search") {
    // web_search input may not have populated yet at content_block_start;
    // we just say "the web" then. The model fills it in shortly.
    const query = block.input?.query ?? "the web";
    return `Searching the web for "${query}"`;
  }
  if (block.name === "inspect_list") {
    const n = block.input?.name;
    return n ? `Reading list "${n}"` : "Reading a list";
  }
  if (block.name === "inspect_friend") {
    const n = block.input?.name;
    return n ? `Exploring ${n}'s places` : "Exploring a friend's places";
  }
  if (block.name === "geocode_address") {
    const q = block.input?.query;
    return q ? `Pinning "${q}"` : "Pinning a venue";
  }
  if (block.name === "create_list") {
    const n = block.input?.name;
    return n ? `Creating list "${n}"` : "Creating a list";
  }
  if (block.name === "delete_list") {
    const n = block.input?.name;
    return n ? `Deleting list "${n}"` : "Deleting a list";
  }
  if (block.name === "create_place") {
    const n = block.input?.name;
    return n ? `Saving "${n}" to your map` : "Saving a pin";
  }
  if (block.name === "delete_place") {
    return "Deleting a pin";
  }
  if (block.name === "create_itinerary") {
    const t = block.input?.title;
    return t ? `Planning "${t}"` : "Planning your day";
  }
  return "Working…";
}

// ---------------------- client tool execution ----------------------
//
// Each tool returns `{ content, mutation? }`.
//   • content — the string fed back into the model as the tool_result.
//   • mutation — optional SSE payload emitted to the iOS client so it
//                can apply the mutation locally (create list, delete
//                pin, etc.). The iOS client owns the actual DB write
//                (it's authed as the user via RLS); the Edge Function
//                just signals what to do.

// deno-lint-ignore no-explicit-any
type ToolMutation = {
  kind:
    | "create_list"
    | "delete_list"
    | "create_place"
    | "delete_place"
    | "create_itinerary";
  // deno-lint-ignore no-explicit-any
  input: any;
};
interface ToolResult { content: string; mutation?: ToolMutation; }

// deno-lint-ignore no-explicit-any
async function executeClientTool(name: string, input: any, ctx: ChatContext): Promise<ToolResult> {
  if (name === "inspect_list") {
    const q = String(input?.name ?? "").toLowerCase();
    if (!q) return { content: `No list name provided.` };
    const matches = ctx.lists.filter((l) =>
      l.name.toLowerCase().includes(q)
    );
    if (matches.length === 0) {
      const known = ctx.lists.map((l) => l.name).join(", ") || "(none)";
      return { content: `No list matched "${input?.name}". Known lists: ${known}.` };
    }
    const lines: string[] = [];
    for (const list of matches) {
      const placesInList = ctx.myPlaces.filter((p) =>
        p.inLists.some((ln) => ln.toLowerCase() === list.name.toLowerCase())
      );
      lines.push(
        `List "${list.name}" — ${list.placeCount} place${list.placeCount === 1 ? "" : "s"}:`,
      );
      if (placesInList.length === 0) {
        lines.push("(no places hydrated in the off-screen index for this list)");
      } else {
        for (const p of placesInList.slice(0, 30)) {
          const area = p.area ? ` in ${p.area}` : "";
          lines.push(`- id=${p.id} · ${p.name} — ${p.category}${area}`);
        }
        if (placesInList.length > 30) {
          lines.push(`…and ${placesInList.length - 30} more`);
        }
      }
    }
    return { content: lines.join("\n") };
  }

  if (name === "inspect_friend") {
    const q = String(input?.name ?? "").toLowerCase();
    if (!q) return { content: `No friend name provided.` };
    const matches = ctx.friends.filter((f) => f.name.toLowerCase().includes(q));
    if (matches.length === 0) {
      const known = ctx.friends.map((f) => f.name).join(", ") || "(none)";
      return { content: `No friend matched "${input?.name}". Known friends: ${known}.` };
    }
    const lines: string[] = [];
    for (const friend of matches) {
      const theirPlaces = ctx.friendPlaces.filter(
        (p) => (p.owner ?? "").toLowerCase() === friend.name.toLowerCase()
      );
      lines.push(`Friend "${friend.name}" — ${theirPlaces.length} visible place${theirPlaces.length === 1 ? "" : "s"}:`);
      if (theirPlaces.length === 0) {
        lines.push("(no places visible from this friend)");
      } else {
        for (const p of theirPlaces.slice(0, 30)) {
          const area = p.area ? ` in ${p.area}` : "";
          const rating = p.myRating != null
            ? ` (rated ${p.myRating.toFixed(1)}/10 by them)`
            : "";
          lines.push(`- id=${p.id} · ${p.name} — ${p.category}${area}${rating}`);
        }
        if (theirPlaces.length > 30) {
          lines.push(`…and ${theirPlaces.length - 30} more`);
        }
      }
    }
    return { content: lines.join("\n") };
  }

  if (name === "geocode_address") {
    // Nominatim (OpenStreetMap) — free, no key, no auth. They require a
    // descriptive User-Agent and rate-limit at 1 req/sec; the model
    // calls this in series so we stay well under.
    const q = String(input?.query ?? "").trim();
    if (!q) return { content: "No query provided." };
    try {
      const url = `https://nominatim.openstreetmap.org/search?format=json&limit=1&q=${encodeURIComponent(q)}`;
      const resp = await fetch(url, {
        headers: {
          "User-Agent": "Someday/1.0 (contact: paulijzermans@gmail.com)",
          "Accept-Language": "en",
        },
      });
      if (!resp.ok) {
        return { content: `Geocode HTTP ${resp.status} for "${q}".` };
      }
      const data = await resp.json();
      if (!Array.isArray(data) || data.length === 0) {
        return { content: `No geocode match for "${q}". Don't pin this venue — pick a different one or skip it.` };
      }
      const r = data[0];
      const lat = parseFloat(r.lat);
      const lon = parseFloat(r.lon);
      if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
        return { content: `Geocode returned invalid coordinates for "${q}".` };
      }
      return {
        content: `lat=${lat.toFixed(6)}, lon=${lon.toFixed(6)} — matched "${r.display_name}". Use these EXACT coordinates in the someday://suggest link.`,
      };
    } catch (e) {
      return { content: `Geocode failed for "${q}": ${String(e)}` };
    }
  }

  // ---- Mutation tools — emit a SSE event the iOS client applies ----

  if (name === "create_list") {
    const listName = String(input?.name ?? "").trim();
    if (!listName) return { content: "No list name provided." };
    return {
      content: `Created list "${listName}". It now exists in the user's Lists tab.`,
      mutation: { kind: "create_list", input: { name: listName } },
    };
  }

  if (name === "delete_list") {
    const listName = String(input?.name ?? "").trim();
    if (!listName) return { content: "No list name provided." };
    const exists = ctx.lists.some((l) => l.name.toLowerCase() === listName.toLowerCase());
    if (!exists) {
      const known = ctx.lists.map((l) => l.name).join(", ") || "(none)";
      return { content: `No list named "${listName}" to delete. Known lists: ${known}.` };
    }
    return {
      content: `Deleted list "${listName}". The places it contained are still on the map.`,
      mutation: { kind: "delete_list", input: { name: listName } },
    };
  }

  if (name === "create_place") {
    const placeName = String(input?.name ?? "").trim();
    const lat = Number(input?.latitude);
    const lon = Number(input?.longitude);
    const category = String(input?.category ?? "food").trim().toLowerCase();
    const listName = input?.list_name ? String(input.list_name).trim() : null;
    if (!placeName || !Number.isFinite(lat) || !Number.isFinite(lon)) {
      return { content: "create_place needs name + latitude + longitude." };
    }
    const validCats = new Set(["food", "drinks", "coffee", "activity", "art", "travel"]);
    const cat = validCats.has(category) ? category : "food";
    const listSuffix = listName ? ` and added it to "${listName}"` : "";
    return {
      content: `Saved "${placeName}" at lat=${lat.toFixed(4)}, lon=${lon.toFixed(4)}${listSuffix}. The pin is on the user's map now.`,
      mutation: {
        kind: "create_place",
        input: { name: placeName, latitude: lat, longitude: lon, category: cat, list_name: listName },
      },
    };
  }

  if (name === "delete_place") {
    const placeID = String(input?.id ?? "").trim();
    if (!placeID) return { content: "delete_place needs the place's id." };
    return {
      content: `Deleted the pin (id=${placeID}). It's gone from the map and from any lists it was in.`,
      mutation: { kind: "delete_place", input: { id: placeID } },
    };
  }

  if (name === "create_itinerary") {
    // Thin intent emitter (AI_STRATEGY.md §6): we normalise + shape the
    // plan, but persistence + rendering happen in Swift through
    // `ItineraryService` and the map carousel. No domain logic lives here.
    const title = String(input?.title ?? "Your day").trim() || "Your day";
    const rawStops = Array.isArray(input?.stops) ? input.stops : [];
    const validCats = new Set(["food", "drinks", "coffee", "activity", "art", "travel"]);
    // deno-lint-ignore no-explicit-any
    const stops = rawStops
      .map((s: any) => {
        const stopName = String(s?.name ?? "").trim();
        if (!stopName) return null;
        const placeID = s?.place_id ? String(s.place_id).trim() : null;
        const lat = Number(s?.latitude);
        const lon = Number(s?.longitude);
        const hasCoord = Number.isFinite(lat) && Number.isFinite(lon);
        // A stop the client can render needs SOMETHING to anchor a pin:
        // either a saved place id (iOS resolves the coord) or explicit
        // coords. Drop anchorless stops so the route never has gaps.
        if (!placeID && !hasCoord) return null;
        const cat = validCats.has(String(s?.category ?? "").toLowerCase())
          ? String(s.category).toLowerCase()
          : null;
        return {
          time: s?.time ? String(s.time).trim() : null,
          name: stopName,
          category: cat,
          note: s?.note ? String(s.note).trim() : null,
          place_id: placeID,
          latitude: hasCoord ? lat : null,
          longitude: hasCoord ? lon : null,
        };
      })
      .filter((s: unknown) => s !== null);

    if (stops.length === 0) {
      return {
        content:
          "create_itinerary needs at least one stop with a place_id OR latitude+longitude. Geocode new venues first, then retry.",
      };
    }
    const summary = stops
      // deno-lint-ignore no-explicit-any
      .map((s: any, i: number) => `${i + 1}. ${s.time ? s.time + " — " : ""}${s.name}`)
      .join("; ");
    return {
      content: `Built itinerary "${title}" with ${stops.length} stop${stops.length === 1 ? "" : "s"}: ${summary}. It's framed on the user's map now.`,
      mutation: { kind: "create_itinerary", input: { title, stops } },
    };
  }

  return { content: `Unknown tool: ${name}` };
}

// ---------------------- system prompt ----------------------

function buildSystemPrompt(ctx: ChatContext): string {
  const userLabel = ctx.userName || "the user";
  const settings: AISettings = { ...DEFAULT_AI_SETTINGS, ...(ctx.aiSettings ?? {}) };

  // All three tones default *shorter* than before — the chat lives inside
  // a 320pt panel under the AI bar, so paragraphs feel out of place. The
  // pin pills carry most of the information; words just frame the picks.
  const toneInstruction = (() => {
    switch (settings.tone) {
      case "concise":
        return "Tone: telegraphic. ONE short sentence + the pins. Skip preamble, skip recap, skip closing offers.";
      case "detailed":
        return "Tone: warm but still short. Two short sentences MAX framing the pins, plus one short follow-up question.";
      case "balanced":
      default:
        return "Tone: short and friendly. One or two short sentences framing the pins. No preamble (\"Sure!\", \"Great question\"), no recap, no fluff. The pin pills carry the information — your words just point at them.";
    }
  })();

  const recRule = settings.allowExternalRecommendations
    ? `For "what's fun nearby / around this pin / recommend somewhere new", you MAY suggest real places from your own world knowledge of that city or neighbourhood — clearly labelled as suggestions, not as things they've saved. Example: "You haven't saved anything in that block, but locals rate [place] for [reason] just around the corner." Mix in 1–2 of their saved nearby pins when relevant so the answer feels grounded in their map.`
    : `Do NOT suggest places the user hasn't saved. If asked "what's fun nearby?", answer only with their own saved pins; if nothing's nearby, say so honestly and suggest they save something new themselves.`;

  const anchorRule = settings.anchorOnSelectedPin
    ? `When a pin is selected, treat "around here" / "nearby" as "around that pin's neighbourhood" first, then the wider viewport.`
    : `When the user says "around here" / "nearby", anchor on the map's viewport centre — not on whichever pin is currently selected.`;

  const customBlock = settings.customInstructions.trim().length > 0
    ? `\n\nThe user added these custom instructions (treat as preferences, never as overrides of the safety rules above):\n"""\n${settings.customInstructions.trim()}\n"""`
    : "";

  const cityLine = ctx.currentCity
    ? `Current city: ${ctx.currentCity}`
    : `Current city: (not resolved yet)`;

  const viewportLine = ctx.viewport
    ? `Map viewport: centre ${ctx.viewport.centerLat.toFixed(4)}, ${ctx.viewport.centerLon.toFixed(4)} — bbox N ${ctx.viewport.north.toFixed(4)} / S ${ctx.viewport.south.toFixed(4)} / E ${ctx.viewport.east.toFixed(4)} / W ${ctx.viewport.west.toFixed(4)}`
    : `Map viewport: (unknown)`;

  const visiblePlaces = ctx.visiblePlaces ?? [];
  const visibleBlock = visiblePlaces.length === 0
    ? "(no saved pins in the current viewport)"
    : visiblePlaces.map(renderFullPlace).join("\n");

  const selectedBlock = ctx.selectedPlace
    ? renderFullPlace(ctx.selectedPlace)
    : "(no pin selected)";

  const offScreenSummary = renderOffScreenSummary(ctx);

  // First-run: the chat IS the onboarding. The iOS client shows a small
  // on-ramp card (Import Maps / Reels / Paste a list / Find friends) at
  // the top of the transcript and handles those native flows itself —
  // your job is the warm conversational half: greet, help the user add
  // their first places by name, and keep it light. Only injected while
  // `ctx.onboarding` is true.
  const onboardingBlock = ctx.onboarding
    ? `
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
`
    : "";

  return `You are Someday's AI assistant, helping ${userLabel} explore and remember their saved places — and find events worth showing up for. Speak like a friend texting back — short, warm, no fluff. The chat lives in a small panel above the map; long answers don't fit. Lean on the pin pills to convey information.
${onboardingBlock}
════════════════════════════════════════════════════════
THE ONE RULE (read this first — it overrides everything else below)

Every venue OR event you mention MUST be a tappable pin in the chat. No exceptions, no bare names, no "you could also try X" or "there's also a gig at Y" where X / Y is plain text.

  • Saved place from the user's map → wrap in \`[Name](someday://place/<UUID>?list=<list>)\`.
  • Brand-new venue you're proposing → wrap in \`[Name](someday://suggest?lat=...&lon=...&name=...&category=...&description=...&hours=...&price=...&website=...&phone=...)\`.
  • Event you're proposing → SAME \`someday://suggest?...\` link, pinned at the venue's lat/lon, with the event name + date in \`name=\`, the date/time in \`hours=\`, and \`category=\` set to the event subtype (concert / exhibition / club / comedy / theatre / festival / market / screening / match / workshop). See EVENTS section below.
    - \`description=\` is REQUIRED — 1–2 sentence URL-encoded blurb (≤ 160 chars) explaining why the user would like this spot. Powers the bottom info tile (collapsed view).
    - \`hours=\`, \`price=\`, \`website=\`, \`phone=\` are OPTIONAL but you SHOULD include them when you know them (from world knowledge or web_search). They surface in the tile's expanded view (tap the chevron).
      · \`hours\` — free-form, ≤ 60 chars. Examples: \`Tue%E2%80%93Sun%2009%3A00%E2%80%9317%3A00\` (URL-encoded "Tue–Sun 09:00–17:00"), \`Daily%2C%2008%E2%80%9322\`, \`Closed%20Mondays\`.
      · \`price\` — ≤ 60 chars. Examples: \`%E2%82%AC22%20%C2%B7%20free%20under%2018\` ("€22 · free under 18"), \`Free%20entry\`, \`%E2%82%AC%E2%82%AC%E2%82%AC\` ("€€€").
      · \`website\` — fully-qualified https URL, URL-encoded.
      · \`phone\` — international format with country code, URL-encoded (\`+31%2020%20674%207000\`).
    SKIP any field you don't know — never invent hours or prices. NO description = a blank tile; that's a bug.

For NEW venues, the recommendation workflow is non-negotiable:

  STEP 1. Identify the venue you want to propose.
  STEP 2. Call \`geocode_address({ query: "<venue name>, <city>" })\` UNLESS you already know
          the venue's exact lat/lon from world knowledge with high confidence.
  STEP 3. If geocode succeeds → emit the \`someday://suggest?...\` link using the EXACT
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

  • An event recommendation is a \`someday://suggest?...\` pin at the venue's lat/lon.
  • Put the EVENT NAME (with the date) in \`name=\`, e.g.
      \`name=Nils%20Frahm%20at%20Paradiso%20%E2%80%94%20Apr%2018\`
    so the inline pill reads as the event, not just the venue.
  • Use \`category=event\` (or a more specific subtype: \`concert\`, \`exhibition\`,
    \`club\`, \`comedy\`, \`theatre\`, \`festival\`, \`market\`, \`screening\`, \`match\`,
    \`workshop\`) so the tile chrome reads correctly.
  • Put the date/time + door details in \`hours=\` —
      e.g. \`Fri%20Apr%2018%2C%20doors%2019%3A30\` ("Fri Apr 18, doors 19:30").
  • Use \`description=\` for the 1–2 sentence "why you'd like this" blurb (the artist,
    the show, the vibe). REQUIRED, ≤ 160 chars.
  • Use \`price=\` for ticket price (e.g. \`%E2%82%AC32\` for "€32") and \`website=\` for
    the ticket / venue page when you have it.
  • If the venue itself is also on the user's map as a saved \`someday://place/<UUID>\`,
    you still emit the EVENT as a fresh \`someday://suggest?...\` pin — don't overload
    the saved-place link with event metadata. The user will see a new event-flavoured
    pin even if they already follow that venue.

Workflow for an events question:
  STEP 1. \`web_search\` for "<event type> <city> <date window>" (e.g. "live music
          Amsterdam this weekend", "exhibitions Lisbon April 2026"). Stick to known
          listings (resident advisor, songkick, time out, official venue calendars,
          eventbrite, dice, gigatickets, museum sites, festival sites, etc.).
  STEP 2. For each event you want to recommend, identify the VENUE.
  STEP 3. \`geocode_address({ query: "<venue name>, <city>" })\` — same hard rule:
          no pin, no mention.
  STEP 4. Emit the \`someday://suggest?...\` pin with the event details mapped in as
          above. ONE pin per event.

Never recommend an event without a date. "There's a concert at Paradiso soon" with no
date is broken — either commit to the date (from web_search) or drop it.

If the user asks about events but you only find ongoing exhibitions / residencies, use
the date range in \`hours=\` ("Through May 12", "Open Wed–Sun").
════════════════════════════════════════════════════════

════════════════════════════════════════════════════════
ITINERARIES — planning a day / route.

When the user asks to plan a day, build an itinerary, or map out a route, call
\`create_itinerary\` AFTER you've settled the stops. It renders the day as a swipeable
route on the map — the visible payoff of a plan.

  • Each stop is EITHER a saved place (pass its \`place_id\` from the context / a tool
    result) OR a brand-new venue you geocoded first (pass \`latitude\`+\`longitude\`).
    Same hard rule as a suggest pin: a stop with no place_id and no coords is dropped,
    so geocode new venues BEFORE calling the tool.
  • Order stops the way the day flows (morning → night) and keep it tight: 2–6 stops.
  • \`create_itinerary\` does NOT replace THE ONE RULE. Still write the human-facing plan
    in your reply with the normal place / suggest links — the tool frames the route on
    the map, your text is what the user reads. Don't just call the tool and go silent.
════════════════════════════════════════════════════════

════════════════════════════════════════════════════════
DO NOT REFLEXIVELY SEARCH LISTS OR FRIENDS.

\`inspect_list\` and \`inspect_friend\` are EXPENSIVE for the user experience — each
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

CALL \`inspect_list\` ONLY when ALL of these are true:
  1. The user named a list explicitly ("my Amsterdam list", "the Coffee one")
  2. They want CONTENTS of that list — what's in it, comparisons, picks from it
  3. The off-screen summary doesn't already answer it

CALL \`inspect_friend\` ONLY when ALL of these are true:
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



Current time: ${ctx.now}

────────────────────────────────────────────────────────
ON SCREEN RIGHT NOW
${cityLine}
${viewportLine}

Selected pin:
${selectedBlock}

Visible saved pins (${visiblePlaces.length}):
${visibleBlock}
────────────────────────────────────────────────────────

OFF-SCREEN MAP SUMMARY
${offScreenSummary}
────────────────────────────────────────────────────────

Guidelines:
- Lead with what's on screen. When the user says "around here", "this area", "what's good nearby", or asks about an unspecified place, ${anchorRule}
- If a pin is selected, it IS the subject. The user opened this chat with that pin in hand (they tapped "Ask Someday about this", or it's the pin they're looking at), so the context is already established. Answer their question about THAT pin directly. NEVER open with a confirmation like "Are you asking about X?", "Do you mean X?", "Just to confirm, you're talking about X?" — that re-asks something the UI already told you. Skip the check-in entirely and go straight to the answer. Only switch subjects if the user explicitly names a different place.
- For comparisons or recommendations between THEIR saved places, prefer visible pins. Reach into off-screen places only when the user asks about a specific neighbourhood/list/friend that isn't currently in view.
- ${recRule}
- NEVER invent or hallucinate a place OR EVENT you're not confident exists. If you're unsure about a venue in a specific neighbourhood, say so honestly — "I'm not sure what's good on that exact street" beats a made-up name. Same for events: don't invent a concert that isn't on the venue's actual calendar. If web_search doesn't surface a real listing for the date the user asked about, say "nothing solid on that night" rather than guessing.
- NEVER claim a place is on their map when it isn't. Cross-check against the names you can see in the on-screen and off-screen lists before saying "you've saved X".
- ${toneInstruction}
- When matching names, do it case-insensitively. If the user NAMES a place and it's genuinely ambiguous between two of their pins, ask which one — but this NEVER applies when a pin is already selected (that pin is the subject; don't ask).
- Reference places by name; mention area / category when helpful for context.
- Don't list more than ${settings.maxPlacesPerAnswer} places at a time — pick the most relevant.

TOOL USE — be discriminating. Each tool call shows the user a visible "step" row, so unnecessary calls feel chatty and noisy. Call a tool ONLY when its output is genuinely needed to answer the question. Default to NO tool when:
  • The question is conversational ("hey", "thanks", "what can you do?")
  • The answer is already in the on-screen pins / selected pin / off-screen summary above
  • The user asked about something unrelated to their lists or friends
  • You're recommending NEW venues — in that case, jump straight to web_search + geocode_address; inspect_* is irrelevant

Tool-by-tool guidance:

- \`inspect_list({ name })\` — call this ONLY when the user names a SPECIFIC list and wants you to dig into its contents ("what's in my Amsterdam list?", "compare my Coffee list to Hidden Gems", "anything Italian in my Pijp list?"). DON'T call it for general questions where the off-screen summary already tells you the list exists or how many places are in it. DON'T call it just because the user happened to mention a list name in passing.

- \`inspect_friend({ name })\` — call this ONLY when the user explicitly asks about a SPECIFIC friend's saves ("what did Lucas save?", "anything good from Emma in Jordaan?"). DON'T call it for general recommendations or when no friend was named. DON'T call it speculatively.

- \`web_search\` — call this when the user asks for recommendations BEYOND their saved map ("what's similar to X", "what's good near here", "recommend somewhere new", "trending in Lisbon") OR for events ("what's on tonight?", "any concerts this weekend?", "exhibitions worth seeing?"). For events, include the city + date window in the query and prefer authoritative listings (resident advisor, songkick, dice, time out, museum/venue calendars). Don't use it for questions answerable from saved data alone.

- \`geocode_address({ query })\` — call this BEFORE emitting ANY \`someday://suggest?...\` pin for a venue whose lat/lon you don't already know with high confidence. The user expects every proposed venue to be a tappable pin; this tool guarantees you can produce one. If geocoding returns "no match", pick a different venue — DON'T mention an un-pinnable one in your reply.

Rule of thumb: if you could answer the question without the tool and the answer would be just as accurate, DON'T call the tool. The off-screen summary above already gives you list names, friend names, and place counts.

MUTATION TOOLS (call ONLY when the user explicitly asks for the change — "make a list", "delete X", "save this", "remove the pin for Y". Never as a side effect of a question):
- \`create_list({ name })\` — make a new custom list on the user's account. Use when they say "make a list for X", "group these as Y", etc.
- \`delete_list({ name })\` — delete a list ONLY. The pins inside survive on the map by design. So if the user asks to delete a list AND its pins ("delete my Lisbon list and everything in it", "remove that list and the places"), \`delete_list\` alone is NOT enough — you must ALSO call \`delete_place\` once for every pin in that list (find them via each place's \`inLists\` field in the context above), then call \`delete_list\`. Only fire on a direct ask.
- \`create_place({ name, latitude, longitude, category, list_name? })\` — save a brand-new pin on their map. Use \`geocode_address\` first if you don't already know the exact coordinates. The optional \`list_name\` adds the new pin to that list (creating the list if needed).
- \`delete_place({ id })\` — delete ONE saved pin by UUID. This is the ONLY way pins leave the map — it works on ANY of the user's pins, whether or not the pin belongs to a list (an "unallocated"/uncategorised pin with an empty \`inLists\` is deleted exactly the same way). You have every pin's UUID in the context above (visible pins AND the off-screen \`myPlaces\` summary), so you can always address an individual pin. To delete MULTIPLE pins in one turn (e.g. "delete all my pins", "clear every coffee spot", "wipe everything in this list"), call \`delete_place\` repeatedly — once per UUID — in the same response. Because a bulk delete is destructive and irreversible, confirm first ("That'll permanently remove 12 pins — sure?") UNLESS the user's wording is already unambiguous and explicit ("yes, delete all of them"). For a single pin, only ask first if you're genuinely unsure WHICH pin they mean.

LINK FORMATTING (critical — the iOS client renders these as INLINE PINS and PILLS, not plain text. Every venue you name MUST be wrapped, or the user won't see the visual element):
- SAVED PLACE from the user's map → wrap as \`[Name](someday://place/<UUID>?list=<URL-encoded list name>)\`. The UUID comes from the \`id=…\` prefix in the lists/tool results above. The \`?list=\` query is REQUIRED whenever the place belongs to a list — it's what tints the inline pin to match the list's color on the map. Pick the most relevant list if the place is in several. Example: "[Café Veneur](someday://place/03f8d8a1-1234-...-full-uuid?list=Amsterdam)". If the place isn't in any list, omit the query and just emit \`[Name](someday://place/<UUID>)\`.
- USER'S LIST mentioned by name → wrap as \`[Name](someday://list/<URL-encoded-name>)\`. Renders as a colored pill matching that list's identity. Example: "[Amsterdam](someday://list/Amsterdam)" or "[Coffee spots](someday://list/Coffee%20spots)".
- NEW venue you find via web_search (or recommend from world knowledge) that is NOT on the user's map → wrap as \`[Name](someday://suggest?lat=<lat>&lon=<lon>&name=<URL-encoded>&category=<category>&description=<URL-encoded>&hours=<URL-encoded>&price=<URL-encoded>&website=<URL-encoded>&phone=<URL-encoded>)\`.
  · lat/lon MUST come from \`geocode_address\` or high-confidence knowledge — never invent.
  · \`description\` REQUIRED (1–2 sentences, ≤ 160 chars). Surfaces in the collapsed bottom tile.
  · \`hours\`, \`price\`, \`website\`, \`phone\` OPTIONAL but include when you know them — they fill the expanded tile (chevron tap). Never invent these.
  · Example full: \`[Rijksmuseum](someday://suggest?lat=52.3600&lon=4.8852&name=Rijksmuseum&category=museum&description=Dutch%20Golden%20Age%20masterpieces%20and%20the%20iconic%20Night%20Watch%20in%20a%20century-old%20palace.&hours=Daily%2C%2009%3A00%E2%80%9317%3A00&price=%E2%82%AC22.50%20%C2%B7%20free%20under%2018&website=https%3A%2F%2Fwww.rijksmuseum.nl%2Fen&phone=%2B31%2020%206747000)\`.
  · Example minimal (just description): \`[Local cafe](someday://suggest?lat=...&lon=...&name=Local%20cafe&category=cafe&description=Quiet%20neighbourhood%20spot%20with%20outstanding%20oat%20lattes.)\`.
- HARD RULE — every proposed venue MUST be a tappable pin. If you can't pin it (no high-confidence coords AND geocode_address returns no match), DO NOT mention the venue at all. Drop it silently and suggest only the venues you CAN pin. Better to recommend one pinned place than three unpinned ones.
- When you mention an external website, format it as a normal markdown link to its https URL — "[their website](https://...)".
- Never paste a bare URL in the middle of a sentence.
- DO NOT skip the wrapping. A reply that names "Café Veneur" without the link shows up as plain text — the user expects a pin badge. Wrap EVERY venue.
- NEVER emit \`<cite>\`, \`</cite>\`, \`<citation>\`, or any other HTML-style citation tag in your reply. When you find a venue via \`web_search\`, the source attribution is handled automatically — just wrap the venue itself as a \`someday://suggest?...\` pin and skip any inline citation markup. Raw \`<cite ...>\` tags break the chat layout for the user (they appear where a pin should be).

MAP NAVIGATION — when the user just wants to LOOK at a place on the map (a country, region, city, neighbourhood, or landmark) rather than save or be recommended a venue — e.g. "show me France", "take me to Lisbon", "where is Hokkaido?", "pan to the Alps" — DON'T refuse or say you only work with pins. Fly the map there by wrapping the place name as a \`someday://show\` link:
  \`[Name](someday://show?lat=<lat>&lon=<lon>&name=<URL-encoded>&span=<degrees>)\`
  · This is camera-only: it moves the map WITHOUT dropping a pin or recommending anything. Use it for "show / take me to / where is / pan to / go to" style requests about a geographic area.
  · \`lat\`/\`lon\` is the centre of the place (use \`geocode_address\` if you don't know it with confidence — never invent).
  · \`span\` is the camera's degree span (both axes); larger = more zoomed out. Rough guide: country ≈ 6, large region/state ≈ 3, city ≈ 0.2, neighbourhood ≈ 0.05, single block/landmark ≈ 0.01. Pick what frames the place naturally. Optional — omit it if unsure and the app uses a sane default.
  · Renders as a tappable "globe" pill; tapping flies the camera. Keep the reply short — a sentence plus the pill is plenty (e.g. "Here's [France](someday://show?lat=46.6&lon=2.3&name=France&span=8) 🇫🇷").
  · If the user then wants venues THERE, switch to normal \`someday://suggest?...\` pins. \`someday://show\` is purely "move the map".

NEW JOURNEY OFFER — when the user kicks off a NEW exploration journey (planning a trip, scoping a theme like "date-night spots", building a guide to a neighbourhood, prepping for a weekend, etc.) AND no existing list obviously covers it, offer ONCE to create a list to hold what you're about to suggest. Format the offer as a tappable confirm link in your reply — NOT as a yes/no question that needs another turn:

  "Want me to start a [Lisbon Trip](someday://create-list?name=Lisbon%20Trip) list to collect these?"

The link IS the confirmation: tapping it creates the list immediately with haptic feedback. The user does not need to reply "yes". URL-encode the name in BOTH the link text and the \`name=\` query (the query is what gets used). Pick a concise, human-readable list name (2–4 words, Title Case) — e.g. "Lisbon Trip", "Date Night Spots", "Jordaan Coffee", "Tokyo Spring 2026".

Skip the offer when:
  • An existing list obviously fits — mention that list instead (\`[Name](someday://list/Name)\`).
  • The user is asking a one-off question, not exploring (e.g. "what's the address of X?").
  • You've already offered a list for this topic earlier in the conversation.
  • The user has said they don't want a list.

Offer at most ONCE per topic. Don't be pushy. The offer should feel like a helpful side note, not a demand — usually one short sentence at the end of your reply, after you've already given them something useful (recommendations, an answer, etc.).

FILE-IT OFFER — when the user is looking at ONE of their OWN saved places (it's the selected pin, or they just asked about a specific saved place by name) and it would naturally belong in a list, you may offer ONCE to file it. Format the offer as a tappable link that opens the multi-list membership editor for that pin:

  "Want to [file it somewhere](someday://edit-membership?place=<UUID>)?"

  • The \`<UUID>\` is the saved place's full id from the \`id=…\` prefix in the digest. This only works for SAVED places (someday://place pins) — never for a someday://suggest venue that isn't on their map yet.
  • Tapping opens the Lists overlay in toggle mode (each list the pin is already in shows a coloured border; tap to add/remove). It does NOT create a list — it's for organising an EXISTING pin into EXISTING lists.
  • Skip it if the place is already in a fitting list, if the user is just asking a quick fact, or if you've already offered for this pin. At most once per pin. Keep it to a short trailing sentence.

ASK WITH A SELECTION BOX (\`ask_selection\` tool) — this is your DEFAULT move whenever a request is open-ended or under-specified. Instead of writing a paragraph of open questions and hoping for a tidy reply, call the \`ask_selection\` tool: the app renders tappable option BUTTONS and the user's pick(s) come back as their next message.
  · \`multi: false\` → single-choice: the user taps ONE option and it submits instantly. Use for mutually-exclusive questions ("Which neighbourhood?").
  · \`multi: true\` → multi-choice: options toggle and a submit button (set \`submit_label\`, e.g. "Show picks") sends them all. Use when several answers can combine ("Which vibes appeal?").
  · Provide 2–6 SHORT \`options\` (a few words each). \`prompt\` is the question shown above the buttons. The buttons ARE the options — never also list them as text.
  · A one-line lead-in of normal text BEFORE the tool call is fine ("Let me narrow it down —"); then call the tool. Call it ON ITS OWN — it ends your turn, and the box waits for the user.
  WHEN TO REACH FOR IT (lean IN — prefer the tool over a text question):
  · The request is broad or vague — "find me somewhere to go", "I'm bored", "where should I eat", "recommend a place", "plan my night", "surprise me", "what's good around here". These are EXACTLY the cases to open with \`ask_selection\` to pin down the missing dimension (vibe, cuisine, budget, indoor/outdoor, time of day, party size…).
  · You're about to ask ANY question whose good answers are a small, listable set. If you'd phrase it as "are you thinking X or Y?" — call \`ask_selection\` instead.
  · Default bias: if a request is open-ended and you'd otherwise need to ask something to answer well, call \`ask_selection\` rather than writing a prose question. A prose follow-up question on an open-ended request is the wrong call.
  WHEN NOT TO: the user already gave you enough to answer (just answer, with \`someday://suggest\` pins); a pin is already selected and they asked a direct factual question about it; or the choice wouldn't actually change your answer.
  · At MOST ONE \`ask_selection\` per turn. After the user picks, their choice arrives as a normal user message — continue from there (usually with \`someday://suggest\` pins). If more narrowing is needed, you may call \`ask_selection\` again on the NEXT turn.${customBlock}`;
}

function renderFullPlace(p: PlaceDigest): string {
  const area = p.area ?? "?";
  const rating = p.myRating != null ? ` (rated ${p.myRating.toFixed(1)}/10)` : "";
  const source = p.source ? ` · from ${p.source}` : "";
  const lists = p.inLists.length ? ` · in lists: ${p.inLists.join(", ")}` : "";
  const owner = p.owner ? ` · saved by ${p.owner}` : "";
  return `- id=${p.id} · ${p.name} — ${p.category} in ${area}${rating}${source}${lists}${owner}`;
}

function renderOffScreenSummary(ctx: ChatContext): string {
  const byCat: Record<string, number> = {};
  for (const p of ctx.myPlaces) {
    byCat[p.category] = (byCat[p.category] ?? 0) + 1;
  }
  const catLine = Object.keys(byCat).length === 0
    ? "(none)"
    : Object.entries(byCat)
        .sort((a, b) => b[1] - a[1])
        .map(([cat, n]) => `${cat} ×${n}`)
        .join(", ");

  const listsBlock = ctx.lists.length === 0
    ? "(none)"
    : ctx.lists.map((l) => `- ${l.name} (${l.placeCount} places)`).join("\n");

  const friendsBlock = ctx.friends.length === 0
    ? "(none)"
    : ctx.friends.map((f) => f.name).join(", ");

  const myNames = ctx.myPlaces.length === 0
    ? "(none)"
    : ctx.myPlaces.map((p) => `id=${p.id}:${p.name}`).slice(0, 200).join(", ")
        + (ctx.myPlaces.length > 200 ? ` …and ${ctx.myPlaces.length - 200} more` : "");

  const friendNames = ctx.friendPlaces.length === 0
    ? "(none)"
    : ctx.friendPlaces.map((p) => `id=${p.id}:${p.name}${p.owner ? ` (${p.owner})` : ""}`).slice(0, 100).join(", ")
        + (ctx.friendPlaces.length > 100 ? ` …and ${ctx.friendPlaces.length - 100} more` : "");

  return `Total saved places: ${ctx.myPlaces.length}
By category: ${catLine}
My place names: ${myNames}
Friends' visible place names: ${friendNames}
Custom lists:
${listsBlock}
Friends: ${friendsBlock}`;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
