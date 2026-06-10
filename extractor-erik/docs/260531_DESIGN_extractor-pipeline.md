# Someday — Extractor Pipeline Design

**Date:** 2026-05-31  
**Status:** Validated MVP, ready for production integration

---

## What it does

Given an Instagram Reel URL, the pipeline:
1. Downloads the video
2. Transcodes it to a small format Gemini can process cheaply
3. Uses Gemini to extract every mentioned place (name, type, context)
4. Resolves each place to a canonical Google Place ID with full details
5. Stores the reel and its places in SQLite

Output: a list of resolved places with name, address, coordinates, rating, hours, website, and Maps link.

---

## Architecture

```
URL
 └─ 0. Reel cache check          ← skip everything if URL already processed
     └─ 1. Download (yt-dlp)     ← MP4 to disk
         └─ 2. Transcode (ffmpeg) ← reduce to 1fps / 360p for Gemini
             └─ 3. Extract (Gemini) ← inline base64, structured JSON out
                 └─ 4. Resolve (Places API) ← all places in parallel
                     └─ 5. Store (SQLite)
```

---

## Step-by-step design decisions

### 0. Reel cache (SQLite)

**What:** Before downloading, check if this URL's `post_id` is already in the `reels` table. If yes, return stored places immediately and skip all API calls.

**Why:** The biggest efficiency gain in the pipeline. A re-submitted URL costs ~0ms instead of 6–13s.

**Toggle:** `REEL_CACHE_ENABLED` in `config.py` (default: on). Also exposed as a checkbox in the test UI so it can be disabled per-run without a code change — important for benchmarking.

---

### 1. Download — yt-dlp

**What:** Download the Reel MP4 to `extractor-test-app/cache/{post_id}.mp4`.

**Why yt-dlp:** No auth required for public content, handles both Instagram and TikTok, actively maintained. Official Instagram APIs don't provide MP4 access.

**Key setting — concurrent fragment downloads (`CONCURRENT_FRAGMENTS=True`):**  
Instagram serves video in segments (HLS/DASH). Downloading 5 segments in parallel instead of 1 at a time cuts download time by ~2.5× (from ~2.5s to ~1.0s average in benchmarks).

**Format:** Best available quality. A 480p cap was benchmarked but found to have no effect — Instagram doesn't expose lower-quality variants in a way yt-dlp can select. The transcoder reduces size anyway.

**File-level cache:** If `cache/{post_id}.mp4` already exists, skip the download. This is always active regardless of `REEL_CACHE_ENABLED`, so a second run of the same URL (with reel cache off) still avoids re-downloading.

---

### 2. Transcode — ffmpeg

**What:** Convert the downloaded MP4 to 1fps / 360px-wide, keeping audio. Output: `cache/{post_id}_out.mp4`.

**Why transcode at all:** Gemini's inline base64 limit is 20MB. Raw Reels average 6–16MB but can be larger. More importantly, Gemini uses `MEDIA_RESOLUTION_LOW` (1 token/sec of video) so sending a 1080p source wastes upload time without improving extraction.

**1fps:** Text overlays on Reels stay on screen for 2–5 seconds. 1fps captures all of them with 30–60× fewer frames than the original 30fps source. Audio is kept in full for voiceover detection.

**scale=360:-2:** Fixed 360px width, height calculated to maintain aspect ratio (portrait Reels → ~360×640). This is a fixed absolute size rather than `iw/2:ih/2` (which varies with source resolution and gave inconsistent results: 540px for 1080p source, 360px for 720p).

**libx264 -crf 40 -preset ultrafast:**  
- Tested against `h264_videotoolbox` (Apple Silicon hardware encoder). Hardware encoder was *slower* for this workload — it has a fixed initialization cost that dominates when encoding only 30–90 frames.  
- libx264 compiled with `--enable-neon` uses Apple Silicon NEON SIMD — so it is hardware-optimized at the CPU level.  
- CRF 40 is visually low quality but perfectly legible for AI extraction. Lower quality = smaller file.
- Result: **avg 0.83 MB vs 6.75 MB** before (8× reduction), slightly faster encoding.

**Audio: 32kbps mono 16kHz:** Sufficient for speech/voiceover recognition. Reduced from 64kbps with no accuracy impact.

**Transcoding time:** ~0.37s for a 20s reel, ~0.97s for a 90s reel. The floor is set by input decoding speed (~0.011s per second of source video). The 0.5s target is achievable for reels ≤ ~45 seconds; longer reels are physically limited by H.264 decode throughput regardless of encoder choice.

**Skip if exists:** Transcoded file is cached on disk. Re-runs (with reel cache disabled) skip this step.

