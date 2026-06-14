import SwiftUI
import MapKit

@Observable
final class MapViewModel {
    var places: [Place] = []
    var friends: [UserProfile] = []
    var selectedPlace: Place?
    /// Saved pin to make "breathe" on the map WITHOUT opening its card —
    /// set when the user peeks a pin from chat (Flow C) so the located
    /// pin is visually obvious behind/below the chat panel. Cleared on
    /// any deliberate navigation that opens a card or changes context.
    var peekHighlightPlaceID: String?
    /// Saved pin currently in long-press "delete mode" — the iPhone
    /// home-screen jiggle idiom applied to map pins. When set, the
    /// matching pin wiggles and shows a red × badge in its top-right
    /// corner; tapping the badge deletes the pin, tapping anywhere else
    /// on the map clears this back to normal. Driven by the long-press
    /// gesture in `ClusteredMapView`. Only one pin is ever "armed" at a
    /// time, so a single id (not a set) is enough.
    var deletingPlaceID: String?
    var searchText = ""
    var searchResults: [LocationSearchResult] = []
    var isSearching = false
    var isLoading = false
    var showSavedToast = false
    var showFriends = false
    var showReservation = false
    var reservationMode: ReservationMode = .tonight
    var showMapsImport = false
    var showSocialsImport = false
    /// Presents the contacts-based friend-discovery sheet — the
    /// "Find friends" on-ramp in the chat onboarding flow. Replaces the
    /// friends step of the old OnboardingFlowTile wizard.
    var showFriendDiscovery = false
    /// True while first-run onboarding is active. Mirrored from
    /// `AppState.isOnboarding` by `MapHomeView` so `buildChatContext`
    /// can flip the assistant into ONBOARDING mode without the VM
    /// needing a reference to AppState.
    var onboardingActive = false
    /// Filled in by external triggers (Share Extension, deep link). The
    /// LinkImportView reads this as its initial value so the user doesn't
    /// have to paste the URL again.
    var prefillImportURL: String?
    var showProfile = false
    /// Lists the user has created in-app (with optional cover image).
    /// In-memory for now; once `lists` + `list_places` go through Supabase
    /// we'll persist these too.
    var customLists: [CustomList] = []
    /// Summary card shown after a successful import — auto-dismissed by
    /// `presentImportSummary` after a short delay so it doesn't linger.
    var lastImportSummary: ImportSummary?
    /// Places staged for adding to a custom list. Set when the user taps
    /// "Add" on the summary tile; consumed when they pick a list in the
    /// Lists overlay (or cancel out). Non-nil = the Lists picker is in
    /// "stash these places" mode and selecting a list runs the commit.
    var pendingAddToListPlaces: [Place]?
    /// When non-nil, the Lists overlay is in "membership editor" mode for
    /// this place. Tiles render with a thick border around any list the
    /// place is in; tapping a list toggles membership (in → remove, out
    /// → add). The pin_tile is hidden while editing and restored on
    /// dismiss so the user can confirm the new chip state.
    ///
    /// Distinct from `pendingAddToListPlaces` (the import-stash-and-commit
    /// flow) because:
    ///   • Membership editing operates on ONE existing pin, not a batch.
    ///   • Each tap is an immediate, idempotent toggle — no stash, no commit.
    ///   • Multi-membership is allowed: a place can live in any number of
    ///     lists at once. (The old single-list invariant is intentionally
    ///     dropped here at the user's request.)
    var membershipEditingPlace: Place?

    /// A pin the user asked the chatbot about ("Ask Someday about this"
    /// on the pin_tile, or a `someday://ask?place=…` link). Bound as the
    /// conversation's context so the next message resolves "this place"
    /// / "here" without the user retyping the name.
    ///
    /// Distinct from `selectedPlace` on purpose: opening the chat focuses
    /// the input, which dismisses the pin_tile (and clears
    /// `selectedPlace`) so the keyboard has room. `chatContextPlace`
    /// survives that dismissal so the bound context isn't lost the instant
    /// the keyboard rises. Cleared when the user clears the context chip
    /// or sends a message that moves the conversation on.
    var chatContextPlace: Place?

    // MARK: - AI Availability
    //
    // The "Availability" CTA on PlaceCardSheet kicks off an AI lookup of
    // booking platforms for the tapped place. Three pieces of state:
    //   • `availabilityStatus[place.id]` — drives the button's visual
    //      state on the card (.idle, .loading with sparkle pulse, .ready).
    //   • `availabilityResult` — the result currently displayed in the
    //      floating AI bar (top-right). Cleared on dismiss.
    //   • `availabilityResultPlace` — which place that result is for, so
    //      the bar headline can name the venue.
    /// Per-place status of the availability lookup. Keyed by `place.id`.
    var availabilityStatus: [String: AvailabilityState] = [:]
    /// The currently-displayed availability result. Non-nil = the AI bar
    /// is on screen.
    var availabilityResult: AvailabilityResult?
    /// The place the on-screen result belongs to (for the bar headline).
    var availabilityResultPlace: Place?

    // MARK: - Real-time "is there a table tonight?" check
    //
    // Distinct from the AI Availability lookup above. The AI step tells
    // us WHICH platform can book a venue; this step asks that platform
    // whether tonight is actually free. Backed by the `check-availability`
    // Edge Function, which dispatches per-provider (Zenchef live; others
    // return `.unknown` and the UI falls back to opening the booking URL).

    /// Per-place result of the tonight check. Keyed by `place.id`.
    /// Cleared when the user picks a different date later (not yet
    /// exposed in the UI — v1 always checks tonight).
    var tonightCheckResults: [String: AvailabilityCheck] = [:]
    /// Place IDs currently mid-flight. Lets the UI render a spinner
    /// without conflating "we don't know yet" with "we checked and got
    /// nothing".
    var tonightCheckLoading: Set<String> = []

    // MARK: - Floating-tile overlays
    //
    // The "tile" overlays (Lists, Activity, Add, Feedback, Create-list,
    // Share-request) are mutually exclusive — only one tile can be on
    // screen at a time. We store that in a single `presentedOverlay`
    // optional and expose Bool accessors so existing call sites that
    // read/write `vm.showLists` etc. keep working unchanged.

    /// Tab-bar floating tiles. Only one is presented at a time.
    enum Overlay: Equatable {
        case lists
        case activity
        case addOptions
        case feedback
        case createList
        case shareRequest
    }

    /// Single source of truth for which floating tile is on screen.
    /// Defaults to `nil` so the user lands on a clean map. The share-
    /// request overlay still exists as a `case` so a real incoming
    /// share (once that feature is wired to the backend) can present
    /// it via `presentedOverlay = .shareRequest`. The launch-time
    /// "Bodil wants to share…" demo state has been retired.
    var presentedOverlay: Overlay? = nil

    /// Switch to a specific overlay (or none). Wrap in `withAnimation`
    /// at the call site so the dismiss + present spring is unified.
    func showOverlay(_ overlay: Overlay?) {
        presentedOverlay = overlay
    }

    /// Tab-button helper: if the same overlay is already showing, close
    /// it; otherwise switch to it. Lets tab buttons feel like real toggles.
    func toggleOverlay(_ overlay: Overlay) {
        presentedOverlay = (presentedOverlay == overlay) ? nil : overlay
    }

    // Bool-accessor proxies so existing call sites that do
    // `vm.showLists = true` / `if vm.showLists { … }` keep compiling.
    // All four tab-tile overlays are routed through `presentedOverlay`.
    var showLists: Bool {
        get { presentedOverlay == .lists }
        set { setOverlay(.lists, to: newValue) }
    }
    var showActivity: Bool {
        get { presentedOverlay == .activity }
        set { setOverlay(.activity, to: newValue) }
    }
    var showAddOptions: Bool {
        get { presentedOverlay == .addOptions }
        set { setOverlay(.addOptions, to: newValue) }
    }
    var showFeedback: Bool {
        get { presentedOverlay == .feedback }
        set { setOverlay(.feedback, to: newValue) }
    }
    var showCreateList: Bool {
        get { presentedOverlay == .createList }
        set { setOverlay(.createList, to: newValue) }
    }
    var showShareRequest: Bool {
        get { presentedOverlay == .shareRequest }
        set { setOverlay(.shareRequest, to: newValue) }
    }

