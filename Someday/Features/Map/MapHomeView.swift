import SwiftUI
import MapKit

struct MapHomeView: View {
    let appState: AppState
    @State private var vm: MapViewModel
    @State private var aiSuggestionIndex = 0
    /// Drives the soft 1.4-second pulse on the sparkle icon so the input
    /// feels alive without distracting from typing.
    @State private var aiSparklePulse = false
    /// Slowly orbits the gradient stroke around the input — gives the bar
    /// that "AI is thinking" shimmer without explicit motion graphics.
    @State private var aiBorderStart: UnitPoint = .topLeading
    @State private var aiBorderEnd: UnitPoint = .bottomTrailing
    @State private var aiBorderOpacity: Double = 0.55
    /// Toggles the `ChatSheet` modal. The aiChatBar's sparkles icon is
    /// the entry point — tap it to open the chat with full map context.
    /// Inline AI chat. Owned by the screen so the conversation
    /// persists across pans/zooms/pin taps without a sheet getting in
    /// the way of the map. Rendered as a dropdown panel under the
    /// top-right AI bar (mirroring where the old search results lived).
    @State private var chat: ChatViewModel
    /// Pending drag-to-merge request from the Lists tile. Held at this
    /// level (not inside ListsGridView) so the confirmation alert doesn't
    /// race with the tile dismissing — alerts presented from a view
    /// that's simultaneously dismissing reliably crash on iOS.
    @State private var pendingMerge: PendingMergeRequest?
    /// Pending "Delete list" request from a list tile's context menu.
    /// Same rationale as `pendingMerge` for living at the parent.
    @State private var pendingDelete: PendingDeleteRequest?
    /// Focus state for the AI chat input — gives us programmatic control
    /// to dismiss the keyboard from the keyboard accessory toolbar's
    /// chevron-down button and from a swipe-down gesture on the panel.
    @FocusState private var chatInputFocused: Bool
    /// True while the locate-me button is awaiting a `CLLocation`
    /// (after the user tapped). Drives a soft pulse on the icon and
    /// disables the button to prevent re-fire while the request is
    /// in flight.
    @State private var isLocating: Bool = false
    /// Whether the map should render the standard pulsing blue user-
    /// location dot. Off by default — we only flip it on after the
    /// user explicitly taps the locate-me button and grants
    /// permission. Matches the Info.plist promise of "only when you
    /// tap" and matches Apple's HIG (don't show the dot until the
    /// user has opted in).
    @State private var showUserLocationDot: Bool = false
    /// True when the user opened the chat by tapping the lime + button
    /// in the bottom tab bar. Drives the welcome-tile pair (`TileTop`
    /// above the transcript, `TileBottom` pinned to the navigation
    /// bar) that brackets the chat while the conversation is empty.
    /// Cleared as soon as the user sends a message or types — the
    /// tiles are a starting screen, not a permanent fixture.
    @State private var showWelcomeTiles: Bool = false
    /// On-device speech recognition for the mic button in the AI bar.
    /// Singleton because only one mic session can be alive at a time
    /// on iOS — multiple owners would just clobber each other.
    @State private var speech = SpeechRecognitionService.shared

    /// Identifiable carrier for the merge alert. SwiftUI's `.alert(item:)`
    /// keys lifecycle off this value.
    struct PendingMergeRequest: Identifiable {
        let source: String
        let target: String
        var id: String { "\(source)➡︎\(target)" }
    }

    /// Identifiable carrier for the delete alert.
    struct PendingDeleteRequest: Identifiable {
        let name: String
        var id: String { name }
    }

    /// Rotating placeholder hints. The bar is purely an AI input now —
    /// no live location search — so the prompts coach the user toward
    /// questions Claude can actually answer with their map context.
    private let aiSuggestions = [
        "Ask anything about your map…",
        "What's fun around this pin?",
        "Best coffee I've saved nearby?",
        "Compare two of my places…",
        "What's in my Hidden gems list?",
        "Recommend somewhere new here…"
    ]

    private let suggestionTimer = Timer.publish(every: 5.0, on: .main, in: .common).autoconnect()

    init(appState: AppState) {
        self.appState = appState
        let mapVM = MapViewModel(
            services: appState.services,
            userID: appState.currentUser?.id ?? "user_paul"
        )
        self._vm = State(initialValue: mapVM)
        // Inline AI chat lives in the top-right search bar. The view
        // model is owned by the screen (not a sheet) so the conversation
        // persists while the user pans/zooms and inspects pins between
        // questions. Context is rebuilt per-send from the latest map
        // state via the closure below.
        self._chat = State(initialValue: ChatViewModel(
            chatService: appState.services.chat,
            contextProvider: { [weak mapVM] in mapVM?.buildChatContext() ?? ChatContext.empty },
            // Apply chat-driven mutations (create_list, delete_place, …)
            // through the same MapViewModel methods the UI calls. Local
            // state updates immediately, Supabase persists in the
            // background — same optimistic policy as user-driven edits.
            mutationApplier: { [weak mapVM] mutation in
                guard let vm = mapVM else { return }
                Task { @MainActor in
                    switch mutation {
                    case .createList(let name):
                        vm.createList(name: name, imageData: nil, placeIDs: [])
                    case .deleteList(let name):
                        await vm.deleteCustomList(name: name)
                    case .createPlace(let name, let lat, let lon, let cat, let listName):
                        // The server already validates the category
                        // string against the allowed set; if a future
                        // server version slips through something
                        // unexpected, fall back to .food so we still
                        // drop the pin rather than no-oping.
                        let category = PlaceCategory(rawValue: cat) ?? .food
                        _ = await vm.savePlaceFromChat(
                            name: name,
                            latitude: lat,
                            longitude: lon,
                            category: category,
                            addToListNamed: listName
                        )
                    case .deletePlace(let id):
                        await vm.deletePlaceFromChat(placeID: id)
                    }
                }
            }
        ))
    }

