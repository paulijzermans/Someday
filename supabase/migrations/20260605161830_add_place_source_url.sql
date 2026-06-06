-- Add source_url to places so a saved pin can deep-link back to the
-- Instagram Reel / TikTok / Google Maps share URL it was imported from.
-- Drives the "tap the source badge → open the original post" affordance
-- in PlaceCardSheet. Nullable for manually-added places.

ALTER TABLE public.places
  ADD COLUMN IF NOT EXISTS source_url TEXT;
