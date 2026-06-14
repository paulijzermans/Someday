-- ============================================================================
-- Per-user usage accounting
-- ============================================================================
--
-- Tracks two lifetime counters per user so Settings → Plan can show how
-- much someone leans on the heavy bits:
--   • imports_count — number of places imported via the link/extraction
--     flow. Bumped from the iOS client after each successful import
--     through `increment_usage`.
--   • tokens_used   — cumulative AI tokens (input + output) attributed to
--     the user by the `chat` Edge Function. Written server-side with the
--     service-role key (it sums `usage.input_tokens + usage.output_tokens`
--     from each streamed message), so the client can never inflate it.
--
-- One row per user, created lazily on first write via upsert. RLS lets a
-- user read ONLY their own row; all writes go through the security-definer
-- `increment_usage` function (client, scoped to auth.uid()) or the
-- service-role key (Edge Function), so there are deliberately no
-- INSERT/UPDATE policies for ordinary users.

create table if not exists public.user_usage (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  imports_count integer     not null default 0,
  tokens_used   bigint      not null default 0,
  updated_at    timestamptz not null default now()
);

alter table public.user_usage enable row level security;

-- Read: a user may see only their own usage row.
drop policy if exists user_usage_read on public.user_usage;
create policy user_usage_read on public.user_usage
  for select to authenticated
  using (auth.uid() = user_id);

-- No INSERT/UPDATE policies for `authenticated` on purpose: counter bumps
-- happen through `increment_usage` (security definer) and the Edge
-- Function's service-role client, both of which bypass RLS. This keeps a
-- malicious client from zeroing or inflating its own numbers directly.

-- ----------------------------------------------------------------------------
-- increment_usage: atomically bump the caller's counters, creating the row
-- on first use. SECURITY DEFINER + auth.uid() so a client can only ever
-- touch its own row, and only by ADDING to it (never setting absolutes).
-- Used by the iOS client for imports (p_tokens = 0) and is also a safe RPC
-- for the chat path if we ever move token writes client-adjacent.
-- ----------------------------------------------------------------------------

create or replace function public.increment_usage(p_imports integer, p_tokens bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'increment_usage: no auth.uid()';
  end if;
  insert into public.user_usage (user_id, imports_count, tokens_used, updated_at)
    values (v_user, greatest(p_imports, 0), greatest(p_tokens, 0), now())
  on conflict (user_id) do update
    set imports_count = public.user_usage.imports_count + greatest(p_imports, 0),
        tokens_used   = public.user_usage.tokens_used   + greatest(p_tokens, 0),
        updated_at    = now();
end;
$$;

revoke all on function public.increment_usage(integer, bigint) from public;
grant execute on function public.increment_usage(integer, bigint) to authenticated;
