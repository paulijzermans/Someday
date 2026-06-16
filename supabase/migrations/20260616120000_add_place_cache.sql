-- ============================================================================
-- place_cache — global, owner-agnostic store of every place we've ever
-- extracted from the internet.
-- ============================================================================
--
-- Why this exists
-- ---------------
-- The user-facing `public.places` table is PER-OWNER: RLS lets you see only
-- your own rows (+ friends'), and deleting a place cascades it away. So today,
-- when user A imports a venue and later deletes it, the structured data we paid
-- Apify (and, for Instagram, Claude) to extract is gone — and when user B
-- imports the same venue we re-pay the full scrape cost.
--
-- `place_cache` decouples "the place exists in the world" from "a user saved
-- it". It is written ONLY by the Edge Functions via the service-role key
-- (mirroring `availability_cache`), and nothing here is ever deleted when a
-- user deletes their saved copy. Import the same venue again — from any user,
-- from any source that resolves to the same identity — and we serve it for free.
--
-- Identity (cache_key)
-- --------------------
-- Per-PLACE identity, not per-URL:
--   * 'gmaps:<placeId>'                 when we have Google's stable place id
--   * 'geo:<name-slug>:<lat4>:<lon4>'   when we have coordinates but no id
--   * 'name:<name-slug>:<addr-slug>'    caption-only path (Instagram, pre-geocode)
-- Rounding coords to 4 decimals (~11 m) means two slightly different pin drops
-- on the same venue collapse to one row.
--
-- TTL
-- ---
-- 90 days. Venues are far more stable than reservation platforms, but they do
-- close / move / re-brand, so we re-fetch on demand after the window rather
-- than trusting a year-old scrape forever. Freshness is enforced in the Edge
-- Function (see _shared/place-cache.ts), not by a DB job.

create table if not exists public.place_cache (
  -- Stable per-place identity. See the header for the key scheme.
  cache_key    text primary key,
  -- Google Maps placeId when known — lets us re-key / dedupe later and is the
  -- strongest cross-source join we have. Null for caption-only places.
  place_id     text,
  -- Structured, denormalised columns. Handy for analytics ("most-imported
  -- venues in Amsterdam"), debugging, and future re-keying. The CLIENT-FACING
  -- payload, however, is `payload` below — that's what the function serves back
  -- verbatim so the import contract never drifts from these columns.
  name         text not null,
  category     text not null default 'food',
  latitude     double precision,
  longitude    double precision,
  address      text not null default '',
  neighborhood text not null default '',
  image_url    text,
  source       text not null default 'manual',
  kind         text not null default 'venue',   -- 'venue' | 'region'
  -- The exact place object the Edge Function returns to iOS. Stored as JSONB so
  -- a cache hit replays a byte-identical response without us having to keep the
  -- reconstruction logic in lockstep with the structured columns above.
  payload      jsonb not null,
  -- Lightweight telemetry: how often this cached place has been re-served.
  hit_count    integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Lets the freshness GC scan stale rows cheaply, and powers "recently added".
create index if not exists place_cache_created_at_idx
  on public.place_cache (created_at desc);
-- Cross-source dedupe / re-keying by Google placeId.
create index if not exists place_cache_place_id_idx
  on public.place_cache (place_id) where place_id is not null;

-- ============================================================================
-- extraction_index — URL → which cached places that import contained.
-- ============================================================================
--
-- `place_cache` is keyed by PLACE identity, but an import arrives as a URL (a
-- Google Maps list link, an Instagram reel). To skip the paid scrape on a
-- REPEAT of the same URL we need to remember which places that URL resolved to.
-- This table stores nothing about the places themselves — just pointers
-- (`place_keys`) into `place_cache`. On a hit we load those rows and replay
-- their payloads. A miss (or any evicted member) falls through to a live fetch.
create table if not exists public.extraction_index (
  url         text primary key,           -- normalised source URL
  source      text not null,              -- 'gmaps' | 'instagram'
  place_keys  text[] not null default '{}',
  note        text,                       -- e.g. "Post has no caption"
  hit_count   integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists extraction_index_created_at_idx
  on public.extraction_index (created_at desc);

-- ============================================================================
-- RLS — clients never touch these tables directly. The Edge Functions use
-- SUPABASE_SERVICE_ROLE_KEY, which bypasses RLS, so reads/writes still work.
-- Authenticated SELECT is allowed (harmless, and useful for future "popular
-- places" features); writes have NO policy, so Postgres denies them for
-- everyone but the service role.
-- ============================================================================
alter table public.place_cache      enable row level security;
alter table public.extraction_index enable row level security;

drop policy if exists place_cache_read on public.place_cache;
create policy place_cache_read on public.place_cache
  for select to authenticated using (true);

drop policy if exists extraction_index_read on public.extraction_index;
create policy extraction_index_read on public.extraction_index
  for select to authenticated using (true);
