-- ============================================================================
-- place-thumbnails — durable storage for cached place thumbnails.
-- ============================================================================
--
-- `place_cache.image_url` originally held the EXTERNAL image link the scraper
-- returned (Apify's Google image URL, or Instagram's `displayUrl`). Those rot:
-- Instagram CDN URLs are signed and expire within hours, and Google's rotate
-- too. A global cache whose thumbnails 404 a week later isn't much of a cache.
--
-- So the parse-* Edge Functions now download the thumbnail once (in the
-- background, after responding) and upload a durable copy here, then rewrite
-- the cached `image_url` / payload to this public URL. Future cache hits serve
-- an image that outlives the source.
--
-- Public-read (like `avatars`) so the iOS client can load thumbnails with the
-- anon key. Writes come only from the Edge Functions via the service-role key,
-- which bypasses RLS — so there is deliberately NO insert/update policy.

insert into storage.buckets (id, name, public)
values ('place-thumbnails', 'place-thumbnails', true)
on conflict (id) do nothing;

drop policy if exists place_thumbnails_read on storage.objects;
create policy place_thumbnails_read on storage.objects
  for select using (bucket_id = 'place-thumbnails');