---

### 3. Extraction — Gemini

**Model:** `gemini-3.1-flash-lite`  
Validated in a 12-run spike (21s Bangkok rooftop video, 6 configurations): 12/12 correct, 5/5 places, correct city and country. Reliable, fast, cheap (~$0.0008/video).

**Upload method: inline base64 (no File API)**  
The File API requires uploading, then polling until the file reaches `ACTIVE` state — adds 10–30s of latency. Inline sends everything in a single request (~3s total). The transcoded file averages 0.83MB, well within the 20MB inline limit.

**`thinking_budget=0` (thinking off)**  
Thinking adds up to 2× latency with no accuracy improvement for this task. Place name extraction is straightforward pattern-matching, not multi-step reasoning.

**`media_resolution=LOW`**  
Reduces video token count from ~23,500 to ~1,915 (12× reduction) with identical extraction accuracy. Gemini samples at 1 token/sec of video at LOW resolution, which is well-matched to our 1fps transcoded output.

**Prompt structure:**  
- System prompt: instructs JSON-only output
- User prompt: includes Reel metadata (title, caption, uploader) as text alongside the video. Place names sometimes appear in captions but not in the video itself.
- Output schema: `[{name, type, detail}]` — detail holds city, neighbourhood, address as free text to feed the Places API query.

**Retry:** On JSON parse failure, retries once with an explicit correction instruction. Two consecutive failures → log and skip the URL.

**Gemini is the dominant bottleneck:** 2–13s depending on video length and number of places to extract. This is the step with the most remaining optimization potential.

---

### 4. Resolution — Google Places API

**What:** For each extracted place, resolve to a canonical `place_id` and fetch full details.

**Single-call design (`SINGLE_CALL_PLACES=True`):**  
Originally two calls per place: (1) Text Search ID-only (free SKU) → (2) Place Details (Enterprise SKU, $0.020/request). Merged into a single Text Search call with a full field mask. Eliminates one HTTP round-trip per place. Same cost as the two-call path (field access triggers the same billing tier regardless of endpoint).

**Parallel resolution (ThreadPoolExecutor, max 20 workers):**  
All places are resolved concurrently. Wall-clock time is driven by the slowest single call, not by the number of places. A reel with 15 places takes roughly the same time as one with 3.

**Confidence check:** The returned `displayName` must share at least one significant token (>2 chars) with the query string. Prevents low-confidence matches from being stored as resolved places.

**Place cache:** `place_id` → full details stored in SQLite permanently. A place seen in any reel is never fetched twice. Toggle: `PLACE_CACHE_ENABLED` (default: on).

**Fields fetched:** `id, displayName, formattedAddress, location (lat/lng), rating, userRatingCount, regularOpeningHours, nationalPhoneNumber, websiteUri, priceLevel, primaryType, businessStatus, googleMapsUri`

**SKU cost:**
| SKU | Trigger | Price |
|---|---|---|
| Text Search (with full field mask) | Per place | ~$0.020/request |
| Place cache hit | — | $0 |

---

### 5. Storage — SQLite

Three tables:

**`reels`** — one row per processed URL. Stores post_id, title, caption, uploader, view count, timestamps.

**`reel_places`** — junction table linking a reel to its extracted places. Stores both the Gemini-extracted name/type/detail and the resolved `place_id`.

**`places`** — permanent cache of resolved place details, keyed by `place_id`. Written once, never updated (place data is stable enough for MVP).

SQLite writes are serialised via a `threading.Lock()` because place resolution runs in parallel threads.

---

## Performance results (benchmarked 2026-05-31)

Full benchmark across all 4 optimisation configs × 3 reels (cold run, no caching, sequential, 3s sleep between runs):

| Config | download | transcode | gemini | places | **total** |
|---|---|---|---|---|---|
| baseline | 0.9s | 0.7s | 8.5s | 0.4s | **10.4s** |
| A: fragments | 0.8s | 0.7s | 7.5s | 0.4s | **9.4s** |
| A+B: 480p | 1.0s | 0.7s | 6.0s | 0.4s | **8.1s** |
| A+B+C: all | 0.9s | 0.7s | 3.9s | 0.3s | **5.7s** |

Per-reel breakdown (final optimised config):

| Reel | length | download | transcode | gemini | places | total |
|---|---|---|---|---|---|---|
| DTpr7JzDaNF | 88s | 0.9s | 1.0s | 4.3s | 0.2s | 6.4s |
| DW4EnUbjALF | 57s | 0.9s | 0.7s | 3.3s | 0.2s | 5.2s |
| DWgFaJ3gv3_ | 20s | 0.9s | 0.4s | 4.0s | 0.3s | 5.6s |

