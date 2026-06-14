-- ============================================================================
-- Chat observability: a structured per-turn debug log + a gated read RPC
-- ============================================================================
--
-- Purpose: give the team (and the AI agent helping build this) a queryable
-- record of what the `chat` Edge Function actually did on each turn, so we
-- can debug behaviour (e.g. "did the model call ask_selection? with what
-- options?") WITHOUT scraping console logs out of the dashboard.
--
-- The chat function writes one row per turn with the service-role key (which
-- bypasses RLS). The table has NO RLS read policy, so ordinary clients can't
-- read it directly. Instead, a SECURITY DEFINER RPC (`read_chat_debug`)
-- exposes the most recent rows, gated by a shared secret so possession of the
-- public anon key alone isn't enough to read user chat content.
--
-- This is a DEV/observability tool. The rows contain user message text and
-- the assistant's reply, so treat the secret like a credential and rotate /
-- drop this table before it would ever hold sensitive production data at
-- scale. A simple retention sweep (delete rows older than N days) can be
-- added later if the table grows.

create table if not exists public.chat_debug_log (
  id           uuid        primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  -- Caller's auth uid when known (null for anon/service-role invocations).
  user_id      uuid,
  -- The last user message that drove this turn.
  user_message text,
  -- Names of the tools the model invoked this turn, in order.
  tools        text[]      not null default '{}',
  -- The exact ask_selection payload emitted to the client this turn, if any
  -- ({ prompt, options, multi, submitLabel }). Null when no box was shown.
  selection    jsonb,
  -- The assistant's final reply text (accumulated from the streamed deltas).
  reply_text   text,
  -- Error string when the turn threw mid-stream; null on success.
  error        text,
  -- Free-form extras (token count, iteration count, model, etc.).
  meta         jsonb
);

-- Recent-first reads are the only access pattern.
create index if not exists chat_debug_log_created_idx
  on public.chat_debug_log (created_at desc);

-- RLS on, with NO policies: only the service-role key (function writes) and
-- the SECURITY DEFINER read RPC below can touch this table.
alter table public.chat_debug_log enable row level security;

-- ----------------------------------------------------------------------------
-- read_chat_debug: return the most recent debug rows, gated by a shared
-- secret. SECURITY DEFINER so it can read past RLS; granted to anon so the
-- debug loop can call it with the public anon key + the secret (the secret is
-- what actually authorizes — the anon key alone returns nothing).
-- ----------------------------------------------------------------------------

create or replace function public.read_chat_debug(p_secret text, p_limit int default 20)
returns setof public.chat_debug_log
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Constant-time-ish guard. The secret lives only here and with the caller;
  -- a wrong/empty secret reveals nothing.
  if p_secret is null or p_secret <> '4e17aa02130b6649834f1369fb0e1dec' then
    raise exception 'read_chat_debug: forbidden';
  end if;
  return query
    select *
    from public.chat_debug_log
    order by created_at desc
    limit greatest(1, least(coalesce(p_limit, 20), 200));
end;
$$;

revoke all on function public.read_chat_debug(text, int) from public;
grant execute on function public.read_chat_debug(text, int) to anon, authenticated;
