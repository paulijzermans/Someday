# AI_STRATEGY.md — Someday

How we leverage AI to **build** the app and to **be** the app, and how the
current architecture migrates toward that setup over time. Living doc — update
it in the same PR that changes the reality it describes.

> Companion to `CLAUDE.md`. CLAUDE.md is the *how the code works today* guide;
> this is the *where the AI leverage is going* guide.

---

## 1. The two engines

Someday runs on two AI engines that share one architecture.

**Engine A — AI builds the app (build-time).**
Agents write and refactor most of the code. The human is PM/architect: defines
product, steers architecture, reviews output. Quality is gated by tests + CI
rather than line-by-line review, so multiple agents can work in parallel.

**Engine B — AI *is* the app (run-time).**
An LLM sits in the middle at runtime and orchestrates tools. The user gives a
vague goal ("plan my Saturday in Lisbon from my saved spots"); the model decides
which tools to call, fills parameters, and renders results into UI surfaces.
Today this is the `chat` Edge Function + the `someday://` action bus + map
context injection.

The payoff compounds when the two are linked: **what we learn from Engine B —
how users actually use the in-app AI — becomes the highest-value backlog for
Engine A.** That link is the flywheel (§4).

---

## 2. The keystone: service abstraction = the agent boundary

Someday already abstracts every capability behind a protocol held by
`ServiceContainer`, with a **Router** that swaps implementations invisibly:

```
AuthServiceProtocol          PlaceServiceProtocol     UserServiceProtocol
LocationSearchProtocol       ListServiceProtocol      ContactsServiceProtocol
URLExtractionService  ──►  ExtractionRouter(pipeline1, pipeline2)
AvailabilityService   ──►  AvailabilityRouter(live, fallback)
ReservationCheckService ─► ReservationCheckRouter(live, fallback)
ChatService           ──►  ChatRouter(live, fallback)
```

This boundary is doing triple duty, and that is the whole strategy:

1. **It's the swap seam.** A router can replace a hand-coded service with a
   different backend — or with an *agent-driven* one — and nothing upstream
   changes. Pipeline 1 vs Pipeline 2 extraction already proves this.
2. **It's the build-time agent's domain.** A specialized agent owns exactly one
   protocol + its implementations. It can go deep without risking the rest of
   the app, because the protocol is the contract it must not break.
3. **It's the runtime tool namespace.** Each protocol maps cleanly to a cluster
   of tools the orchestrator model composes over (`PlaceServiceProtocol` →
   `get_saved_spots` / `create_place` / `delete_place`).

> The same line in the codebase — the protocol — is the unit of *isolation*, the
> unit of *agent ownership*, and the unit of *model capability*. Keep it sharp.

---

## 3. Specialized agents over a narrow domain

Rather than one generalist agent touching everything, we move toward **narrow
agents with deep domain knowledge**, each scoped to one service boundary.

| Domain agent | Owns (protocol / area) | Deep knowledge it carries |
|---|---|---|
| `extraction-agent` | `URLExtractionService`, both pipelines, `ExtractorConfig` | gmaps/instagram parsing, Railway limits, router fallback rules |
| `rls-agent` | `supabase/schema.sql`, migrations, RLS | row-level security invariants, migration safety |
| `map-agent` | `ClusteredMapView`, pin renderers, `MapViewModel` camera | Core Graphics pin geometry, clustering, tile vocabulary |
| `chat-agent` | `chat` Edge Function, tools, system prompt | tool-loop, SSE streaming, `someday://` action bus |
| `reservation-agent` | `AvailabilityService`, `ReservationCheckService` | provider adapters (Zenchef…), tonight-check semantics |

Why this is safe **because** of §2: an agent confined to one protocol can change
its implementation freely; the contract guarantees the blast radius stops at the
boundary. Tests on the protocol are the gate. This is the build-time mirror of
the runtime tool isolation.

Each domain agent gets a short brief (a mini-CLAUDE.md for its folder) + only the
files in its domain — not the whole repo. Narrow context = deeper, cheaper, more
accurate work.

---

## 4. The improvement flywheel (the "over time" part)

```
   OBSERVE  →  DECIDE  →  CHANGE  →  VERIFY  →  SHIP   ↺
```

| Stage | What happens | Where AI helps |
|---|---|---|
| **Observe** | Capture runtime signal: chat transcripts, which tools fired, tool failures, abandoned flows, feedback tile | AI summarizes transcripts into patterns |
| **Decide** | Turn signal into a small backlog | AI drafts options + trade-offs; human picks |
| **Change** | Implement — usually a *prompt/tool* change, not a screen | Domain agent (Engine A) implements |
| **Verify** | Quality gate before users see it | Tests/CI + eval prompts on AI behavior |
| **Ship** | Build → install → release; Edge Functions deploy independently | Automated build/install flow |

**Most improvements are changes to prompts, tools, and guardrails — not new
screens.** That is what lets the loop spin fast.

