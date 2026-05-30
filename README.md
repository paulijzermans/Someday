# Someday

iOS place-discovery app — save places for *someday*, share them on a social map, see where your friends have been.

> Status: work-in-progress. Demo assets (brand logos, Gondens DEMO font) are not licensed for commercial use.

## Stack

- **Client**: SwiftUI (iOS 26 target), MapKit, MVVM with `@Observable`
- **Backend**: [Supabase](https://supabase.com) — Postgres + Auth (Google OAuth) + Storage, Row-Level Security
- **Search**: MapKit local search

The app runs in two modes:

- **Demo mode** (no backend) — uses an in-memory mock stack with `SampleData`. The default if `Secrets.plist` is missing.
- **Live mode** — wires the Supabase client when `Secrets.plist` is present. See setup below.

## Run the demo (no setup)

If you just want to try the app, this is the whole flow — no Supabase, no Apple Developer account, no signing.

**Prerequisites**
- A Mac
- Xcode 16.2 or newer with the **iOS 26 simulator runtime** installed (Xcode → Settings → Components)

**Steps**
```bash
git clone git@github.com:paulijzermans/Someday.git
cd Someday
open Someday.xcodeproj
```
On first open, Xcode resolves Swift packages (~30s) and auto-creates the `Someday` scheme. Pick any iPhone simulator and hit ▶ Run.

The app boots straight onto an Amsterdam map populated with sample places, friends, and activity events. Because `Secrets.plist` isn't in the repo, `ServiceContainer.live` automatically falls back to the in-memory mock stack — nothing leaves the device.

## Project layout

```
Someday/
├── App/                # @main, AppState, ServiceContainer
├── Core/
│   ├── Config/         # SupabaseConfig, Secrets template
│   ├── Models/         # Place, UserProfile, SampleData
│   ├── Protocols/      # Service protocols (Auth, Place, User, Search)
│   ├── Services/
│   │   ├── Mock/       # In-memory implementations
│   │   └── Supabase/   # Live implementations + row DTOs
│   └── Theme/          # Colors, fonts
├── Features/           # Map, Auth, Activity, Friends, Onboarding, …
└── Resources/Fonts/
supabase/
└── schema.sql          # Postgres tables, RLS, triggers, storage policies
```

## Setup (live mode)

1. **Create a Supabase project** at https://supabase.com.
2. **Run the schema**: SQL Editor → paste `supabase/schema.sql` → Run.
3. **Configure Google OAuth** in both Google Cloud Console (Web client) and Supabase (Authentication → Providers → Google). Add `someday://auth-callback` under Authentication → URL Configuration.
4. **Copy your keys**: in Xcode, duplicate `Someday/Core/Config/Secrets.example.plist` → `Secrets.plist`, fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY` (anon/public key — **never** ship the service-role key), and add it to the Someday target. It's gitignored.
5. **Build & run.**

## Security notes

- Only the **anon/public** key belongs in the client; RLS gates every row.
- The **service-role** key and any LLM API keys must live in Supabase Edge Functions, never in the iOS bundle.
- `Secrets.plist`, `.env`, and Supabase local config are all gitignored.
