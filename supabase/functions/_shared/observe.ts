// _shared/observe.ts
// =============================================================================
// Cross-surface observability for Someday's Edge Functions.
//
// One job: make every function emit uniform, trace-correlated breadcrumbs that
// (a) show up in the Supabase function log stream (via console.log) AND (b)
// land in the `debug_log` table so the AI agent can read the whole journey of
// a request through `read_debug_log` with the anon key + the debug secret —
// no dashboard, no `supabase functions logs` needed.
//
// Two pieces:
//   • extractTraceId(req)  — pull X-Trace-Id off the incoming request, or mint
//     a fresh UUID. The iOS client generates the ID at the start of a user
//     action and sends it; functions that call other functions should forward
//     it. One ID ties iOS → function → (nested function) → DB together.
//   • createLogger(surface, traceId) — info/warn/error helpers. Each call
//     console.log's a JSON line AND best-effort INSERTs a `debug_log` row with
//     the service-role key (bypasses RLS). Fully swallow-on-error, exactly like
//     recordChatDebug/recordTokenUsage in chat/index.ts — telemetry must never
//     break a real response.
//
// Edge Functions are short-lived: a fire-and-forget insert can be cut off when
// the response resolves. So each log call returns the insert Promise, and the
// logger exposes `flush()` (await all pending inserts) to call right before you
// return. console.log is synchronous and always captured, so even if a flush is
// skipped the line is never lost — only the queryable row might be.
// =============================================================================

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

export type LogLevel = "debug" | "info" | "warn" | "error";

/// Known surfaces. Free-form `string` is still accepted so a new function can
/// log without editing this file, but the union documents the current set and
/// gives autocomplete at call sites.
export type Surface =
  | "chat"
  | "check-availability"
  | "find-friends-on-someday"
  | "find-reservation-platforms"
  | "parse-gmaps"
  | "parse-instagram"
  | "db"
  | (string & {});

export interface LogFields {
  /// Short machine label for the moment, e.g. "request_received", "tool_call".
  event?: string;
  /// Caller's auth uid when known.
  userId?: string | null;
  /// Timing for the thing this row describes.
  durationMs?: number;
  /// Free-form structured payload — inputs, status codes, token counts, etc.
  data?: Record<string, unknown> | null;
}

export interface Logger {
  traceId: string;
  debug(message: string, fields?: LogFields): Promise<void>;
  info(message: string, fields?: LogFields): Promise<void>;
  warn(message: string, fields?: LogFields): Promise<void>;
  error(message: string, fields?: LogFields): Promise<void>;
  /// Await every pending best-effort insert. Call before returning the response.
  flush(): Promise<void>;
}

/// Read X-Trace-Id off the incoming request, or generate a fresh UUID so a
/// function invoked without a trace still produces a correlatable stream.
export function extractTraceId(req: Request): string {
  const header = req.headers.get("X-Trace-Id") ?? req.headers.get("x-trace-id");
  const trimmed = header?.trim();
  return trimmed && trimmed.length > 0 ? trimmed : crypto.randomUUID();
}

// One admin client per isolate is enough; build it lazily so functions with no
// service-role env (or that never log) pay nothing.
let _admin: SupabaseClient | null | undefined;
function admin(): SupabaseClient | null {
  if (_admin !== undefined) return _admin;
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    _admin = null;
    return _admin;
  }
  _admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return _admin;
}

export function createLogger(surface: Surface, traceId: string): Logger {
  const pending: Promise<void>[] = [];

  function write(level: LogLevel, message: string, fields?: LogFields): Promise<void> {
    // (a) Always emit a structured line to the function log stream. Prefixed so
    // the stream can be grepped to just observability rows.
    const line = {
      t: new Date().toISOString(),
      trace: traceId,
      surface,
      level,
      event: fields?.event,
      msg: message,
      ms: fields?.durationMs,
      data: fields?.data ?? undefined,
    };
    // console.error for warn/error so they surface as errors in the dashboard.
    (level === "error" || level === "warn" ? console.error : console.log)(
      `observe ${JSON.stringify(line)}`,
    );

    // (b) Best-effort row in debug_log. Swallow every failure — telemetry must
    // never break a real response.
    const db = admin();
    if (!db) return Promise.resolve();
    const p = db
      .from("debug_log")
      .insert({
        trace_id: traceId,
        surface,
        level,
        event: fields?.event ?? null,
        user_id: fields?.userId ?? null,
        message,
        duration_ms: fields?.durationMs ?? null,
        data: fields?.data ?? null,
      })
      .then(({ error }) => {
        if (error) console.error("observe insert failed:", error.message);
      })
      .catch((err) => {
        console.error("observe insert threw:", String(err));
      });
    pending.push(p);
    return p;
  }

  return {
    traceId,
    debug: (m, f) => write("debug", m, f),
    info: (m, f) => write("info", m, f),
    warn: (m, f) => write("warn", m, f),
    error: (m, f) => write("error", m, f),
    flush: async () => {
      // Snapshot — late inserts kicked off during the await are harmless.
      await Promise.allSettled(pending.splice(0));
    },
  };
}
