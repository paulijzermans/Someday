# Chat evals — the VERIFY gate for Engine B

This is the regression suite the `chat-agent` (and any human) runs after **any**
prompt or tool change to the `chat` Edge Function, per `AI_STRATEGY.md` §4/§7.

It replays a folder of **golden prompts** against the *deployed* function,
consumes the SSE stream, and asserts on observable behaviour — not on verbatim
output. Model wording drifts; tool choice and render links don't. So a golden
says "called `inspect_list`" or "reply contains a `someday://place/` link",
never an exact string.

## Run it

```bash
CHAT_URL=https://<ref>.supabase.co/functions/v1/chat \
SUPABASE_ANON_KEY=<anon key> \
deno run --allow-net --allow-read --allow-env supabase/functions/chat/evals/run.ts
```

Exit code = number of failing goldens (0 = all green), so CI can gate on it.
Deploy first (`supabase functions deploy chat`) — the runner hits the live URL,
not your local edits.

## What a golden looks like

One JSON file per case in `golden/`. Shape:

```jsonc
{
  "name": "human-readable description of what this proves",
  "prompt": "the user turn to replay",
  "expect": {
    "toolsAnyOf":      ["geocode_address"],          // pass if AT LEAST ONE fired
    "toolsAllOf":      ["inspect_list"],             // pass only if ALL fired
    "toolsNoneOf":     ["create_place"],             // pass if NONE fired
    "textIncludesAnyOf": ["someday://place/"]        // pass if reply has ANY substring
  }
}
```

All four checks are optional; a golden uses whichever subset is meaningful.
Every golden runs against the same synthetic `fixtureContext()` in `run.ts`
(Eval User in Amsterdam, a Coffee + Dinner list, three saved places, one friend
Sanne) so cases are reproducible without a real account.

## The current goldens

| File | Proves |
|---|---|
| `01_inspect_list.json` | Asking about a named list calls `inspect_list` and links its places. |
| `02_inspect_friend.json` | Asking what a friend saved calls `inspect_friend`. |
| `03_smalltalk_no_tools.json` | A bare greeting fires **no** data tools (no spurious work). |
| `04_suggest_geocodes_pin.json` | Proposing a brand-new venue geocodes it and emits a `someday://suggest?` pin. |

## Adding a golden

Drop a new `NN_slug.json` in `golden/` (the `NN_` prefix just controls run
order). Prefer the weakest assertion that still catches the regression you care
about — over-tight goldens flake on harmless model variation and erode trust in
the gate.
