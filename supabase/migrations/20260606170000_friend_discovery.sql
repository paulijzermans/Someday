-- ============================================================================
-- Friend discovery via contact matching
-- ============================================================================
--
-- Adds the columns + tables needed for "find your loved ones who already
-- have Someday" — the user lets us read their address book on-device, we
-- hash every phone + email, send the hash list to the `find-friends-on-
-- someday` Edge Function, and it returns the matched profiles.
--
-- Privacy posture:
--   • The server NEVER sees raw phone numbers or email addresses from a
--     user's contacts. The iOS client hashes everything client-side with
--     SHA-256 before transmitting.
--   • A user's own phone + email are hashed by a Postgres trigger so the
--     hash columns stay in lock-step with the source columns automatically
--     — no client-side bookkeeping required.
--   • The hash columns are indexed for cheap O(log n) matches against
--     incoming hash arrays.
--   • SHA-256 of a 10-digit phone number is brute-force-able by a motivated
--     attacker; this is the standard limitation of contact-discovery and
--     is accepted by every major messaging app. Future iteration could
--     layer a server-side secret salt for k-anonymity.

create extension if not exists pgcrypto with schema extensions;

-- ----------------------------------------------------------------------------
-- profiles: phone column + hash columns for matching
-- ----------------------------------------------------------------------------

alter table public.profiles
  add column if not exists phone        text,
  add column if not exists phone_hash   text,
  add column if not exists email_hash   text;

-- Indexes on the hashes so a `where phone_hash = any($1)` lookup is fast
-- even with hundreds of incoming hashes from a typical address book.
create index if not exists profiles_phone_hash_idx on public.profiles(phone_hash);
create index if not exists profiles_email_hash_idx on public.profiles(email_hash);

-- ----------------------------------------------------------------------------
-- Hash trigger: keep `phone_hash` and `email_hash` in sync with the
-- source columns. Normalisation rules:
--   • phone — strip everything except digits and a leading "+".
--   • email — lower-case, trim leading/trailing whitespace.
-- A NULL or empty source column yields a NULL hash so the matching
-- function naturally skips empty rows.
-- ----------------------------------------------------------------------------

create or replace function public.compute_profile_contact_hashes()
returns trigger
language plpgsql
as $$
declare
  norm_email text;
  norm_phone text;
begin
  -- Email: lowercase + trim. NULL or "" → NULL hash.
  norm_email := nullif(lower(trim(coalesce(new.email, ''))), '');
  if norm_email is null then
    new.email_hash := null;
  else
    new.email_hash := encode(extensions.digest(norm_email, 'sha256'), 'hex');
  end if;

  -- Phone: keep digits and a leading "+". E.164 strings like
  -- "+31 6 12 34 56 78" collapse to "+31612345678".
  norm_phone := regexp_replace(coalesce(new.phone, ''), '[^\d+]', '', 'g');
  -- A single "+" with no digits is meaningless; treat as empty.
  if norm_phone is null or norm_phone = '' or norm_phone = '+' then
    new.phone_hash := null;
  else
    new.phone_hash := encode(extensions.digest(norm_phone, 'sha256'), 'hex');
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_hash_contacts on public.profiles;
create trigger profiles_hash_contacts
  before insert or update of email, phone on public.profiles
  for each row execute function public.compute_profile_contact_hashes();

-- Backfill: hash existing rows in-place so already-registered users are
-- discoverable immediately rather than waiting for their next profile
-- update. Touches each row exactly once — cheap on the size of profiles
-- we expect for a new product.
update public.profiles set email = email;

-- ----------------------------------------------------------------------------
-- friend_requests: pending friendship invites
-- ----------------------------------------------------------------------------
-- One row per outstanding request. Accepting inserts two `friendships`
-- rows (one each direction) AND deletes the request. Rejecting just
-- deletes the request. Re-requesting a recently-rejected user is allowed
-- because the row no longer exists.

create table if not exists public.friend_requests (
  from_id    uuid not null references public.profiles(id) on delete cascade,
  to_id      uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (from_id, to_id),
  check (from_id <> to_id)
);
create index if not exists friend_requests_to_idx on public.friend_requests(to_id);

alter table public.friend_requests enable row level security;

-- Readable by either party — the sender (to see if it's pending) and
-- the receiver (to see incoming requests in their inbox).
drop policy if exists friend_requests_read on public.friend_requests;
create policy friend_requests_read on public.friend_requests
  for select to authenticated
  using (auth.uid() = from_id or auth.uid() = to_id);

-- Insert: only the sender can create the row, and only with themselves
-- as `from_id`. No requesting yourself.
drop policy if exists friend_requests_insert on public.friend_requests;
create policy friend_requests_insert on public.friend_requests
  for insert to authenticated
  with check (auth.uid() = from_id and from_id <> to_id);

-- Delete: either party can delete (sender cancels, receiver
-- accepts/rejects). The receiver's "accept" path inserts the friendship
-- rows BEFORE deleting — done atomically inside the RPC below.
drop policy if exists friend_requests_delete on public.friend_requests;
create policy friend_requests_delete on public.friend_requests
  for delete to authenticated
  using (auth.uid() = from_id or auth.uid() = to_id);

-- ----------------------------------------------------------------------------
-- accept_friend_request: SECURITY DEFINER so the receiver can insert
-- the two friendship rows atomically with the request deletion. Without
-- this we'd need separate RLS rules on `friendships` for the inserts.
-- ----------------------------------------------------------------------------

create or replace function public.accept_friend_request(p_from_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_to_id uuid := auth.uid();
begin
  if v_to_id is null then
    raise exception 'accept_friend_request: no auth.uid()';
  end if;
  -- Confirm a request exists from p_from_id to the caller.
  if not exists (
    select 1 from public.friend_requests
    where from_id = p_from_id and to_id = v_to_id
  ) then
    raise exception 'accept_friend_request: no pending request from %', p_from_id;
  end if;
  -- Bidirectional friendship.
  insert into public.friendships(user_id, friend_id) values (v_to_id, p_from_id)
    on conflict do nothing;
  insert into public.friendships(user_id, friend_id) values (p_from_id, v_to_id)
    on conflict do nothing;
  delete from public.friend_requests
    where from_id = p_from_id and to_id = v_to_id;
end;
$$;

revoke all on function public.accept_friend_request(uuid) from public;
grant execute on function public.accept_friend_request(uuid) to authenticated;