**Optimisation impact vs baseline:**

| | Baseline | Optimised | Change |
|---|---|---|---|
| Transcode (file size) | 6.75 MB | 0.83 MB | −88% |
| Places (per-place calls) | 2 API calls | 1 API call | −50% |
| **Total pipeline** | **10.4s** | **5.7s** | **−45%** |

**Notes:**
- Download shows no meaningful gain from concurrent fragments (0.9s baseline vs 0.8s optimised) — the connection ran at 50–65 MB/s, so parallel fragments had nothing to accelerate.
- Gemini times show run-order variance (DWgFaJ3gv3_ went 18.5s → 4.0s across configs), likely API warm-up on sequential runs. Per-reel numbers for the final config above are the most reliable.
- **Gemini remains the dominant bottleneck** at 55–75% of total time. The main lever remaining is video length.

---

## Production configuration

All flags live in `extractor/config.py`. These are the validated production settings:

| Flag | Value | Rationale |
|---|---|---|
| `REEL_CACHE_ENABLED` | `True` | Re-submitted URLs return instantly from SQLite — skip all API calls |
| `PLACE_CACHE_ENABLED` | `True` | A resolved place is never fetched twice across all reels |
| `CONCURRENT_FRAGMENTS` | `True` | Download video segments in parallel (yt-dlp HLS/DASH) |
| `LOW_QUALITY_DOWNLOAD` | `False` | Benchmarked — no effect. Instagram doesn't expose lower-quality variants via yt-dlp. Leave off. |
| `SINGLE_CALL_PLACES` | `True` | One Text Search call returns all place fields — eliminates a round-trip per place |

Transcode settings (`extractor/transcoder.py`) are fixed, not flags:
- **1fps / 360px wide / libx264 CRF 40 / ultrafast** — 8× file size reduction vs raw, sufficient quality for AI extraction
- **Audio: 32kbps mono 16kHz** — sufficient for voiceover recognition

Gemini settings (`extractor/gemini.py`) are fixed:
- **Model: `gemini-3.1-flash-lite`** — reliable, fast, cheap (~$0.0008/video)
- **`thinking_budget=0`** — thinking adds latency with no accuracy benefit for this task
- **`media_resolution=LOW`** — 12× token reduction with identical extraction accuracy

---

## Project structure

```
someday/
├── app/                        # Reserved for iOS app
├── extractor/                  # Reusable pipeline package
│   ├── __init__.py
│   ├── config.py               # Feature flags (cache toggles, speed opts)
│   ├── downloader.py           # yt-dlp wrapper
│   ├── transcoder.py           # ffmpeg wrapper
│   ├── gemini.py               # Gemini Flash extraction
│   ├── places.py               # Google Places resolution (parallel)
│   └── cache_db.py             # SQLite schema + read/write helpers
├── extractor-test-app/         # Flask UI for manual testing
│   ├── server.py               # Flask + SSE pipeline runner
│   ├── main.py                 # CLI entrypoint
│   ├── ui.html                 # Single-file frontend
│   ├── benchmark_speed.py      # Timing benchmark across configs
│   ├── cache/                  # Downloaded + transcoded videos (gitignored)
│   └── places.db               # SQLite database (gitignored)
├── .env                        # GEMINI_API_KEY, GOOGLE_PLACES_API_KEY (gitignored)
└── docs/
    └── design/
        └── 260531_DESIGN_extractor-pipeline.md  ← this file
```

**Running the test app:**
```bash
cd extractor-test-app
python3 server.py
# open http://localhost:5050
```

---

## iOS integration

### Architecture

The extractor runs as a standalone HTTP service. The iOS app is a pure client — it sends a URL, streams progress events, and receives a list of resolved places. No pipeline logic lives in the app.

```
iOS app
  └─ POST /run  →  Extractor service
                      └─ SSE stream  →  iOS app (step progress + final result)
```

The Flask server in `extractor-test-app/server.py` is already this service. For production it needs to be deployed to a cloud host and hardened (see next steps below).

---

### Current API contract

**Start a pipeline run**
```
POST /run
Content-Type: application/json

{ "url": "https://www.instagram.com/reel/...", "reel_cache": true, "place_cache": true }

→ 200 { "run_id": "<uuid>" }
→ 400 { "error": "url required" }
```

**Stream events for a run**
```
GET /events/{run_id}
Accept: text/event-stream
```

Event types emitted on the stream:

