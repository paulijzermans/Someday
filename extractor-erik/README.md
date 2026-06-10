# extractor-erik — Erik's video-extraction pipeline (vendored)

A **vendored copy** of the place-extraction backend from Erik's repo
[`etij/someday`](https://github.com/etij/someday). It lives here, in a separate
folder from the iOS app, so we can try it out as an alternative to our own
extraction pipeline and **switch back to ours at any time**.

> This is a snapshot copy, not a git submodule — so it won't drift or break the
> build. To refresh it, re-copy `extractor/`, `extractor-test-app/`, `Dockerfile`,
> `railway.toml` from upstream `etij/someday`.

## What it does

Turns an Instagram Reel / TikTok URL into structured places:

```
URL → yt-dlp download → ffmpeg transcode → Gemini vision → Google Places resolve → JSON
```

| Path | Role |
|---|---|
| `extractor/downloader.py`  | yt-dlp video download (concurrent fragments) |
| `extractor/transcoder.py`  | ffmpeg transcode (subprocess) |
| `extractor/gemini.py`      | Gemini vision → place names (`GEMINI_API_KEY`) |
| `extractor/places.py`      | Google Places Text Search → coords/details (`GOOGLE_PLACES_API_KEY`) |
| `extractor/cache_db.py`    | SQLite reel + place cache |
| `extractor/config.py`      | feature flags (single-call Places, concurrent fragments, caching) |
| `extractor-test-app/server.py` | Flask orchestrator + SSE/polling endpoints |
| `Dockerfile`, `railway.toml`   | Railway deploy (gunicorn, persistent cache volume) |

## API contract (consumed by the iOS app)

All authed endpoints require `X-Api-Key: <API_KEY>` when the server has `API_KEY` set.

| Method | Path | Returns |
|---|---|---|
| `POST` | `/run`           | `{ "run_id": "<uuid>" }` |
| `GET`  | `/result/{id}`   | `{ status: pending\|done\|error, places: [...], error }` (polling) |
| `GET`  | `/events/{id}`   | Server-Sent Events: `step:start` / `step:done` / `step:error` / `pipeline:done` |
| `GET`  | `/health`        | `{ "status": "ok" }` |

Our iOS client (`Pipeline2Service`) uses the **`/result` polling** path (1.5s ×
90 attempts) rather than SSE — see "iOS integration" below.

## Run it locally

```bash
cd extractor-erik
cp .env.example .env          # fill in GEMINI_API_KEY + GOOGLE_PLACES_API_KEY
pip install -r requirements.txt
# ffmpeg must be on PATH (brew install ffmpeg)
PYTHONPATH=. python extractor-test-app/server.py     # serves on :5050
# or, prod-style:
# gunicorn -w 1 -k gthread --threads 4 --bind 0.0.0.0:5050 --chdir extractor-test-app server:app
```

The live upstream deploy is `https://extractor-production-3a29.up.railway.app`.

## iOS integration — how to switch pipelines

The Swift side is **already abstracted** behind a single protocol so the app
never hard-codes which backend runs. Files in
`Someday/Core/Services/Extraction/`:

- `URLExtractionService` — the protocol (`extractFromInstagram`, `extractFromGoogleMaps`).
- `Pipeline1Service` — **our** pipeline (Supabase Edge Functions + CLGeocoder). Default.
- `Pipeline2Service` — **Erik's** pipeline (this folder), talked to over REST.
- `ExtractionRouter` — dispatches each call to Pipeline 1 or 2 based on the selector.
- `ExtractionPipelineSelector` — the single switch (UserDefaults-backed).
- `ExtractorConfig` — reads `EXTRACTOR_URL` + `EXTRACTOR_API_KEY` from `Secrets.plist`.

### Try Erik's pipeline

1. Add to the app's gitignored `Secrets.plist`:
   - `EXTRACTOR_URL` = `https://extractor-production-3a29.up.railway.app` (or your local URL)
   - `EXTRACTOR_API_KEY` = the server's `API_KEY` (omit/empty if the server has no auth)
2. Flip the selector (lldb console, a debug action, or anywhere in code):
   ```swift
   ExtractionPipelineSelector.current = .pipeline2
   ```

### Switch back to ours

```swift
ExtractionPipelineSelector.current = .pipeline1   // also the default
```

Safety nets baked into the router:
- The selector is read **lazily on every call**, so flipping it takes effect on
  the next extraction — no app restart.
- If Pipeline 2 is selected but `Secrets.plist` isn't configured, the router
  **silently falls back to Pipeline 1** instead of erroring.
- Google Maps URLs **always** use Pipeline 1 — Erik's pipeline is video-only.

## Provenance

Source: `etij/someday` (Erik), `extractor/` + `extractor-test-app/`. Excluded from
this copy: Erik's own iOS app (`app/`), `db/`, `seed/`, benchmarks. Secrets and
caches (`.env`, `cache/`, `*.db`, `__pycache__`) are intentionally not vendored.
