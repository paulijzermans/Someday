-- ============================================================================
-- places_global — canonical, owner-agnostic registry of place "world facts".
-- ============================================================================
--
-- Until now every user's `places` row stored a FULL copy of the venue (name,
-- coords, category, photo, …). Ten friends saving the same restaurant = ten
-- duplicate copies. This migration splits a place into:
--
--   • places_global  — the shared FACTS (name, category, kind, coordinates,
--                       neighborhood, thumbnail, source link). One row per
--                       real-world place, deduped by an identity key. Readable
--                       by everyone; written only through the RPCs below.
--   • places         — the PERSONAL save (owner, how they found it, their
--                       tags, visited flags, is_saved, created_at) PLUS a
--                       global_place_id pointer. The old descriptive columns
--                       are kept but become NULLABLE *overrides*: NULL means
--                       "inherit from places_global", non-null means "this user
--                       customised it" (copy-on-write — see update_place()).
--
-- A `places_resolved` view re-COALESCEs the two back into the exact flat shape
-- the iOS `PlaceRow` already decodes, so the read path barely changes.
--
-- SAFETY: this migration is NON-DESTRUCTIVE. Existing `places` rows keep their
-- descriptive values (they simply act as overrides), so the view returns
-- identical data even if anything downstream is wrong. New saves dedupe via
-- the RPC. A separate, gated follow-up migration nulls the now-redundant legacy
-- copies once the end-to-end path is verified on-device.

-- ---------------------------------------------------------------------------
-- Identity key: same venue from slightly different pin drops collapses to one
-- row. lower(name) + coords rounded to 4 decimals (~11 m).
-- ---------------------------------------------------------------------------
create or replace function public.place_identity_key(
  p_name text, p_lat double precision, p_lon double precision
) returns text language sql immutable as $$
  select lower(trim(coalesce(p_name, ''))) || '|'
       || round(p_lat::numeric, 4)::text || '|'
       || round(p_lon::numeric, 4)::text;
$$;

