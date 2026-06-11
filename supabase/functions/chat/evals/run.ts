// =============================================================================
// Chat eval runner — the VERIFY gate for Engine B (AI_STRATEGY.md §4 / §7)
// =============================================================================
//
// Replays a folder of "golden" prompts against the deployed `chat` Edge
// Function, consumes the SSE stream, and asserts on observable behavior:
//   • which TOOLS the model called (from `step` events' `tool` field), and
//   • what the final reply contains (e.g. `someday://place/…` render links).
//
// This is intentionally behavioral, not exact-match: model output varies, so
// goldens assert "called inspect_list" or "reply includes a place link",
// never a verbatim string. Run it after ANY prompt/tool change before shipping.
//
// Usage:
//   CHAT_URL=https://<ref>.supabase.co/functions/v1/chat \
//   SUPABASE_ANON_KEY=<anon key> \
//   deno run --allow-net --allow-read --allow-env supabase/functions/chat/evals/run.ts
//
// Exit code is the number of failing goldens (0 = all green), so CI can gate on it.

interface Expectation {
  /** Pass if the model called AT LEAST ONE of these tools. */
  toolsAnyOf?: string[];
  /** Pass only if the model called ALL of these tools. */
  toolsAllOf?: string[];
  /** Pass if the model did NOT call any of these tools. */
  toolsNoneOf?: string[];
  /** Pass if the final reply text contains AT LEAST ONE of these substrings. */
  textIncludesAnyOf?: string[];
}

interface Golden {
  name: string;
  prompt: string;
  expect: Expectation;
}

// Minimal synthetic context so goldens are reproducible without a real user.
// Mirrors the `ChatContext` shape the iOS app sends. Keep it small but
// representative — a couple of lists, a few places, one friend.
function fixtureContext() {
  return {
    userName: "Eval User",
    now: new Date().toISOString(),
    currentCity: "Amsterdam",
    myPlaces: [
      { id: "p1", name: "Café Veneur", category: "coffee", area: "Jordaan", inLists: ["Coffee"] },
      { id: "p2", name: "Toscanini", category: "food", area: "Jordaan", inLists: ["Dinner"] },
      { id: "p3", name: "Bar Centraal", category: "drinks", area: "De Pijp", inLists: ["Dinner"] },
    ],
    friendPlaces: [
      { id: "f1", name: "Mr Porter", category: "food", area: "Centrum", owner: "Sanne" },
    ],
    lists: [
      { name: "Coffee", placeCount: 1 },
      { name: "Dinner", placeCount: 2 },
    ],
    friends: [{ name: "Sanne" }],
  };
}

interface RunResult {
  tools: string[];
  text: string;
}

async function runPrompt(chatURL: string, anonKey: string, prompt: string): Promise<RunResult> {
  const res = await fetch(chatURL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${anonKey}`,
      "apikey": anonKey,
    },
    body: JSON.stringify({
      messages: [{ role: "user", content: prompt }],
      context: fixtureContext(),
    }),
  });
  if (!res.ok || !res.body) {
    throw new Error(`HTTP ${res.status}: ${await res.text().catch(() => "")}`);
  }

  const tools: string[] = [];
  let text = "";

  // Parse the SSE stream: events are separated by a blank line; each carries
  // an `event:` name and a `data:` JSON payload.
  const reader = res.body.pipeThrough(new TextDecoderStream()).getReader();
  let buffer = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += value;
    let sep: number;
    while ((sep = buffer.indexOf("\n\n")) !== -1) {
      const chunk = buffer.slice(0, sep);
      buffer = buffer.slice(sep + 2);
      const evMatch = chunk.match(/^event: (.+)$/m);
      const dataMatch = chunk.match(/^data: (.+)$/m);
      if (!evMatch || !dataMatch) continue;
      const event = evMatch[1].trim();
      let data: unknown;
      try { data = JSON.parse(dataMatch[1]); } catch { continue; }
      if (event === "step" && data && typeof (data as { tool?: string }).tool === "string") {
        tools.push((data as { tool: string }).tool);
      } else if (event === "text") {
        text += (data as { delta?: string }).delta ?? "";
      } else if (event === "error") {
        throw new Error(`stream error: ${(data as { message?: string }).message}`);
      }
    }
  }
  return { tools, text };
}

function evaluate(exp: Expectation, r: RunResult): string[] {
  const fails: string[] = [];
  const has = (t: string) => r.tools.includes(t);
  if (exp.toolsAnyOf && !exp.toolsAnyOf.some(has)) {
    fails.push(`expected one of tools [${exp.toolsAnyOf}], got [${r.tools}]`);
  }
  if (exp.toolsAllOf && !exp.toolsAllOf.every(has)) {
    fails.push(`expected all tools [${exp.toolsAllOf}], got [${r.tools}]`);
  }
  if (exp.toolsNoneOf && exp.toolsNoneOf.some(has)) {
    fails.push(`expected none of tools [${exp.toolsNoneOf}], got [${r.tools}]`);
  }
  if (exp.textIncludesAnyOf && !exp.textIncludesAnyOf.some((s) => r.text.includes(s))) {
    fails.push(`reply missing any of [${exp.textIncludesAnyOf}]`);
  }
  return fails;
}

async function loadGoldens(dir: string): Promise<Golden[]> {
  const out: Golden[] = [];
  for await (const entry of Deno.readDir(dir)) {
    if (!entry.isFile || !entry.name.endsWith(".json")) continue;
    const raw = await Deno.readTextFile(`${dir}/${entry.name}`);
    out.push(JSON.parse(raw) as Golden);
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

async function main() {
  const chatURL = Deno.env.get("CHAT_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!chatURL || !anonKey) {
    console.error(
      "Set CHAT_URL and SUPABASE_ANON_KEY env vars.\n" +
      "  CHAT_URL=https://<ref>.supabase.co/functions/v1/chat\n" +
      "  SUPABASE_ANON_KEY=<anon key>",
    );
    Deno.exit(2);
  }

  const goldenDir = new URL("./golden", import.meta.url).pathname;
  const goldens = await loadGoldens(goldenDir);
  if (goldens.length === 0) {
    console.error(`No goldens found in ${goldenDir}`);
    Deno.exit(2);
  }

  let failed = 0;
  for (const g of goldens) {
    try {
      const r = await runPrompt(chatURL, anonKey, g.prompt);
      const fails = evaluate(g.expect, r);
      if (fails.length === 0) {
        console.log(`✅ ${g.name}`);
      } else {
        failed++;
        console.log(`❌ ${g.name}`);
        for (const f of fails) console.log(`     ${f}`);
      }
    } catch (err) {
      failed++;
      console.log(`❌ ${g.name} — ${String(err)}`);
    }
  }

  console.log(`\n${goldens.length - failed}/${goldens.length} passed`);
  Deno.exit(failed);
}

main();