    /// Internal helper used by the Bool setters above so they all behave
    /// identically: setting `true` activates this overlay (closing any
    /// other), setting `false` clears it only if it was the current one.
    private func setOverlay(_ overlay: Overlay, to active: Bool) {
        if active {
            presentedOverlay = overlay
        } else if presentedOverlay == overlay {
            presentedOverlay = nil
        }
    }
    // `showShareRequest` proxies into `presentedOverlay == .shareRequest`
    // (see the overlay-accessor block above). The default value of
    // `presentedOverlay` is `.shareRequest`, so the banner appears on launch.
    var previewedList: PreviewedList?
    /// Which of the current user's lists the in-progress preview will be
    /// added to. `nil` until the user explicitly picks one in the preview
    /// action bar — reset whenever a new preview starts.
    var previewTargetList: String?
    var showSearch = false
    var showShareSheet = false
    var showImportList = false
    var filteredFriendID: String?
    var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.3676, longitude: 4.8900),
        span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
    )

    /// Best-effort city name for the current viewport centre. Resolved
    /// asynchronously by `CityResolver` whenever `region` changes; nil
    /// until the first resolve completes. Used as on-screen context in
    /// `buildChatContext()` so the assistant knows what city the user
    /// is looking at without having to figure it out from coords.
    var currentCityName: String?

    /// Transient banner shown briefly when the AI chat sends the user to
    /// a coordinate that isn't on any of their saved pins — e.g. a
    /// venue Claude recommended via web_search. Holds the venue name +
    /// category so the user has context for the spot they were taken
    /// to. Auto-clears after a few seconds.
    var aiSuggestionHint: AISuggestionHint?
    private var suggestionHintClearTask: Task<Void, Never>?

    /// AI-proposed pins currently dropped on the map. Distinct from
    /// `places` (the user's saved set) — they render in lime via
    /// `SuggestionPinAnnotationView` and never sync to Supabase. The
    /// user can either save one into their map (TBD) or dismiss it.
    /// Held in an Array so insertion order is stable and dedup is
    /// cheap on `id`.
    ///
    /// Persisted to `UserDefaults` on every mutation (see
    /// `persistSuggestionPins`) so a chatbot suggestion lingers on the map
    /// for a real 24h — surviving app restarts — and only drops off when
    /// its `createdAt + lifetime` passes (swept by `startSuggestionSweep`)
    /// or the user saves it to a list.
    var aiSuggestionPins: [SuggestedPin] = [] {
        didSet { persistSuggestionPins() }
    }

    /// Ordered list backing the suggestion tile above the nav bar.
    /// One entry → single-pin info card (no swipe). Multiple entries →
    /// horizontal carousel where swiping pages pans the map. Same
    /// state powers both paths so the bottom slot has a single source
    /// of truth.
    var discoverAllSuggestions: [SuggestedPin] = []

    /// ID of the AI-suggestion pin the map should be visually
    /// emphasising — the active carousel page, the just-tapped chat
    /// link, or the single-pin tap target. Drives the breathing
    /// scale animation on the matching annotation view. Cleared
    /// when the bottom tile dismisses.
    var currentSuggestionID: String?

    /// The day plan the chat agent most recently built via
    /// `create_itinerary`. Kept so the `someday://plan` action can re-frame
    /// the whole route on demand without the model re-emitting every stop.
    var activeItinerary: Itinerary?

    /// The active point-to-point route between two saved pins, if any.
    /// Non-nil while a route is on screen — drives the polyline overlay in
    /// `ClusteredMapView` AND the floating route readout (mode toggle +
    /// ETA/distance) in `MapHomeView`. Set by `showRoute`, recomputed by
    /// `setRouteMode`, cleared by `clearRoute`. Backs the
    /// `someday://route?from=…&to=…` chat action.
    var activeRoute: ActiveRoute?

    /// Debounce token for the city resolve. Each `regionDidChange` call
    /// cancels the previous one so we only fire the SDK request after
    /// the user stops panning for ~300ms.
    private var cityResolveTask: Task<Void, Never>?

    /// Delayed second-phase of the Discover-all reveal (overview →
    /// zoom-in on pins[0]). Held so a rapid re-tap of "Discover all"
    /// can cancel the in-flight choreography before kicking off a
    /// new one — prevents the camera from snapping to a stale pin.
    private var discoverAllRevealTask: Task<Void, Never>?

    /// Drives the choreographed pin deletion (zoom-to-frame → hold →
    /// pop pins off one-by-one). A SINGLE long-lived worker drains
    /// `pendingRemovalIDs`, so when the chat fires several `delete_place`
    /// mutations in one turn (a bulk "delete everything in this list")
    /// they all join the same sweep instead of each restarting it and
    /// only the last pin surviving the animation.
    private var pinRemovalTask: Task<Void, Never>?

    /// FIFO queue of pin ids still waiting to pop. Appended to by
    /// `animatePinRemoval`; drained one-per-stagger by the worker.
    private var pendingRemovalIDs: [String] = []

    /// Long-lived ticker that sweeps expired AI-suggestion pins off the
    /// map. Wakes every 60s (and once on launch) and drops any pin whose
    /// 24h window has elapsed. Held so it can be cancelled if the VM is
    /// ever torn down.
    private var suggestionSweepTask: Task<Void, Never>?

    /// UserDefaults key for the persisted suggestion-pin array.
    private static let suggestionPinsDefaultsKey = "someday.aiSuggestionPins.v1"

    private let placeService: PlaceServiceProtocol
    private let userService: UserServiceProtocol
    private let searchService: LocationSearchProtocol
    /// URL→[Place] extraction. Holds the `ExtractionRouter` rather than a
    /// concrete pipeline so the active backend (Pipeline 1 vs Pipeline 2)
    /// can be flipped at runtime via `ExtractionPipelineSelector` without
    /// touching the view model.
    private let extractionService: URLExtractionService
    /// AI lookup for "where can I book this place?". Holds the cache
    /// internally so re-taps on the same place are instant.
    private let availabilityService: AvailabilityService
    /// Real-time provider check ("is there a table tonight?"). Wraps
    /// the `check-availability` Edge Function.
    private let reservationCheckService: ReservationCheckService
    /// CRUD on the user's `customLists` + `list_places` join table. Used
    /// by `createList`, `addPendingPlaces(to:)`, and `loadData` so custom
    /// lists + their memberships survive cold launches.
    private let listService: ListServiceProtocol
    /// Contact-discovery + friend-request inbox. Used by the Activity tab
    /// to surface incoming requests with Accept/Reject affordances.
    private let contactsService: ContactsServiceProtocol
    /// Per-user usage accounting. We bump the import counter here after a
    /// successful import so Settings → Plan can show lifetime totals.
    private let usageService: UsageServiceProtocol
    private let userID: String

    init(services: ServiceContainer, userID: String) {
        self.placeService = services.places
        self.userService = services.users
        self.searchService = services.search
        self.extractionService = services.extraction
        self.availabilityService = services.availability
        self.reservationCheckService = services.reservationCheck
        self.listService = services.lists
        self.contactsService = services.contacts
        self.usageService = services.usage
        self.userID = userID

        // Re-hydrate any still-living suggestions from a previous run and
        // start the 24h expiry sweep. Pins that already aged out while the
        // app was closed are dropped during load.
        loadPersistedSuggestionPins()
        startSuggestionSweep()
    }

    // MARK: - Suggestion-pin persistence & expiry
    //
    // Chatbot suggestions linger on the map for a real day. To make that
    // survive app restarts the array is mirrored into UserDefaults as JSON
    // on every mutation, re-hydrated on launch, and continuously swept for
    // pins whose `createdAt + 24h` has passed.

    /// Serialise `aiSuggestionPins` to UserDefaults. Called from the
    /// property's `didSet` so persistence is automatic — no caller has to
    /// remember to flush. A failed encode just no-ops (the pins stay in
    /// memory for this session).
    private func persistSuggestionPins() {
        guard let data = try? JSONEncoder().encode(aiSuggestionPins) else { return }
        UserDefaults.standard.set(data, forKey: Self.suggestionPinsDefaultsKey)
    }

    /// Re-hydrate suggestions saved by a previous run, dropping any that
    /// already expired while the app was closed. Assigns through the normal
    /// stored property so the surviving set is immediately re-persisted in
    /// its pruned form.
    private func loadPersistedSuggestionPins() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.suggestionPinsDefaultsKey),
            let decoded = try? JSONDecoder().decode([SuggestedPin].self, from: data)
        else { return }
        aiSuggestionPins = decoded.filter { !$0.isExpired }
    }

    /// Kick off the long-lived expiry ticker. Runs an immediate sweep, then
    /// every 60s until cancelled. 60s granularity is plenty for a 24h
    /// window — the countdown pill animates smoothly on its own via
    /// `TimelineView`; this only governs when the pin actually disappears.
    private func startSuggestionSweep() {
        suggestionSweepTask?.cancel()
        suggestionSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run { self?.sweepExpiredSuggestions() }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Drop any suggestion whose 24h window has elapsed — from the map
    /// pins and, if currently shown, the bottom tile too.
    private func sweepExpiredSuggestions() {
        let live = aiSuggestionPins.filter { !$0.isExpired }
        if live.count != aiSuggestionPins.count {
            withAnimation(SomedayAnimations.inTileNav) {
                aiSuggestionPins = live
                discoverAllSuggestions.removeAll { $0.isExpired }
                if let cur = currentSuggestionID,
                   !live.contains(where: { $0.id == cur }) {
                    currentSuggestionID = nil
                }
            }
        }
    }

    // MARK: - Location dedup
    //
    // A "place" in our model is a physical venue, not a row. Two imports
    // of the same Reel — or the same restaurant via Maps + Instagram —
    // must collapse into a single pin on the map. We dedupe on import
    // (so re-imports are silently dropped), on map-search add (so the
    // user can't double-add a pin by searching for a place they already
    // have), and on initial load from Supabase (so historical DB
    // duplicates from before this dedup existed only render once).

    /// Coarse normalisation for name comparison: accent-folded,
    /// case-insensitive, punctuation-stripped, whitespace-collapsed.
    /// Handles real-world variation like "Le Petit Vendôme" vs
    /// "Le Petit Vendome" or "St. Smalle" vs "St Smalle".
    private static func normalizeName(_ name: String) -> String {
        let folded = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.punctuationCharacters).joined()
        return folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Heuristic for "same physical venue": normalised names match AND
    /// the two coordinates are within 200m of each other. The distance
    /// gate stops chains like Starbucks deduping across cities; the
    /// name gate stops two unrelated venues at the same mall address
    /// from collapsing into one pin.
    private static func isLikelySamePlace(_ a: Place, _ b: Place) -> Bool {
        guard normalizeName(a.name) == normalizeName(b.name) else { return false }
        let aLoc = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let bLoc = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return aLoc.distance(from: bLoc) < 200
    }

    /// First existing place that matches `candidate` (by name + coords).
    /// Used by both `importPlaces` (drop dup imports) and `addPlace` (jump
    /// to the existing pin instead of creating a second one).
    func existingPlaceMatching(_ candidate: Place) -> Place? {
        places.first(where: { Self.isLikelySamePlace($0, candidate) })
    }

    // MARK: - Source-URL cache lookup
    //
    // Before paying for an AI extraction call, we check whether the same
    // URL has been imported before — `place.source_url` stamps the link
    // each pin came from, so we can look it up in `places` (which is
    // pre-loaded from Supabase on `loadData`). A hit returns the
    // already-imported pins instantly with zero pipeline cost.

    /// Normalised key for comparing URLs across imports. Strips query
    /// params (Instagram appends tracking like `?igsh=…`), trailing
    /// slashes, and lowercases the whole string so two reels at the
    /// same canonical URL collapse to one cache key.
    private static func normalizeURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.lowercased()
    }

    /// Places already in the user's map that came from `url` — i.e.
    /// already-imported reels / posts. Empty when the URL has never
    /// been processed (cache miss → caller should run the pipeline).
    func placesImported(from url: String) -> [Place] {
        let key = Self.normalizeURL(url)
        return places.filter { place in
            guard let s = place.sourceURL?.absoluteString else { return false }
            return Self.normalizeURL(s) == key
        }
    }

    // MARK: - Chat context
    //
    // Builds the structured digest the AI chatbot uses to answer
    // questions about the user's map. Friends' places that the user
    // can already see (via RLS) come along too, so the bot can suggest
    // "Bodil's been to a great place near here" without us having to
    // load extra rows.

    /// Splits `places` into "mine" and "friends' visible" and packages
    /// the whole thing through `ChatContextBuilder`. Called by the
    /// chat sheet's `contextProvider` closure on every send.
    ///
    /// On-screen context (current city, viewport, visible pins,
    /// selected pin) is the model's primary signal; off-screen places
    /// come along as a slim summary so it can still roll up totals.
    func buildChatContext() -> ChatContext {
        let mine     = places.filter { $0.ownerID == userID }
        let theirs   = places.filter { $0.ownerID != userID && !$0.ownerID.isEmpty }
        let userName = friends.first(where: { $0.id == userID })?.name ?? ""
        return ChatContextBuilder.build(
            userName: userName,
            region: region,
            currentCity: currentCityName,
            // Prefer the open pin_tile; fall back to a pin the user
            // explicitly bound via "Ask Someday about this" so "this
            // place" / "here" still resolves after the card dismissed to
            // make room for the keyboard.
            selectedPlace: selectedPlace ?? chatContextPlace,
            myPlaces: mine,
            friendPlaces: theirs,
            lists: customLists,
            friends: friends,
            onboarding: onboardingActive
        )
    }

    /// Kick off (or re-kick) the current-city resolve with a 300ms
    /// debounce. Called from `MapHomeView` whenever the region binding
    /// changes — typical pan/zoom fires this many times a second, so
    /// the debounce is what keeps us under CLGeocoder's rate limit.
    /// The cached results inside `CityResolver` mean even after the
    /// debounce, panning within a city is free.
    @MainActor
    func scheduleCityResolve() {
        cityResolveTask?.cancel()
        let center = region.center
        cityResolveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let resolved = await CityResolver.shared.resolve(center)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.currentCityName = resolved
            }
        }
    }

    /// Strip duplicates out of an arbitrary `[Place]`, keeping the first
    /// occurrence of each location. Used on initial Supabase load so any
    /// historical duplicates in the DB collapse to one pin.
    private static func deduplicate(_ all: [Place]) -> [Place] {
        var result: [Place] = []
        for place in all {
            if !result.contains(where: { isLikelySamePlace($0, place) }) {
                result.append(place)
            }
        }
        return result
    }

    @MainActor
    func loadData() async {
        isLoading = true
        defer { isLoading = false }

        async let fetchedPlaces  = placeService.fetchPlaces(for: userID)
        async let fetchedFriends = userService.fetchFriends(for: userID)
        // Custom lists + their memberships restored from the `lists` +
        // `list_places` tables. Hydrating these on startup is what makes
        // list-coloured pins survive across cold launches — the renderer
        // looks up membership via `listContaining(_:)` and stamps the
        // list's colour on the pin.
        async let fetchedLists   = listService.fetchLists(for: userID)

        do {
            // Collapse any historical duplicates in the DB so we render
            // exactly one pin per venue even when the underlying rows
            // weren't deduped at write time.
            places       = Self.deduplicate(try await fetchedPlaces)
            friends      = try await fetchedFriends
            customLists  = try await fetchedLists
            // Single-list invariant cleanup — if any place is in two
            // lists from before the invariant was enforced, drop it
            // from all but the first list locally + on the server.
            // Without this, the pin's colour on the map is
            // non-deterministic (depends on which list
            // `listContaining` happens to find first).
            enforceSingleListInvariantOnLoad()
        } catch {
            // Gracefully handle — keep existing data
        }

        // Demo seed: in DEBUG builds we always layer the 5 mock friends
        // + 10 real Amsterdam restaurants from `SampleData` on top of
        // whatever the live backend returned. That way the AI chat has
        // a real friend-recommendation surface to show off even before
        // the user has friends with saved places in Supabase. Merging
        // is id-keyed so re-running loadData() doesn't duplicate. The
        // Supabase tables are NEVER touched — this is in-memory only.
        #if DEBUG
        mergeDemoFriendsAndRestaurants()
        #endif
    }

    /// One-time data cleanup that enforces the single-list invariant
    /// on whatever shape the lists arrived in from Supabase. Walks
    /// `customLists` in their stored order; the first list to claim a
    /// place id keeps it, every later list loses it (locally + via a
    /// background `removePlace` so the DB matches).
    ///
    /// Solves the "pin showed up in the wrong colour" complaint:
    /// before the invariant was enforced at write time, a single place
    /// could end up in two lists, and `listContaining(_:)` would
    /// return whichever happened to be earlier in the array — not
    /// necessarily the list the user most recently moved it into.
    @MainActor
    private func enforceSingleListInvariantOnLoad() {
        var claimed: Set<String> = []
        var orphans: [(listID: String, placeID: String)] = []
        for i in customLists.indices {
            var keep: [String] = []
            keep.reserveCapacity(customLists[i].placeIDs.count)
            for pid in customLists[i].placeIDs {
                if claimed.insert(pid).inserted {
                    keep.append(pid)
                } else {
                    orphans.append((customLists[i].id.uuidString, pid))
                }
            }
            if keep.count != customLists[i].placeIDs.count {
                customLists[i].placeIDs = keep
            }
        }
        guard !orphans.isEmpty else { return }
        #if DEBUG
        print("[MapViewModel] single-list cleanup — dropping \(orphans.count) duplicate membership(s)")
        #endif
        Task {
            for (listID, placeID) in orphans {
                do {
                    try await listService.removePlace(placeID: placeID, fromListID: listID)
                } catch {
                    #if DEBUG
                    print("[MapViewModel] single-list cleanup failed for \(placeID) on \(listID): \(error)")
                    #endif
                }
            }
        }
    }

    /// Layer the static demo friends + their curated restaurants onto
    /// the in-memory `friends` / `places` arrays. Dedupes on id so any
    /// real friend with a matching id wins (we don't clobber live data).
    /// DEBUG-only path — see the call site in `loadData()`.
    @MainActor
    private func mergeDemoFriendsAndRestaurants() {
        let existingFriendIDs = Set(friends.map(\.id))
        let demoFriends = SampleData.friends.filter { !existingFriendIDs.contains($0.id) }
        if !demoFriends.isEmpty { friends.append(contentsOf: demoFriends) }

        let existingPlaceIDs = Set(places.map(\.id))
        let demoPlaces = SampleData.places.filter {
            $0.id.hasPrefix("place_resto_") && !existingPlaceIDs.contains($0.id)
        }
        if !demoPlaces.isEmpty { places.append(contentsOf: demoPlaces) }

        mergeDemoEvents()
    }

    /// Layer the static demo EVENT pins (food-truck stops, pop-ups, night
    /// markets) onto `places`. Only the ones still upcoming / in progress
    /// are added — already-finished mock events are skipped so a long
    /// session that reloads doesn't resurrect them. DEBUG-only, in-memory;
    /// never written to Supabase. The map drops each one on its own once
    /// `eventEnd` passes (via `visiblePlaces`).
    @MainActor
    private func mergeDemoEvents() {
        let existingPlaceIDs = Set(places.map(\.id))
        let demoEvents = SampleData.events.filter {
            $0.isActiveEvent && !existingPlaceIDs.contains($0.id)
        }
        if !demoEvents.isEmpty { places.append(contentsOf: demoEvents) }
    }

    @MainActor
    func search() async {
        guard searchText.count >= 2 else {
            searchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        let center = region.center
        do {
            searchResults = try await searchService.search(query: searchText, near: center)
        } catch {
            searchResults = []
        }
    }

    @MainActor
    func addPlace(from result: LocationSearchResult) async {
        let place = Place(
            name: result.name,
            category: result.category ?? .food,
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude,
            source: .manual,
            neighborhood: result.address,
            isSaved: true,
            ownerID: userID
        )

        // Already on the map? Don't add a second pin — just jump to the
        // existing one so the user knows we picked it up.
        if let existing = existingPlaceMatching(place) {
            searchText = ""
            searchResults = []
            showSearch = false
            selectPlace(existing)
            return
        }

        do {
            try await placeService.savePlace(place)
            places.append(place)
            searchText = ""
            searchResults = []
            showSearch = false
        } catch {
            // Handle error
        }
    }

    @MainActor
    func toggleSaved(_ place: Place) async {
        do {
            let newState = try await placeService.toggleSaved(placeID: place.id, userID: userID)
            if let index = places.firstIndex(where: { $0.id == place.id }) {
                places[index].isSaved = newState
            }
        } catch {
            // Handle error
        }
    }

    func selectPlace(_ place: Place) {
        // Light impact so a pin tap reads as the card physically
        // "landing" on screen. Fires before the animation starts so
        // the user perceives the response as instant.
        Haptics.tap()
        // Centre the map on the pin so it lands in the middle of the
        // screen — but shift the camera SOUTH by ~25% of the latitude
        // span so the pin actually sits in the middle of the VISIBLE
        // map area, which is the top half of the screen once the
        // place card slides up to cover the bottom half. Geometric
        // centering would hide the pin under the card.
        let span = MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
        let visibleAreaOffset = span.latitudeDelta * 0.25
        let cameraCentre = CLLocationCoordinate2D(
            latitude: place.coordinate.latitude - visibleAreaOffset,
            longitude: place.coordinate.longitude
        )
        withAnimation(SomedayAnimations.inTileNav) {
            region = MKCoordinateRegion(center: cameraCentre, span: span)
            selectedPlace = place
            peekHighlightPlaceID = nil
        }
    }

    func dismissPlace() {
        withAnimation(SomedayAnimations.inTileNav) {
            selectedPlace = nil
        }
    }

    // MARK: - AI chat link routing
    //
    // The chat assistant emits `someday://place/<id>` and
    // `someday://suggest?...` links. Tapping one calls the matching
    // helper below — saved pins recenter + open the card, suggestions
    // recenter + show a transient hint banner so the user knows what
    // they're looking at on the map.

    /// Recenter the map on the given place and select it. Accepts a
    /// raw place id (UUID) or an 8-char prefix (matches what the
    /// chat function uses to compress the prompt). Returns true when
    /// a matching pin was found.
    @discardableResult
    @MainActor
    func focusOnPlaceLink(_ idOrPrefix: String) -> Bool {
        guard let place = places.first(where: { $0.id == idOrPrefix })
                ?? places.first(where: { $0.id.hasPrefix(idOrPrefix) })
        else { return false }

        withAnimation(SomedayAnimations.inTileNav) {
            region = MKCoordinateRegion(
                center: place.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
            )
            selectedPlace = place
            peekHighlightPlaceID = nil
        }
        Haptics.tap()
        return true
    }

    /// Quietly recenter the map on a saved place WITHOUT opening its card
    /// or collapsing the chat. Used by the in-chat peek (Flow C): tapping a
    /// pin in the conversation surfaces its inline tile AND moves the map
    /// underneath to that spot (its saved pin is already on the map), so
    /// pulling the chat down reveals the located pin. The center is nudged
    /// south of the pin so it renders in the visible strip above the chat
    /// panel rather than dead-center behind it.
    /// - Parameter screenFraction: where on screen (0 = top, 1 = bottom)
    ///   the pin should land. The chat panel is anchored at the TOP and
    ///   the nav bar at the bottom, so the caller passes the centre of the
    ///   visible map gap between them (≈ lower third) to park the pin
    ///   "nicely in the middle" of what the user can actually see. The map
    ///   fills the whole screen, so a screen fraction maps linearly onto
    ///   the camera's latitude span.
    @MainActor
    func revealPlaceUnderChat(_ idOrPrefix: String, screenFraction: CGFloat = 0.7) {
        guard let place = places.first(where: { $0.id == idOrPrefix })
                ?? places.first(where: { $0.id.hasPrefix(idOrPrefix) })
        else { return }

        // Offset the camera centre so the pin renders at `screenFraction`
        // down the screen. A point at fraction p has latitude
        // `center + (0.5 - p) * span`, so to pin our coordinate there the
        // centre must be `pinLat + (p - 0.5) * span` — i.e. shift the
        // centre NORTH of the pin to push the pin DOWN into the lower gap.
        let span = 0.012
        let bias = Double(screenFraction) - 0.5
        let center = CLLocationCoordinate2D(
            latitude: place.coordinate.latitude + span * bias,
            longitude: place.coordinate.longitude
        )
        withAnimation(SomedayAnimations.inTileNav) {
            region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
            )
            // Highlight the located pin (breathing pulse) without opening
            // its card, so it's unmistakable on the map under the chat.
            peekHighlightPlaceID = place.id
        }
    }

    /// Recenter on a coordinate the AI suggested (a venue NOT on the
    /// user's map), DROP A PIN there, and show a transient hint
    /// banner with the venue name. The pin stays on the map until the
    /// user dismisses it (via `dismissAISuggestionPin(id:)` or
    /// `clearAISuggestionPins()`); the banner auto-clears after a few
    /// seconds so it doesn't linger.
    ///
    /// Idempotent: re-tapping the same link (same name + same coord
    /// rounded to 5dp) doesn't drop a duplicate pin.
    @MainActor
    func focusOnAISuggestion(
        name: String,
        category: String?,
        description: String? = nil,
        hours: String? = nil,
        price: String? = nil,
        website: String? = nil,
        phone: String? = nil,
        latitude: Double,
        longitude: Double
    ) {
        // Stable id keyed off name + quantised coord so dedupe works
        // when the AI re-mentions the same venue with slightly noisy
        // coords from web search.
        let key = String(format: "%@@%.5f,%.5f", name.lowercased(), latitude, longitude)
        let id = key.data(using: .utf8)?.base64EncodedString() ?? key
        // If a pin with this id already exists and the new call carries
        // a description while the old one didn't, prefer the richer
        // one. Cheap upsert without breaking idempotency.
        if let existing = aiSuggestionPins.first(where: { $0.id == id }),
           existing.description != nil {
            // Already have the rich version — fall through to recenter
            // logic without touching the array.
        }
        let pin = SuggestedPin(
            id: id,
            name: name,
            category: category,
            description: description,
            hours: hours,
            price: price,
            website: website,
            phone: phone,
            latitude: latitude,
            longitude: longitude
        )

        // When the bottom carousel tile is on screen, its footprint hides
        // the bottom ~270pt of the map. Centring the camera on the pin's
        // coord parks it in the geometric centre of the *full* screen,
        // which lands the pin BEHIND the tile. To keep the pin in a
        // "logical place" (centre of the *visible* map area — between
        // the top of the screen and the top of the tile), nudge the
        // camera centre SOUTH by a fraction of the latitude span. The
        // pin (rendered at its real lat) then appears that same fraction
        // ABOVE the screen centre, i.e. mid-visible-area.
        //
        // The fraction (~0.18 of latitudeDelta) is tuned to:
        //   • compact carousel page (~174pt) + 96pt bottom padding ≈ 270pt
        //   • screen height ≈ 850pt
        //   • pin needs to sit at (screenH - 270)/2 from top
        //   • shift in pixels ≈ 135 → 135/850 ≈ 0.16, rounded to 0.18 for
        //     a touch of headroom against the expanded tile state (300pt
        //     page) and Dynamic Island devices.
        let latSpan: Double = 0.008
        let carouselUp = !discoverAllSuggestions.isEmpty
        let centreLatShift: Double = carouselUp ? -(latSpan * 0.18) : 0
        withAnimation(SomedayAnimations.inTileNav) {
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: latitude + centreLatShift,
                    longitude: longitude
                ),
                span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: latSpan)
            )
            if let idx = aiSuggestionPins.firstIndex(where: { $0.id == pin.id }) {
                // Upsert: prefer the version that carries the most
                // metadata. We score each candidate by the number of
                // non-nil optional fields and replace only when the
                // incoming pin is richer. Keeps the array stable when
                // the user re-taps a link the AI repeats verbatim,
                // and upgrades it the moment a later turn ships more
                // detail (e.g. hours/price arriving on a follow-up).
                let existing = aiSuggestionPins[idx]
                let score: (SuggestedPin) -> Int = { p in
                    [p.description, p.hours, p.price, p.website, p.phone]
                        .compactMap { $0 }.count
                }
                if score(pin) > score(existing) {
                    // Keep the ORIGINAL drop time so the richer payload
                    // doesn't reset the 24h countdown — the user has
                    // already been looking at this pin.
                    var richer = pin
                    richer.createdAt = existing.createdAt
                    aiSuggestionPins[idx] = richer
                }
            } else {
                aiSuggestionPins.append(pin)
            }
            aiSuggestionHint = AISuggestionHint(
                name: name,
                category: category,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            )
            // Whichever pin we just centred on is now the "active"
            // one for the breathing pulse. Covers all entry points:
            // chat link tap, single-pin map tap (via
            // `beginDiscoverAll([pin])` → here), and carousel
            // page swipe (via `onPageChange` → here).
            currentSuggestionID = id
        }
        Haptics.tap()

        // Auto-clear the banner after 6 seconds. The pin itself stays
        // on the map until the user explicitly dismisses it.
        suggestionHintClearTask?.cancel()
        suggestionHintClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.dismissAISuggestionHint() }
        }
    }

    /// Render a chat-built day plan: resolve each stop to a coordinate and
    /// hand the ordered set to the existing suggestion carousel, which
    /// frames them on the map and lets the user swipe stop-to-stop. This is
    /// the render half of the `create_itinerary` seam — the agent shaped
    /// the plan, `ItineraryService` persisted it, and this turns it into
    /// the same photo-tile pins every other suggestion uses (no bespoke
    /// itinerary UI). Stores it as `activeItinerary` so `someday://plan`
    /// can re-frame it later.
    @MainActor
    func applyItinerary(_ itinerary: Itinerary) {
        activeItinerary = itinerary
        let pins = itineraryPins(for: itinerary)
        guard !pins.isEmpty else { return }
        // `beginDiscoverAll` choreographs the zoom-out-to-fit → hold →
        // zoom-to-first reveal and surfaces the swipeable tile. Ordered, so
        // page 1 is the first stop of the day.
        beginDiscoverAll(pins)
    }

    /// Re-frame the most recently built itinerary (the `someday://plan`
    /// action). No-op with a soft haptic if there's no active plan.
    @MainActor
    func reframeActiveItinerary() -> Bool {
        guard let itinerary = activeItinerary else { return false }
        let pins = itineraryPins(for: itinerary)
        guard !pins.isEmpty else { return false }
        beginDiscoverAll(pins)
        return true
    }

    /// Resolve an itinerary's stops to renderable suggestion pins. A stop
    /// anchors either to a saved place (look the coord up by id) or to its
    /// own lat/lon (a venue the agent geocoded). Stops we can't anchor are
    /// dropped so the route has no gaps. The time label is folded into the
    /// pin name ("10:00 · Café Veneur") so the carousel reads as a schedule.
    @MainActor
    private func itineraryPins(for itinerary: Itinerary) -> [SuggestedPin] {
        itinerary.stops.compactMap { stop -> SuggestedPin? in
            let coordinate: (lat: Double, lon: Double)?
            if let pid = stop.placeID,
               let saved = places.first(where: { $0.id == pid || $0.id.hasPrefix(pid) }) {
                coordinate = (saved.latitude, saved.longitude)
            } else if let lat = stop.latitude, let lon = stop.longitude {
                coordinate = (lat, lon)
            } else {
                coordinate = nil
            }
            guard let coord = coordinate else { return nil }
            let label = stop.time.map { "\($0) · \(stop.name)" } ?? stop.name
            return SuggestedPin(
                id: ChatAction.suggestionID(name: label, lat: coord.lat, lon: coord.lon),
                name: label,
                category: stop.category,
                description: stop.note,
                hours: nil,
                price: nil,
                website: nil,
                phone: nil,
                latitude: coord.lat,
                longitude: coord.lon
            )
        }
    }

    /// Focuses the map on the places in the named list. Case-insensitive
    /// substring match against `customLists.name`. On hit, recenters the
    /// camera to fit those places and selects the list as a filter so
    /// only those pins remain visible. Returns true when a list was
    /// found, false to let the URL handler discard the tap.
    @MainActor
    func focusOnList(named query: String) -> Bool {
        let q = query.lowercased()
        guard let list = customLists.first(where: { $0.name.lowercased() == q })
            ?? customLists.first(where: { $0.name.lowercased().contains(q) })
        else { return false }

        // Resolve the list's places into coordinates we can fit a region to.
        let coords: [CLLocationCoordinate2D] = list.placeIDs.compactMap { pid in
            places.first(where: { $0.id == pid })
                .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
        guard !coords.isEmpty else { return false }

        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return false }

        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        // Pad the span so the pins aren't kissing the edges. Floor at a
        // sane minimum span for the single-place case.
        let spanLat = max((maxLat - minLat) * 1.5, 0.01)
        let spanLon = max((maxLon - minLon) * 1.5, 0.01)

        withAnimation(SomedayAnimations.inTileNav) {
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
            )
            // Clear any other narrowing filter so the list's pins stand alone.
            filteredFriendID = nil
            selectedPlace = nil
            showSearch = false
        }
        Haptics.tap()
        return true
    }

    /// Tears down the bottom suggestion *tile* (carousel + breathing
    /// highlight) without evicting the pins from the map. Hooked up to the
    /// chat's clear-thread action: clearing the conversation dismisses the
    /// in-chat surfaces, but each suggested pin now owns an independent 24h
    /// life on the map (persisted, swept by `sweepExpiredSuggestions`) and
    /// shouldn't vanish just because the user cleared the thread. Pins drop
    /// off when their clock runs out or when saved to a list.
    @MainActor
    func clearAISuggestionPins() {
        discoverAllRevealTask?.cancel()
        discoverAllRevealTask = nil
        withAnimation(SomedayAnimations.inTileNav) {
            discoverAllSuggestions.removeAll()
            currentSuggestionID = nil
        }
    }

    /// Open the bottom suggestion tile with one or more pins.
    /// `pins.count == 1` → single-page card (pin tap on the map).
    /// `pins.count > 1` → choreographed reveal: zoom out to fit all
    /// pins so the user can see them pop onto the map, briefly hold
    /// the wide view, then zoom in on `pins[0]` and surface the
    /// swipeable carousel tile. Single-pin case skips the overview
    /// step (no point zooming out to one dot).
    @MainActor
    func beginDiscoverAll(_ pins: [SuggestedPin]) {
        guard !pins.isEmpty else { return }
        Haptics.tap()
        selectedPlace = nil

        // Fresh discover swaps the bottom *tile* contents but deliberately
        // does NOT wipe `aiSuggestionPins`: every suggested pin now lives on
        // the map for a full 24h (or until saved), so reopening the carousel
        // for a new batch must not evict pins from earlier turns. The new
        // set is upserted into the map below; old pins age out on their own
        // clock via `sweepExpiredSuggestions`.
        discoverAllRevealTask?.cancel()
        discoverAllRevealTask = nil
        discoverAllSuggestions.removeAll()
        currentSuggestionID = nil

        // Single-pin fast path: no overview phase, straight to focus
        // + tile (matches the previous behaviour for map-pin taps).
        if pins.count == 1 {
            withAnimation(SomedayAnimations.inTileNav) {
                discoverAllSuggestions = pins
            }
            focusOnAISuggestion(
                name: pins[0].name,
                category: pins[0].category,
                description: pins[0].description,
                hours: pins[0].hours,
                price: pins[0].price,
                website: pins[0].website,
                phone: pins[0].phone,
                latitude: pins[0].latitude,
                longitude: pins[0].longitude
            )
            return
        }

        // Multi-pin choreography. Drop all pins onto the map first
        // (upsert into `aiSuggestionPins`) so they animate in while
        // the camera is wide. The carousel tile stays hidden during
        // the overview hold — we don't want it racing the zoom.
        upsertAISuggestionPins(pins)

        // Compute an overview region that contains every pin with a
        // generous edge pad so the tile doesn't end up covering the
        // bottom pin. Floor at a sane minimum span for tightly-
        // clustered pins (~few blocks apart).
        let lats = pins.map(\.latitude)
        let lons = pins.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let spanLat = max((maxLat - minLat) * 1.8, 0.02)
        let spanLon = max((maxLon - minLon) * 1.8, 0.02)

        withAnimation(SomedayAnimations.inTileNav) {
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
            )
            // Clear breathing during the overview — no pin is
            // "active" yet, just everyone equally on stage.
            currentSuggestionID = nil
        }

        // Hold the wide view long enough for the pop-in to register,
        // then zoom in on the first pin and surface the carousel.
        // 1.1s ≈ camera ease (~0.6s) + a beat to let the user see
        // the spread before we narrow in.
        discoverAllRevealTask?.cancel()
        discoverAllRevealTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                withAnimation(SomedayAnimations.inTileNav) {
                    self.discoverAllSuggestions = pins
                }
                self.focusOnAISuggestion(
                    name: pins[0].name,
                    category: pins[0].category,
                    description: pins[0].description,
                    hours: pins[0].hours,
                    price: pins[0].price,
                    website: pins[0].website,
                    phone: pins[0].phone,
                    latitude: pins[0].latitude,
                    longitude: pins[0].longitude
                )
            }
        }
    }

    /// Idempotent batch upsert used by the Discover-all overview
    /// phase so we can drop every pin onto the map BEFORE running
    /// the camera animation. Mirrors `focusOnAISuggestion`'s upsert
    /// rule (richer metadata wins) but without touching the camera
    /// or banner — those are owned by the caller.
    @MainActor
    private func upsertAISuggestionPins(_ pins: [SuggestedPin]) {
        withAnimation(SomedayAnimations.inTileNav) {
            for pin in pins {
                if let idx = aiSuggestionPins.firstIndex(where: { $0.id == pin.id }) {
                    let existing = aiSuggestionPins[idx]
                    let score: (SuggestedPin) -> Int = { p in
                        [p.description, p.hours, p.price, p.website, p.phone]
                            .compactMap { $0 }.count
                    }
                    if score(pin) > score(existing) {
                        // Preserve the original drop time so a richer
                        // re-suggest doesn't reset the 24h clock.
                        var richer = pin
                        richer.createdAt = existing.createdAt
                        aiSuggestionPins[idx] = richer
                    }
                } else {
                    aiSuggestionPins.append(pin)
                }
            }
        }
    }

    @MainActor
    func endDiscoverAll() {
        discoverAllRevealTask?.cancel()
        discoverAllRevealTask = nil
        withAnimation(SomedayAnimations.inTileNav) {
            discoverAllSuggestions.removeAll()
            currentSuggestionID = nil
        }
    }

    /// Instant (no-animation) dismissal of the two bottom-anchored
    /// context tiles — pin_tile (`selectedPlace`) and tile_bottom
    /// (`discoverAllSuggestions`). Called by the chat-input focus
    /// handler in MapHomeView so the tiles vanish on the next frame,
    /// before the iOS keyboard rise animation runs. Wrapping this in
    /// `withAnimation` would conflict with the keyboard slide — both
    /// animate over ~250ms and the user perceives the tile drifting
    /// upward instead of disappearing. Skipping the animation makes
    /// it pop away cleanly.
    @MainActor
    func dismissBottomTilesForKeyboard() {
        if selectedPlace != nil {
            selectedPlace = nil
        }
        if !discoverAllSuggestions.isEmpty {
            discoverAllRevealTask?.cancel()
            discoverAllRevealTask = nil
            discoverAllSuggestions.removeAll()
            currentSuggestionID = nil
        }
    }

    /// Removes a single AI-proposed pin by id. Surfaced via the hint
    /// banner's dismiss button so the user can drop the suggestion
    /// without nuking the others.
    @MainActor
    func dismissAISuggestionPin(id: String) {
        withAnimation(SomedayAnimations.inTileNav) {
            aiSuggestionPins.removeAll { $0.id == id }
            if aiSuggestionHint?.coordinate.latitude == nil { return }
        }
    }

    @MainActor
    func dismissAISuggestionHint() {
        suggestionHintClearTask?.cancel()
        suggestionHintClearTask = nil
        withAnimation(SomedayAnimations.inTileNav) {
            aiSuggestionHint = nil
        }
    }

    func dismissToast() {
        withAnimation(SomedayAnimations.inTileNav) {
            showSavedToast = false
        }
    }

    var filteredFriend: UserProfile? {
        guard let id = filteredFriendID else { return nil }
        return friends.first { $0.id == id }
    }

    var visiblePlaces: [Place] {
        // Time-limited event pins (food-truck pop-ups etc.) drop off the
        // map the moment they're over — so a finished event never lingers.
        // Ordinary places (eventEnd == nil) always pass this filter.
        func notExpired(_ p: Place) -> Bool { !p.isEvent || p.isActiveEvent }

        // When previewing a friend's list, the map shows only that list's pins
        // so the user can decide whether to Add them to their own map.
        if let preview = previewedList { return preview.places.filter(notExpired) }
        guard let friendID = filteredFriendID else { return places.filter(notExpired) }
        return places.filter {
            notExpired($0) && ($0.visitedByIDs.contains(friendID) || $0.recommendedBy == friendID)
        }
    }

    // MARK: - List preview

    /// Resolves a friend's named list into a `PreviewedList` (zooming the map
    /// to fit the pins) and shows it on the map. Called from the Activity
    /// feed when the user taps one of the in-tile list tiles.
    func showListPreview(owner: UserProfile, listName: String) {
        // Toggle: re-tapping the same friend's list while it's already
        // being previewed exits preview mode. Replaces the explicit
        // "Cancel" button the old action-bar tile used to provide.
        if let current = previewedList,
           current.owner.id == owner.id,
           current.name == listName {
            cancelListPreview()
            return
        }

        let placeIDs = owner.lists[listName] ?? []
        // Resolve IDs to Place objects from anything we know about — first the
        // live data already loaded for the current user, then the sample
        // catalog so the demo path still has pins to draw.
        var resolved: [String: Place] = [:]
        for p in places { resolved[p.id] = p }
        for p in SampleData.places where resolved[p.id] == nil { resolved[p.id] = p }

        let placesForList = placeIDs.compactMap { resolved[$0] }
        guard !placesForList.isEmpty else { return }

        withAnimation(SomedayAnimations.tile) {
            previewedList = PreviewedList(owner: owner, name: listName, places: placesForList)
            previewTargetList = nil
            filteredFriendID = nil
            showActivity = false
            showLists = false
        }

        // Frame the camera to fit the previewed pins.
        let lats = placesForList.map(\.latitude)
        let lons = placesForList.map(\.longitude)
        let centerLat = (lats.min()! + lats.max()!) / 2
        let centerLon = (lons.min()! + lons.max()!) / 2
        let spanLat = max((lats.max()! - lats.min()!) * 1.6, 0.012)
        let spanLon = max((lons.max()! - lons.min()!) * 1.6, 0.012)
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )
    }

    /// Tap on one of the user's own custom lists in the Lists grid:
    /// zoom the map to fit every pin in that list. Dismisses the Lists
    /// tile so the user sees the result; no preview banner needed since
    /// these are already the user's own places.
    ///
    /// Behaviour:
    ///   • Empty list → no-op (nothing to zoom to).
    ///   • Single pin → zoom in tight to that pin.
    ///   • Multiple pins → bounding region with 60% slack so the pins
    ///     aren't crammed against the screen edge.
    @MainActor
    func focusOnCustomList(name: String) {
        guard let list = customLists.first(where: { $0.name == name }) else { return }
        let placesForList = places.filter { list.placeIDs.contains($0.id) }
        guard !placesForList.isEmpty else { return }

        let lats = placesForList.map(\.latitude)
        let lons = placesForList.map(\.longitude)
        let centerLat = (lats.min()! + lats.max()!) / 2
        let centerLon = (lons.min()! + lons.max()!) / 2
        // 60% slack: pins land away from the screen edges. The 0.012
        // floor keeps single-pin lists from zooming in absurdly close —
        // ≈1.3km, roughly a neighbourhood block, which feels like "I'm
        // looking at THIS pin" rather than "I'm staring at a parking spot".
        let spanLat = max((lats.max()! - lats.min()!) * 1.6, 0.012)
        let spanLon = max((lons.max()! - lons.min()!) * 1.6, 0.012)

        withAnimation(SomedayAnimations.tile) {
            showLists = false
            // Picking your own list clears any active friend-list
            // preview — the user is now looking at THEIR map, so the
            // preview's filtering should drop away.
            previewedList = nil
            previewTargetList = nil
        }
        withAnimation(SomedayAnimations.followCTA) {
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
            )
        }
        Haptics.tap()
    }

    func cancelListPreview() {
        withAnimation(SomedayAnimations.inTileNav) {
            previewedList = nil
            previewTargetList = nil
        }
    }

    /// Commit the previewed list to the user's own map by importing any
    /// places they don't already have, then drop the preview banner.
    @MainActor
    func acceptListPreview() async {
        guard let preview = previewedList else { return }
        await importPlaces(preview.places)
        // TODO: once we wire list membership to Supabase, also add the
        // imported places to `previewTargetList` if the user picked one.
        withAnimation(SomedayAnimations.inTileNav) {
            previewedList = nil
            previewTargetList = nil
        }
    }

    func showFriendPlaces(friendID: String) {
        withAnimation(SomedayAnimations.tile) {
            filteredFriendID = friendID
            showFriends = false
        }

        let friendPlaces = places.filter { $0.visitedByIDs.contains(friendID) || $0.recommendedBy == friendID }
        guard !friendPlaces.isEmpty else { return }

        let lats = friendPlaces.map(\.latitude)
        let lons = friendPlaces.map(\.longitude)
        let centerLat = (lats.min()! + lats.max()!) / 2
        let centerLon = (lons.min()! + lons.max()!) / 2
        let spanLat = max((lats.max()! - lats.min()!) * 1.5, 0.01)
        let spanLon = max((lons.max()! - lons.min()!) * 1.5, 0.01)

        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )
    }

    func clearFriendFilter() {
        withAnimation(SomedayAnimations.inTileNav) {
            filteredFriendID = nil
        }
    }

    static let amsterdamOverview = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.3676, longitude: 4.8900),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )

    func zoomToOverview() {
        region = Self.amsterdamOverview
    }

    /// Fly the camera to an arbitrary location the chat asked us to show
    /// — a country, city, neighbourhood, or landmark — WITHOUT dropping a
    /// pin or opening any card. Backs the `someday://show?...` action so
    /// "show me France" / "take me to Lisbon" just moves the map.
    ///
    /// `span` is the model's requested degree span (both axes); we clamp
    /// it to a sane camera range (a city block up to a continent) and
    /// fall back to a city-level view when it's missing or unusable.
    @MainActor
    func flyTo(latitude: Double, longitude: Double, span: Double?) {
        // Reject NaN / non-finite spans before clamping so a malformed
        // link can't produce an invalid region.
        let requested = (span.map { $0.isFinite ? $0 : nil } ?? nil) ?? 0.4
        let delta = min(max(requested, 0.004), 120)
        withAnimation(SomedayAnimations.inTileNav) {
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
            )
            // Clear any narrowing UI so the destination isn't half-hidden
            // behind a card or a friend filter.
            selectedPlace = nil
            showSearch = false
            filteredFriendID = nil
            peekHighlightPlaceID = nil
        }
        Haptics.tap()
    }

    // MARK: - Routing (point-to-point between two saved pins)

    /// Begin showing a route between two of the user's saved pins. Resolves
    /// both ids to live places, frames the pair, and kicks off the first
    /// `MKDirections` calculation (defaulting to walking — this is a
    /// city/neighbourhood app, so a walk is the most common intent; the
    /// user can flip to driving/transit from the readout). Returns false —
    /// so the chat action can `.discard` — when either id isn't a saved pin
    /// or the two resolve to the same place (a route to yourself is a no-op).
    @MainActor
    @discardableResult
    func showRoute(fromID: String, toID: String) -> Bool {
        guard
            let from = places.first(where: { $0.id == fromID }),
            let to = places.first(where: { $0.id == toID }),
            from.id != to.id
        else { return false }

        activeRoute = ActiveRoute(
            fromID: from.id,
            toID: to.id,
            fromName: from.name,
            toName: to.name,
            fromCoord: from.coordinate,
            toCoord: to.coordinate,
            mode: .walking,
            polyline: nil,
            travelTime: nil,
            distance: nil,
            isLoading: true,
            errorMessage: nil
        )

        // Clear competing bottom-slot / search UI so the route + its
        // readout own the screen, same hygiene as `flyTo`.
        selectedPlace = nil
        showSearch = false
        peekHighlightPlaceID = nil

        // Frame the straight-line pair immediately for instant feedback;
        // `computeRoute` reframes to the actual path's bounds once it lands.
        frameRoute(from: from.coordinate, to: to.coordinate)
        Haptics.tap()
        Task { await computeRoute() }
        return true
    }

    /// Switch the active route's travel mode (walk ⇄ drive ⇄ transit) and
    /// recompute. No-op if there's no route or the mode is unchanged.
    @MainActor
    func setRouteMode(_ mode: RouteTravelMode) {
        guard var route = activeRoute, route.mode != mode else { return }
        route.mode = mode
        route.isLoading = true
        route.errorMessage = nil
        route.polyline = nil
        route.travelTime = nil
        route.distance = nil
        activeRoute = route
        Haptics.tap()
        Task { await computeRoute() }
    }

    /// Tear down the active route — removes the polyline overlay and the
    /// floating readout. The map stays where it is (the user is presumably
    /// looking at the area they routed across).
    @MainActor
    func clearRoute() {
        guard activeRoute != nil else { return }
        activeRoute = nil
        Haptics.tap()
    }

    /// Run an `MKDirections` calculation for the current route + mode and
    /// fold the result back onto `activeRoute`. Guards against races: if
    /// the user cleared the route or changed mode while the async request
    /// was in flight, the stale result is dropped (we re-read `activeRoute`
    /// and bail unless it still matches the request we issued).
    @MainActor
    private func computeRoute() async {
        guard let pending = activeRoute else { return }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: pending.fromCoord))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: pending.toCoord))
        request.transportType = pending.mode.transportType

        func stillCurrent() -> Bool {
            guard let cur = activeRoute else { return false }
            return cur.fromID == pending.fromID
                && cur.toID == pending.toID
                && cur.mode == pending.mode
        }

        do {
            let response = try await MKDirections(request: request).calculate()
            guard stillCurrent(), var route = activeRoute else { return }
            guard let best = response.routes.first else {
                route.isLoading = false
                route.errorMessage = "No \(pending.mode.noun) route between these two."
                activeRoute = route
                return
            }
            route.polyline = best.polyline
            route.travelTime = best.expectedTravelTime
            route.distance = best.distance
            route.isLoading = false
            route.errorMessage = nil
            activeRoute = route
            // Reframe to the actual path's bounds — a curved walk/drive can
            // bow well outside the straight-line box we framed on entry.
            frameRoute(boundingMapRect: best.polyline.boundingMapRect)
        } catch {
            guard stillCurrent(), var route = activeRoute else { return }
            route.isLoading = false
            // MapKit returns a "directions not available" error for transit
            // in unsupported regions — surface a human-readable hint.
            route.errorMessage = "Couldn't find a \(pending.mode.noun) route here."
            activeRoute = route
        }
    }

    /// Frame the camera around two coordinates (the straight-line pair) —
    /// used the instant a route starts, before the path is known.
    @MainActor
    private func frameRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) {
        let minLat = min(from.latitude, to.latitude)
        let maxLat = max(from.latitude, to.latitude)
        let minLon = min(from.longitude, to.longitude)
        let maxLon = max(from.longitude, to.longitude)
        // 1.8× the extent so the two pins aren't jammed against the edges,
        // with a floor so two near-identical coords don't over-zoom.
        let spanLat = max((maxLat - minLat) * 1.8, 0.006)
        let spanLon = max((maxLon - minLon) * 1.8, 0.006)
        withAnimation(SomedayAnimations.inTileNav) {
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: (minLat + maxLat) / 2,
                    longitude: (minLon + maxLon) / 2
                ),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
            )
        }
    }

    /// Frame the camera to a route polyline's bounding rect with padding —
    /// used once the real path lands so the whole route is visible.
    @MainActor
    private func frameRoute(boundingMapRect rect: MKMapRect) {
        var framed = MKCoordinateRegion(rect)
        framed.span.latitudeDelta = max(framed.span.latitudeDelta * 1.4, 0.006)
        framed.span.longitudeDelta = max(framed.span.longitudeDelta * 1.4, 0.006)
        withAnimation(SomedayAnimations.inTileNav) {
            region = framed
        }
    }

    @MainActor
    func importPlaces(_ newPlaces: [Place]) async {
        // Strip region results before we touch the map. A Google Maps
        // share of a country/city/area resolves to a `Place(kind: .region)`
        // — useful for the summary tile to flag with "this is not a
        // single place", but pointless as an actual pin (it would
        // cluster at the country centroid and pollute the map).
        // `ImportSummaryCardView` still sees them via its own
        // `summary.places`, so the user gets the explanation; only the
        // map-state path filters them out.
        let venueCandidates = newPlaces.filter { $0.kind == .venue }

        // Two passes of dedup:
        //   1. Against `places` already on the map — drops re-imports of
        //      a venue the user already has, regardless of source.
        //   2. Against the in-progress `toAdd` batch — protects against a
        //      single Reel returning the same place twice (rare, but the
        //      AI does occasionally double-extract).
        // Names are normalised + coords within 200m count as a match;
        // see `isLikelySamePlace` for the heuristic.
        var toAdd: [Place] = []
        for candidate in venueCandidates {
            if existingPlaceMatching(candidate) != nil { continue }
            if toAdd.contains(where: { Self.isLikelySamePlace($0, candidate) }) { continue }
            toAdd.append(candidate)
        }
        guard !toAdd.isEmpty else { return }

        // Clear any active friend filter so the new pins are visible.
        filteredFriendID = nil

        // Wait briefly so the import sheet finishes dismissing before we touch the map.
        try? await Task.sleep(nanoseconds: 450_000_000)

        // Frame the camera to fit the incoming places.
        let lats = toAdd.map(\.latitude)
        let lons = toAdd.map(\.longitude)
        let centerLat = (lats.min()! + lats.max()!) / 2
        let centerLon = (lons.min()! + lons.max()!) / 2
        let spanLat = max((lats.max()! - lats.min()!) * 1.7, 0.02)
        let spanLon = max((lons.max()! - lons.min()!) * 1.7, 0.02)
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )

        // Slight wait so the camera settles before pins arrive.
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Stagger each place in. Critical: we ALSO write the row to
        // Supabase here so the import survives cold launches. Errors
        // are swallowed per-place — if the write fails (network blip,
        // RLS, etc.) the pin still lands in-memory and the user can
        // re-save manually; better than aborting the whole batch.
        for place in toAdd {
            do {
                try await placeService.savePlace(place)
            } catch {
                #if DEBUG
                print("[MapViewModel] savePlace failed for \(place.name): \(error)")
                #endif
            }
            places.append(place)
            // Soft thud each time a pin lands — the cumulative feel of
            // a 3-place import is a rhythmic "tk tk tk" that mirrors
            // the pins staggering onto the map.
            Haptics.soft()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // Record the import for per-user usage accounting (Settings → Plan).
        // Best-effort and fire-and-forget — the service swallows its own
        // errors, so this never affects the import the user just made.
        await usageService.recordImport(count: toAdd.count)
    }

    /// Routes the Maps URL through the extraction service. Google Maps
    /// always runs on Pipeline 1 regardless of the pipeline toggle —
    /// Pipeline 2 is a video-only pipeline (see `ExtractionRouter`).
    /// Returned places aren't saved yet — the import preview flow stages
    /// them and decides whether to commit.
    @MainActor
    func parseGoogleMaps(url: String) async throws -> [Place] {
        // Cache check before paying for the Edge Function call.
        let cached = placesImported(from: url)
        if !cached.isEmpty {
            #if DEBUG
            print("[MapViewModel] Cache hit for Maps URL — \(cached.count) place(s), skipping extraction")
            #endif
            return cached
        }
        return try await extractionService.extractFromGoogleMaps(url: url, ownerID: userID)
    }

    /// Routes the Instagram URL through the extraction service. Whether
    /// Pipeline 1 (Supabase Edge Function + geocoding) or Pipeline 2
    /// (Erik's Railway video extractor) handles the call is decided by
    /// `ExtractionPipelineSelector.current`. Same staging contract as
    /// `parseGoogleMaps` — caller decides whether to commit.
    @MainActor
    func parseInstagram(url: String) async throws -> [Place] {
        // Cache check before paying for the AI extraction.
        let cached = placesImported(from: url)
        if !cached.isEmpty {
            #if DEBUG
            print("[MapViewModel] Cache hit for Instagram URL — \(cached.count) place(s), skipping extraction")
            #endif
            return cached
        }
        return try await extractionService.extractFromInstagram(url: url, ownerID: userID)
    }

    var shareText: String {
        let saved = places.filter(\.isSaved)
        guard !saved.isEmpty else { return "My Someday list is empty — time to explore!" }

        let grouped = Dictionary(grouping: saved) { $0.category }
        var lines = ["My Someday List", ""]
        for category in PlaceCategory.allCases {
            guard let items = grouped[category], !items.isEmpty else { continue }
            lines.append("\(category.displayName)")
            for item in items {
                let location = item.neighborhood.isEmpty ? "" : " — \(item.neighborhood)"
                lines.append("  \(item.name)\(location)")
            }
            lines.append("")
        }
        lines.append("Shared from Someday")
        return lines.joined(separator: "\n")
    }

    func friendProfile(for id: String) -> UserProfile? {
        friends.first { $0.id == id }
    }

    /// Show the full-tile import summary. The caller is responsible for
    /// waiting until the pin-stagger animation has finished so the user
    /// sees the pins land *before* the summary takes over the screen.
    /// Fires the aggressive "importing now" haptic burst the moment
    /// results land — the user physically feels the app pulling places
    /// in. Covers Maps + shared-Lists; the Instagram path lands the
    /// same burst from inside `startInstagramImport`. The per-row taps
    /// during the staggered reveal animation are fired by the
    /// `ImportSummaryCardView` itself, not here.
    @MainActor
    func presentImportSummary(_ summary: ImportSummary) {
        if !summary.isLoading { Haptics.importBurst() }
        withAnimation(SomedayAnimations.tile) {
            lastImportSummary = summary
        }
    }

    /// One-shot Instagram import that **skips** the LinkImportView URL
    /// step. Surfaces the loading tile immediately, runs the parse in
    /// the background, then swaps to the results. Used by:
    ///   • Share Extension / deep-link entries — URL already known.
    ///   • Add-Sources Instagram tap when the clipboard already holds an
    ///      Instagram URL — no need to ask the user to paste it again.
    /// The flow handles its own errors: on failure the tile dismisses
    /// and we leave a no-op (errors aren't surfaced as toast yet).
    @MainActor
    func startInstagramImport(url: String) async {
        // Fast path: have we already imported this URL before? If so,
        // skip the loading animation entirely and show the existing
        // pins as the summary. Saves a Gemini/Apify hit + ~5s of wait
        // for a flow the user has already done once.
        let cached = placesImported(from: url)
        if !cached.isEmpty {
            #if DEBUG
            print("[MapViewModel] Cache hit on startInstagramImport — \(cached.count) place(s)")
            #endif
            Haptics.importBurst()
            withAnimation(SomedayAnimations.tile) {
                lastImportSummary = ImportSummary(places: cached, source: .instagram)
            }
            return
        }

        // Show the loading tile right away — gives the user immediate
        // feedback that something is happening even before the AI starts.
        // Aggressive burst fires alongside so the user feels the import
        // start before the visual catches up.
        Haptics.importBurst()
        withAnimation(SomedayAnimations.tile) {
            lastImportSummary = .loading(.instagram)
        }

        do {
            let parsed = try await parseInstagram(url: url)
            guard !parsed.isEmpty else {
                // AI ran but couldn't find a venue — most often the
                // location is named in the comments instead of the
                // caption. Swap the loading state for an empty-state
                // tile that suggests checking the comments + links
                // back to the original post.
                Haptics.warning()
                withAnimation(SomedayAnimations.tile) {
                    lastImportSummary = .empty(.instagram, url: URL(string: url))
                }
                return
            }
            await importPlaces(parsed)
            // Burst at the load-complete moment — same haptic as
            // `presentImportSummary` so all three import sources
            // (Instagram, Maps, Lists) feel identical. The per-row
            // ticks during the staggered reveal animation are fired by
            // `ImportSummaryCardView` itself.
            Haptics.importBurst()
            // Swap loading state → results in a single animated step so
            // the tile feels like it morphed in place rather than two
            // separate sheets stacking on top of each other.
            withAnimation(SomedayAnimations.tile) {
                lastImportSummary = ImportSummary(places: parsed, source: .instagram)
            }
        } catch {
            // Hard fail — error haptic so the user feels the difference
            // between "loaded into nothing" (warning) and "blew up".
            Haptics.error()
            withAnimation(SomedayAnimations.tile) {
                lastImportSummary = nil
            }
        }
    }

    func dismissImportSummary() {
        withAnimation(SomedayAnimations.tile) {
            lastImportSummary = nil
        }
    }

    /// Tap from the summary tile's "Add" CTA. Stash the places, open the
    /// Lists picker, and dismiss the summary tile + place card so the
    /// picker has the screen. Same entry point used by the per-place
    /// "+" / list-color button on PlaceCardSheet — just with a single-
    /// element array.
    @MainActor
    func beginAddImportedPlacesToList(_ places: [Place]) {
        pendingAddToListPlaces = places
        withAnimation(SomedayAnimations.tile) {
            lastImportSummary = nil
            selectedPlace = nil   // dismiss the place card if it's open
            showOverlay(.lists)
        }
    }

    /// "Save to list" from the suggestion tile. Converts an ephemeral
    /// `SuggestedPin` into a real saved `Place`, drops the lingering
    /// suggestion (its 24h countdown stops the moment it's saved), and
    /// hands the new place to the Lists picker so the user can file it.
    ///
    /// This is the one action that promotes a chatbot suggestion from
    /// "on the map for a day" to "permanently saved" — exactly the escape
    /// hatch the countdown pill is nudging toward.
    @MainActor
    func saveSuggestionToList(_ pin: SuggestedPin) {
        let category = pin.category
            .flatMap { PlaceCategory(rawValue: $0.lowercased()) } ?? .food
        let place = Place(
            id: UUID().uuidString,
            name: pin.name.trimmingCharacters(in: .whitespaces),
            category: category,
            latitude: pin.latitude,
            longitude: pin.longitude,
            source: .manual,
            neighborhood: currentCityName ?? "",
            isSaved: true,
            ownerID: userID
        )
        guard !place.name.isEmpty else { return }

        // De-dupe against an already-saved venue at the same spot so a
        // double-tap (or saving a pin the user already has) doesn't create
        // a twin. If it's already on the map, just route to the picker.
        let existing = places.first { Self.isLikelySamePlace($0, place) }
        let target = existing ?? place
        if existing == nil {
            withAnimation(SomedayAnimations.tile) {
                places.append(place)
            }
            Task {
                do { try await placeService.savePlace(place) }
                catch {
                    #if DEBUG
                    print("[MapViewModel] saveSuggestionToList persist failed: \(error)")
                    #endif
                }
            }
        }

        // Stop the countdown: pull the suggestion off the map + tile.
        withAnimation(SomedayAnimations.inTileNav) {
            aiSuggestionPins.removeAll { $0.id == pin.id }
            discoverAllSuggestions.removeAll { $0.id == pin.id }
            if currentSuggestionID == pin.id { currentSuggestionID = nil }
        }
        Haptics.success()

        // Hand the saved place to the Lists picker (also tears down the
        // remaining bottom tiles so the picker owns the screen).
        beginAddImportedPlacesToList([target])
    }

    /// First custom list this place currently belongs to. Returns nil if
    /// the place isn't in any list. The place-card button uses this to
    /// decide between the empty "+" affordance (not yet listed) and the
    /// filled / list-coloured chip (already listed).
    /// A place can technically live in multiple lists, but the card only
    /// surfaces the first one — adding to additional lists is still a
    /// single tap on the same button.
    func listContaining(_ place: Place) -> CustomList? {
        customLists.first(where: { $0.placeIDs.contains(place.id) })
    }

    /// All custom lists this place currently belongs to. Used by the
    /// Lists overlay's "edit membership" mode to decide which tiles get
    /// the highlighted border. Order matches `customLists` (user's own
    /// stored order).
    func listsContaining(placeID: String) -> [CustomList] {
        customLists.filter { $0.placeIDs.contains(placeID) }
    }

    /// True iff the place currently belongs to the named list. O(n) over
    /// the placeIDs of that one list — cheap; called per tile per render.
    func placeIsInList(placeID: String, listName: String) -> Bool {
        guard let list = customLists.first(where: { $0.name == listName }) else {
            return false
        }
        return list.placeIDs.contains(placeID)
    }

    // MARK: - Membership editor

    /// Enter membership-editor mode for the given pin. Dismisses the
    /// pin_tile (so the lists tile owns the screen) and opens the lists
    /// overlay. The view checks `membershipEditingPlace` to decide
    /// whether to render the lists tile in editor mode.
    @MainActor
    func beginEditMembership(for place: Place) {
        membershipEditingPlace = place
        withAnimation(SomedayAnimations.tile) {
            selectedPlace = nil
            showOverlay(.lists)
        }
    }

    /// Leave membership-editor mode. Re-opens the pin_tile for the same
    /// pin so the user can see the updated list chip without having to
    /// re-tap the map. Called when the lists overlay dismisses while in
    /// editor mode.
    @MainActor
    func endEditMembership() {
        guard let editing = membershipEditingPlace else { return }
        membershipEditingPlace = nil
        // Re-resolve the place from the live `places` array so a stale
        // snapshot doesn't bring back e.g. an out-of-date category. Falls
        // back to the captured value if it was somehow removed from the
        // map while editing.
        let refreshed = places.first(where: { $0.id == editing.id }) ?? editing
        withAnimation(SomedayAnimations.tile) {
            selectedPlace = refreshed
        }
    }

    /// Toggle the membership of `membershipEditingPlace` in the named
    /// list. If the pin is already in the list, remove it; otherwise add
    /// it to the END of the list. Optimistic local mutation drives the
    /// border + pin colour instantly; the Supabase write follows.
    ///
    /// Errors are logged but don't roll back — same policy as the rest
    /// of the view model's mutation tools.
    @MainActor
    func toggleListMembership(listName: String) {
        guard let place = membershipEditingPlace else { return }
        guard let idx = customLists.firstIndex(where: { $0.name == listName }) else {
            return
        }
        let listID = customLists[idx].id.uuidString
        let placeID = place.id
        let wasMember = customLists[idx].placeIDs.contains(placeID)

        withAnimation(SomedayAnimations.tile) {
            if wasMember {
                customLists[idx].placeIDs.removeAll { $0 == placeID }
            } else {
                customLists[idx].placeIDs.append(placeID)
            }
        }
        // Tap haptic on every toggle so the user feels the change land
        // before the optimistic mutation animates in.
        Haptics.tap()

        // Persist in the background. `position` for adds = current
        // tail (length minus 1 because we already appended).
        let newPosition = customLists[idx].placeIDs.count - 1
        Task {
            do {
                if wasMember {
                    try await listService.removePlace(placeID: placeID, fromListID: listID)
                } else {
                    try await listService.addPlace(
                        placeID: placeID,
                        toListID: listID,
                        position: newPosition
                    )
                }
            } catch {
                #if DEBUG
                let verb = wasMember ? "removePlace" : "addPlace"
                print("[MapViewModel] \(verb) persist failed for \(placeID) on \(listID): \(error)")
                #endif
            }
        }
    }

    /// What list name (if any) should colour this place's map pin?
    /// Wider than `listContaining` because it also surfaces the list a
    /// FRIEND owns — when the user is previewing a shared list, the
    /// pins should adopt that list's deterministic colour even though
    /// the user hasn't saved them into one of their own lists yet.
    ///
    /// Resolution order:
    ///   1. The user's own custom lists (via `listContaining`).
    ///   2. The currently-previewed friend's list, if any.
    ///   3. The first friend whose `lists` dictionary mentions this id.
    ///
    /// `MapHomeView` passes this through to `ClusteredMapView` as the
    /// `listNameFor:` closure.
    func displayedListName(for place: Place) -> String? {
        if let mine = listContaining(place) { return mine.name }
        if let preview = previewedList,
           preview.places.contains(where: { $0.id == place.id }) {
            return preview.name
        }
        // Fallback: any friend's named list claiming this id. Gives
        // shared pins a colour identity on the map even when no
        // preview is active (e.g. they were "Add"-ed into the user's
        // map but pre-date the new list-bucket flow).
        for friend in friends {
            for (name, ids) in friend.lists where ids.contains(place.id) {
                return name
            }
        }
        return nil
    }

    /// Commit the staged places to the given custom list.
    ///
    /// A pin "belongs to one list at a time" — so when a place is added
    /// to list B, we also remove it from any *other* custom list it
    /// was already in. The user's mental model is "the pin moved", and
    /// the visual cue (the pin's coloured chip / map pin colour) needs
    /// to match: re-tapping the list-membership button on the place card
    /// recolours the pin to B's palette, not "stays at A even though I
    /// just picked B".
    ///
    /// Edge cases:
    ///   • Same list re-pick → no-op (idempotent).
    ///   • Place already on target list → no-op for that one place.
    ///   • Target list disappeared (rename/delete during picker) →
    ///     silently clear stash.
    ///
    /// Persistence runs in the background: optimistic local mutation
    /// updates the pin colour + the place-card chip instantly; the
    /// Supabase writes (insert into target, deletes from previous lists)
    /// follow. Errors are logged but don't roll back the in-memory
    /// state — same policy as elsewhere in the view model.
    @MainActor
    func addPendingPlaces(to listName: String) {
        guard let pending = pendingAddToListPlaces else { return }
        guard let targetIdx = customLists.firstIndex(where: { $0.name == listName }) else {
            // Target list disappeared (rename / delete during the picker).
            // Silently clear the stash; no UI surfaces this edge case yet.
            pendingAddToListPlaces = nil
            return
        }
        let targetListID = customLists[targetIdx].id.uuidString
        let existingOnTarget = Set(customLists[targetIdx].placeIDs)

        // Build the work list:
        //   • `newIDs`         — places to insert into the target.
        //   • `removalsByList` — places to evict from their previous
        //                       home list(s). Keyed by listID so the
        //                       background task can batch deletes.
        let pendingIDs = pending.map(\.id)
        let pendingIDSet = Set(pendingIDs)
        let newIDs = pendingIDs.filter { !existingOnTarget.contains($0) }
        var removalsByList: [String: [String]] = [:]
        // First pass (before mutating): record which list currently holds
        // each pending place, so we can both stage the remote delete and
        // know exactly what to remove from each in-memory array.
        for i in customLists.indices where i != targetIdx {
            let inThisList = customLists[i].placeIDs.filter { pendingIDSet.contains($0) }
            if !inThisList.isEmpty {
                removalsByList[customLists[i].id.uuidString] = inThisList
            }
        }
        // Optimistic local mutation in one animated pass.
        withAnimation(SomedayAnimations.tile) {
            for i in customLists.indices {
                if i == targetIdx {
                    customLists[i].placeIDs.append(contentsOf: newIDs)
                } else {
                    customLists[i].placeIDs.removeAll { pendingIDSet.contains($0) }
                }
            }
        }
        let startPosition = customLists[targetIdx].placeIDs.count - newIDs.count
        pendingAddToListPlaces = nil
        withAnimation(SomedayAnimations.tile) {
            showOverlay(nil)
        }
        Task {
            // 1) Insert each new membership on the target.
            for (offset, pid) in newIDs.enumerated() {
                do {
                    try await listService.addPlace(
                        placeID: pid,
                        toListID: targetListID,
                        position: startPosition + offset
                    )
                } catch {
                    #if DEBUG
                    print("[MapViewModel] addPlace persist failed for \(pid): \(error)")
                    #endif
                }
            }
            // 2) Evict from the previous list(s). Sequential so any
            // server-side rate limit doesn't bunch-fail the batch.
            for (listID, placeIDs) in removalsByList {
                for pid in placeIDs {
                    do {
                        try await listService.removePlace(placeID: pid, fromListID: listID)
                    } catch {
                        #if DEBUG
                        print("[MapViewModel] removePlace persist failed for \(pid) on \(listID): \(error)")
                        #endif
                    }
                }
            }
        }
    }

    /// Cancel the "add to list" flow (user dismissed the picker without
    /// choosing). Just clears the stash — the picker closes via its own
    /// dismiss handler.
    @MainActor
    func cancelAddPendingPlaces() {
        pendingAddToListPlaces = nil
    }

    /// Delete one of the user's own custom lists. Triggered by the
    /// per-tile context menu (long-press → "Delete list") after the
    /// user confirms the "Delete X?" alert raised at MapHomeView level.
    ///
    /// Behaviour:
    ///   • Removes the list locally with the same spring animation as
    ///     `mergeCustomList`, so the grid feels coherent.
    ///   • `listService.deleteList` cascades the join rows on the
    ///     backend (see init migration), so we don't need to per-row
    ///     `removePlace`. The places themselves stay on the map —
    ///     they're independent of list membership.
    ///   • Persist errors logged but don't roll back, same policy as
    ///     `mergeCustomList`.
    /// Deletes the list AND every pin inside it. Pins are evicted from
    /// `places` locally and via `placeService.deletePlace` so they
    /// disappear from the map immediately. With the single-list
    /// invariant enforced, each pin belongs to at most this list, so
    /// removing them doesn't orphan memberships elsewhere.
    ///
    /// Note for shared lists: if the user has shared this list with
    /// friends, those friends keep their server-side copy — the
    /// confirmation alert that opens this call surfaces that fact.
    /// Our delete here only touches the OWNER's rows; the shared
    /// access grants the friends already accepted live on separate
    /// rows that this method intentionally doesn't touch.
    @MainActor
    func deleteCustomList(name: String) async {
        guard let idx = customLists.firstIndex(where: { $0.name == name }) else { return }
        // Snapshot EVERYTHING we need to know about the list BEFORE we
        // touch `customLists`. The old version read `customLists[idx]`
        // inside a `removeAll(where:)` predicate that was simultaneously
        // mutating the same array — `idx` could become a stale or
        // out-of-bounds index mid-partition, and the subscript would
        // either return the wrong row (silent bug) or trap (crash).
        let listToRemove = customLists[idx]
        let listID = listToRemove.id.uuidString
        let listUUID = listToRemove.id
        let pinIDsToDelete = listToRemove.placeIDs
        // Optimistic local removal of the LIST chrome only — drop the
        // list tile + any transient list-scoped state immediately so the
        // grid updates. The pins it contained are NOT yanked here; they
        // get the choreographed zoom-then-pop treatment below so the
        // user actually sees what's being swept off the map instead of
        // pins silently vanishing while the camera looks elsewhere.
        // Use the captured UUID so the predicate doesn't re-read the
        // mutating array.
        withAnimation(SomedayAnimations.tile) {
            customLists.removeAll { $0.id == listUUID }
            // Defensive cleanup for transient list-scoped state. A stale
            // `previewedList` / `previewTargetList` pointing at the just-
            // deleted list would otherwise keep its name alive in the UI
            // and cause downstream lookups to silently return the wrong
            // row.
            if previewedList?.name == name {
                previewedList = nil
            }
            if previewTargetList == name {
                previewTargetList = nil
            }
        }
        // Frame the doomed pins, hold, then pop them away one-by-one.
        // No-ops gracefully when the list carried no pins.
        animatePinRemoval(placeIDs: pinIDsToDelete)
        Haptics.warning()
        Task {
            // Delete pins first. `lists.delete` cascades the
            // `list_places` rows (per schema), so we only need to
            // delete the place rows themselves.
            for pid in pinIDsToDelete {
                do { try await placeService.deletePlace(pid) }
                catch {
                    #if DEBUG
                    print("[MapViewModel] deletePlace (during list-delete) failed for \(pid): \(error)")
                    #endif
                }
            }
            do {
                try await listService.deleteList(listID: listID)
            } catch {
                #if DEBUG
                print("[MapViewModel] deleteList failed for \(listID): \(error)")
                #endif
            }
        }
    }

    // MARK: - Place mutations driven by the AI chat
    //
    // The chat assistant can call `create_place` / `delete_place` tools
    // (defined in the Edge Function). When the SSE stream surfaces a
    // mutation event, MapHomeView routes it to one of these helpers.
    // Optimistic local update + fire-and-forget Supabase write, same
    // policy as the list mutations above.

    /// Drop a brand-new saved pin on the map from the AI chat. Creates
    /// the `Place` row, persists it, and (optionally) appends it to the
    /// named custom list. Returns the new place's id so the chat tool
    /// can echo it back to the model in its tool_result.
    @MainActor
    @discardableResult
    func savePlaceFromChat(
        name: String,
        latitude: Double,
        longitude: Double,
        category: PlaceCategory,
        addToListNamed listName: String? = nil
    ) async -> String? {
        // Build a Place skeleton with sensible defaults. `manual` source
        // since this came from the AI assistant typing it in — not from
        // a social import. `isSaved = true` so the bookmark badge lights
        // up immediately.
        let place = Place(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            category: category,
            latitude: latitude,
            longitude: longitude,
            source: .manual,
            neighborhood: currentCityName ?? "",
            isSaved: true,
            ownerID: userID
        )
        guard !place.name.isEmpty else { return nil }
        withAnimation(SomedayAnimations.tile) {
            places.append(place)
        }
        Haptics.success()
        // Persist + optional list membership in the background. Errors
        // are logged but don't roll back the optimistic insert — same
        // policy as the list mutations.
        Task {
            do { try await placeService.savePlace(place) }
            catch {
                #if DEBUG
                print("[MapViewModel] savePlaceFromChat persist failed: \(error)")
                #endif
            }
        }
        if let listName, !listName.isEmpty {
            addPlaceToList(placeID: place.id, listName: listName)
        }
        return place.id
    }

    /// Delete a saved pin (and all its memberships) by id. The AI chat
    /// uses this via the `delete_place` tool — the list_places rows
    /// drop via the schema's ON DELETE CASCADE so we only need the one
    /// row delete here.
    @MainActor
    func deletePlaceFromChat(placeID: String) async {
        guard places.contains(where: { $0.id == placeID }) else { return }
        // Frame the pin, hold a beat, then pop it off — same choreography
        // a list-delete uses, just with a single pin. Local list-
        // membership + selection cleanup happens inside the helper.
        animatePinRemoval(placeIDs: [placeID])
        Haptics.warning()
        Task {
            do { try await placeService.deletePlace(placeID) }
            catch {
                #if DEBUG
                print("[MapViewModel] deletePlaceFromChat persist failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Long-press "delete mode" for map pins
    //
    // The iPhone home-screen idiom, applied to saved pins: long-press a
    // pin to "arm" it for deletion (a red × badge appears and the pin
    // wiggles), tap the × to delete, or tap anywhere else to disarm.
    // The gesture detection + badge rendering live in `ClusteredMapView`
    // (it owns the MapKit surface); these three methods are the state
    // transitions it calls into.

    /// Long-press landed on `place` — arm it for deletion. Fires a heavy
    /// tap so the mode entry has the same tactile "picked it up" feel as
    /// the home-screen jiggle. Idempotent for the already-armed pin.
    @MainActor
    func beginPinDeleteMode(for place: Place) {
        guard deletingPlaceID != place.id else { return }
        Haptics.heavy()
        withAnimation(.easeOut(duration: 0.18)) { deletingPlaceID = place.id }
    }

    /// User tapped somewhere other than the × badge — disarm and return
    /// the map to normal. No-op when nothing is armed.
    @MainActor
    func cancelPinDeleteMode() {
        guard deletingPlaceID != nil else { return }
        withAnimation(.easeOut(duration: 0.18)) { deletingPlaceID = nil }
    }

    /// User tapped the red × on an armed pin — disarm and delete it.
    /// Reuses the same choreographed removal + fire-and-forget server
    /// delete the chat's `delete_place` path already goes through.
    @MainActor
    func confirmPinDeletion(placeID: String) async {
        deletingPlaceID = nil
        await deletePlaceFromChat(placeID: placeID)
    }

    /// Choreographed local removal of saved pins from the map. Before a
    /// pin disappears the user should see *which* pins are going — so we
    /// (1) zoom the camera to frame every doomed pin, (2) hold briefly so
    /// the spread registers, then (3) pop them off one-by-one with a
    /// quick stagger and a tick per pin. Reads as a deliberate sweep
    /// rather than pins blinking out while the camera looks elsewhere.
    ///
    /// Local-only: the caller owns the (fire-and-forget) server delete.
    /// This method just drives `places`, the dependent list memberships,
    /// the open place card, and the camera. Safe to call with ids that
    /// aren't on the map — they're filtered out, and an empty result
    /// no-ops (so a list-delete with no pins just removes the list).
    @MainActor
    func animatePinRemoval(placeIDs: [String]) {
        // Keep only ids that point at a pin still on the map and aren't
        // already queued, preserving caller order for a predictable
        // sweep. Filtering against `pendingRemovalIDs` means a second
        // call in the same turn extends the sweep rather than double-
        // queuing a pin.
        let doomed = placeIDs.filter { id in
            places.contains { $0.id == id } && !pendingRemovalIDs.contains(id)
        }
        guard !doomed.isEmpty else { return }
        pendingRemovalIDs.append(contentsOf: doomed)

        // 1. Frame EVERY still-pending pin (not just this batch) with a
        //    generous pad so none sit under the screen edges. Clear any
        //    narrowing UI so the pins stand alone on stage during the
        //    sweep. Re-framing on each batch lets a bulk delete that
        //    arrives as several calls converge on a region holding all
        //    of them.
        let coords: [CLLocationCoordinate2D] = pendingRemovalIDs.compactMap { id in
            places.first { $0.id == id }.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
        }
        if let target = Self.regionFitting(coords) {
            withAnimation(SomedayAnimations.inTileNav) {
                region = target
                selectedPlace = nil
                showSearch = false
                filteredFriendID = nil
            }
        }

        // 2. A single worker drains the queue. If one's already running
        //    (an earlier call this turn), the ids we just appended get
        //    picked up by it — don't spin up a second sweep.
        guard pinRemovalTask == nil else { return }
        pinRemovalTask = Task { [weak self] in
            // Hold for the camera ease (~0.6s) plus a beat so the user
            // sees the spread before pins start popping.
            try? await Task.sleep(for: .seconds(0.7))
            while true {
                guard let self else { break }
                // Pop the next pin off `places` (which prunes its map
                // annotation — ClusteredMapView diffs by id and fades the
                // dropped annotation, so it reads as a physical pop). When
                // the queue is empty we clear `pinRemovalTask` in the SAME
                // MainActor hop that observed the empty queue: that closes
                // the race where a concurrent `animatePinRemoval` appends
                // an id and sees a still-non-nil task right as this worker
                // is winding down, which would strand the new id forever.
                let didPop: Bool = await MainActor.run {
                    guard let id = self.pendingRemovalIDs.first else {
                        self.pinRemovalTask = nil
                        return false
                    }
                    self.pendingRemovalIDs.removeFirst()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                        self.places.removeAll { $0.id == id }
                        // Wipe local list memberships pointing at this pin
                        // so the lists grid doesn't render dangling ids.
                        for i in self.customLists.indices {
                            self.customLists[i].placeIDs.removeAll { $0 == id }
                        }
                        if self.selectedPlace?.id == id { self.selectedPlace = nil }
                    }
                    Haptics.tap()
                    return true
                }
                if !didPop { break }
                // Quick stagger between pops — fast enough to feel like a
                // rapid sweep, slow enough that each pin reads as its own
                // beat.
                try? await Task.sleep(for: .seconds(0.12))
            }
        }
    }

    /// Smallest `MKCoordinateRegion` that frames every coordinate with a
    /// comfortable edge pad. Floors the span so a single pin (or a tight
    /// cluster) doesn't zoom in to street level. Nil for an empty input.
    private static func regionFitting(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return nil }
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let spanLat = max((maxLat - minLat) * 1.8, 0.02)
        let spanLon = max((maxLon - minLon) * 1.8, 0.02)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )
    }

    /// Reorder the user's custom lists by moving the list whose name
    /// matches `sourceName` to sit immediately before `targetName`. Used
    /// by the Lists grid's home-screen-style jiggle mode (drag a tile
    /// onto another to reposition it). Local-only for now — there's no
    /// `position` column on the `lists` table yet, so the order won't
    /// survive a cold launch on a different device. iOS-side state stays
    /// in sync within a session, which is what the gesture promises.
    @MainActor
    func reorderCustomList(named sourceName: String, beforeName targetName: String) {
        guard sourceName != targetName else { return }
        guard let sourceIdx = customLists.firstIndex(where: { $0.name == sourceName }),
              let targetIdx = customLists.firstIndex(where: { $0.name == targetName })
        else { return }
        let moving = customLists.remove(at: sourceIdx)
        // After removal, the target's index may have shifted left by one
        // if the source was earlier in the array.
        let adjustedTarget = targetIdx > sourceIdx ? targetIdx - 1 : targetIdx
        withAnimation(SomedayAnimations.tile) {
            customLists.insert(moving, at: adjustedTarget)
        }
        Haptics.tap()
    }

    /// Replace the custom-list ordering wholesale with `orderedNames`.
    /// The Lists grid's home-screen jiggle mode reflows tiles *live* as
    /// the finger crosses slots (iPhone Home Screen reflow), so by the
    /// time the user lifts their finger the final order is already known
    /// as a complete sequence of names — handing back the whole order is
    /// simpler and less error-prone than replaying a "move before"
    /// instruction. Names are matched case-sensitively against the
    /// current lists; any list the caller omits is appended at the end
    /// (defensive — the grid always passes a complete order). Local-only,
    /// same caveat as `reorderCustomList`: there's no `position` column on
    /// the `lists` table yet, so the order is per-session.
    @MainActor
    func setCustomListOrder(_ orderedNames: [String]) {
        var reordered: [CustomList] = []
        var seen = Set<String>()
        for name in orderedNames {
            guard !seen.contains(name),
                  let list = customLists.first(where: { $0.name == name }) else { continue }
            reordered.append(list)
            seen.insert(name)
        }
        // Preserve any lists the caller didn't mention (shouldn't happen,
        // but keeps the array complete rather than silently dropping one).
        for list in customLists where !seen.contains(list.name) {
            reordered.append(list)
        }
        guard reordered.count == customLists.count,
              reordered.map(\.id) != customLists.map(\.id) else { return }
        withAnimation(SomedayAnimations.tile) {
            customLists = reordered
        }
    }

    /// Append a place to a custom list by name. Creates the list if it
    /// doesn't exist yet — handy when the AI proposes "save this to a
    /// new 'Date night' list" in a single turn.
    ///
    /// Enforces the single-list invariant: a pin lives in exactly one
    /// list at a time. Before adding to `listName`, removes the pin
    /// from every OTHER list it was in. Mirrors `addPendingPlaces`'s
    /// "the pin moved" mental model so the pin colour on the map
    /// matches its newest list.
    @MainActor
    func addPlaceToList(placeID: String, listName: String) {
        let trimmed = listName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // 1. Find (or create) the target list. The create branch
        //    re-enters this method via `createList(placeIDs:)` below,
        //    which handles single-list eviction inline.
        guard let idx = customLists.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            createList(name: trimmed, imageData: nil, placeIDs: [placeID])
            return
        }
        let targetListID = customLists[idx].id.uuidString
        // 2. Idempotent — already in the target list, nothing to do.
        if customLists[idx].placeIDs.contains(placeID) { return }
        // 3. Evict from any other list first (single-list invariant).
        removePlaceFromOtherLists(placeID: placeID, exceptListID: targetListID)
        // 4. Append to the target list, optimistic local + background persist.
        let position = customLists[idx].placeIDs.count
        withAnimation(SomedayAnimations.tile) {
            customLists[idx].placeIDs.append(placeID)
        }
        Task {
            do {
                try await listService.addPlace(placeID: placeID, toListID: targetListID, position: position)
            } catch {
                #if DEBUG
                print("[MapViewModel] addPlaceToList persist failed: \(error)")
                #endif
            }
        }
    }

    /// Remove a place from every custom list EXCEPT the one whose id
    /// matches `exceptListID`. Local + persisted. The "single-list
    /// invariant" enforcement helper — called from every membership-
    /// adding path that doesn't already do this inline.
    @MainActor
    private func removePlaceFromOtherLists(placeID: String, exceptListID: String) {
        let toRemove = customLists
            .filter { $0.id.uuidString != exceptListID && $0.placeIDs.contains(placeID) }
            .map(\.id)
        guard !toRemove.isEmpty else { return }
        withAnimation(SomedayAnimations.tile) {
            for listID in toRemove {
                if let i = customLists.firstIndex(where: { $0.id == listID }) {
                    customLists[i].placeIDs.removeAll { $0 == placeID }
                }
            }
        }
        Task {
            for listID in toRemove {
                do {
                    try await listService.removePlace(placeID: placeID, fromListID: listID.uuidString)
                } catch {
                    #if DEBUG
                    print("[MapViewModel] removePlaceFromOtherLists persist failed for \(placeID) on \(listID): \(error)")
                    #endif
                }
            }
        }
    }

    /// Merge two of the user's own custom lists: everything from
    /// `source` is added to `target` (deduped against what's already
    /// there), then `source` is deleted. Triggered by the drag-to-merge
    /// gesture on the Lists grid, after the user confirms the
    /// "Merge X with Y" alert.
    ///
    /// Edge cases handled:
    ///   • Same list dropped on itself → no-op.
    ///   • Either list not found in `customLists` → no-op (could happen
    ///     mid-fetch).
    ///   • Persist errors are logged but don't roll back the optimistic
    ///     in-memory mutation — same policy as `addPendingPlaces`.
    @MainActor
    func mergeCustomList(source sourceName: String, into targetName: String) async {
        guard sourceName != targetName else { return }
        guard let sourceIdx = customLists.firstIndex(where: { $0.name == sourceName }),
              let targetIdx = customLists.firstIndex(where: { $0.name == targetName })
        else { return }

        let sourcePlaceIDs = customLists[sourceIdx].placeIDs
        let existing = Set(customLists[targetIdx].placeIDs)
        let newIDs = sourcePlaceIDs.filter { !existing.contains($0) }
        let targetListID = customLists[targetIdx].id.uuidString
        let sourceListID = customLists[sourceIdx].id.uuidString
        let startPosition = customLists[targetIdx].placeIDs.count

        // Optimistic in-memory mutation: append to target, remove source.
        // The Lists grid reads from `customLists` so the visual merge
        // happens instantly.
        withAnimation(SomedayAnimations.tile) {
            customLists[targetIdx].placeIDs.append(contentsOf: newIDs)
            customLists.removeAll { $0.id == customLists[sourceIdx].id }
        }
        Haptics.success()

        // Persist in the background. We do the membership writes first so
        // a transient failure on `deleteList` leaves the data consistent
        // (target has everything; source still exists with the same
        // pins) rather than half-merged.
        Task {
            for (offset, pid) in newIDs.enumerated() {
                do {
                    try await listService.addPlace(
                        placeID: pid,
                        toListID: targetListID,
                        position: startPosition + offset
                    )
                } catch {
                    #if DEBUG
                    print("[MapViewModel] merge addPlace failed for \(pid): \(error)")
                    #endif
                }
            }
            do {
                try await listService.deleteList(listID: sourceListID)
            } catch {
                #if DEBUG
                print("[MapViewModel] merge deleteList failed for \(sourceListID): \(error)")
                #endif
            }
        }
    }

    /// Append a new user-created list. Optional cover image + initial
    /// place IDs are stored alongside, so the Lists grid can render the
    /// cover photo and (eventually) filter the map to its contents.
    ///
    /// Persists the list row via `listService.createList` and writes a
    /// `list_places` row per initial place ID. Cover photos (imageData)
    /// remain in-memory only for now — Storage upload is a separate
    /// concern documented on `ListServiceProtocol`.
    @MainActor
    func createList(name: String, imageData: Data?, placeIDs: [String] = []) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newList = CustomList(name: trimmed, imageData: imageData, placeIDs: placeIDs)
        // Single-list invariant: if any of the initial `placeIDs` are
        // already in another list, evict them first. Without this a
        // newly-created list with seeded places would silently leave
        // those places in their old list too, and the pin colour
        // would point at the older list.
        for pid in placeIDs {
            removePlaceFromOtherLists(placeID: pid, exceptListID: newList.id.uuidString)
        }
        // Mutate local state immediately so the UI doesn't wait on the
        // network round-trip. The write is fire-and-forget below.
        withAnimation(SomedayAnimations.tile) {
            customLists.append(newList)
        }
        Task {
            do {
                try await listService.createList(newList, ownerID: userID)
                // Stamp any initial memberships.
                for (i, pid) in placeIDs.enumerated() {
                    try? await listService.addPlace(
                        placeID: pid,
                        toListID: newList.id.uuidString,
                        position: i
                    )
                }
            } catch {
                #if DEBUG
                print("[MapViewModel] createList persist failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Onboarding first-list bucket
    //
    // Every place a user imports during onboarding (Maps, Socials, the
    // inline list step) gets dropped into a single auto-created list
    // named "My first places". Gives the user a populated list out of
    // the gate — they finish onboarding with both pins on the map AND
    // a list to find them in.

    /// Deterministic name we use for the auto-created onboarding list.
    /// Kept as a constant so re-running ensure(…) idempotently picks
    /// up the existing row if one was already created earlier.
    static let onboardingFirstListName = "My first places"

    /// True if the onboarding bucket list has already been created
    /// (now or in a prior session — we match by name).
    var hasOnboardingFirstList: Bool {
        customLists.contains(where: { $0.name == Self.onboardingFirstListName })
    }

    /// Make sure the onboarding bucket list exists. Safe to call many
    /// times — only creates the row the first time. Returns the list's
    /// UUID string so callers can immediately add memberships to it.
    @MainActor
    @discardableResult
    func ensureOnboardingFirstList() -> String {
        if let existing = customLists.first(where: { $0.name == Self.onboardingFirstListName }) {
            return existing.id.uuidString
        }
        let list = CustomList(
            name: Self.onboardingFirstListName,
            imageData: nil,
            placeIDs: []
        )
        // Mutate local state synchronously so the next call to
        // `addToOnboardingFirstList` can find the row in `customLists`
        // without waiting on the persist round-trip.
        withAnimation(SomedayAnimations.tile) {
            customLists.append(list)
        }
        let listID = list.id.uuidString
        Task {
            do {
                try await listService.createList(list, ownerID: userID)
            } catch {
                #if DEBUG
                print("[MapViewModel] ensureOnboardingFirstList persist failed: \(error)")
                #endif
            }
        }
        return listID
    }

    /// Drop the given places into the onboarding bucket. Optimistic
    /// local update first, then a background write per membership.
    /// Idempotent against the list's existing IDs so re-firing for
    /// a place that's already there is a no-op.
    @MainActor
    func addToOnboardingFirstList(_ placesToAdd: [Place]) {
        guard !placesToAdd.isEmpty else { return }
        let listID = ensureOnboardingFirstList()
        guard let listIdx = customLists.firstIndex(where: { $0.id.uuidString == listID }) else { return }
        let existing = Set(customLists[listIdx].placeIDs)
        let newIDs = placesToAdd.map(\.id).filter { !existing.contains($0) }
        guard !newIDs.isEmpty else { return }
        // Single-list invariant: evict each new place from any OTHER
        // list before appending it to the onboarding bucket. Without
        // this, importing a place during onboarding (e.g. via the
        // share extension that already put it in another list) would
        // leave the pin in two lists and the map pin colour would be
        // ambiguous.
        for pid in newIDs {
            removePlaceFromOtherLists(placeID: pid, exceptListID: listID)
        }
        let startPosition = customLists[listIdx].placeIDs.count
        withAnimation(SomedayAnimations.tile) {
            customLists[listIdx].placeIDs.append(contentsOf: newIDs)
        }
        Task {
            for (offset, pid) in newIDs.enumerated() {
                do {
                    try await listService.addPlace(
                        placeID: pid,
                        toListID: listID,
                        position: startPosition + offset
                    )
                } catch {
                    #if DEBUG
                    print("[MapViewModel] addToOnboardingFirstList persist failed for \(pid): \(error)")
                    #endif
                }
            }
        }
    }

    var activityFeed: [ActivityFeedEvent] {
        ActivityFeedBuilder.build(friends: friends, places: places)
    }

    // MARK: - Shared-list access windows
    //
    // When a friend shares a list with this user, the share-request tile
    // lets them pick how long the list stays accessible — 30 days, 90
    // days, or forever. We track the chosen window here so a future
    // background sweep (or the UI directly) can prune lists past their
    // expiry. Keyed by `"<ownerID>::<listName>"` so the same friend can
    // share multiple lists independently.

    /// Access grants for shared lists. `nil` value = `.forever` (no
    /// expiry). Persisted in-memory only for now — backend table for
    /// `shared_list_access(owner_id, list_name, recipient_id, expires_at)`
    /// is the natural place to make this durable once we wire it.
    var sharedListExpiries: [String: Date] = [:]

    /// Record the receiver's chosen access window for a freshly-accepted
    /// shared list. `.forever` clears any previous expiry so the user
    /// can upgrade a time-bounded grant to unlimited later.
    func recordSharedListAccess(
        listName: String,
        ownerID: String,
        duration: ShareAccessDuration
    ) {
        let key = "\(ownerID)::\(listName)"
        if let expiry = duration.expiryDate() {
            sharedListExpiries[key] = expiry
        } else {
            sharedListExpiries.removeValue(forKey: key)
        }
    }

    /// Convenience reader for shared-list tiles that want to show a
    /// "expires in N days" footer. Returns the expiry if one was
    /// recorded; `nil` means "forever" or "never accepted".
    func sharedListExpiry(ownerID: String, listName: String) -> Date? {
        sharedListExpiries["\(ownerID)::\(listName)"]
    }

    // MARK: - Incoming friend-request inbox
    //
    // The Activity tile renders this list at the top of the events page
    // as a real, server-driven inbox. Source of truth = the
    // `friend_requests` table; we refetch on every Activity-tile open so
    // the user never sees a stale row after acting from another device.

    /// Pending friend requests addressed to the current user. Drives the
    /// Activity-tab inbox section. Empty = no banner shown.
    var incomingFriendRequests: [IncomingFriendRequest] = []
    /// True while `refreshIncomingFriendRequests()` is in flight. Lets the
    /// UI show a subtle spinner the first time the inbox loads instead of
    /// briefly rendering "no requests".
    var incomingFriendRequestsLoading = false
    /// Request IDs the user already acted on this session. Used to fade
    /// the row out optimistically before the server confirms the delete /
    /// RPC — the next refresh removes it for real.
    var resolvedFriendRequestIDs: Set<String> = []

    /// Refetch the inbox from the backend. Fire-and-forget — UI reads
    /// the result via `incomingFriendRequests`.
    func refreshIncomingFriendRequests() {
        Task { @MainActor in
            incomingFriendRequestsLoading = true
            defer { incomingFriendRequestsLoading = false }
            do {
                let rows = try await contactsService.fetchIncomingRequests()
                // Filter out anything the user already accepted/rejected
                // earlier this session so the row doesn't flicker back in
                // before its delete has propagated.
                incomingFriendRequests = rows.filter { !resolvedFriendRequestIDs.contains($0.id) }
            } catch {
                #if DEBUG
                print("[MapViewModel] refreshIncomingFriendRequests failed: \(error)")
                #endif
            }
        }
    }

    /// Accept the request from `userID`. Optimistically removes the row,
    /// then calls the `accept_friend_request` RPC; on success we also pull
    /// fresh `friends` so the new friendship lights up immediately.
    func acceptFriendRequest(_ request: IncomingFriendRequest) {
        resolvedFriendRequestIDs.insert(request.id)
        incomingFriendRequests.removeAll { $0.id == request.id }
        Task { @MainActor in
            do {
                try await contactsService.acceptFriendRequest(fromUserID: request.id)
                // Friendship is now real — refresh the friends list so the
                // newly-accepted person appears in the Friends carousel +
                // their pins start participating in friend filters.
                await reloadFriends()
            } catch {
                #if DEBUG
                print("[MapViewModel] acceptFriendRequest failed: \(error)")
                #endif
                // Roll back optimistic removal so the user can retry.
                resolvedFriendRequestIDs.remove(request.id)
                refreshIncomingFriendRequests()
            }
        }
    }

    /// Reject the request from `userID`. Same optimistic pattern as accept,
    /// minus the friends reload (nothing new to surface).
    func rejectFriendRequest(_ request: IncomingFriendRequest) {
        resolvedFriendRequestIDs.insert(request.id)
        incomingFriendRequests.removeAll { $0.id == request.id }
        Task { @MainActor in
            do {
                try await contactsService.rejectFriendRequest(fromUserID: request.id)
            } catch {
                #if DEBUG
                print("[MapViewModel] rejectFriendRequest failed: \(error)")
                #endif
                resolvedFriendRequestIDs.remove(request.id)
                refreshIncomingFriendRequests()
            }
        }
    }

    /// Reload the friends list after a successful accept. Pulled into its
    /// own helper so the call site stays readable.
    private func reloadFriends() async {
        do {
            self.friends = try await userService.fetchFriends(for: userID)
        } catch {
            #if DEBUG
            print("[MapViewModel] reloadFriends after accept failed: \(error)")
            #endif
        }
    }

    // MARK: - Availability flow
    //
    // Three entry points used by the UI:
    //   • `availabilityState(for:)`     — read the current button state
    //                                      for a given place.
    //   • `checkAvailability(for:)`     — kick off (or cache-hit) the AI
    //                                      lookup. Idempotent per place.
    //   • `presentAvailabilityResult()` — surface the result in the AI
    //                                      bar after the user taps "Done".

    /// Convenience reader used by PlaceCardSheet to decide which button
    /// label/animation to render. Defaults to `.idle` for places we
    /// haven't checked yet.
    func availabilityState(for placeID: String) -> AvailabilityState {
        availabilityStatus[placeID] ?? .idle
    }

    /// Start the AI lookup for `place`. Safe to call multiple times — the
    /// router caches by place.id so repeat taps are instant. While the
    /// network call is in flight, the place's status is `.loading`, which
    /// PlaceCardSheet's availability button reads to show the sparkle
    /// animation. Errors surface as `.ready` with an empty result so the
    /// UI still progresses past the loading state.
    @MainActor
    func checkAvailability(for place: Place) async {
        // No-op if we're already mid-flight or already done.
        switch availabilityState(for: place.id) {
        case .loading, .ready: return
        case .idle: break
        }
        availabilityStatus[place.id] = .loading
        do {
            let result = try await availabilityService.findPlatforms(for: place)
            availabilityStatus[place.id] = .ready(result)
            // Two-beat success haptic so the user feels the AI
            // finishing — pairs with the button's morph to "Done ✓".
            Haptics.success()
        } catch {
            // The router itself already falls back to mock data on live
            // failures, so a thrown error here is genuinely unexpected.
            // Surface an empty result so the user still gets out of the
            // loading state — accompanied by an error notification so
            // the haptic vocabulary stays consistent.
            availabilityStatus[place.id] = .ready(
                AvailabilityResult(summary: "Couldn't reach the AI. Try again.", platforms: [])
            )
            Haptics.error()
        }
    }

    /// Tear down the place card and show the AI result bar (top-right
    /// overlay in MapHomeView). Called when the user taps the "Done"
    /// state of the Availability button.
    @MainActor
    func presentAvailabilityResult(for place: Place) {
        guard case .ready(let result) = availabilityState(for: place.id) else { return }
        availabilityResult = result
        availabilityResultPlace = place
        // Dismiss the card so the bar has the screen to itself.
        withAnimation(SomedayAnimations.inTileNav) {
            selectedPlace = nil
        }
    }

    /// Close the AI result bar.
    @MainActor
    func dismissAvailabilityResult() {
        withAnimation(SomedayAnimations.inTileNav) {
            availabilityResult = nil
            availabilityResultPlace = nil
        }
    }

    // MARK: - Tonight check
    //
    // Public surface used by PlaceCardSheet to render the "Tonight?" pill
    // inside the expanded Availability panel. Kicked off automatically
    // when the panel auto-expands after the AI lookup completes — the
    // user doesn't have to ask, the answer is just there.

    /// Result for a place, if we've already checked. Returns nil if we
    /// haven't checked yet OR if the check is mid-flight.
    func tonightCheck(for placeID: String) -> AvailabilityCheck? {
        tonightCheckResults[placeID]
    }

    /// True while a check is in flight for this place — drives the
    /// spinner state on the "Tonight?" pill.
    func isCheckingTonight(for placeID: String) -> Bool {
        tonightCheckLoading.contains(placeID)
    }

    /// Fire the tonight check. Idempotent: re-calling while a check is
    /// in flight is a no-op; re-calling after a result is cached returns
    /// instantly because the router caches by `place|date|party`.
    @MainActor
    func checkTonight(for place: Place, partySize: Int = 2) async {
        if tonightCheckLoading.contains(place.id) { return }
        // If we already have a result for tonight, don't refire — the
        // user can tap the pill to refresh in a future iteration.
        if tonightCheckResults[place.id] != nil { return }
        tonightCheckLoading.insert(place.id)
        defer { tonightCheckLoading.remove(place.id) }
        do {
            let result = try await reservationCheckService.check(
                place: place,
                date: Date(),
                partySize: partySize
            )
            tonightCheckResults[place.id] = result
            // Tiny haptic when a real answer lands — only on a positive
            // result so the user isn't buzzed every check. Errors / unknown
            // stay silent.
            if case .open = result { Haptics.tap() }
        } catch {
            // Treat thrown errors as `.error` so the pill stops spinning
            // and the user sees a stable end state. The router already
            // falls back to mock on live failures, so reaching here is
            // genuinely unexpected.
            tonightCheckResults[place.id] = .error
        }
    }
}

/// Status of the AI availability lookup for a single place. Drives the
/// three visual states of the Availability button on PlaceCardSheet.
enum AvailabilityState: Equatable {
    case idle
    case loading
    case ready(AvailabilityResult)
}

/// How to travel a point-to-point route. Maps 1:1 onto MapKit's
/// `MKDirectionsTransportType`. `walking` is the default because Someday
/// is a city/neighbourhood app — most "how do I get from X to Y" asks are
/// short hops on foot — but the readout lets the user flip to driving or
/// transit (transit availability varies by region; MapKit returns an
/// error where it has no transit data, which the readout surfaces).
enum RouteTravelMode: String, CaseIterable, Equatable {
    case walking
    case driving
    case transit

    var transportType: MKDirectionsTransportType {
        switch self {
        case .walking: return .walking
        case .driving: return .automobile
        case .transit: return .transit
        }
    }

    /// Short label for the segmented toggle.
    var label: String {
        switch self {
        case .walking: return "Walk"
        case .driving: return "Drive"
        case .transit: return "Transit"
        }
    }

    /// Lower-case noun for error copy ("No walking route…").
    var noun: String {
        switch self {
        case .walking: return "walking"
        case .driving: return "driving"
        case .transit: return "transit"
        }
    }

    /// SF Symbol for the toggle button.
    var icon: String {
        switch self {
        case .walking: return "figure.walk"
        case .driving: return "car.fill"
        case .transit: return "tram.fill"
        }
    }
}

/// An active point-to-point route between two of the user's saved pins.
/// Holds both endpoints (resolved to coordinates up front so a later
/// delete of the pin can't strand the computation), the chosen travel
/// mode, and the computed result (polyline + ETA + distance) once
/// `MKDirections` returns. `isLoading` / `errorMessage` drive the readout's
/// spinner and failure states. Not `Equatable` — it carries a class-backed
/// `MKPolyline` and `CLLocationCoordinate2D`s, and nothing diffs it.
struct ActiveRoute {
    let fromID: String
    let toID: String
    let fromName: String
    let toName: String
    let fromCoord: CLLocationCoordinate2D
    let toCoord: CLLocationCoordinate2D
    var mode: RouteTravelMode
    var polyline: MKPolyline?
    var travelTime: TimeInterval?
    var distance: CLLocationDistance?
    var isLoading: Bool
    var errorMessage: String?
}

/// A list the user created in-app, with an optional cover image used as
/// the background of its tile in the Lists grid.
struct CustomList: Identifiable, Equatable {
    let id: UUID
    var name: String
    var imageData: Data?
    var placeIDs: [String] = []

    /// Mints a fresh `id` by default — used by the UI when the user
    /// creates a list locally. `SupabaseListService.fetchLists` reuses
    /// the DB-stored UUID so the in-memory model and the row share an id.
    init(id: UUID = UUID(), name: String, imageData: Data? = nil, placeIDs: [String] = []) {
        self.id = id
        self.name = name
        self.imageData = imageData
        self.placeIDs = placeIDs
    }
}
