-- ============================================================================
-- availability_cache: add provider-specific venue IDs
-- ============================================================================
--
-- The `find-reservation-platforms` function discovers which booking
-- platforms support a venue and returns their URLs. From those URLs we
-- can extract per-platform venue IDs:
--   • Zenchef:   bookings.zenchef.com/results?rid=357246   → "357246"
--   • TheFork:   thefork.com/restaurant/<slug>-r30078       → "30078"
--   • OpenTable: opentable.com/r/<slug>-<rid>               → "<rid>"
--
-- Storing those IDs lets the new `check-availability` function call the
-- provider's own JSON availability endpoint directly — no AI cost, no
-- web search, sub-second answer to "is there a table tonight?".
--
-- JSONB keyed by provider name keeps the shape open-ended: we can add
-- new providers (Formitable, Resy, SevenRooms) without further
-- migrations — just write a new key.

alter table public.availability_cache
  add column if not exists provider_ids jsonb not null default '{}'::jsonb;

-- Index on the JSON keys present, so future "which venues do we have a
-- Zenchef ID for?" admin queries don't full-scan.
create index if not exists availability_cache_provider_ids_gin
  on public.availability_cache using gin (provider_ids);