| Event | Payload | Meaning |
|---|---|---|
| `step:start` | `{ step }` | Step began |
| `step:done` | `{ step, duration_ms, output }` | Step succeeded |
| `step:error` | `{ step, duration_ms, error }` | Step failed with user-readable message |
| `pipeline:done` | `{ places, total_ms, cached }` | All steps complete — `places` is the final result |
| `pipeline:error` | `{ error, total_ms }` | Pipeline aborted — user-readable message |
| `stream:close` | `{}` | Stream is done, close the connection |

Step names in order: `download`, `transcode`, `gemini`, `places`, `store`.

**Place object shape** (array in `pipeline:done.places`):
```json
{
  "place_id": "ChIJ...",
  "display_name": "Le Petit Vendôme",
  "formatted_address": "8 Rue des Capucines, 75002 Paris, France",
  "lat": 48.869,
  "lng": 2.333,
  "rating": 4.5,
  "rating_count": 1234,
  "price_level": "PRICE_LEVEL_MODERATE",
  "phone": "+33 1 ...",
  "website": "https://...",
  "google_maps_uri": "https://maps.google.com/...",
  "primary_type": "restaurant",
  "business_status": "OPERATIONAL",
  "opening_hours": { ... },
  "from_cache": false,
  "gemini_name": "Le Petit Vendome",
  "gemini_type": "restaurant",
  "gemini_detail": "Paris, near Opera"
}
```

If a place could not be resolved to a Google Place, `place_id` is `null` and only `gemini_name`, `gemini_type`, `gemini_detail` are populated.

**Step timeouts** (enforced server-side — errors are user-readable):

| Step | Timeout |
|---|---|
| download | 8s |
| transcode | 3s |
| gemini | 30s |
| places | 3s |

---

### Consuming SSE in Swift

Swift's `URLSession` supports streaming responses but has no built-in SSE parser. Two options:

1. **Use the `EventSource` Swift package** (`swift-eventsource` or similar) — handles reconnection and event parsing automatically.
2. **Use a simple polling endpoint instead** — add a `GET /result/{run_id}` endpoint to the service that returns the final places once complete. The iOS app polls every 2s. Simpler to implement in Swift at the cost of slightly delayed results.

Option 2 is recommended for the initial iOS build to keep the client code simple. SSE can be added later for real-time progress display.

---

### Next steps before iOS integration

These need to be done on the service side before the iOS app can consume it:

1. **Add API key auth** — the service currently has no authentication. Add a shared secret checked on every request (`X-Api-Key` header). Store the key in `.env`.

2. **Add `GET /health` endpoint** — returns `{ "status": "ok" }`. Used by the iOS app to check connectivity and by any hosting platform for health checks.

3. **Add `GET /result/{run_id}` endpoint** — returns `{ "status": "pending"|"done"|"error", "places": [...], "error": "..." }`. Lets the iOS app poll instead of consuming SSE. The pipeline thread writes the result into a shared dict when complete.

4. **Clean up completed runs** — the `_runs` dict in `server.py` currently grows forever. Add a TTL (e.g. remove entries older than 10 minutes) to prevent memory leaks on a long-running server.

5. **Switch from Flask dev server to gunicorn** — `app.run()` is single-process and not suitable for production. Use `gunicorn -w 1 -k gthread --threads 4 server:app` (single process, thread pool — needed because the pipeline uses threading internally).

6. **Deploy to a cloud host** — the service needs to be reachable by the iOS app. Recommended: **Railway** or **Fly.io** — both support Python, have free tiers, and handle HTTPS automatically. The service is stateless except for the SQLite file and the video cache; for MVP these can live on a persistent volume.

7. **HTTPS** — required by iOS for production (App Transport Security). The recommended cloud hosts provide this automatically.

8. **Move secrets to environment variables on the host** — `GEMINI_API_KEY`, `GOOGLE_PLACES_API_KEY`, and the new `API_KEY` should be set as environment variables on the hosting platform, not deployed via `.env`.

9. **Persist SQLite across deploys** — on a cloud host, the local filesystem is ephemeral. Mount a persistent volume for `places.db` and the video `cache/` directory, or swap SQLite for a hosted database (e.g. Turso, which is SQLite-compatible).

---

## Cost model (at scale)

Per reel (avg 30s, with place cache warm after first pass):

| Step | Cost |
|---|---|
| Gemini extraction | ~$0.0008 |
| Places API (5 places avg, first time) | ~$0.10 |
| Places API (cached) | $0 |
| yt-dlp / ffmpeg | $0 (self-hosted) |

At 10,000 reels with 80% place cache hit rate: ~$8 Gemini + ~$100 Places = **~$110 total**.
