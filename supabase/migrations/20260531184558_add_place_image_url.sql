-- Add image_url to places so imports (Google Maps, Instagram, etc.) can
-- carry through the source's thumbnail / hero photo. Nullable because
-- not every place will have one and we don't want to backfill existing
-- rows with placeholders.

ALTER TABLE public.places
  ADD COLUMN IF NOT EXISTS image_url TEXT;
