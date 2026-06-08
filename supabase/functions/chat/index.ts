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

import Anthropic from "npm:@anthropic-ai/sdk@0.30.0";
import { corsHeaders } from "../_shared/cors.ts";

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

  // -------- 2. Env -------------------------------------------------------
  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!anthropicKey) {
    return json({ error: "ANTHROPIC_API_KEY not configured" }, 500);
  }

  // -------- 3. Build system prompt --------------------------------------
  const systemPrompt = buildSystemPrompt(body.context);
  const anthropic = new Anthropic({ apiKey: anthropicKey });

  // -------- 4. SSE stream + agentic tool loop ---------------------------
  const encoder = new TextEncoder();
  const ctx = body.context;

  const stream = new ReadableStream({
    async start(controller) {
      const send = (event: string, data: unknown) => {
        controller.enqueue(
          encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`),
        );
      };

      try {
        // Anthropic-format conversation we keep extending as we loop.
        // Starts from the iOS-supplied history; we push assistant +
        // user (tool_result) turns each iteration that uses a client tool.
        // deno-lint-ignore no-explicit-any
        const conversation: Array<{ role: "user" | "assistant"; content: any }> =
          body.messages.map((m) => ({ role: m.role, content: m.content }));

        let stepCounter = 0;

        // ---- Upfront context-overview steps ---------------------------
        //
        // Before the model loop runs, surface what's actually being
        // considered: the user's own lists, then their friends'
        // shareable lists. Each step carries a `chips` array the iOS
        // bubble renders as a stacked preview (colored list pills /
        // friend avatars). Marked done immediately — they're a
        // "scoping" step, not real work — but the model loop's
        // subsequent `inspect_list` / `inspect_friend` calls land
        // beneath them and the user sees the full reasoning trail.
        const listNames = ctx.lists.map((l) => l.name);
        if (listNames.length > 0) {
          stepCounter += 1;
          const id = `step_${stepCounter}`;
          send("step", {
            id,
            icon: "list.bullet.rectangle.fill",
            label: `Searching your lists`,
            chips: listNames,
          });
          send("step_done", { id });
        }
        const friendNames = ctx.friends.map((f) => f.name);
        if (friendNames.length > 0) {
          stepCounter += 1;
          const id = `step_${stepCounter}`;
          send("step", {
            id,
            icon: "person.2.fill",
            label: `Searching friends' lists`,
            chips: friendNames,
          });
          send("step_done", { id });
        }

        for (let iter = 0; iter < MAX_TOOL_ITERATIONS; iter++) {
          // Per-iteration map: block index → step ID. We use it to emit
          // step_done events at the end of the iteration when we know the
          // model has finished writing this tool call.
          const stepIDByBlockIndex = new Map<number, string>();

          const ms = anthropic.messages.stream({
            model: MODEL,
            max_tokens: 1024,
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
                type: "web_search_20250305",
                name: "web_search",
                max_uses: 3,
                // deno-lint-ignore no-explicit-any
              } as any,
            ],
            messages: conversation,
          });

          // Live-stream events to the client as they fire.
          // deno-lint-ignore no-explicit-any
          ms.on("streamEvent", (event: any) => {
            if (event.type === "content_block_start") {
              const block = event.content_block;
              if (
                block?.type === "tool_use" ||
                block?.type === "server_tool_use"
              ) {
                stepCounter += 1;
                const stepID = `step_${stepCounter}`;
                stepIDByBlockIndex.set(event.index, stepID);
                send("step", {
                  id: stepID,
                  icon: stepIcon(block.name),
                  label: stepLabel(block),
                });
              }
            } else if (event.type === "content_block_delta") {
              if (event.delta?.type === "text_delta") {
                send("text", { delta: event.delta.text });
              }
            }
          });

          const message = await ms.finalMessage();

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

          // Push the assistant's tool-using turn into the conversation,
          // then a user turn with all tool_result blocks. Loop again.
          conversation.push({
            role: "assistant",
            content: message.content,
          });
          // `executeClientTool` is now async (geocode_address hits
          // Nominatim, the mutation tools emit SSE events back). Each
          // call returns `{ content, mutation? }`. We emit any
          // mutation onto the SSE stream BEFORE pushing the
          // tool_result back — so the iOS side starts applying the
          // mutation immediately (optimistic UI) while the model
          // continues thinking on the same turn.
          const settled = await Promise.all(
            toolUseBlocks.map(async (tb) => ({
              tb,
              result: await executeClientTool(tb.name, tb.input, ctx),
            })),
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
        send("error", { message: String(err) });
      } finally {
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
  kind: "create_list" | "delete_list" | "create_place" | "delete_place";
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

  return `You are Someday's AI assistant, helping ${userLabel} explore and remember their saved places. Speak like a friend texting back — short, warm, no fluff. The chat lives in a small panel above the map; long answers don't fit. Lean on the pin pills to convey information.

════════════════════════════════════════════════════════
THE ONE RULE (read this first — it overrides everything else below)

Every venue you mention MUST be a tappable pin in the chat. No exceptions, no bare names, no "you could also try X" where X is plain text.

  • Saved place from the user's map → wrap in \`[Name](someday://place/<UUID>?list=<list>)\`.
  • Brand-new venue you're proposing → wrap in \`[Name](someday://suggest?lat=...&lon=...&name=...&category=...)\`.

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
SCOPE GUARDRAIL — what you'll help with and what you won't.

Someday is a place-discovery and place-memory app. Your job is bounded to that domain:
  ✓ Recommending or finding venues (restaurants, bars, cafés, activities, art, travel)
  ✓ Talking about the user's saved places, lists, and friends' saves
  ✓ Comparing places, summarising a neighbourhood, suggesting an itinerary
  ✓ Mutations on the user's data via the tools (create/delete lists, save/remove pins)
  ✓ Reservations / availability for venues the user is curious about
  ✓ Trip planning that's grounded in places ("3 days in Lisbon" with pinned venues)

If the user asks ANYTHING outside that scope — coding help, math, news, weather (unless
strictly tied to "should I go to X tonight"), general trivia, life advice, gossip,
philosophical questions, language translation, joke requests, write-me-an-email tasks,
celebrity facts, sports scores, etc. — politely decline with EXACTLY this shape:

  "Sorry, Someday exists to explore and experience. I can't help with that —
   but if you want to find somewhere good to go, I'm in."

(You may rephrase the second sentence to be context-aware — e.g. "but if you're
curious about anywhere in <currentCity>, ask away" — but the first sentence stays
verbatim so the refusal reads consistently every time. Don't apologise twice. Don't
offer to "try anyway".)

Edge cases:
  • "What time is it?" → refuse (the chat isn't a clock).
  • "What's the weather?" → ONLY answer if it's clearly to decide a venue ("is the
    rooftop bar X going to be open with this rain?"); otherwise refuse.
  • "How do I cook risotto?" → refuse.
  • "Translate this menu" → refuse — but offer to find a similar venue instead.
  • A vague "hi" / "hey" / "thanks" → NOT a scope violation. Reply briefly + warmly,
    no refusal, no tool calls.
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
- If a pin is selected, treat it as the subject of any follow-up unless the user names something else.
- For comparisons or recommendations between THEIR saved places, prefer visible pins. Reach into off-screen places only when the user asks about a specific neighbourhood/list/friend that isn't currently in view.
- ${recRule}
- NEVER invent or hallucinate a place you're not confident exists. If you're unsure about a venue in a specific neighbourhood, say so honestly — "I'm not sure what's good on that exact street" beats a made-up name.
- NEVER claim a place is on their map when it isn't. Cross-check against the names you can see in the on-screen and off-screen lists before saying "you've saved X".
- ${toneInstruction}
- When matching names, do it case-insensitively. If ambiguous, ask which one.
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

- \`web_search\` — call this when the user asks for recommendations BEYOND their saved map ("what's similar to X", "what's good near here", "recommend somewhere new", "trending in Lisbon"). Don't use it for questions answerable from saved data alone.

- \`geocode_address({ query })\` — call this BEFORE emitting ANY \`someday://suggest?...\` pin for a venue whose lat/lon you don't already know with high confidence. The user expects every proposed venue to be a tappable pin; this tool guarantees you can produce one. If geocoding returns "no match", pick a different venue — DON'T mention an un-pinnable one in your reply.

Rule of thumb: if you could answer the question without the tool and the answer would be just as accurate, DON'T call the tool. The off-screen summary above already gives you list names, friend names, and place counts.

MUTATION TOOLS (call ONLY when the user explicitly asks for the change — "make a list", "delete X", "save this", "remove the pin for Y". Never as a side effect of a question):
- \`create_list({ name })\` — make a new custom list on the user's account. Use when they say "make a list for X", "group these as Y", etc.
- \`delete_list({ name })\` — delete a list. The places inside survive. Only fire on a direct ask.
- \`create_place({ name, latitude, longitude, category, list_name? })\` — save a brand-new pin on their map. Use \`geocode_address\` first if you don't already know the exact coordinates. The optional \`list_name\` adds the new pin to that list (creating the list if needed).
- \`delete_place({ id })\` — delete a saved pin by UUID. Only on a direct ask, and only when you're sure which pin they mean — if their wording is ambiguous, ask first.

LINK FORMATTING (critical — the iOS client renders these as INLINE PINS and PILLS, not plain text. Every venue you name MUST be wrapped, or the user won't see the visual element):
- SAVED PLACE from the user's map → wrap as \`[Name](someday://place/<UUID>?list=<URL-encoded list name>)\`. The UUID comes from the \`id=…\` prefix in the lists/tool results above. The \`?list=\` query is REQUIRED whenever the place belongs to a list — it's what tints the inline pin to match the list's color on the map. Pick the most relevant list if the place is in several. Example: "[Café Veneur](someday://place/03f8d8a1-1234-...-full-uuid?list=Amsterdam)". If the place isn't in any list, omit the query and just emit \`[Name](someday://place/<UUID>)\`.
- USER'S LIST mentioned by name → wrap as \`[Name](someday://list/<URL-encoded-name>)\`. Renders as a colored pill matching that list's identity. Example: "[Amsterdam](someday://list/Amsterdam)" or "[Coffee spots](someday://list/Coffee%20spots)".
- NEW venue you find via web_search (or recommend from world knowledge) that is NOT on the user's map → wrap as \`[Name](someday://suggest?lat=<lat>&lon=<lon>&name=<URL-encoded name>&category=<category>)\`. The lat/lon MUST come from \`geocode_address\` or your high-confidence knowledge of that EXACT venue — never invent coordinates. Renders as a lime sparkles-pin pill the user can tap to drop on their map. Example: "[Bar Centraal](someday://suggest?lat=52.3702&lon=4.8893&name=Bar%20Centraal&category=cafe)".
- HARD RULE — every proposed venue MUST be a tappable pin. If you can't pin it (no high-confidence coords AND geocode_address returns no match), DO NOT mention the venue at all. Drop it silently and suggest only the venues you CAN pin. Better to recommend one pinned place than three unpinned ones.
- When you mention an external website, format it as a normal markdown link to its https URL — "[their website](https://...)".
- Never paste a bare URL in the middle of a sentence.
- DO NOT skip the wrapping. A reply that names "Café Veneur" without the link shows up as plain text — the user expects a pin badge. Wrap EVERY venue.${customBlock}`;
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
