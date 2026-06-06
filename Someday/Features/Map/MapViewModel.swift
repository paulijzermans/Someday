import SwiftUI
import MapKit

@Observable
final class MapViewModel {
    var places: [Place] = []
    var friends: [UserProfile] = []
    var selectedPlace: Place?
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
    private let userID: String

    init(services: ServiceContainer, userID: String) {
        self.placeService = services.places
        self.userService = services.users
        self.searchService = services.search
        self.extractionService = services.extraction
        self.availabilityService = services.availability
        self.reservationCheckService = services.reservationCheck
        self.listService = services.lists
        self.userID = userID
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
    func buildChatContext() -> ChatContext {
        let mine     = places.filter { $0.ownerID == userID }
        let theirs   = places.filter { $0.ownerID != userID && !$0.ownerID.isEmpty }
        let userName = friends.first(where: { $0.id == userID })?.name ?? ""
        return ChatContextBuilder.build(
            userName: userName,
            myPlaces: mine,
            friendPlaces: theirs,
            lists: customLists,
            friends: friends
        )
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
        } catch {
            // Gracefully handle — keep existing data
        }

        // (toast suppressed for demo screenshot)
        // DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        //     withAnimation(.spring(response: 0.5)) {
        //         self.showSavedToast = true
        //     }
        // }
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
        withAnimation(SomedayAnimations.inTileNav) {
            selectedPlace = place
        }
    }

    func dismissPlace() {
        withAnimation(SomedayAnimations.inTileNav) {
            selectedPlace = nil
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
        // When previewing a friend's list, the map shows only that list's pins
        // so the user can decide whether to Add them to their own map.
        if let preview = previewedList { return preview.places }
        guard let friendID = filteredFriendID else { return places }
        return places.filter { $0.visitedByIDs.contains(friendID) || $0.recommendedBy == friendID }
    }

    // MARK: - List preview

    /// Resolves a friend's named list into a `PreviewedList` (zooming the map
    /// to fit the pins) and shows it on the map. Called from the Activity
    /// feed when the user taps one of the in-tile list tiles.
    func showListPreview(owner: UserProfile, listName: String) {
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
    @MainActor
    func deleteCustomList(name: String) async {
        guard let idx = customLists.firstIndex(where: { $0.name == name }) else { return }
        let listID = customLists[idx].id.uuidString
        withAnimation(SomedayAnimations.tile) {
            customLists.removeAll { $0.id == customLists[idx].id }
        }
        Haptics.warning()
        Task {
            do {
                try await listService.deleteList(listID: listID)
            } catch {
                #if DEBUG
                print("[MapViewModel] deleteList failed for \(listID): \(error)")
                #endif
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
        // Mutate local state immediately so the UI doesn't wait on the
        // network round-trip. The write is fire-and-forget below.
        withAnimation(SomedayAnimations.tile) {
            customLists.append(newList)
        }
        Task {
            do {
                try await listService.createList(newList, ownerID: userID)
                // Stamp any initial memberships — useful when a list is
                // created with a pre-seeded `placeIDs` array (currently
                // unused by the UI but the contract supports it).
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
