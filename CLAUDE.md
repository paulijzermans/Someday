# CLAUDE.md — Someday

Guidance for AI agents (and humans) working in this repo. Read this before
making changes. It captures the architecture, the conventions we hold to, the
non-obvious gotchas, and — most importantly — the *why* behind each.

> If something here is wrong or out of date, fix it in the same PR that proves
> it wrong. A stale guide is worse than none.

---

## 1. What this is

**Someday** is a SwiftUI iOS app for saving places to visit "someday" — pulled
from Instagram/TikTok shares, Google Maps lists, friend recommendations, and an
AI chat — and browsing them on a beautiful clustered map.

- **Client**: SwiftUI, **iOS 26 deployment target**, MapKit, MVVM with `@Observable`.
- **Backend**: Supabase — Postgres + Auth (Google OAuth) + Storage + Edge Functions (Deno/TypeScript). Row-Level Security gates every row.
- **Repo**: `git@github.com:paulijzermans/Someday.git`, working branch `main`.
- **Two extra components in-repo**: `supabase/` (schema, migrations, Edge Functions) and `extractor-erik/` (a vendored Python/Flask video-extraction service deployed on Railway — "Pipeline 2").

> Historical note: an earlier `SOMEDAY-MODEL.md` product doc described a Firebase /
> iOS 17 / turquoise / "no-AI" version of the app and was removed once it had
> drifted entirely from reality. This file plus `README.md` are the current
> source of truth — trust the code over any older doc you find.

---

## 2. Build, install, run

The app targets a **physical iPhone** (device id `945D7B7E-22B7-52A4-AC68-24A2BCE2B301`, bundle `com.paulijzermans.someday`). Scheme: `Someday`.

```bash
# Build for the connected device
xcodebuild -scheme Someday -configuration Debug \
  -destination 'id=945D7B7E-22B7-52A4-AC68-24A2BCE2B301' \
  -derivedDataPath build -allowProvisioningUpdates build

# Install the built .app onto the device
xcrun devicectl device install app --device 945D7B7E-22B7-52A4-AC68-24A2BCE2B301 \
  build/Build/Products/Debug-iphoneos/Someday.app
```

- **Standing instruction**: after any code change, auto-build + install to the device — don't wait to be asked.
- Builds are long; run them in the background and wait for completion rather than polling.
- For a simulator instead, swap the `-destination` for a simulator id and use `Debug-iphonesimulator`.

### Runtime modes (important)
`ServiceContainer.live` auto-selects the stack based on whether `Secrets.plist` is present:
- **Demo/mock mode** — no `Secrets.plist` → in-memory `Mock*` services + `SampleData`. Previews and a fresh clone boot straight onto an Amsterdam map. Nothing leaves the device.
- **Live mode** — `Secrets.plist` present and valid → the Supabase-backed stack.

This means the app **always runs** even without a backend. Keep it that way: every live service has a mock counterpart, and every router falls back to a mock when the Edge Function isn't deployed or errors.

---

## 3. Architecture

### Layering
```
Someday/
├── App/                      # @main (SomedayApp), AppState, ServiceContainer, SomedayPreferences
├── Core/
│   ├── Config/               # SupabaseConfig, ExtractorConfig, Secrets(.example).plist
│   ├── Models/               # Place, UserProfile, SampleData  (pure value types)
│   ├── Protocols/            # Service protocols (Auth, Place, User, List, Search)
│   ├── Services/
│   │   ├── Mock/             # In-memory implementations (demo mode + previews)
│   │   ├── Supabase/         # Live implementations + row DTOs (SupabaseRows)
│   │   ├── Extraction/       # URL→[Place] pipeline (router + 2 pipelines)
│   │   ├── Chat/ Reservation/ Location/ Friends/ Voice/
│   └── Theme/                # SomedayColors, SomedayAnimations, Haptics, TileStyle
├── Features/                 # One folder per surface: Map, AddPlace, Profile, Lists, …
└── Resources/Fonts/
supabase/                     # schema.sql, migrations/, functions/ (Edge Functions)
extractor-erik/               # vendored Python Flask video extractor (Railway)
SomedayShareExtension/        # iOS Share Sheet target → someday://import deep link
```

### Dependency injection via `ServiceContainer`
`ServiceContainer` (an `@Observable`) holds every service behind a protocol. Two
static factories build the whole graph — `.mock` and `.supabase` — and `.live`
picks between them. **All app code depends on protocols, never on a concrete
service.** This is what makes demo mode, previews, and incremental Edge Function
rollout possible.

`AppState` (`@Observable`) owns the top-level screen (`.auth` / `.map`), the
current user, onboarding flag, and deep-link handling. It's created once in
`SomedayApp` and threaded down.

### MVVM with `@Observable`
- Views are SwiftUI; view models are `@Observable` classes (e.g. `MapViewModel`, `ChatViewModel`).
- The map is the heart of the app. `MapHomeView` (~3300 loc) + `MapViewModel` (~2600 loc) are the largest files — expect to spend most time here.
- Services are `Sendable`, async/throws. UI-mutating methods are `@MainActor`.

