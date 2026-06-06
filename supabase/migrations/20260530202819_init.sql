-- ============================================================================
-- Someday — Postgres schema + Row-Level Security
-- Paste this into the Supabase SQL editor (Dashboard → SQL → New query → Run).
-- Safe to re-run: drops and recreates policies, uses IF NOT EXISTS for tables.
-- ============================================================================

-- Extensions ----------------------------------------------------------------
create extension if not exists "pgcrypto";   -- gen_random_uuid()

-- ============================================================================
-- ENUMS  (mirror the Swift enums in Place.swift)
-- ============================================================================
do $$ begin
  create type place_category as enum ('food','drinks','coffee','activity','art','travel');
exception when duplicate_object then null; end $$;

do $$ begin
  create type place_source as enum ('manual','instagram','facebook','tiktok','googleMaps','friend');
exception when duplicate_object then null; end $$;

-- ============================================================================
-- TABLES
-- ============================================================================

-- profiles: 1:1 with auth.users (id == auth.users.id) ------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null default '',
  email       text not null default '',
  avatar_url  text,
  created_at  timestamptz not null default now()
);

-- friendships: directional rows; a mutual friendship = two rows --------------
create table if not exists public.friendships (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  friend_id  uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);
create index if not exists friendships_friend_idx on public.friendships(friend_id);

-- places ---------------------------------------------------------------------
create table if not exists public.places (
  id             uuid primary key default gen_random_uuid(),
  owner_id       uuid not null references public.profiles(id) on delete cascade,
  name           text not null,
  category       place_category not null default 'food',
  latitude       double precision not null,
  longitude      double precision not null,
  source         place_source not null default 'manual',
  neighborhood   text not null default '',
  recommended_by uuid references public.profiles(id) on delete set null,
  visited_by_ids uuid[] not null default '{}',
  tags           text[] not null default '{}',
  is_saved       boolean not null default false,
  created_at     timestamptz not null default now()
);
create index if not exists places_owner_idx on public.places(owner_id);

-- reviews: full breakdown by ANY user for a place.
--   * owner's own row  -> maps to Place.review
--   * other users rows -> map to Place.friendRatings[author_id] = overall
create table if not exists public.reviews (
  place_id   uuid not null references public.places(id) on delete cascade,
  author_id  uuid not null references public.profiles(id) on delete cascade,
  price      double precision not null default 0,
  quality    double precision not null default 0,
  service    double precision not null default 0,
  comment    text not null default '',
  -- generated overall = average of the three sliders
  overall    double precision generated always as ((price + quality + service) / 3.0) stored,
  created_at timestamptz not null default now(),
  primary key (place_id, author_id)
);

-- lists & list membership ----------------------------------------------------
create table if not exists public.lists (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  name       text not null,
  created_at timestamptz not null default now(),
  unique (owner_id, name)
);

create table if not exists public.list_places (
  list_id   uuid not null references public.lists(id) on delete cascade,
  place_id  uuid not null references public.places(id) on delete cascade,
  position  integer not null default 0,
  primary key (list_id, place_id)
);

-- ============================================================================
-- HELPER: are_friends() — SECURITY DEFINER so RLS policies that call it do not
-- recurse into the friendships table's own RLS.
-- ============================================================================
create or replace function public.are_friends(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.friendships
    where (user_id = a and friend_id = b)
       or (user_id = b and friend_id = a)
  );
$$;

-- ============================================================================
-- TRIGGER: auto-create a profile row when a new auth user signs up
-- ============================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, name, email, avatar_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', ''),
    coalesce(new.email, ''),
    new.raw_user_meta_data->>'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================================
-- ROW-LEVEL SECURITY
-- ============================================================================
alter table public.profiles    enable row level security;
alter table public.friendships enable row level security;
alter table public.places      enable row level security;
alter table public.reviews     enable row level security;
alter table public.lists       enable row level security;
alter table public.list_places enable row level security;

-- ---- profiles --------------------------------------------------------------
-- Any authenticated user can read profiles (needed for friend search + display).
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated using (true);

drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles
  for insert to authenticated with check (id = auth.uid());

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- ---- friendships -----------------------------------------------------------
-- You can see and manage only rows where you are the owning side.
drop policy if exists friendships_select on public.friendships;
create policy friendships_select on public.friendships
  for select to authenticated
  using (user_id = auth.uid() or friend_id = auth.uid());

drop policy if exists friendships_insert on public.friendships;
create policy friendships_insert on public.friendships
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists friendships_delete on public.friendships;
create policy friendships_delete on public.friendships
  for delete to authenticated using (user_id = auth.uid());

-- ---- places ----------------------------------------------------------------
-- Read your own places + your friends' places. Write only your own.
drop policy if exists places_select on public.places;
create policy places_select on public.places
  for select to authenticated
  using (owner_id = auth.uid() or public.are_friends(auth.uid(), owner_id));

drop policy if exists places_insert on public.places;
create policy places_insert on public.places
  for insert to authenticated with check (owner_id = auth.uid());

drop policy if exists places_update on public.places;
create policy places_update on public.places
  for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists places_delete on public.places;
create policy places_delete on public.places
  for delete to authenticated using (owner_id = auth.uid());

-- ---- reviews ---------------------------------------------------------------
-- Read a review if you can see the underlying place. Write only your own.
drop policy if exists reviews_select on public.reviews;
create policy reviews_select on public.reviews
  for select to authenticated
  using (
    exists (
      select 1 from public.places p
      where p.id = place_id
        and (p.owner_id = auth.uid() or public.are_friends(auth.uid(), p.owner_id))
    )
  );

drop policy if exists reviews_write on public.reviews;
create policy reviews_write on public.reviews
  for all to authenticated
  using (author_id = auth.uid())
  with check (author_id = auth.uid());

-- ---- lists -----------------------------------------------------------------
drop policy if exists lists_select on public.lists;
create policy lists_select on public.lists
  for select to authenticated
  using (owner_id = auth.uid() or public.are_friends(auth.uid(), owner_id));

drop policy if exists lists_write on public.lists;
create policy lists_write on public.lists
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- ---- list_places -----------------------------------------------------------
drop policy if exists list_places_select on public.list_places;
create policy list_places_select on public.list_places
  for select to authenticated
  using (
    exists (
      select 1 from public.lists l
      where l.id = list_id
        and (l.owner_id = auth.uid() or public.are_friends(auth.uid(), l.owner_id))
    )
  );

drop policy if exists list_places_write on public.list_places;
create policy list_places_write on public.list_places
  for all to authenticated
  using (
    exists (select 1 from public.lists l where l.id = list_id and l.owner_id = auth.uid())
  )
  with check (
    exists (select 1 from public.lists l where l.id = list_id and l.owner_id = auth.uid())
  );

-- ============================================================================
-- STORAGE (avatars / place photos) — create a public-read bucket
-- ============================================================================
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

-- Anyone can read avatars; users can upload/replace their own (path = <uid>/...)
drop policy if exists avatars_read on storage.objects;
create policy avatars_read on storage.objects
  for select using (bucket_id = 'avatars');

drop policy if exists avatars_write on storage.objects;
create policy avatars_write on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists avatars_update on storage.objects;
create policy avatars_update on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