    var body: some View {
        ZStack {
            mapLayer
            aiSuggestionHintLayer
            savedToastLayer
            searchLayer
            friendFilterBanner
            profileLayer
            placeCardLayer
            // Floating tiles. Their scrims absorb taps for tap-outside-
            // to-dismiss — that's why the tab bar + feedback pill render
            // AFTER these layers, on top, so tab-switching never gets
            // intercepted by the scrim.
            listsLayer
            createListLayer
            activityLayer
            addSourcesLayer
            feedbackTileLayer
            // Chrome that stays interactive even when a tile is up.
            bottomBarLayer
            feedbackLayer
            // previewListLayer intentionally NOT rendered — the small
            // "Cancel / Add" action bar was visually noisy on top of
            // the friend's list once it was already filtering the map.
            // Exit paths kept clean elsewhere: tapping a friend's list
            // a second time toggles the preview off, and tapping any
            // of your own lists clears it too. The layer + the
            // VM helpers (`acceptListPreview`, `cancelListPreview`)
            // remain in the source so we can bring the bar back as a
            // bottom-sheet later if needed.
            // previewListLayer
            // Top-of-screen confirmation after an import completes.
            importSummaryLayer
            shareRequestLayer
            // First-run onboarding flow — overlays everything else when
            // `appState.isOnboarding` is true, so the user always sees
            // the current step until they finish.
            onboardingLayer
            // NOTE: the AI Availability result used to render here as a
            // floating top-right bar (`availabilityBarLayer`). It now
            // expands inline inside `PlaceCardSheet` directly below the
            // Availability button — the card slides upward to reveal the
            // booking platforms. The bar view + layer remain in the file
            // for reference but are no longer wired into the layer stack.
        }
        .sheet(isPresented: $vm.showFriends) {
            FriendsListView(places: vm.places, friends: vm.friends) { friendID in
                vm.showFriendPlaces(friendID: friendID)
            }
        }
        .sheet(isPresented: $vm.showReservation) {
            if let place = vm.selectedPlace {
                ReservationView(place: place, initialDate: vm.reservationMode.initialDate) {
                    vm.showReservation = false
                    vm.dismissPlace()
                }
            }
        }
        .sheet(isPresented: $vm.showShareSheet) {
            ShareSheet(items: [vm.shareText])
        }
        .sheet(isPresented: $vm.showImportList) {
            ImportListView { newPlaces in
                Task {
                    await vm.importPlaces(newPlaces)
                    vm.presentImportSummary(.init(places: newPlaces, source: .list))
                }
            }
        }
        .sheet(isPresented: $vm.showMapsImport) {
            LinkImportView(
                source: .googleMaps,
                prefilledURL: vm.prefillImportURL,
                onImport: { newPlaces in
                    Task {
                        await vm.importPlaces(newPlaces)
                        vm.presentImportSummary(.init(places: newPlaces, source: .googleMaps))
                    }
                },
                parseURL: { url in
                    try await vm.parseGoogleMaps(url: url)
                }
            )
            .onDisappear { vm.prefillImportURL = nil }
        }
        .sheet(isPresented: $vm.showProfile) {
            if let user = appState.currentUser {
                ProfileView(
                    appState: appState,
                    // Place count = pins this user owns + any place that
                    // appears in one of their custom lists. The OR-with-
                    // custom-lists half catches places imported via the
                    // onboarding flow where `ownerID` may have been the
                    // anonymous import bot's UUID rather than the user's.
                    placeCount: profilePlaceCount(for: user),
                    reviewCount: vm.places.filter { $0.ownerID == user.id && $0.review != nil }.count,
                    friendCount: vm.friends.count,
                    friendAvatars: vm.friends,
                    onSignOut: {
                        vm.showProfile = false
                        appState.signOut()
                    },
                    onOpenFriends: {
                        // Tapping the Friends action tile in Profile → pop
                        // the Activity tile open. The user starts on the
                        // events page; second tab dot = friends list.
                        withAnimation(SomedayAnimations.tile) {
                            vm.showActivity = true
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $vm.showSocialsImport) {
            LinkImportView(
                source: .instagram,
                prefilledURL: vm.prefillImportURL,
                onImport: { newPlaces in
                    Task {
                        await vm.importPlaces(newPlaces)
                        vm.presentImportSummary(.init(places: newPlaces, source: .instagram))
                    }
                },
                parseURL: { url in
                    try await vm.parseInstagram(url: url)
                }
            )
            .onDisappear { vm.prefillImportURL = nil }
        }
        .task { await vm.loadData() }
        // External imports arriving via the Share Extension / Safari deep
        // links land in AppState.pendingImportURL. Route to the matching
        // sheet here so the user lands directly on the import preview.
        .onChange(of: appState.pendingImportURL) { _, newValue in
            handlePendingImport(newValue)
        }
        .onAppear { handlePendingImport(appState.pendingImportURL) }
        // Drag-to-merge confirmation. Phrasing matches the user's
        // mental model: the dragged list is "merged with" the target,
        // then deleted. Hosted at the MapHomeView level (NOT on the
        // Lists tile) so the alert never overlaps a dismissing host —
        // that combination crashes on iOS.
        .alert(item: $pendingMerge) { merge in
            Alert(
                title: Text("Merge \"\(merge.source)\" with \"\(merge.target)\"?"),
                message: Text("Pins from \"\(merge.source)\" will be moved into \"\(merge.target)\", then \"\(merge.source)\" will be deleted."),
                primaryButton: .destructive(Text("Merge")) {
                    Task { await vm.mergeCustomList(source: merge.source, into: merge.target) }
                    // Close the Lists tile once the user has committed —
                    // they're done with the picker for this gesture.
                    withAnimation(SomedayAnimations.tile) {
                        vm.showOverlay(nil)
                    }
                    pendingMerge = nil
                },
                secondaryButton: .cancel { pendingMerge = nil }
            )
        }
        // iPhone-style removal — the context menu raises this alert
        // when the user picks "Delete list". Now deletes the list AND
        // every pin inside it (single-list invariant means pins belong
        // to exactly this list, so it's safe). The message also warns
        // that friends with whom this list was shared keep their
        // copy on the server — our delete only touches the owner's
        // rows.
        .alert(item: $pendingDelete) { request in
            let pinCount = vm.customLists.first(where: { $0.name == request.name })?.placeIDs.count ?? 0
            let pinPhrase = pinCount == 1 ? "1 pin" : "\(pinCount) pins"
            return Alert(
                title: Text("Delete \"\(request.name)\"?"),
                message: Text(
                    "This removes the list and \(pinPhrase) inside it from your map.\n\n"
                    + "If you've shared this list with friends, they'll keep their copy — deleting it here only removes it from your account."
                ),
                primaryButton: .destructive(Text("Delete")) {
                    Task { await vm.deleteCustomList(name: request.name) }
                    pendingDelete = nil
                },
                secondaryButton: .cancel { pendingDelete = nil }
            )
        }
    }

    /// Sends the current search-bar text to the inline AI chat. The
    /// conversation renders in a dropdown panel right under the bar —
    /// no sheet — so the user keeps full visibility of the map (and
    /// the selected pin / visible pins that fuel the answer).
    private func askChat() {
        let trimmed = vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.inputText = trimmed
        vm.searchText = ""
        Task { await chat.send() }
    }

    /// Wipes the inline AI conversation. Called from the bar's clear
    /// affordance and when the user collapses the search bar entirely.
    /// Also clears any breadcrumb AI-suggestion pins on the map — they
    /// belong to the conversation and shouldn't outlive it.
    private func clearChat() {
        chat.messages.removeAll()
        chat.errorMessage = nil
        vm.clearAISuggestionPins()
        // The welcome tile pair (TileTop + TileBottom) is a "+ button"
        // affordance only — clearing the conversation must also clear
        // its flag, otherwise the next time the user opens the bar
        // via the AI search button the tiles would re-appear
        // unwanted.
        showWelcomeTiles = false
    }

    /// Open the chat panel pre-seeded with an "I'm here to help you
    /// add stuff" message. Triggered by the + button in the bottom
    /// tab bar. Keeping the seed as a normal assistant ChatMessage
    /// means the user sees it land in the transcript exactly like a
    /// model reply, so the affordance reads as "the AI is ready to
    /// help" rather than a one-off banner.
    @MainActor
    private func openChatForAdding() {
        withAnimation(SomedayAnimations.tile) {
            vm.showSearch = true
            // Show the welcome tile pair — TileTop (three placeholder
            // animations) and TileBottom (empty same-size placeholder
            // pinned to the nav bar) — while the chat is still a
            // blank slate. We hide them the moment a message lands
            // so the transcript has room.
            if chat.messages.isEmpty {
                showWelcomeTiles = true
            }
        }
        // Focus the input so the keyboard slides up — the user can
        // start typing immediately without an extra tap.
        chatInputFocused = true
    }

    /// Handles a tap on a link inside an AI reply. Recognises three
    /// custom schemes:
    ///
    ///   • `someday://place/<id>`
    ///     A saved pin. Recenters the map and opens the place card.
    ///     Accepts the full UUID or an 8-char prefix (Edge Function
    ///     compresses IDs in the prompt).
    ///
    ///   • `someday://suggest?lat=…&lon=…&name=…&category=…`
    ///     A venue the AI found online via web_search that ISN'T on the
    ///     user's map. Recenters on the coordinate and shows a transient
    ///     "AI suggested here" hint banner so the user has context.
    ///
    ///   • `someday://list/<URL-encoded name>`
    ///     One of the user's saved lists. Focuses the map on the places
    ///     in that list (selects the list as a friend-style filter and
    ///     fits the camera to those pins).
    ///
    /// Before either action runs, we **minimize the AI bar** and
    /// **dismiss any open PlaceCardSheet**. Otherwise the chat panel
    /// (and possibly a previously-opened pin's card) would sit on top
    /// of the map and hide the very thing the user just asked to be
    /// taken to. The chat thread itself is NOT cleared — re-tapping the
    /// AI button restores the conversation.
    ///
    /// Anything else hits the system handler so http(s) links still
    /// open in Safari.
    private func handleChatLinkTap(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "someday" else { return .systemAction }

        switch url.host {
        case "place":
            // `URL.path` looks like "/<id>"; drop the leading slash.
            let raw = url.path.split(separator: "/").first.map(String.init)
                ?? url.lastPathComponent
            guard !raw.isEmpty else { return .discarded }
            collapseChrome()
            return vm.focusOnPlaceLink(raw) ? .handled : .discarded

        case "suggest":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard
                let items = comps?.queryItems,
                let latStr = items.first(where: { $0.name == "lat" })?.value,
                let lonStr = items.first(where: { $0.name == "lon" })?.value,
                let lat = Double(latStr),
                let lon = Double(lonStr)
            else { return .discarded }
            let name = items.first(where: { $0.name == "name" })?.value ?? "Suggested place"
            let category = items.first(where: { $0.name == "category" })?.value
            collapseChrome()
            vm.focusOnAISuggestion(name: name, category: category, latitude: lat, longitude: lon)
            return .handled

        case "list":
            // `URL.path` looks like "/<encoded list name>"; strip the
            // leading slash and percent-decode so spaces survive.
            let raw = url.path.hasPrefix("/")
                ? String(url.path.dropFirst())
                : url.path
            let decoded = raw.removingPercentEncoding ?? raw
            guard !decoded.isEmpty else { return .discarded }
            collapseChrome()
            return vm.focusOnList(named: decoded) ? .handled : .discarded

        default:
            return .systemAction
        }
    }

    /// Tidies the map screen before the chat-link routing focuses on a
    /// new place. Dismisses any open place card (so the new pin's card
    /// has a clean entrance) and minimises the AI bar (so the user can
    /// actually see the spot the AI sent them to). The chat thread is
    /// preserved — tapping the AI button restores it.
    private func collapseChrome() {
        withAnimation(SomedayAnimations.tile) {
            if vm.selectedPlace != nil {
                vm.selectedPlace = nil
            }
            vm.showSearch = false
        }
    }

    /// Kicks off the gradient-orbit + opacity shimmer on the AI chat
    /// bar's border. The two endpoints rotate around the bar with a
    /// slow ease, giving a "the AI is alive and listening" feel.
    private func startAIBorderAnimation() {
        withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
            aiBorderStart = .bottomTrailing
            aiBorderEnd = .topLeading
            aiBorderOpacity = 0.85
        }
    }

    /// Reads a pending external-import URL out of `AppState` and pops the
    /// matching sheet. We clear `appState.pendingImportURL` immediately so
    /// the sheet's `prefilledURL` reads it once via `vm.prefillImportURL`
    /// and we never fire the same import twice.
    private func handlePendingImport(_ pending: AppState.PendingImport?) {
        guard let pending else { return }
        switch pending {
        case .instagram(let url):
            // Skip the LinkImportView "paste a URL" step entirely — the
            // URL is already known. Go straight to the loading tile.
            Task { await vm.startInstagramImport(url: url.absoluteString) }
        case .googleMaps(let url):
            vm.prefillImportURL = url.absoluteString
            vm.showMapsImport = true
        }
        appState.pendingImportURL = nil
    }

    /// Best-effort: pull an Instagram or TikTok URL out of the system
    /// clipboard. We use `NSDataDetector` (same logic LinkImportView uses
    /// for the manual paste flow) so it tolerates "Check this out: <url>"
    /// style share copy. Returns `nil` when the clipboard is empty or
    /// holds a non-social URL — caller falls back to the paste sheet.
    /// Resolve the "places" stat shown on the Profile hero card. Combines:
    ///   • pins this user owns (`ownerID == user.id`)
    ///   • places that appear in any of this user's `customLists` — covers
    ///     onboarding imports where the place row was inserted under the
    ///     anonymous bot rather than the user themselves.
    ///   • places this user has in their `lists` dict (legacy / mock data).
    /// Deduped so a place that satisfies multiple paths only counts once.
    private func profilePlaceCount(for user: UserProfile) -> Int {
        var ids = Set<String>()
        for p in vm.places where p.ownerID == user.id { ids.insert(p.id) }
        for list in vm.customLists { for pid in list.placeIDs { ids.insert(pid) } }
        for (_, pids) in user.lists { for pid in pids { ids.insert(pid) } }
        return ids.count
    }

    private func instagramURLFromClipboard() -> String? {
        guard let text = UIPasteboard.general.string, !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range),
              let url = match.url else { return nil }

        let host = (url.host ?? "").lowercased()
        let isSocial = host.contains("instagram.com") ||
                       host.contains("tiktok.com") ||
                       host.contains("vm.tiktok.com")
        return isSocial ? url.absoluteString : nil
    }

    // MARK: - Map

    private var mapLayer: some View {
        ClusteredMapView(
            places: vm.visiblePlaces,
            region: $vm.region,
            onSelectPlace: { vm.selectPlace($0) },
            // Map every place to a list-name colour identity. Resolves
            // through the user's own lists first, then the previewed
            // friend's list, then any friend list that claims the id —
            // so shared pins on the map adopt their list's colour just
            // like own pins do, instead of falling back to the
            // friend-hash default.
            listNameFor: { place in vm.displayedListName(for: place) },
            // AI-proposed venues dropped via `someday://suggest?...`
            // links in the chat. Distinct lime pins; tapping re-shows
            // the transient hint banner with the venue name + a tap-
            // to-dismiss affordance so the user can clear it.
            suggestions: vm.aiSuggestionPins,
            onSelectSuggestion: { pin in
                vm.focusOnAISuggestion(
                    name: pin.name,
                    category: pin.category,
                    latitude: pin.latitude,
                    longitude: pin.longitude
                )
            },
            // Flipped on by `locateMe()` after the first granted fix
            // — MKMapView draws the standard pulsing blue dot and
            // keeps it live as the user moves.
            showsUserLocation: showUserLocationDot
        )
        .ignoresSafeArea()
        // Resolve the current city name whenever the viewport settles.
        // `scheduleCityResolve` debounces internally (300ms after the
        // last pan), and `CityResolver` caches by ~1km quantized coord
        // so panning within a city is free. `currentCityName` lands on
        // the VM and feeds into every chat send via `buildChatContext`.
        // `MKCoordinateRegion` isn't Equatable, so we watch the
        // centre lat/lon individually — same effect, equatable types.
        .onAppear { vm.scheduleCityResolve() }
        .onChange(of: vm.region.center.latitude)  { _, _ in vm.scheduleCityResolve() }
        .onChange(of: vm.region.center.longitude) { _, _ in vm.scheduleCityResolve() }
    }

    // MARK: - Saved Toast

    @ViewBuilder
    private var savedToastLayer: some View {
        if vm.showSavedToast {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .zIndex(99)

            VStack {
                Spacer()
                SavedToastCard { vm.dismissToast() }
                Spacer()
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
            .zIndex(100)
        }
    }

    /// Floating glass pill anchored above the bottom tab bar that
    /// surfaces a venue the AI chat just sent the user to via
    /// `someday://suggest?...`. Since these venues aren't on the user's
    /// map, the recenter alone would feel like a no-op — the pill gives
    /// it context ("AI suggested ___ here") and auto-dismisses after a
    /// few seconds. Tap to dismiss sooner.
    @ViewBuilder
    private var aiSuggestionHintLayer: some View {
        if let hint = vm.aiSuggestionHint {
            VStack {
                Spacer()
                Button {
                    Haptics.soft()
                    vm.dismissAISuggestionHint()
                } label: {
                    HStack(spacing: 10) {
                        // Lime mini-pin matching the on-map AI suggestion
                        // pin (same MapPinShape, same lime fill, same
                        // white border) so the slider visually echoes
                        // the pin that just dropped. Format-consistent
                        // with chat pills and the on-map pin family.
                        ZStack {
                            MapPinShape().fill(.white)
                            MapPinShape().fill(SomedayColors.lime).padding(1.5)
                        }
                        .frame(width: 14, height: 18)
                        .shadow(color: .black.opacity(0.18), radius: 1.2, y: 0.5)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(hint.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(SomedayColors.charcoal)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text("AI suggested here")
                                    .font(.system(size: 11))
                                    .foregroundColor(SomedayColors.grayMedium)
                                if let cat = hint.category, !cat.isEmpty {
                                    Text("•")
                                        .font(.system(size: 11))
                                        .foregroundColor(SomedayColors.grayMedium)
                                    Text(cat)
                                        .font(.system(size: 11))
                                        .foregroundColor(SomedayColors.grayMedium)
                                }
                            }
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(SomedayColors.grayMedium)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(SomedayColors.primary.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 30)
                // Sit above the tab bar / feedback pill area.
                .padding(.bottom, 140)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(95)
        }
    }

    // MARK: - Search / AI

    private var searchLayer: some View {
        VStack(spacing: 8) {
            HStack {
                if vm.showSearch {
                    aiChatBar
                } else {
                    Spacer()
                    aiButton
                }
            }
            .padding(.top, 8)

            // NOTE: the inline AI conversation lives INSIDE the
            // `aiChatBar` container (so the input + transcript share
            // one glass+gradient surface and visually feel like the
            // bar is expanding downward, not dropping a separate
            // card).
            //
            // `TileTop` sits as a SIBLING right below the bar — it's
            // a standalone surface that shows three (eventually-real)
            // animation slots in a horizontally scrollable row.
            // `TileBottom` is its mirror, pinned to the navigation
            // bar with the same gap. Both are shown together while
            // the conversation is a blank slate (the user just opened
            // chat via the + button); the moment a message lands,
            // both retire so the transcript has the screen.
            if showWelcomeTiles && chat.messages.isEmpty && vm.showSearch {
                TileTop()
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()

            // tile_bottom — empty same-size companion pinned to the
            // bottom. Sits with its bottom edge against the floating
            // capsule tab bar with the same inset the preview action
            // bar uses (96pt above the screen bottom — capsule height
            // + the 16pt safe-area gap), so the spacing reads as the
            // navigation-bar gap, not as a random offset.
            if showWelcomeTiles && chat.messages.isEmpty && vm.showSearch {
                TileBottom()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Hide the search affordance while any floating tile is up so the
        // overlay reads as the only thing on screen. Also disable hit-test
        // so the invisible button doesn't silently swallow taps meant for
        // the scrim or the tab bar underneath.
        .opacity(anyOverlayOpen ? 0 : 1)
        .allowsHitTesting(!anyOverlayOpen)
        .animation(SomedayAnimations.tile, value: anyOverlayOpen)
    }

    /// True when any floating tile is up. Single computed property keeps
    /// the search/profile fade rules in one place.
    private var anyOverlayOpen: Bool {
        vm.showLists || vm.showActivity || vm.showAddOptions || vm.showFeedback || vm.showShareRequest || vm.showCreateList || vm.lastImportSummary != nil
    }

    private var aiGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.55, green: 0.45, blue: 1.0),
                SomedayColors.primary,
                Color(red: 1.0, green: 0.45, blue: 0.80)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private var aiButton: some View {
        Button {
            withAnimation(SomedayAnimations.tile) {
                vm.showSearch = true
                // The AI button is a search/chat entry point, NOT
                // the "+ add anything" path. Make sure the welcome
                // tile flag is off here so the tile only ever shows
                // when the user explicitly tapped the + button.
                showWelcomeTiles = false
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                // When a minimised chat thread is waiting to be
                // restored (the user tapped an AI link, which sent them
                // to a pin and tucked the bar away), swap the icon to a
                // sparkle so the affordance reads as "tap to come back
                // to your AI conversation". Otherwise keep the
                // magnifier for the standard search affordance.
                Image(systemName: hasMinimizedChat ? "sparkles" : "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(hasMinimizedChat
                                     ? AnyShapeStyle(aiGradient)
                                     : AnyShapeStyle(SomedayColors.green))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .circle)

                // Small sparkle accent in the top-right corner — hints
                // at AI when collapsed in normal state; doubles as a
                // "thread waiting" dot when there's a minimised chat
                // (tinted lime so it reads as an unread indicator).
                Group {
                    if hasMinimizedChat {
                        Circle()
                            .fill(SomedayColors.lime)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    } else {
                        Image(systemName: "sparkle")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(aiGradient)
                            .padding(3)
                            .glassEffect(.regular, in: .circle)
                    }
                }
                .offset(x: 2, y: -2)
            }
        }
        .padding(.trailing, 16)
        .transition(.scale(scale: 0.5, anchor: .topTrailing).combined(with: .opacity))
    }

    /// True when there's an AI chat conversation in flight or completed
    /// but the bar is collapsed — e.g. the user tapped a chat link and
    /// the bar minimised itself to reveal the map. Drives the AI
    /// button's "thread waiting" state.
    private var hasMinimizedChat: Bool {
        !vm.showSearch && (!chat.messages.isEmpty || chat.isThinking)
    }

    // Floating profile avatar, positioned **directly below** the search
    // button in the top-right corner. Search button is 44pt + 8pt top
    // inset → place the avatar at top inset 60pt so there's a small gap.
    // The locate-me chip stacks beneath the avatar with the same trailing
    // alignment so the right edge reads as one column of round buttons.
    private var profileLayer: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                VStack(spacing: 10) {
                    profileButton
                    locateMeButton
                }
            }
            .padding(.top, 60)       // sits just below the search button
            .padding(.trailing, 18)
            Spacer()
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // Hide when any floating tile owns the screen — also when the
        // search bar expands to a full-width aiChatBar (would otherwise
        // be visually adjacent to the avatar in an awkward way).
        .opacity((anyOverlayOpen || vm.showSearch) ? 0 : 1)
        .allowsHitTesting(!(anyOverlayOpen || vm.showSearch))
        .animation(SomedayAnimations.tile, value: anyOverlayOpen)
        .animation(SomedayAnimations.tile, value: vm.showSearch)
    }

    private var profileButton: some View {
        Button {
            vm.showProfile = true
        } label: {
            AsyncImage(url: appState.currentUser?.avatarURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Circle().fill(SomedayColors.butter)
                        .overlay(
                            Text(appState.currentUser?.initials.prefix(1) ?? "?")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(SomedayColors.green)
                        )
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
    }

    /// Round 38pt glass button under the profile avatar. Tap → walk
    /// the location permission ladder (request once on first use) and,
    /// when authorized, recenter the map on the user's current fix.
    /// Stays compact + minimal — no label, just the SF Symbol — so it
    /// fits cleanly beneath the profile avatar without crowding the
    /// top-right chrome.
    private var locateMeButton: some View {
        Button {
            Haptics.tap()
            Task { await locateMe() }
        } label: {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.85))
                Image(systemName: isLocating ? "location.fill" : "location")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SomedayColors.primary)
                    // Subtle pulse while we're awaiting the fix —
                    // mirrors the AI sparkle's idle pulse so "the app
                    // is working on it" reads the same everywhere.
                    .scaleEffect(isLocating ? 1.08 : 1.0)
                    .opacity(isLocating ? 0.85 : 1.0)
                    .animation(
                        isLocating
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .default,
                        value: isLocating
                    )
            }
            .frame(width: 38, height: 38)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(isLocating)
    }

    /// Walk the permission ladder, then (on success) animate the map
    /// camera to the user's fix. Soft haptic on resolution; silent on
    /// denial (the system prompt already conveyed it).
    @MainActor
    private func locateMe() async {
        isLocating = true
        defer { isLocating = false }
        let location = await UserLocationService.shared.currentLocation()
        guard let location else { return }
        // Flip on the standard pulsing blue dot before recentering so
        // it's already drawing by the time the camera settles. Stays
        // on for the rest of the session — re-taps just recenter; the
        // dot keeps tracking the user live via MKMapView.
        showUserLocationDot = true
        withAnimation(SomedayAnimations.inTileNav) {
            vm.region = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)
            )
        }
        Haptics.success()
    }

    /// The expanding AI surface in the top-right. Visually one glass
    /// capsule. When the thread is empty it's just `aiInputRow`. When
    /// a question has been asked, the transcript mounts ABOVE the
    /// input — the input row stays anchored at the bottom of the
    /// capsule (chat-app metaphor: you type at the bottom, replies
    /// stack upward). The whole thing shares one glass + gradient
    /// stroke so it reads as the bar growing, not stacking cards.
    private var aiChatBar: some View {
        VStack(spacing: 0) {
            if !chat.messages.isEmpty || chat.isThinking {
                aiConversationPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))

                // Hairline separator between the transcript and the
                // input. Keeps the input row visually distinct without
                // breaking the shared capsule.
                Divider()
                    .background(SomedayColors.grayMedium.opacity(0.25))
                    .padding(.horizontal, 14)
            }

            aiInputRow
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.45, blue: 1.0).opacity(aiBorderOpacity),
                            SomedayColors.primary.opacity(aiBorderOpacity),
                            Color(red: 1.0, green: 0.45, blue: 0.80).opacity(aiBorderOpacity)
                        ],
                        startPoint: aiBorderStart,
                        endPoint: aiBorderEnd
                    ),
                    lineWidth: 1.8
                )
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        // Swipe down anywhere on the whole AI bar (including the input
        // row) to dismiss the keyboard. The transcript scroll already
        // has `.scrollDismissesKeyboard(.interactively)`, but that only
        // fires when there are enough messages to drag — this gesture
        // covers the empty / short-transcript case so the user can
        // always "slide down the keyboard" no matter the state.
        // minimumDistance: 20 prevents this from interfering with taps
        // on the sparkle / mic / close buttons that share the bar.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height > 30 && chatInputFocused {
                        chatInputFocused = false
                    }
                }
        )
        .onAppear { startAIBorderAnimation() }
        .padding(.horizontal, 16)
        .animation(SomedayAnimations.tile, value: chat.messages.count)
        .animation(SomedayAnimations.tile, value: chat.isThinking)
        .transition(.scale(scale: 0.6, anchor: .topTrailing).combined(with: .opacity))
        // Suggestion rotation deliberately disabled — the placeholder
        // is now a static "Or drop URL / image here" string, so the
        // 5-second cycle is no longer relevant. `aiSuggestions` +
        // `suggestionTimer` are kept as dead state for now; remove
        // them in the next pass.
    }

    // NOTE: the live location-search dropdown was removed when this bar
    // became a pure AI input. `MapViewModel.search` / `addPlace(from:)`
    // and `LocationSearchService` are still on the VM in case we
    // re-introduce a dedicated "find a place to save" flow elsewhere.

    /// Just the input row content — no glass, no border, no shadow.
    /// Wrapped by `aiChatBar` together with the conversation panel so
    /// the chrome is shared (one capsule that grows when there's a
    /// transcript to show).
    private var aiInputRow: some View {
        HStack(spacing: 12) {
            // Tappable sparkle — submits the typed question to the AI,
            // or opens the field for a new ask when empty.
            Button {
                Haptics.tap()
                askChat()
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(aiGradient)
                    .scaleEffect(aiSparklePulse ? 1.08 : 0.92)
                    .opacity(aiSparklePulse ? 1.0 : 0.85)
                    .animation(
                        .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                        value: aiSparklePulse
                    )
                    .contentShape(Rectangle())     // larger hit target
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .onAppear { aiSparklePulse = true }

            ZStack(alignment: .leading) {
                if vm.searchText.isEmpty {
                    // Static placeholder — no rotation. Hints that the
                    // bar accepts a URL or image as well as a typed
                    // question (drop targets to follow). Keeping the
                    // copy stable avoids the text flicker that the
                    // rotating suggestions caused while typing was
                    // about to begin.
                    Text("Or drop URL / image here")
                        .font(.system(size: 16))
                        .foregroundColor(SomedayColors.grayMedium)
                        .allowsHitTesting(false)
                }
                TextField("", text: $vm.searchText)
                    .font(.system(size: 16))
                    .submitLabel(.send)
                    .focused($chatInputFocused)
                    // Pure AI input: typing does NOT do live location
                    // search. Submitting (Return / Send) hands the
                    // question to the inline AI chat below.
                    .onSubmit { askChat() }
                    // Keyboard accessory bar — gives the user an
                    // unambiguous "dismiss keyboard" affordance for the
                    // case where the transcript scroll isn't long
                    // enough to drag down interactively. Pairs with the
                    // `.scrollDismissesKeyboard(.interactively)` on
                    // `scrollableTranscript` (swipe down on messages)
                    // and the drag-down gesture on the panel below.
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button {
                                chatInputFocused = false
                            } label: {
                                Image(systemName: "keyboard.chevron.compact.down")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(SomedayColors.charcoal)
                            }
                        }
                    }
            }
            .frame(maxHeight: 22)
            .clipped()

            // Dictation. Visible whenever the field is empty OR the
            // recognizer is already running (so the user can tap to
            // stop without first clearing the text). Tap toggles the
            // session: first tap starts capturing, second tap (or
            // 1.5s of silence) stops and the partial transcript is
            // already in `vm.searchText` via the onUpdate closure.
            if vm.searchText.isEmpty || speech.isListening {
                Button {
                    // Toggle. The callback mirrors the recognizer's
                    // partial result into `vm.searchText` so the user
                    // sees their words land in the field as they
                    // speak. Once stopped, `searchText` carries the
                    // final transcript and a tap on the sparkle
                    // submits it like any typed question.
                    speech.toggle { partial in
                        vm.searchText = partial
                    }
                } label: {
                    Image(systemName: speech.isListening ? "waveform" : "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(speech.isListening
                                         ? AnyShapeStyle(Color.red)
                                         : AnyShapeStyle(aiGradient))
                        .frame(width: 28, height: 28)
                        .background(
                            (speech.isListening
                             ? Color.red.opacity(0.12)
                             : Color.white.opacity(0.5))
                        )
                        .clipShape(Circle())
                        // Subtle pulse while listening, mirroring the
                        // sparkle's "alive" feel everywhere else.
                        .scaleEffect(speech.isListening ? 1.08 : 1.0)
                        .animation(
                            speech.isListening
                                ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                                : .default,
                            value: speech.isListening
                        )
                }
                .accessibilityLabel(speech.isListening ? "Stop dictating" : "Start dictating")
            }

            Button {
                withAnimation(SomedayAnimations.tile) {
                    vm.showSearch = false
                    vm.searchText = ""
                    vm.searchResults = []
                    // Collapsing the bar discards the in-flight chat
                    // too — the next open should feel like a fresh
                    // "ask Someday" session, not a resumed thread.
                    clearChat()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(SomedayColors.grayMedium)
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.5))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Inline AI conversation panel
    //
    // Renders INSIDE `aiChatBar`'s glass container — no own background,
    // shadow, or border. Just the transcript + a clear-thread footer.
    // The shared glass + animated gradient stroke makes the whole
    // bar+transcript read as one expanding capsule.

    private var aiConversationPanel: some View {
        scrollableTranscript
            // Intercept taps on chat links so `someday://place/<id>` and
            // `someday://suggest?…` URLs route to the map instead of the
            // browser. Anything else falls through to the system handler.
            .environment(\.openURL, OpenURLAction { url in
                handleChatLinkTap(url)
            })
    }

    @ViewBuilder
    private var scrollableTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { idx, msg in
                        // A bubble is "live" when the stream is still
                        // running and this is the last assistant message
                        // (the one being actively populated). Live
                        // bubbles keep their step list expanded; everyone
                        // else collapses behind a "N steps" disclosure.
                        ChatBubbleView(
                            msg: msg,
                            isStreaming: chat.isThinking
                                && msg.role == .assistant
                                && idx == chat.messages.count - 1,
                            // Bubble needs vm access for `attachedPlaceID`
                            // bubbles — looks the place + availability
                            // state up directly. Passing the @Observable
                            // instance keeps the bubble reactive when
                            // state flips loading → ready.
                            vm: vm,
                            onCheckTonightForAttachment: { place in
                                Task { await vm.checkTonight(for: place) }
                            }
                        )
                        .id(msg.id)
                    }
                    // Pre-stream thinking dots: only shown when the
                    // assistant hasn't started emitting yet, so the user
                    // sees activity between submit and first event.
                    if chat.isThinking,
                       chat.messages.last?.role != .assistant
                        || (chat.messages.last?.content.isEmpty == true
                            && chat.messages.last?.steps.isEmpty == true) {
                        inlineThinking.id("thinking")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: chat.messages.count) { _, _ in
                if let last = chat.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: chat.isThinking) { _, isOn in
                if isOn {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("thinking", anchor: .bottom)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxHeight: 320)
    }

    // The bubble view is extracted to `ChatBubbleView` (below) so each
    // bubble owns its own "steps expanded?" state and so we can attach
    // `.sensoryFeedback` keyed on step count for the per-step haptic.

    /// Converts the raw model reply into an `AttributedString` so links
    /// render as tappable, lime-tinted text. Two stages:
    ///
    ///  1. **Auto-link raw URLs** — Claude usually emits markdown links,
    ///     but it sometimes drops a bare `https://example.com` into a
    ///     sentence. We regex-replace those into proper markdown form
    ///     so the parser picks them up. Skips anything already inside a
    ///     `[…](…)` pair via a `(?<!\()` lookbehind.
    ///  2. **Parse as markdown** — `AttributedString(markdown:)` with
    ///     `inlineOnlyPreservingWhitespace` so newlines/spaces survive
    ///     intact. On any failure we fall back to the plain string so
    ///     the message still shows up.
    private func attributedChatBody(_ raw: String) -> AttributedString {
        var processed = raw
        let pattern = #"(?<![\(\[])https?://[^\s)\]]+"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsRange = NSRange(processed.startIndex..., in: processed)
            // Iterate in reverse so each replacement doesn't shift the
            // ranges of the matches we haven't applied yet.
            let matches = regex.matches(in: processed, range: nsRange).reversed()
            for match in matches {
                guard let range = Range(match.range, in: processed) else { continue }
                let url = String(processed[range])
                processed.replaceSubrange(range, with: "[\(url)](\(url))")
            }
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: processed, options: options))
            ?? AttributedString(raw)
    }

    /// Three pulsing dots while the AI is generating. Matches the
    /// shimmer language already used on the bar.
    private var inlineThinking: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(SomedayColors.grayMedium)
                    .frame(width: 6, height: 6)
                    .opacity(aiSparklePulse ? 1.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: aiSparklePulse
                    )
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 60)
    }

    // MARK: - Friend Filter Banner

    @ViewBuilder
    private var friendFilterBanner: some View {
        if let friend = vm.filteredFriend {
            VStack {
                HStack(spacing: 10) {
                    AsyncImage(url: friend.avatarURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Circle().fill(SomedayColors.primary.opacity(0.3))
                                .overlay(
                                    Text(friend.initials.prefix(1))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white)
                                )
                        }
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())

                    Text("\(friend.name)'s somedays")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(SomedayColors.charcoal)

                    Spacer()

                    Button {
                        vm.clearFriendFilter()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(SomedayColors.grayMedium)
                            .frame(width: 26, height: 26)
                            .background(SomedayColors.grayLight)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.white)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                .padding(.horizontal, 16)

                Spacer()
            }
            .padding(.top, 56)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Feedback Pill

    /// Tiny glass pill that sits in the home-indicator strip, directly
    /// below the tab bar. We extend into the bottom safe area so the pill
    /// sits *under* the bar rather than overlapping it, and stays text-only
    /// + small so it doesn't compete with the tab bar above. Tapping it
    /// opens the full feedback tile.
    private var feedbackLayer: some View {
        VStack {
            Spacer()
            Button {
                withAnimation(SomedayAnimations.tile) {
                    vm.toggleOverlay(.feedback)
                }
            } label: {
                Text("Feedback")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
            }
            .padding(.bottom, 14)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Bottom Bar

    private var bottomBarLayer: some View {
        VStack(spacing: 4) {
            Spacer()

            HStack(spacing: 0) {
                BottomTabButton(
                    icon: "bell.fill",
                    label: "Activity",
                    isActive: vm.showActivity
                ) {
                    withAnimation(SomedayAnimations.tile) {
                        vm.toggleOverlay(.activity)
                    }
                }

                Button {
                    // The + button now opens the AI chat directly,
                    // in an "add" context. The chat is powerful
                    // enough (via the create_place + geocode_address
                    // tools) to add a venue from a single sentence
                    // — "save Cafe de Klepel" — so the older
                    // AddSourcesView overlay (Maps / Socials option
                    // buttons) is no longer the default surface. The
                    // overlay code is still present and reachable
                    // programmatically, just not from this tab.
                    Haptics.tap()
                    openChatForAdding()
                } label: {
                    ZStack {
                        Circle()
                            .fill(SomedayColors.lime)
                            .frame(width: 48, height: 48)
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(SomedayColors.charcoal)
                    }
                    .shadow(color: SomedayColors.lime.opacity(0.4), radius: 8, y: 3)
                }
                .frame(maxWidth: .infinity)

                BottomTabButton(
                    icon: "list.bullet.rectangle.fill",
                    label: "Lists",
                    isActive: vm.showLists
                ) {
                    withAnimation(SomedayAnimations.tile) {
                        vm.toggleOverlay(.lists)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .glassEffect(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.08), radius: 12, y: -2)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }


    // MARK: - List Preview Action Bar

    /// Floating bar that appears just above the bottom tab bar when the
    /// user is previewing a friend's list. Surfaces context (whose list)
    /// and the **Cancel** / **Add** decisions.
    @ViewBuilder
    private var previewListLayer: some View {
        if let preview = vm.previewedList {
            VStack {
                Spacer()
                previewActionBar(preview: preview)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 96)   // sits above the capsule tab bar
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(40)
        }
    }

    private func previewActionBar(preview: PreviewedList) -> some View {
        VStack(spacing: 10) {
            // Context header — "Wouter's Bookshops (3 places)"
            HStack(spacing: 8) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.primary)
                (Text("\(preview.owner.name)'s ").foregroundColor(SomedayColors.charcoal)
                 + Text(preview.name).fontWeight(.bold).foregroundColor(SomedayColors.charcoal)
                 + Text("  ·  \(preview.places.count) \(preview.places.count == 1 ? "place" : "places")")
                    .foregroundColor(SomedayColors.grayMedium))
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer()
            }

            HStack(spacing: 10) {
                // 1) List picker — opens the Lists overlay, where tapping
                //    a tile sets `previewTargetList` and dismisses.
                Button {
                    withAnimation(SomedayAnimations.tile) {
                        vm.showLists = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let target = vm.previewTargetList {
                            let style = ListVisualStyle.style(for: target)
                            Image(systemName: style.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(style.color)
                            Text(target)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(SomedayColors.charcoal)
                                .lineLimit(1)
                        } else {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(SomedayColors.grayMedium)
                            Text("List")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(SomedayColors.grayMedium)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(SomedayColors.grayMedium)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(SomedayColors.grayMedium.opacity(0.35), lineWidth: 1.5)
                    )
                }

                Button {
                    vm.cancelListPreview()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundColor(SomedayColors.charcoal)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(SomedayColors.grayMedium.opacity(0.35), lineWidth: 1.5)
                        )
                }

                Button {
                    Task { await vm.acceptListPreview() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                        Text("Add")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(SomedayColors.lime)
                    .foregroundColor(SomedayColors.charcoal)
                    .cornerRadius(12)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
    }

    // MARK: - Onboarding Overlay

    /// First-run onboarding flow rendered as a centered glass tile
    /// over the map. Visible only when `appState.isOnboarding` is true
    /// — set by `handleAuthSuccess`, cleared by `completeOnboarding`.
    @ViewBuilder
    private var onboardingLayer: some View {
        if appState.isOnboarding {
            ZStack {
                // Same brand background the AuthView uses, so the
                // hand-off from sign-up → onboarding feels like one
                // continuous backdrop instead of "map flashes through
                // onboarding glass". Hot-air balloon mark centred,
                // mirroring the login layout for visual continuity.
                Image("loginBackground")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                Image("balloon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220)
                    .foregroundStyle(.white.opacity(0.92))
                    .offset(y: -160)
                    .allowsHitTesting(false)
                OnboardingFlowTile(appState: appState, vm: vm)
            }
            .transition(.opacity)
            .zIndex(20)
        }
    }

    // MARK: - Share Request Floating Tile

    /// Big tile shown on launch ("Bodil wants to share an Amsterdam list").
    /// Tapping Preview hands off to the existing list-preview flow so the
    /// user can review pins and decide whether to Add them.
    @ViewBuilder
    private var shareRequestLayer: some View {
        if vm.showShareRequest {
            let bodil = SampleData.bodil
            let listName = "Amsterdam"
            // Resolve Bodil's place IDs into real Place objects so the tile
            // can show real names + neighborhoods as examples.
            let listPlaceIDs = bodil.lists[listName] ?? []
            let resolvedPlaces: [Place] = listPlaceIDs.compactMap { id in
                SampleData.places.first(where: { $0.id == id })
            }

            ShareRequestTileView(
                person: bodil,
                listName: listName,
                places: resolvedPlaces,
                onPreview: {
                    withAnimation(SomedayAnimations.tile) {
                        vm.showShareRequest = false
                    }
                    vm.showListPreview(owner: bodil, listName: listName)
                },
                onAdd: { duration in
                    // Skip the preview step — import the places, also
                    // create a matching list in the user's Lists so the
                    // shared collection shows up next to their own,
                    // then surface the import summary so the user knows
                    // what landed.
                    //
                    // `duration` carries the receiver's chosen access
                    // window (30 days / 90 days / forever). We register
                    // it with the view model so a future expiry sweep
                    // can prune the list, then proceed with the same
                    // import flow regardless of choice.
                    withAnimation(SomedayAnimations.tile) {
                        vm.showShareRequest = false
                    }
                    vm.createList(
                        name: listName,
                        imageData: nil,
                        placeIDs: resolvedPlaces.map(\.id)
                    )
                    vm.recordSharedListAccess(
                        listName: listName,
                        ownerID: bodil.id,
                        duration: duration
                    )
                    Task {
                        await vm.importPlaces(resolvedPlaces)
                        vm.presentImportSummary(.init(places: resolvedPlaces, source: .list))
                    }
                },
                onDismiss: {
                    withAnimation(SomedayAnimations.tile) {
                        vm.showShareRequest = false
                    }
                }
            )
            .zIndex(70)
        }
    }

    // MARK: - Import Summary Card

    @ViewBuilder
    private var importSummaryLayer: some View {
        // During onboarding the OnboardingFlowTile owns the celebration
        // moment + result rows. Suppress the external summary so we
        // don't double-render results in two competing tiles.
        if let summary = vm.lastImportSummary, !appState.isOnboarding {
            ImportSummaryCardView(
                summary: summary,
                onDismiss: { vm.dismissImportSummary() },
                // "Add" hands the imported places off to the Lists picker
                // — see `beginAddImportedPlacesToList` and the matching
                // `pendingAddToListPlaces` check inside the lists layer.
                // Only shown when the tile actually has places (not the
                // loading variant).
                onAdd: summary.places.isEmpty ? nil : {
                    vm.beginAddImportedPlacesToList(summary.places)
                }
            )
            .zIndex(80)
        }
    }

    // MARK: - Feedback Floating Tile

    @ViewBuilder
    private var feedbackTileLayer: some View {
        if vm.showFeedback {
            FeedbackTileView(
                onDismiss: {
                    withAnimation(SomedayAnimations.tile) {
                        vm.showFeedback = false
                    }
                }
            )
            .zIndex(60)
        }
    }

    // MARK: - Add Sources Floating Tile

    @ViewBuilder
    private var addSourcesLayer: some View {
        if vm.showAddOptions {
            AddSourcesTileView(
                onSelectList: {
                    withAnimation(SomedayAnimations.tile) {
                        vm.showAddOptions = false
                    }
                    vm.showImportList = true
                },
                onSelectMaps: {
                    withAnimation(SomedayAnimations.tile) {
                        vm.showAddOptions = false
                    }
                    vm.showMapsImport = true
                },
                onSelectSocials: {
                    withAnimation(SomedayAnimations.tile) {
                        vm.showAddOptions = false
                    }
                    // Try the clipboard first — if the user already
                    // copied an Instagram/TikTok URL we can skip the
                    // LinkImportView "paste here" sheet entirely. Falls
                    // back to LinkImportView when the clipboard doesn't
                    // hold a usable URL (manual paste flow).
                    if let url = instagramURLFromClipboard() {
                        Task { await vm.startInstagramImport(url: url) }
                    } else {
                        vm.showSocialsImport = true
                    }
                },
                onDismiss: {
                    withAnimation(SomedayAnimations.tile) {
                        vm.showAddOptions = false
                    }
                }
            )
            .zIndex(50)
        }
    }

    // MARK: - Activity Floating Tile

    @ViewBuilder
    private var activityLayer: some View {
        if vm.showActivity {
            ActivityView(
                events: vm.activityFeed,
                places: vm.places,
                friends: vm.friends,
                followingIDs: Set(vm.friends.map(\.id)),
                incomingFriendRequests: vm.incomingFriendRequests,
                onAcceptFriendRequest: { req in
                    vm.acceptFriendRequest(req)
                },
                onRejectFriendRequest: { req in
                    vm.rejectFriendRequest(req)
                },
                onSelectPlace: { place in
                    withAnimation(SomedayAnimations.tile) {
                        vm.showActivity = false
                    }
                    vm.selectPlace(place)
                },
                onSelectList: { person, name in
                    vm.showListPreview(owner: person, listName: name)
                },
                onDismiss: {
                    withAnimation(SomedayAnimations.tile) {
                        vm.showActivity = false
                    }
                }
            )
            // Refetch the inbox every time the Activity tile is presented
            // so a request accepted from another device disappears here
            // on the next open without a manual pull-to-refresh.
            .onAppear { vm.refreshIncomingFriendRequests() }
            .zIndex(50)
        }
    }

    // MARK: - Lists Floating Tile

    @ViewBuilder
    private var listsLayer: some View {
        if vm.showLists {
            ListsGridView(
                lists: appState.currentUser?.lists ?? [:],
                customLists: vm.customLists,
                // Source of truth for the Shared tab — surface each
                // friend's curated lists as their own tiles.
                friends: vm.friends,
                onSelectList: { name in
                    if vm.pendingAddToListPlaces != nil {
                        // Summary "Add" mode — stash the imported places
                        // in the picked list, clear state, dismiss.
                        vm.addPendingPlaces(to: name)
                    } else if vm.previewedList != nil {
                        // Picker mode — set this as the import target for
                        // the in-progress preview, then let the overlay
                        // dismiss itself.
                        vm.previewTargetList = name
                    } else {
                        // Normal mode — zoom the map to fit all the pins
                        // in this list and dismiss the Lists tile.
                        vm.focusOnCustomList(name: name)
                    }
                },
                onSelectSharedList: { owner, name in
                    // Tapping a friend-curated list preview-mounts it on
                    // the map (existing `showListPreview` flow handles the
                    // banner + "Add" CTA + bounding-region zoom).
                    vm.showListPreview(owner: owner, listName: name)
                },
                onMergeRequested: { source, target in
                    // User long-pressed `source`, dragged onto `target`.
                    // Stage the request — the alert lives on MapHomeView
                    // so dismissing the tile doesn't race the alert
                    // lifecycle (a known SwiftUI crash pattern).
                    pendingMerge = PendingMergeRequest(source: source, target: target)
                },
                onDeleteRequested: { name in
                    // User picked "Delete list" from a tile's context
                    // menu. Same parent-hosted alert pattern as merge.
                    pendingDelete = PendingDeleteRequest(name: name)
                },
                onReorderRequested: { source, target in
                    // Edit-mode drag-and-drop reorder. Optimistic local
                    // shuffle (no alert) — same UX as iPhone Home Screen.
                    vm.reorderCustomList(named: source, beforeName: target)
                },
                onCreateList: {
                    // Single state write switches `presentedOverlay`
                    // from .lists → .createList atomically, so SwiftUI
                    // animates the cross-fade once and never sees a
                    // momentary "neither tile is up" gap.
                    withAnimation(SomedayAnimations.tile) {
                        vm.showOverlay(.createList)
                    }
                },
                onDismiss: {
                    // Cancel any in-flight "Add to list" stash so the
                    // next time the user opens Lists it's not in picker
                    // mode by accident.
                    vm.cancelAddPendingPlaces()
                    withAnimation(SomedayAnimations.tile) {
                        vm.showLists = false
                    }
                }
            )
            .zIndex(50)
        }
    }

    @ViewBuilder
    private var createListLayer: some View {
        if vm.showCreateList {
            CreateListView(
                onCreate: { name, imageData in
                    // Create the list but keep the view open — the user
                    // can still tap "Share list" before closing. The
                    // transition back to the Lists grid happens in
                    // onDismiss once we know whether a create actually
                    // happened.
                    vm.createList(name: name, imageData: imageData)
                },
                onDismiss: { didCreate in
                    withAnimation(SomedayAnimations.tile) {
                        if didCreate {
                            // Created (and possibly shared) — land the
                            // user on the Lists grid so they see the
                            // new entry. Single atomic overlay swap.
                            vm.showOverlay(.lists)
                        } else {
                            // Cancelled out — close everything.
                            vm.showCreateList = false
                        }
                    }
                }
            )
            .zIndex(55)
        }
    }

    // MARK: - AI Availability bar

    /// Floating glass panel in the top-right of the map. Mirrors the
    /// aiChatBar visually (gradient border, sparkles) but is read-only.
    /// Shown when `vm.availabilityResult` is non-nil — i.e. after the
    /// user has tapped "Done" on a place's Availability CTA.
    @ViewBuilder
    private var availabilityBarLayer: some View {
        if let result = vm.availabilityResult, let place = vm.availabilityResultPlace {
            VStack {
                HStack {
                    Spacer()
                    AIAvailabilityBar(
                        result: result,
                        place: place,
                        onClose: { vm.dismissAvailabilityResult() }
                    )
                    .padding(.trailing, 14)
                    .padding(.top, 12)
                }
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }

    // MARK: - Place Card

    @ViewBuilder
    private var placeCardLayer: some View {
        if let place = vm.selectedPlace {
            PlaceCardSheet(
                place: place,
                friends: vm.friends,
                // Driven by MapViewModel.availabilityStatus — drives the
                // three visual states of the Availability button.
                availabilityState: vm.availabilityState(for: place.id),
                // Real-time "tonight?" check result + loading state.
                // Surfaced as a pill at the top of the inline platforms
                // panel inside the card.
                tonightCheck: vm.tonightCheck(for: place.id),
                isCheckingTonight: vm.isCheckingTonight(for: place.id),
                // The custom list the place currently lives in (if any).
                // Drives the "+" / list-coloured chip next to Availability.
                listForPlace: vm.listContaining(place),
                onDismiss: { vm.dismissPlace() },
                onReservation: { mode in
                    vm.reservationMode = mode
                    vm.showReservation = true
                },
                onAvailabilityTap: {
                    // Dismiss the place card and surface the result
                    // inside the chat thread as an "availability card"
                    // bubble. The bubble carries `attachedPlaceID =
                    // place.id` and pulls live state from vm, so it
                    // reactively flips loading → ready as the lookup
                    // resolves. Tapping the pill on the bubble routes
                    // back to the map via `someday://place/<id>`.
                    let captured = place
                    // Expand the AI chat bar so the carrier bubble is
                    // immediately visible — otherwise it lands in a
                    // minimised chat and the user wouldn't see what
                    // just happened.
                    withAnimation(SomedayAnimations.tile) {
                        vm.showSearch = true
                    }
                    var carrier = ChatMessage(role: .assistant, content: "")
                    carrier.attachedPlaceID = captured.id
                    chat.messages.append(carrier)
                    // Kick the AI lookup if it hasn't started yet. If
                    // it's already `.ready` (cached), the card just
                    // renders the result immediately.
                    if case .idle = vm.availabilityState(for: captured.id) {
                        Task { await vm.checkAvailability(for: captured) }
                    }
                    vm.dismissPlace()
                },
                onCheckTonight: {
                    // Auto-fires when the inline panel expands (the card
                    // calls back to us so the result lands on the view
                    // model, not as transient @State inside the sheet).
                    Task { await vm.checkTonight(for: place) }
                },
                onAddToListTap: {
                    // Same plumbing the summary tile's "Add" button uses
                    // — stash the place and let the Lists picker commit
                    // via `addPendingPlaces(to:)`. Card dismisses inside
                    // `beginAddImportedPlacesToList` so the picker has
                    // the screen to itself.
                    vm.beginAddImportedPlacesToList([place])
                }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// =============================================================================
// ChatBubbleView — one row in the inline transcript
// =============================================================================
//
// User bubbles right-align in primary (solid, anchors the eye to the
// question). Assistant bubbles left-align in pure glass.
//
// Assistant bubbles can carry an ordered list of `ChatStep`s — the
// agent's visible work for that turn. Steps render above the body. While
// the stream is live (`isStreaming == true`) they stay expanded so the
// user watches each step roll in. Once the stream finishes we collapse
// them behind a "Show N steps" disclosure so the answer stays clean.
//
// Per-step haptic: `.sensoryFeedback(.impact, trigger: msg.steps.count)`
// fires exactly once each time a new step arrives.

private struct ChatBubbleView: View {
    let msg: ChatMessage
    /// Set by the parent. True iff (a) `chat.isThinking` and (b) this is
    /// the last assistant message — i.e. the one being actively populated.
    let isStreaming: Bool
    /// Map view model — only used by bubbles that carry an
    /// `attachedPlaceID` (currently: the Availability card). Pulled out
    /// of the bubble's state so a `nil` attachment is a pure no-op.
    let vm: MapViewModel
    /// Fires when an attached availability card mounts in `.ready` and
    /// wants the tonight check to spin up. Parent does the work; the
    /// bubble just signals.
    let onCheckTonightForAttachment: (Place) -> Void

    @State private var stepsExpanded: Bool

    init(
        msg: ChatMessage,
        isStreaming: Bool,
        vm: MapViewModel,
        onCheckTonightForAttachment: @escaping (Place) -> Void
    ) {
        self.msg = msg
        self.isStreaming = isStreaming
        self.vm = vm
        self.onCheckTonightForAttachment = onCheckTonightForAttachment
        // Initial render: expanded while live, collapsed for old
        // messages scrolled back into view. `.onChange(of: isStreaming)`
        // below keeps the state honest after the stream ends.
        _stepsExpanded = State(initialValue: isStreaming)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if msg.role == .user { Spacer(minLength: 30) }
            bubbleContent
                .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
            if msg.role == .assistant { Spacer(minLength: 30) }
        }
        // One light haptic tick each time the assistant emits a new
        // step. The trigger value is `steps.count`, so SwiftUI guarantees
        // exactly one fire per new step.
        .sensoryFeedback(.impact(weight: .light), trigger: msg.steps.count)
        .onChange(of: isStreaming) { _, nowStreaming in
            // When the stream ends, fold the steps away so the bubble
            // shrinks to just the answer. Auto-open again if a fresh
            // stream lands on this bubble (rare).
            if !nowStreaming {
                withAnimation(.easeInOut(duration: 0.25)) { stepsExpanded = false }
            } else {
                withAnimation(.easeInOut(duration: 0.25)) { stepsExpanded = true }
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ---- Steps area --------------------------------------
            if !msg.steps.isEmpty {
                if stepsExpanded || isStreaming {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(msg.steps) { step in
                            ChatStepRow(step: step)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        // Disclosure footer (only when stream is done —
                        // while streaming, no point showing a collapse).
                        if !isStreaming {
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    stepsExpanded = false
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 9, weight: .bold))
                                    Text("Hide steps")
                                        .font(.system(size: 11))
                                }
                                .foregroundColor(SomedayColors.grayMedium)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: msg.steps)
                } else {
                    // Collapsed disclosure: tap to re-expand.
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            stepsExpanded = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                            Text("Show \(msg.steps.count) step\(msg.steps.count == 1 ? "" : "s")")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(SomedayColors.grayMedium)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Subtle divider between steps and answer text, only when
            // both are present.
            if !msg.steps.isEmpty && !msg.content.isEmpty && (stepsExpanded || isStreaming) {
                Rectangle()
                    .fill(SomedayColors.grayMedium.opacity(0.25))
                    .frame(height: 0.5)
            }

            // ---- Body text --------------------------------------
            // Inline flow layout: words + list pills + tappable links
            // all flow together with wrapping. See ChatMessageRenderer.swift.
            if !msg.content.isEmpty {
                ChatMessageBody(
                    raw: msg.content,
                    textColor: msg.role == .user ? .white : SomedayColors.charcoal
                )
            }

            // ---- Availability attachment ------------------------
            // Bubbles created by the place-card "Availability" CTA
            // carry an `attachedPlaceID`. Resolve to the live place +
            // availability state and render the in-chat card.
            if let pid = msg.attachedPlaceID,
               let place = vm.places.first(where: { $0.id == pid }) {
                ChatAvailabilityCardView(
                    placeName: place.name,
                    placeID: place.id,
                    // Use the SAME resolution the map renderer uses
                    // (own list → previewed friend list → any friend
                    // list claiming the id) so the chat pin's colour
                    // matches the pin you tapped on the map. Reading
                    // only the user's own lists here meant a friend-
                    // list pin would tint correctly on the map but
                    // fall back to Someday primary in chat — visible
                    // mismatch when you opened Availability.
                    listHint: vm.displayedListName(for: place),
                    state: vm.availabilityState(for: place.id),
                    tonightCheck: vm.tonightCheck(for: place.id),
                    isCheckingTonight: vm.isCheckingTonight(for: place.id),
                    onAppearWithReady: {
                        onCheckTonightForAttachment(place)
                    }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if msg.role == .user {
                RoundedRectangle(cornerRadius: 14)
                    .fill(SomedayColors.primary)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

/// One step row: SF Symbol + label + (spinner | checkmark). Lime while
/// in-progress, fades to grey on done.
private struct ChatStepRow: View {
    let step: ChatStep

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: step.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(step.done ? SomedayColors.grayMedium : SomedayColors.lime)
                    .frame(width: 14, alignment: .center)
                Text(step.label)
                    .font(.system(size: 12))
                    .foregroundColor(SomedayColors.charcoal.opacity(step.done ? 0.55 : 0.9))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if step.done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SomedayColors.grayMedium)
                        .transition(.opacity.combined(with: .scale))
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.55)
                        .tint(SomedayColors.lime)
                        .frame(width: 14, height: 14)
                }
            }

            // Stacked chips — only present on the upfront "Searching your
            // lists" / "Searching friends' lists" steps. Icon discriminates
            // the rendering: list pills (colored from ListVisualStyle) vs
            // friend chips (initials avatar + name).
            if !step.chips.isEmpty {
                ChatStepChipsView(icon: step.icon, names: step.chips, dim: step.done)
                    .padding(.leading, 22) // align with the label
            }
        }
    }
}

/// Renders the stacked preview chips beneath a step's label. Picks the
/// chip style based on the step's icon — list-style pills (colored
/// swatch + name) for the "Searching your lists" step, friend-style
/// chips (initials circle + name) for the friends step. Hidden when
/// `names` is empty.
private struct ChatStepChipsView: View {
    let icon: String
    let names: [String]
    let dim: Bool

    var body: some View {
        InlineFlowLayout(hSpacing: 4, vSpacing: 4) {
            ForEach(names, id: \.self) { name in
                if icon == "person.2.fill" {
                    FriendChip(name: name, dim: dim)
                } else {
                    ListChip(name: name, dim: dim)
                }
            }
        }
    }
}

/// Compact list pill matching the in-chat ListPillView identity
/// (deterministic color + swatch) but smaller, used as a preview chip
/// under the "Searching your lists" step.
private struct ListChip: View {
    let name: String
    let dim: Bool

    var body: some View {
        let style = ListVisualStyle.style(for: name)
        let color = dim ? style.color.opacity(0.5) : style.color
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.30), lineWidth: 0.5))
    }
}

/// Compact friend chip — initials in a small primary circle + name.
/// Used under the "Searching friends' lists" step.
private struct FriendChip: View {
    let name: String
    let dim: Bool

    private var initial: String {
        name.split(separator: " ").compactMap { $0.first }.prefix(2).map(String.init).joined().uppercased()
    }

    var body: some View {
        let tint = dim ? SomedayColors.primary.opacity(0.5) : SomedayColors.primary
        HStack(spacing: 4) {
            Text(initial.isEmpty ? "?" : initial)
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(tint))
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(SomedayColors.charcoal.opacity(dim ? 0.55 : 0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.10)))
        .overlay(Capsule().stroke(tint.opacity(0.25), lineWidth: 0.5))
    }
}

// =============================================================================
// Chat welcome tiles — `TileTop` + `TileBottom`
// =============================================================================
//
// Two same-size glass surfaces that bracket the chat dropdown while the
// conversation is still a blank slate (the user just tapped + and hasn't
// typed anything yet). Naming convention is deliberately positional —
// `tile_top` sits directly below the chat bar, `tile_bottom` is anchored
// against the navigation bar with the same gap. Sharing the size + glass
// styling keeps the two visually consistent so future content slots in
// without each tile drifting into its own bespoke geometry.
//
// `TileTop` carries a horizontally-paging carousel of three placeholder
// animation slots (the hot-air-balloon scaling gently). Each slot can be
// swapped to a richer animation later (a Lottie file, a looping image
// sequence, a sparkle pulse, etc.) without touching the surrounding chat
// plumbing.
//
// `TileBottom` is intentionally empty for now — a sized placeholder that
// establishes the visual rhythm and reserves the slot for content in a
// follow-up turn. Keeping it here (rather than inlining its frame at the
// call site) means future contributors find both tiles next to each
// other when they look for "where do the welcome tiles live."

/// Shared sizing for the two welcome tiles so their frames can't drift
/// apart. Bumping `contentHeight` here resizes both tiles together.
private enum ChatTileMetrics {
    /// Height of the inner content area (the scroller / future bottom
    /// content). The total tile is this + the dot strip + vertical
    /// padding.
    static let contentHeight: CGFloat = 168
    /// Corner radius used by both tiles' glass background.
    static let cornerRadius: CGFloat = 16
}

private struct TileTop: View {
    /// Three placeholder animation slots. Real animations plug in via
    /// `WelcomeAnimationSlot`'s body later; the surrounding layout
    /// (scroller + dots) doesn't need to change.
    private let slotCount = 3
    /// Current slot index, driven by `.scrollPosition`. The trailing
    /// dot strip uses this to highlight the active position. `nil`
    /// while the scroller hasn't reported yet — we treat that as 0.
    @State private var currentIndex: Int? = 0

    var body: some View {
        // Vertical layout: paging scroller on top, horizontal page-
        // indicator dots centred underneath — the standard iOS
        // carousel idiom. Each slot fills the scroller's full width
        // so a swipe moves between balloons one at a time; the dot
        // strip mirrors the active index.
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<slotCount, id: \.self) { idx in
                        WelcomeAnimationSlot(phaseDelay: Double(idx) * 0.35)
                            // Each slot takes the full width of the
                            // scroller's visible region. Without this
                            // the three small slots would sit
                            // side-by-side inside the viewport, never
                            // scroll, and the dots would never update.
                            .containerRelativeFrame(.horizontal)
                            .id(idx)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentIndex)
            .frame(height: ChatTileMetrics.contentHeight)

            // Horizontal dot strip, centred under the scroller.
            // `fixedSize(horizontal: true, vertical: true)` pins the
            // HStack to its natural intrinsic width — without it,
            // SwiftUI was sizing the HStack to the full available
            // width on this build of the SDK, which combined with the
            // dot frames' aspect ratio made it visually read as a
            // vertical column. Wrapping in Spacers ALSO guarantees
            // the strip is centred regardless of the parent's
            // alignment defaults.
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<slotCount, id: \.self) { idx in
                        Circle()
                            .fill(idx == (currentIndex ?? 0)
                                  ? SomedayColors.primary
                                  : SomedayColors.grayMedium.opacity(0.35))
                            .frame(width: 7, height: 7)
                            .animation(.easeOut(duration: 0.18), value: currentIndex)
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: ChatTileMetrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ChatTileMetrics.cornerRadius)
                .stroke(SomedayColors.primary.opacity(0.18), lineWidth: 1)
        )
    }
}

// =============================================================================
// TileBottom — same size as TileTop, currently empty.
// =============================================================================
//
// Pinned to the navigation bar with the same gap the preview action bar
// uses. Intentionally a blank glass surface for now: we're establishing
// the structure first (matching frame, matching corner radius, matching
// stroke) so the eventual content drops in without rebalancing the
// chat-overlay geometry. When we wire real content, it goes inside the
// VStack here — TileTop already shows the pattern (carousel + dots).

private struct TileBottom: View {
    var body: some View {
        VStack(spacing: 10) {
            // Reserved for future content. Keeping the frame
            // explicit so the empty tile occupies the exact same
            // vertical footprint as `TileTop`'s scroller — that way
            // a side-by-side comparison reads as "two same-size
            // tiles" rather than "one tile and a thin bar".
            Color.clear
                .frame(height: ChatTileMetrics.contentHeight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: ChatTileMetrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ChatTileMetrics.cornerRadius)
                .stroke(SomedayColors.primary.opacity(0.18), lineWidth: 1)
        )
    }
}

/// One slot inside `TileTop`. Now compact (no caption, no
/// title) so the tile stays ~half its former height. Placeholder
/// content: the SF Symbol `airballoon.fill` scaling on a repeat-
/// forever ease. Swap for a Lottie loop later — the slot's outer
/// frame is fixed via the parent's `.frame(width:height:)`, so any
/// replacement renders cleanly inside that box.
private struct WelcomeAnimationSlot: View {
    let phaseDelay: Double
    @State private var scaledUp = false

    var body: some View {
        // No background rectangle — the parent tile already provides
        // the glass surface. The slot is just the balloon, centred in
        // whatever frame the parent allocates (the scroller's full
        // viewport width × 52pt tall). Swap the SF Symbol for a
        // Lottie loop / image sequence later without touching
        // anything around it.
        Image(systemName: "airballoon.fill")
            .font(.system(size: 84, weight: .regular))
            .foregroundStyle(SomedayColors.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(scaledUp ? 1.10 : 0.92)
            .animation(
                .easeInOut(duration: 1.8)
                    .repeatForever(autoreverses: true)
                    .delay(phaseDelay),
                value: scaledUp
            )
            .onAppear { scaledUp = true }
    }
}