### The Map feature (where most work happens)
| File | Role |
|---|---|
| `MapHomeView.swift` | The home screen: map + chrome + all the floating tiles + chat bubbles. |
| `MapViewModel.swift` | State + behaviour: places, lists, AI suggestion pins, camera choreography. |
| `ClusteredMapView.swift` | `UIViewRepresentable` MapKit bridge + all the Core Graphics pin renderers. |
| `PlaceCardSheet.swift` | The `map_pin_tile` — the card shown when you tap a saved pin. |
| `ChatMessageRenderer.swift` | Inline chat flow layout (pills, links) + `ChatPlacePeekCard` (the `chatbot_tile`). |
| `ChatAction.swift` | Typed decode of `someday://` commands → intents (see §6). |

---

## 4. The "tile" vocabulary (use these exact names)

We kept confusing UI surfaces, so the names are now fixed. Use them in code,
comments, and conversation:

- **`map_pin_tile`** — `PlaceCardSheet`. The standard card shown when you tap a saved pin on the map.
- **`introduction_tile`** — the swipeable slideshow in `ImportSummaryCardView` shown after importing a list of places (one card per place).
- **`chatbot_tile`** — `ChatPlacePeekCard`. The in-chat preview card for a pin.

Design rules learned the hard way:
- **Never nest a tile inside another tile.** `ChatPlacePeekCard` carries its own card chrome (white bg, rounded corners, shadow), so it must NOT live inside the glass chat bubble — it renders as a standalone sibling. Same lesson for the `introduction_tile` slideshow: no inner card chrome around each slide.
- **Map pins are one visual family.** Saved pins, AI-suggestion pins, and clusters all render as the same rounded **photo-tile** (40pt rounded square, photo or category-fallback image, white edge, little pointer to the coordinate). AI-suggestion pins differ only by a **lime edge + sparkle badge**; clusters show a count. The renderers live in `ClusteredMapView.swift` (`PlacePinAnnotationView.renderTile`, `SuggestionPinAnnotationView.renderTile`, `ClusterPinAnnotationView.renderCountTile`) — keep their geometry in sync.
- **Every image wears the photo-tile edge.** The map pins frame their photo in a thin white edge + faint hairline; that's the app-wide treatment for imagery. Use the **`.photoTileEdge(cornerRadius:edge:)`** modifier (in `TileStyle.swift`) on any image inside a tile/card instead of clipping it straight to a `RoundedRectangle`. It clips the image to an inner rounded rect, wraps it in a small white margin (`edge`, ~3pt) and a 0.5pt black hairline — the same look as the pin renderer, scaled up. Already applied to `map_pin_tile` (96pt hero), `introduction_tile` (160pt photo), and `chatbot_tile` (hero). New image surfaces should use it too.

### Floating glass tiles
`TileStyle.swift` defines `TileSize` (`.large` / `.half` / `.compact`) and the
`.floatingTile(size:onDismiss:)` modifier — a centered glass card on a
tap-to-dismiss scrim. Use it instead of hand-rolling the "floating card on a dim
scrim" pattern. Every map overlay (Lists, Activity, Add, Feedback, ImportSummary)
goes through it.

---

## 5. Theme & design language

- **Brand palette is blue + lime, NOT turquoise** (older docs say turquoise — wrong). Source of truth is `SomedayColors.swift`:
  - `primary` = blue `#4272FF`; accents cyan `#42EAFF`, amber `#FFB343`, coral `#FF7E42`.
  - **`lime` `#D4F061`** is the signature accent — the dominant CTA color (Send, Add, Import) and the "added/verified" status indicator. Pairs with **charcoal** text (too bright for white).
  - Many **backward-compatible aliases** exist (`green`→blue, `butter`→cyan, `accentGreen`→lime). Prefer semantic names (`primary`, `lime`, `charcoal`) in new code; don't add more aliases.
- **Haptics**: use `Haptics.tap()` / `Haptics.success()` etc. (`Haptics.swift`) — don't call `UIImpactFeedbackGenerator` directly.
- **Custom font**: `GondensDEMO` (brand wordmark only), registered in `SomedayApp.init` via `SomedayFonts.registerAll()`. Demo-licensed — not for commercial use.

---

## 6. Deep links & the AI action bus

The app is partly driven by `someday://` URLs — from the Share Extension, Supabase
auth redirects, and (crucially) the AI chat embedding command links in its replies.

- **External entry**: `SomedayApp.onOpenURL` → `AppState.handle(externalURL:)`. Hosts: `import` (Share Extension hand-off) and `auth-callback` (Supabase email/OAuth redirect).
- **In-app AI commands**: `ChatAction(url:)` in `ChatAction.swift` is the ONE place `someday://` command links are parsed into typed intents (`openPlace`, `suggest`, `openList`, `createList`, `editMembership`, `askAbout`, `showOnMap`). The view layer switches over the intent and applies side effects (haptics, camera, VM mutation). **Add new bot-driven behaviours as a new enum case here**, not as another inline string parse at a tap site.

---

