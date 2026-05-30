# Someday — World Model

## Vision

Someday is a high-utility, fun, lightweight iOS app that helps you discover and remember
places to go "someday" — when you're bored, planning a date, or looking for somewhere
new with family and friends. It turns scattered bookmarks, shared links, and friend
recommendations into a beautiful, browsable map.

---

## Core Concept

Everyone saves places — in Instagram saves, TikTok shares, Google Maps lists, or just
in their head. Someday pulls all of that into one place: a map of possibilities,
organized by who recommended them and what kind of experience they are.

The tagline: **"What are you doing someday?"**

---

## Target User

- 20-35 year olds who actively discover places via social media and friend recommendations
- People who save tons of Reels/TikToks of restaurants and travel spots but never revisit them
- Couples and friend groups who constantly say "we should go there someday"

---

## Core Features (MVP)

### 1. The Map (Home Screen)
- Full-screen interactive map as the primary interface
- Place pins with category icons (restaurant, bar, activity, travel, etc.)
- Pins are color-coded or badged by which list/source they came from
- Tap a pin to see a card with: name, photo, source, who recommended it, category
- Slide toggle at the bottom: **"My Somedays"** | **"Others' Somedays"**
  - My Somedays: places you saved yourself
  - Others' Somedays: places recommended by your close friends network

### 2. Import Sources
Three ways to populate your map:

**a) Social Share (Instagram / TikTok)**
- Share a Reel or TikTok directly to Someday via the iOS Share Sheet
- Someday extracts the link, fetches the location/place info, and pins it on the map
- If location can't be auto-detected, prompt user to place it manually

**b) Friend Network**
- Add close friends (invite via phone number or username)
- Friends can recommend places to you — these appear on your map under "Others' Somedays"
- Small, trusted circles (not a social feed — think "close friends" on Instagram)

**c) List Import**
- Import from Google Maps saved lists
- Import from CSV/custom lists
- Bulk-add places to get started quickly

### 3. Onboarding
- Authentication via Email or Google Sign-In
- Animated slideshow (Airbnb-style full-screen cards) explaining the three import methods:
  - Slide 1: "Share from Instagram & TikTok" (with animation of share sheet)
  - Slide 2: "Get recommendations from friends" (with animation of friend circle)
  - Slide 3: "Import your existing lists" (with animation of pins dropping on map)
- Each slide has a skip option and a "Let's go" CTA on the last one
- After onboarding, land directly on the map

### 4. Place Cards
- Airbnb-style rounded tile cards
- Photo (fetched from source or Google Places)
- Place name, category icon, neighborhood/city
- Source badge (Instagram, TikTok, Friend name, Google Maps)
- "Someday" button to confirm/save, or swipe to dismiss
- Tap to expand: full details, link to original post, directions button

### 5. Lists / Collections
- Users can organize places into custom lists ("Date nights", "Coffee spots", "Travel bucket list")
- Default list: "All Somedays"
- Lists are browsable as filtered map views or as scrollable Airbnb-style tile grids

---

## User Flows

### Flow 1: First Launch
```
App Open → Splash Screen → Sign Up (Email / Google) → Onboarding Slides (3) → Map (empty state with CTA to import)
```

### Flow 2: Share from Social Media
```
Instagram/TikTok → Share Sheet → "Someday" → Auto-extract place → Confirm pin on map → Saved
```

### Flow 3: Browse the Map
```
Map → Scroll/Zoom → Tap pin → Place card appears → Tap for details → Get directions / Save to list
```

### Flow 4: Friend Recommendation
```
Friend shares a place in-app → Notification → Appears on map under "Others' Somedays" → Tap to view → Save to "My Somedays" or dismiss
```

---

## Design Language

### Philosophy
Fun but refined. Airbnb meets Google Maps with a distinctive turquoise identity.
The app should feel **light, joyful, and effortless** — not another productivity tool.