-- ---------------------------------------------------------------------------
-- The registry table.
-- ---------------------------------------------------------------------------
create table if not exists public.places_global (
  id           uuid primary key default gen_random_uuid(),
  identity_key text not null unique,
  -- Google Maps placeId when an import supplied one (strongest cross-source
  -- join). Null for manual / caption-only places.
  place_id     text,
  name         text not null,
  category     place_category not null default 'food',
  kind         text not null default 'venue',     -- 'venue' | 'region'
  latitude     double precision not null,
  longitude    double precision not null,
  neighborhood text not null default '',
  image_url    text,
  source_url   text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists places_global_place_id_idx
  on public.places_global (place_id) where place_id is not null;

-- ---------------------------------------------------------------------------
-- Reshape `places`: add the pointer, relax the descriptive columns to nullable
-- overrides. Personal columns (owner_id, source, recommended_by, visited_by_ids,
-- tags, is_saved, created_at) are untouched.
-- ---------------------------------------------------------------------------
alter table public.places
  add column if not exists global_place_id uuid references public.places_global(id) on delete set null;

alter table public.places alter column name         drop not null;
alter table public.places alter column category     drop not null;
alter table public.places alter column category     drop default;
alter table public.places alter column latitude     drop not null;
alter table public.places alter column longitude    drop not null;
alter table public.places alter column neighborhood drop not null;
alter table public.places alter column neighborhood drop default;

create index if not exists places_global_place_id_fk_idx
  on public.places (global_place_id);

-- ---------------------------------------------------------------------------
-- Backfill: one global row per distinct identity, then link every place to it.
-- ---------------------------------------------------------------------------
insert into public.places_global
  (identity_key, name, category, kind, latitude, longitude, neighborhood, image_url, source_url, created_at)
select distinct on (public.place_identity_key(name, latitude, longitude))
  public.place_identity_key(name, latitude, longitude),
  name, category, 'venue', latitude, longitude, neighborhood, image_url, source_url, created_at
from public.places
where name is not null and latitude is not null and longitude is not null
order by public.place_identity_key(name, latitude, longitude), created_at
on conflict (identity_key) do nothing;

update public.places p
set global_place_id = g.id
from public.places_global g
where g.identity_key = public.place_identity_key(p.name, p.latitude, p.longitude)
  and p.global_place_id is null
  and p.name is not null and p.latitude is not null and p.longitude is not null;

-- ---------------------------------------------------------------------------
-- The resolving view — exact flat shape the iOS PlaceRow decodes. LEFT JOIN so
-- a row that somehow has no global link still returns its own (override) data.
-- security_invoker => the caller's RLS on `places` still gates which rows show.
-- ---------------------------------------------------------------------------
drop view if exists public.places_resolved;
create view public.places_resolved
  with (security_invoker = true)
as
select
  p.id,
  p.owner_id,
  coalesce(p.name, g.name)                 as name,
  coalesce(p.category, g.category)         as category,
  coalesce(g.kind, 'venue')                as kind,
  coalesce(p.latitude, g.latitude)         as latitude,
  coalesce(p.longitude, g.longitude)       as longitude,
  p.source,
  coalesce(p.neighborhood, g.neighborhood) as neighborhood,
  p.recommended_by,
  p.visited_by_ids,
  p.tags,
  p.is_saved,
  coalesce(p.image_url, g.image_url)       as image_url,
  coalesce(p.source_url, g.source_url)     as source_url,
  p.created_at
from public.places p
left join public.places_global g on g.id = p.global_place_id;

grant select on public.places_resolved to authenticated;
grant select on public.places_global   to authenticated;

-- ---------------------------------------------------------------------------
-- RLS: places_global is world-readable by authenticated users; writes happen
-- only through the SECURITY DEFINER RPCs (which enforce ownership themselves).
-- ---------------------------------------------------------------------------
alter table public.places_global enable row level security;
drop policy if exists places_global_read on public.places_global;
create policy places_global_read on public.places_global
  for select to authenticated using (true);

-- ---------------------------------------------------------------------------
-- save_place(): upsert the global facts (deduped by identity), then insert the
-- caller's thin personal row pointing at it. Descriptive columns on the
-- personal row stay NULL (pure reference) — that's the dedup win.
-- ---------------------------------------------------------------------------
create or replace function public.save_place(
  p_id uuid,
  p_name text,
  p_category text,
  p_kind text,
  p_latitude double precision,
  p_longitude double precision,
  p_neighborhood text,
  p_source text,
  p_recommended_by uuid,
  p_visited_by_ids uuid[],
  p_tags text[],
  p_is_saved boolean,
  p_image_url text,
  p_source_url text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_global uuid;
  v_key    text;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;

  v_key := public.place_identity_key(p_name, p_latitude, p_longitude);

  insert into public.places_global
    (identity_key, name, category, kind, latitude, longitude, neighborhood, image_url, source_url)
  values
    (v_key, p_name, coalesce(p_category, 'food')::place_category, coalesce(p_kind, 'venue'),
     p_latitude, p_longitude, coalesce(p_neighborhood, ''), p_image_url, p_source_url)
  on conflict (identity_key) do update set
    -- Enrich only: fill gaps we didn't have before, never clobber good data.
    image_url  = coalesce(public.places_global.image_url, excluded.image_url),
    source_url = coalesce(public.places_global.source_url, excluded.source_url),
    updated_at = now()
  returning id into v_global;

  insert into public.places
    (id, owner_id, global_place_id, source, recommended_by, visited_by_ids, tags, is_saved)
  values
    (coalesce(p_id, gen_random_uuid()), v_uid, v_global, coalesce(p_source, 'manual')::place_source,
     p_recommended_by, coalesce(p_visited_by_ids, '{}'), coalesce(p_tags, '{}'), coalesce(p_is_saved, false))
  on conflict (id) do update set
    global_place_id = excluded.global_place_id,
    is_saved        = excluded.is_saved,
    tags            = excluded.tags;

  return coalesce(p_id, v_global);
end;
$$;

-- ---------------------------------------------------------------------------
-- update_place(): personal fields always; descriptive fields stored as an
-- override ONLY where they differ from the canonical global row (copy-on-write
-- — keeps dedup intact for unedited places).
-- ---------------------------------------------------------------------------
create or replace function public.update_place(
  p_id uuid,
  p_name text,
  p_category text,
  p_kind text,
  p_latitude double precision,
  p_longitude double precision,
  p_neighborhood text,
  p_source text,
  p_recommended_by uuid,
  p_visited_by_ids uuid[],
  p_tags text[],
  p_is_saved boolean,
  p_image_url text,
  p_source_url text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  g     public.places_global%rowtype;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;

  select gg.* into g
  from public.places p
  join public.places_global gg on gg.id = p.global_place_id
  where p.id = p_id and p.owner_id = v_uid;

  update public.places set
    source          = coalesce(p_source, 'manual')::place_source,
    recommended_by  = p_recommended_by,
    visited_by_ids  = coalesce(p_visited_by_ids, '{}'),
    tags            = coalesce(p_tags, '{}'),
    is_saved        = coalesce(p_is_saved, is_saved),
    name         = case when g.name         is not distinct from p_name then null else p_name end,
    category     = case when g.category     is not distinct from coalesce(p_category,'food')::place_category then null else coalesce(p_category,'food')::place_category end,
    latitude     = case when g.latitude     is not distinct from p_latitude then null else p_latitude end,
    longitude    = case when g.longitude    is not distinct from p_longitude then null else p_longitude end,
    neighborhood = case when g.neighborhood is not distinct from p_neighborhood then null else p_neighborhood end,
    image_url    = case when g.image_url    is not distinct from p_image_url then null else p_image_url end,
    source_url   = case when g.source_url   is not distinct from p_source_url then null else p_source_url end
  where id = p_id and owner_id = v_uid;
end;
$$;

grant execute on function public.save_place(
  uuid, text, text, text, double precision, double precision, text, text, uuid, uuid[], text[], boolean, text, text
) to authenticated;
grant execute on function public.update_place(
  uuid, text, text, text, double precision, double precision, text, text, uuid, uuid[], text[], boolean, text, text
) to authenticated;
