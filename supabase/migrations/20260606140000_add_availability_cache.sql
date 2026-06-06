-- ============================================================================
-- availability_cache — shared cache for the find-reservation-platforms result
-- ============================================================================
--
-- The `find-reservation-platforms` Edge Function asks Claude with web search
-- which booking platforms support a venue. That's expensive (~$0.01–0.03 per
-- call, multi-second latency). Once we've answered it for ONE user, every
-- subsequent user looking up the same venue should get the cached answer
-- instantly and for free.
--
-- Cache key: a normalised composite of the venue name + rounded coordinates.
-- Rounding to 4 decimals (~11m precision) means two slightly different pin
-- drops on the same restaurant still hit the same cache row.
--
-- TTL: 60 days. URLs go stale, venues close, platforms change — but a
-- restaurant on OpenTable today is overwhelmingly likely to still be on
-- OpenTable two months from now. Re-fetch on demand keeps the data fresh
-- without re-paying the AI cost for hot venues.
--
-- RLS: the Edge Function reaches this table via the service-role key, so
-- the policies below are conservative — authenticated reads, no client
-- writes. Clients never touch this table directly; they call the function.

create table if not exists public.availability_cache (
  cache_key   text primary key,
  -- denormalised metadata, useful for debugging / future "popular venues"
  -- features. Not used for lookup.
  venue_name  text not null,
  latitude    double precision,
  longitude   double precision,
  -- The full AvailabilityResult JSON, exactly as the function returns it
  -- to the iOS client. JSONB so we can query / aggregate later (e.g.
  -- "which platforms come up most for restaurants in Paris?").
  result      jsonb not null,
  -- Lightweight telemetry: how many times this cached answer has been
  -- served. Useful to see which venues are getting hit repeatedly and
  -- decide whether to extend TTL on popular ones.
  hit_count   integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Cleanup query for the Edge Function — "is this row still fresh?".
-- Indexing created_at lets the periodic GC scan stale rows cheaply.
create index if not exists availability_cache_created_at_idx
  on public.availability_cache (created_at desc);

-- RLS: lock down direct client access. The Edge Function uses
-- SUPABASE_SERVICE_ROLE_KEY which bypasses RLS, so reads/writes from
-- the function still work.
alter table public.availability_cache enable row level security;

drop policy if exists availability_cache_read on public.availability_cache;
create policy availability_cache_read on public.availability_cache
  for select to authenticated
  using (true);

-- No insert/update/delete policy for clients — only the service role
-- (Edge Function) can write. Postgres denies writes by default when RLS
-- is enabled and no policy matches.
