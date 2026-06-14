-- ============================================================================
-- Unified cross-surface observability: one trace stream + a gated read RPC
-- ============================================================================
--
-- Purpose: give the team (and the AI agent helping build this) a SINGLE
-- queryable record of what every surface of Someday did on a given request —
-- the iOS app, every Edge Function (chat, parse-gmaps, parse-instagram,
-- check-availability, find-friends-on-someday, find-reservation-platforms),
-- and any DB-side work — all correlated by one `trace_id`. So when something
-- breaks we can run ONE query (`read_debug_log` filtered by trace) and see the
-- whole journey of that request across surfaces, WITHOUT scraping console logs
-- out of the Supabase dashboard or pulling OSLog off the device.
--
-- This GENERALISES the chat-only `chat_debug_log` loop (migration
-- 20260613173000) into a cross-surface stream. `chat_debug_log` stays as the
-- rich per-turn chat record; `debug_log` is the thin, uniform breadcrumb feed
-- every surface writes to. Over time the chat per-turn summary can also land a
-- row here so a chat trace and its breadcrumbs read out together.
--
-- Access model (identical to read_chat_debug, deliberately):
--   • Edge Functions write with the service-role key (bypasses RLS).
--   • iOS writes its own breadcrumbs with the user's authenticated session,
--     gated by an RLS INSERT policy that pins surface='ios' and
--     user_id=auth.uid() — so a client can only ever insert its own rows and
--     can NEVER read the table back.
--   • Reads go through the SECURITY DEFINER `read_debug_log` RPC, gated by the
--     shared debug secret — possession of the public anon key alone reveals
--     nothing.
--
-- This is a DEV/observability tool. Rows can contain user message text and
-- request payloads, so treat the secret like a credential, and add a retention
-- sweep (delete rows older than N days) before this would ever hold sensitive
-- production data at scale.

create table if not exists public.debug_log (
  id          uuid        primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  -- Correlates one user action across every surface it touches. Generated on
  -- iOS at the start of an action and propagated via the X-Trace-Id header;
  -- Edge Functions read it from the header (or mint one if absent).
  trace_id    text,
  -- Which surface emitted this row: 'ios' | 'chat' | 'parse-gmaps' |
  -- 'parse-instagram' | 'check-availability' | 'find-friends-on-someday' |
  -- 'find-reservation-platforms' | 'db' | ... (free-form, lowercase).
  surface     text        not null,
  -- Severity. 'debug' is for high-volume breadcrumbs; default 'info'.
  level       text        not null default 'info'
                check (level in ('debug', 'info', 'warn', 'error')),
  -- Short machine-readable label for the moment, e.g. 'request_received',
  -- 'tool_call', 'llm_stream_done', 'stream_hang', 'parse_failed'. Lets us
  -- filter to a phase without regexing the message.
  event       text,
  -- Caller's auth uid when known (null for anon/service-role invocations).
  user_id     uuid,
  -- Human-readable one-liner.
  message     text,
  -- Optional timing for the thing this row describes.
  duration_ms integer,
  -- Free-form structured payload (inputs, status codes, token counts, the
  -- offending value, etc.). Keep it small.
  data        jsonb
);

-- Recent-first reads, trace correlation, and per-surface scans are the access
-- patterns.
create index if not exists debug_log_created_idx
  on public.debug_log (created_at desc);
create index if not exists debug_log_trace_idx
  on public.debug_log (trace_id)
  where trace_id is not null;
create index if not exists debug_log_surface_idx
  on public.debug_log (surface, created_at desc);

-- RLS on. The only policy is a tightly-scoped INSERT for the iOS client (see
-- below); reads have NO policy, so they can only happen via the service-role
-- key or the gated read RPC.
alter table public.debug_log enable row level security;

-- ----------------------------------------------------------------------------
-- iOS breadcrumb writes: an authenticated user may INSERT only its own rows,
-- and only for the 'ios' surface. No SELECT/UPDATE/DELETE policy exists, so a
-- client can write breadcrumbs but never read the stream (or anyone else's).
-- This keeps the anon key + an authenticated session sufficient for iOS to
-- contribute to the trace, with no debug secret baked into the app bundle.
-- ----------------------------------------------------------------------------
create policy debug_log_ios_insert
  on public.debug_log
  for insert
  to authenticated
  with check (surface = 'ios' and user_id = auth.uid());

-- ----------------------------------------------------------------------------
-- read_debug_log: return the most recent rows, optionally filtered by trace or
-- surface, gated by the shared debug secret. SECURITY DEFINER so it reads past
-- RLS; granted to anon so the debug loop can call it with the public anon key +
-- the secret (the secret is what actually authorises). Same secret as
-- read_chat_debug — one credential for the whole observability loop.
-- ----------------------------------------------------------------------------
create or replace function public.read_debug_log(
  p_secret   text,
  p_limit    int  default 50,
  p_trace_id text default null,
  p_surface  text default null
)
returns setof public.debug_log
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_secret is null or p_secret <> '4e17aa02130b6649834f1369fb0e1dec' then
    raise exception 'read_debug_log: forbidden';
  end if;
  return query
    select *
    from public.debug_log
    where (p_trace_id is null or trace_id = p_trace_id)
      and (p_surface  is null or surface  = p_surface)
    order by created_at desc
    limit greatest(1, least(coalesce(p_limit, 50), 500));
end;
$$;

revoke all on function public.read_debug_log(text, int, text, text) from public;
grant execute on function public.read_debug_log(text, int, text, text) to anon, authenticated;