### Three places a change can land (cheapest → deepest)
1. **System prompt** — behavior, tone, tool-selection rules. Zero code.
2. **Tools** — new capability = one tool definition + one service method. Main
   growth axis.
3. **App code / UI surfaces** — new render targets (`someday://` commands,
   tiles) the model can draw into. Slowest; defines what the model *can* show.

Healthy ratio: lots of (1) and (2), occasional (3).

---

## 5. Migration: current state → target

### 5.1 What already matches the target
- ✅ Protocol + Router abstraction for every service (the keystone).
- ✅ Runtime tool loop live: `chat` Edge Function exposes `inspect_list`,
  `inspect_friend`, `create_list`, `delete_list`, `create_place`,
  `delete_place`, `geocode_address`, `create_itinerary`, `web_search`.
- ✅ Model renders into UI via the `someday://` action bus (`openPlace`,
  `suggest`, `showOnMap`, `openList`, `plan`…). This *is* a `render_map`-style tool.
- ✅ Map context injection — the model reasons over the user's saved corpus.
- ✅ Mock/live fallback invariant keeps the app always-runnable.
- ✅ **Narrow domain agents** stood up — `.claude/agents/{extraction,map,chat,
  rls,reservation}-agent.md`, each pinned to one service boundary (§3).
- ✅ **OBSERVE telemetry** — every tool call logs a structured `tool_event` line
  (name, ok, ms, mutated, input keys) captured by Supabase function logs.
- ✅ **VERIFY gate** — a Deno eval runner (`chat/evals/run.ts`) replays golden
  prompts against the deployed function and asserts on tool choice + render links.
- ✅ **First action-tool vertical slice** — `create_itinerary` end-to-end: TS tool
  → `mutation` → `ItineraryService` (protocol + mock + router) → map carousel,
  with a `someday://plan` re-frame action. The worked example of growth axis (2)+(3).

### 5.2 The gaps to close
| Gap | Status | Target |
|---|---|---|
| **Tool logic still partly in TS** | ⚠️ open | Mutations already delegate to Swift via the `mutation` SSE seam (`create_*`/`delete_*`/`create_itinerary` are thin emitters); the read tools (`inspect_*`) still shape data in TS. One source of truth per domain. |
| **Tool/transcript telemetry** | ✅ done (logs) | `tool_event` log lines per call. Next: promote to a `tool_events` table for per-user SQL aggregation. |
| **Eval set** | ✅ done | Four golden prompts + a Deno runner gating on tool choice + render links. Grow the set as tools grow. |
| **Generalist build agents** | ✅ done | Five narrow domain agents per §3. |
| **Tool catalog is inspect-heavy** | ⚠️ improving | `create_itinerary` is the first multi-step action tool. Keep growing the *do* side (plan_day, trip-level planning). |

### 5.3 Migration sequence (crawl / walk / run)
- **Crawl (now): ✅ done.**
  - ✅ Tool-call logging added to the `chat` function (OBSERVE).
  - ✅ Golden-prompt eval set + runner stood up (VERIFY).
  - ✅ All five domain agent briefs written — the narrow-agent pattern is proven.
  - ✅ First action-tool slice (`create_itinerary`) shipped end-to-end.
- **Walk (next):**
  - Make each *read* tool delegate to a single source of truth so TS/Swift
    can't drift (mutations already do via the SSE seam). Decide the boundary (§6).
  - Close the loop: a weekly AI-summarized "what did the AI struggle with" (from
    the `tool_event` logs) → 2–3 tool/prompt changes → eval → ship.
  - Expand action tools (`plan_day`, trip-level planning); promote telemetry to a
    `tool_events` table for SQL aggregation.
- **Run:**
  - Parallel domain agents on independent features, gated by CI.
  - Model owns more flows end-to-end (planning, availability, trips) instead of
    hand-coded paths.

---

## 6. Open decisions (resolve as we go)

1. **Single source of truth for tools.** Should runtime tools live in the Edge
   Function (TS) and the Swift services call *them*, or should both call a shared
   core? Pick one to kill TS/Swift drift.
2. **MCP — yes, and when?** For a single first-party app, Anthropic tool-use
   (what we have) is the right call. MCP earns its keep when there are *multiple
   consumers* of the same tools, *third-party tool servers*, or tool *reuse
   across surfaces*. Revisit when one of those is true; don't adopt it for its
   own sake.
3. **Where the agent loop runs.** Today: client → Edge Function → model loop.
   Keep the loop server-side (keys never touch the client) as tools grow.
4. **Guardrails for mutating tools.** As `create_*`/`delete_*` tools grow, define
   confirmation + undo semantics so the model can't destructively act without a
   gate.

---

## 7. Quality gates (so speed doesn't break things)

- **Code correctness** → tests + CI. Replaces line-by-line review when running
  parallel agents.
- **AI behavior correctness** → the eval set. Re-run golden prompts after any
  prompt/tool change to catch regressions. *This is the piece that makes the
  runtime layer safe to iterate fast — build it early.*
- **Always-runs invariant** → every new live tool/service needs a mock + router
  fallback (existing house rule; non-negotiable).