### Colors
| Role            | Color                          | Usage                                  |
|-----------------|--------------------------------|----------------------------------------|
| Primary         | Turquoise `#2ECFCF`           | Buttons, active states, brand identity |
| Primary Dark    | Deep Teal `#1A9E9E`           | Pressed states, headers                |
| Primary Light   | Soft Turquoise `#E0F7F7`      | Backgrounds, highlights                |
| Secondary       | Coral `#FF5A5F` (Airbnb nod)  | Notifications, badges, accents         |
| Neutral Dark    | Charcoal `#222222`            | Primary text                           |
| Neutral Medium  | Gray `#717171`                | Secondary text                         |
| Neutral Light   | Light Gray `#F7F7F7`          | Card backgrounds, dividers             |
| White           | `#FFFFFF`                      | Base background                        |

### Typography
- **Primary Font:** SF Pro Display (iOS system font)
- **Headings:** SF Pro Display Bold / Semibold
- **Body:** SF Pro Text Regular
- **Size scale:** Follow iOS Dynamic Type for accessibility
- **Style:** Clean, generous spacing, left-aligned

### Components
- **Cards:** Rounded corners (16px radius), subtle shadow, white background
- **Buttons:** Pill-shaped (full radius), turquoise fill with white text
- **Map Pins:** Custom circular icons with category symbol, turquoise border
- **Toggle:** Slide toggle at bottom of map — pill-shaped, turquoise active state
- **Animations:** Smooth, spring-based (like Airbnb's card transitions)
- **Photos:** Rounded corners (12px), 16:9 or square aspect ratio in cards

### Iconography
- Rounded, friendly line icons (SF Symbols as base, custom where needed)
- Category icons: fork+knife (food), cocktail (bar), hiking (activity), plane (travel), star (general)

### Tone of Voice
- Casual, warm, encouraging
- "Where to someday?" not "Select a destination"
- "Your friend thinks you'd love this" not "New recommendation received"
- Use of "someday" as a verb: "Someday this place"

---

## Technical Constraints

| Constraint         | Decision                                          |
|--------------------|---------------------------------------------------|
| Platform           | iOS only (iPhone)                                 |
| Min iOS version    | iOS 17.0                                          |
| Language           | Swift + SwiftUI                                   |
| Architecture       | MVVM                                              |
| Maps               | MapKit (Apple Maps)                               |
| Auth               | Firebase Auth (Email + Google Sign-In)             |
| Backend            | Firebase (Firestore + Cloud Functions)             |
| Image storage      | Firebase Storage or cached from source URLs        |
| Link parsing       | Custom URL metadata extraction + OpenGraph         |
| Notifications      | APNs via Firebase Cloud Messaging                  |
| Offline support    | Core Data local cache for saved places             |
| Dependencies       | Swift Package Manager only                         |

---

## MVP Scope (v1.0)

### In Scope
- [x] Email + Google auth
- [x] Onboarding slideshow
- [x] Map view with pins
- [x] Manual place adding (search + pin)
- [x] Instagram/TikTok share sheet import
- [x] Place cards with details
- [x] My Somedays / Others' Somedays toggle
- [x] Friend invites and recommendations
- [x] Basic list/collection management

### Out of Scope (Later)
- [ ] Android
- [ ] In-app messaging
- [ ] Place reviews/ratings
- [ ] AI-powered recommendations
- [ ] Calendar integration ("Plan your someday")
- [ ] Widgets
- [ ] Apple Watch companion

---

## Screen Map

```
Splash
  └── Auth (Sign Up / Sign In)
        └── Onboarding (3 slides)
              └── Map (Home)
                    ├── Place Card (bottom sheet)
                    │     └── Place Detail (full screen)
                    ├── Search (top bar)
                    ├── Toggle: My / Others
                    ├── Profile (tab)
                    │     ├── My Lists
                    │     ├── Friends
                    │     └── Settings
                    └── Add Place
                          ├── Search location
                          ├── Paste link
                          └── Import list
```

---

*This is a living document. Update as decisions evolve.*
