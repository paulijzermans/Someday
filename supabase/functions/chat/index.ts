// chat Edge Function
// =============================================================================
// Context-aware AI chatbot for the user's Someday map.
//
// Input:
//   {
//     "messages": [
//       { "role": "user" | "assistant", "content": "..." },
//       ...
//     ],
//     "context": {
//       "userName": "...",
//       "now": "ISO 8601",
//       "myPlaces": [...],
//       "friendPlaces": [...],
//       "lists": [...],
//       "friends": [...]
//     }
//   }
//
// Output:
//   { "reply": "..." }
//
// The Edge Function authors the system prompt from `context` so the iOS
// side never needs to build prompt text — it just hands over structured
// data and gets back the assistant's next turn.
//
// Reuses the same `ANTHROPIC_API_KEY` env var the other functions use.
// =============================================================================

import Anthropic from "npm:@anthropic-ai/sdk@0.30.0";
import { corsHeaders } from "../_shared/cors.ts";

const MODEL = "claude-sonnet-4-5";

interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

interface PlaceDigest {
  id: string;
  name: string;
  category: string;
  area: string;
  latitude: number;
  longitude: number;
  myRating: number | null;
  source: string;
  inLists: string[];
  owner: string | null;
}

interface ListDigest { name: string; placeCount: number; }
interface FriendDigest { name: string; }

interface ChatContext {
  userName: string;
  now: string;
  myPlaces: PlaceDigest[];
  friendPlaces: PlaceDigest[];
  lists: ListDigest[];
  friends: FriendDigest[];
}

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

  // -------- 3. Build system prompt from context --------------------------
  // Embed the data as fenced blocks so Claude treats them as structured
  // reference material rather than mixing them with the conversation.
  const systemPrompt = buildSystemPrompt(body.context);

  // -------- 4. Call Claude ----------------------------------------------
  const anthropic = new Anthropic({ apiKey: anthropicKey });
  try {
    const message = await anthropic.messages.create({
      model: MODEL,
      max_tokens: 1024,
      system: systemPrompt,
      messages: body.messages.map((m) => ({
        role: m.role,
        content: m.content,
      })),
    });

    const first = message.content[0];
    if (first.type !== "text") {
      return json({ error: "Unexpected model response shape" }, 502);
    }
    return json({ reply: first.text.trim() });
  } catch (err) {
    console.error("Claude call failed:", err);
    return json({ error: "Chat failed" }, 502);
  }
});

// ---------------------- helpers ----------------------

function buildSystemPrompt(ctx: ChatContext): string {
  const placesBlock = ctx.myPlaces.length === 0
    ? "(none yet)"
    : ctx.myPlaces.map((p) =>
      `- [${p.id.slice(0, 8)}] ${p.name} — ${p.category} in ${p.area}` +
      (p.myRating != null ? ` (rated ${p.myRating.toFixed(1)}/10)` : "") +
      ` · from ${p.source}` +
      (p.inLists.length ? ` · in lists: ${p.inLists.join(", ")}` : "")
    ).join("\n");

  const friendPlacesBlock = ctx.friendPlaces.length === 0
    ? "(none visible)"
    : ctx.friendPlaces.map((p) =>
      `- ${p.name} — ${p.category} in ${p.area}` +
      (p.owner ? ` · saved by ${p.owner}` : "")
    ).join("\n");

  const listsBlock = ctx.lists.length === 0
    ? "(none)"
    : ctx.lists.map((l) => `- ${l.name} (${l.placeCount} places)`).join("\n");

  const friendsBlock = ctx.friends.length === 0
    ? "(none)"
    : ctx.friends.map((f) => `- ${f.name}`).join(", ");

  return `You are Someday's AI assistant, helping ${ctx.userName || "the user"} explore and remember their saved places. Speak naturally — like a friend who knows their map intimately.

Current time: ${ctx.now}

User's saved places (${ctx.myPlaces.length}):
${placesBlock}

Friends' places visible to ${ctx.userName || "the user"} (${ctx.friendPlaces.length}):
${friendPlacesBlock}

User's custom lists:
${listsBlock}

User's friends: ${friendsBlock}

Guidelines:
- Answer concisely. Two or three sentences for most questions.
- When the user mentions a place, match against names case-insensitively. If ambiguous, ask which one.
- Reference places by name; mention area / category when helpful for context.
- For recommendations or comparisons, base your answer on the data above. Don't invent venues.
- If the user asks something outside their map (e.g. general advice), answer naturally but keep it brief.
- If they ask about places you don't have data on, say so honestly rather than guessing.
- Don't list more than 5 places at a time — pick the most relevant.
- Don't dump the raw IDs; they're for your reference only.`;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