## 7. The import / extraction pipeline

"Import a link" → `[Place]` is abstracted behind `URLExtractionService`
(`Core/Services/Extraction/`):
- `ExtractionRouter` dispatches each call to **Pipeline 1** (ours: Supabase Edge Functions `parse-gmaps` / `parse-instagram`) or **Pipeline 2** (Erik's Railway video extractor REST API), based on `ExtractionPipelineSelector` (a UserDefaults toggle, default Pipeline 1).
- **Google Maps always uses Pipeline 1.** If Pipeline 2 isn't configured (no `EXTRACTOR_URL`/`EXTRACTOR_API_KEY` in `Secrets.plist`), selection silently falls back to Pipeline 1.
- `ExtractorConfig.isConfigured` reads the Railway creds from `Secrets.plist`.
- A **DEBUG-only** in-app pipeline switcher lives in Profile → Developer (`DeveloperSettingsView` in `ProfileView.swift`). It never ships to production (`#if DEBUG`).
- Extractor usage limits (Pipeline 2): ≤5 req/min, <50/day, leave `reel_cache`/`place_cache` true.

---

## 8. Backend (Supabase)

- **Tables** (`supabase/schema.sql`): `profiles`, `friendships`, `places`, `reviews`, `lists`, `list_places`. RLS on everything.
- **Migrations** live in `supabase/migrations/` (timestamped). The schema has drifted ahead of the iOS `Place` model in places — some fields (`sourceURL`, `eventStart`/`eventEnd`) are **in-memory only on iOS** until a backing column lands. Check `Place.swift` field comments before assuming persistence.
- **Edge Functions** (`supabase/functions/`, Deno/TS): `chat` (SSE-streaming AI assistant with tools), `check-availability`, `find-friends-on-someday`, `find-reservation-platforms`, `parse-gmaps`, `parse-instagram`, plus `_shared`.
- **Service-role key and all LLM API keys live in Edge Functions only** — never in the iOS bundle. The client only ever holds the anon/public key.

---

## 9. Security & secrets — non-negotiable

- `Secrets.plist` is **gitignored** and holds the Supabase URL, **anon key only**, and the extractor creds. Never commit it. Never put the service-role key in the client.
- When committing, **stage specific files by name** — never `git add -A` / `git add .`. The repo contains untracked scratch files (`Someday/Assets.xcassets/shareButtonAirballoon.imageset/`, personal `heijnrich_*`/`spending_*` files) that must not be swept in.
- Never commit `.env` / credentials. Never skip hooks (`--no-verify`, `--no-gpg-sign`) unless explicitly asked.

---

## 10. Gotchas (the things that will bite you)

1. **No synchronized file groups in the Xcode project.** `project.pbxproj` does NOT use `PBXFileSystemSynchronizedRootGroup` (count: 0). A new `.swift` file dropped on disk is **not** picked up automatically — it needs a manual pbxproj entry. **Workaround we've been using**: add new views/types *inside an already-compiled file* (e.g. `DeveloperSettingsView` lives in `ProfileView.swift`) to avoid editing pbxproj. Prefer this unless a new file is truly warranted.

2. **`SomedayAnimations` springs are broken — verify before trusting.** In `Core/Theme/SomedayAnimations.swift`, `tile`, `inTileNav`, `chipToggle`, `pressFeedback`, and `chipPick` are defined as `static let x = SomedayAnimations.x` — i.e. **they reference themselves**. The app doesn't crash (so they resolve to some default `Animation`, not the tuned springs the comments describe). They're used widely via `withAnimation(SomedayAnimations.inTileNav)`. **These should almost certainly be real `.spring(...)` values.** Don't assume the named animations do what their doc comments say until this is fixed. (Only `followCTA = .spring(response: 0.3)` is real.)

3. **Compound `commit && push` to main is blocked by the auto-mode classifier.** Commit as one command, then `git push origin main` as a *separate* command. Don't chain them.

4. **A failed `git commit` consumes the staged index in the heredoc form.** If a commit fails (e.g. shell-quoting error on an apostrophe), re-`git add` before retrying. Avoid apostrophes/backticks in commit messages.

5. **The big Map files are large** (`MapHomeView` ~3300 loc, `MapViewModel` ~2600 loc, `ChatMessageRenderer` ~1400 loc). They were summarized out of context before — `Read` the exact ranges you need rather than assuming.

6. **Never force-push to main; never `--amend`; always create new commits.** Don't push unless asked (though the standing build+install+commit+push flow for this repo is the exception the owner has approved).

---

## 11. House style for changes

- **Match surrounding conventions** over personal preference — this codebase has a consistent voice (rich explanatory comments that capture the *why*, semantic color names, the tile vocabulary). New code should read like it was always there.
- **Keep demo mode working**: any new live service needs a mock counterpart and a router fallback so the app runs without a backend.
- **Verify, don't assert**: after a change, build + install. A claim like "this fixes the layout" should be backed by a green build, not hope.
- **Comments explain why, not what.** The existing comments are unusually thorough about rationale and trade-offs; keep that bar.
