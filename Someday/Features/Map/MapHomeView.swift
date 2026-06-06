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
    @State private var showChat: Bool = false
    /// Pending drag-to-merge request from the Lists tile. Held at this
    /// level (not inside ListsGridView) so the confirmation alert doesn't
    /// race with the tile dismissing — alerts presented from a view
    /// that's simultaneously dismissing reliably crash on iOS.
    @State private var pendingMerge: PendingMergeRequest?
    /// Pending "Delete list" request from a list tile's context menu.
    /// Same rationale as `pendingMerge` for living at the parent.
    @State private var pendingDelete: PendingDeleteRequest?

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

    private let aiSuggestions = [
        "Search a location...",
        "Drop a WhatsApp list...",
        "Share an Instagram link...",
        "Share a Facebook link...",
        "Paste a Google Maps link...",
        "Ask anything about places..."
    ]

    private let suggestionTimer = Timer.publish(every: 5.0, on: .main, in: .common).autoconnect()

    init(appState: AppState) {
        self.appState = appState
        self._vm = State(initialValue: MapViewModel(
            services: appState.services,
            userID: appState.currentUser?.id ?? "user_paul"
        ))
    }

    var body: some View {
        ZStack {
            mapLayer
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
            previewListLayer
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
                    user: user,
                    placeCount: vm.places.filter { $0.ownerID == user.id }.count,
                    reviewCount: vm.places.filter { $0.ownerID == user.id && $0.review != nil }.count,
                    friendCount: vm.friends.count,
                    friendAvatars: vm.friends,
                    onSignOut: {
                        vm.showProfile = false
                        appState.signOut()
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
        // Context-aware AI chat. The sheet rebuilds its `ChatContext`
        // on every send via the closure below, so the assistant always
        // sees the user's *current* places + lists + friends.
        .sheet(isPresented: $showChat) {
            ChatSheet(
                viewModel: ChatViewModel(
                    chatService: appState.services.chat,
                    contextProvider: { [weak vm] in vm?.buildChatContext() ?? ChatContext.empty }
                ),
                onDismiss: { showChat = false }
            )
        }
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
        // when the user picks "Delete list". Pins keep their existing
        // map positions; only list membership is dropped.
        .alert(item: $pendingDelete) { request in
            Alert(
                title: Text("Delete \"\(request.name)\"?"),
                message: Text("The list will be removed. The pins themselves stay on your map."),
                primaryButton: .destructive(Text("Delete")) {
                    Task { await vm.deleteCustomList(name: request.name) }
                    pendingDelete = nil
                },
                secondaryButton: .cancel { pendingDelete = nil }
            )
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
            // Map every place to the name of the custom list it lives in
            // (if any). The renderer turns that into the pin's fill colour
            // via ListVisualStyle, so pins re-tint the moment a place is
            // added or removed from a list.
            listNameFor: { place in vm.listContaining(place)?.name }
        )
        .ignoresSafeArea()
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

            if vm.showSearch && !vm.searchResults.isEmpty {
                searchResultsList
            }

            Spacer()
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
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(SomedayColors.green)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .circle)

                // Small sparkle accent in the top-right corner — hint at AI without dominating.
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(aiGradient)
                    .padding(3)
                    .glassEffect(.regular, in: .circle)
                    .offset(x: 2, y: -2)
            }
        }
        .padding(.trailing, 16)
        .transition(.scale(scale: 0.5, anchor: .topTrailing).combined(with: .opacity))
    }

    // Floating profile avatar, positioned **directly below** the search
    // button in the top-right corner. Search button is 44pt + 8pt top
    // inset → place the avatar at top inset 60pt so there's a small gap.
    private var profileLayer: some View {
        VStack {
            HStack {
                Spacer()
                profileButton
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

    private var aiChatBar: some View {
        HStack(spacing: 12) {
            // Tappable sparkle — entry point to the context-aware chat.
            // The text field next to it continues to do live location
            // search; the sparkle owns the AI chat surface specifically.
            Button {
                Haptics.tap()
                showChat = true
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
                    Text(aiSuggestions[aiSuggestionIndex])
                        .font(.system(size: 16))
                        .foregroundColor(SomedayColors.grayMedium)
                        .id(aiSuggestionIndex)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                        .allowsHitTesting(false)
                }
                TextField("", text: $vm.searchText)
                    .font(.system(size: 16))
                    .onChange(of: vm.searchText) { _, _ in
                        Task { await vm.search() }
                    }
            }
            .frame(maxHeight: 22)
            .clipped()

            if vm.isSearching {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(SomedayColors.charcoal.opacity(0.6))
            } else if vm.searchText.isEmpty {
                // Voice-input affordance — visible only when no text is
                // entered. Wired to a TODO for now; placeholder for the
                // dictation flow once Speech permissions are set up.
                Button {
                    // TODO: hand off to SFSpeechRecognizer once mic
                    // permissions are added to Info.plist.
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(aiGradient)
                        .frame(width: 28, height: 28)
                        .background(SomedayColors.grayLight)
                        .clipShape(Circle())
                }
            }

            Button {
                withAnimation(SomedayAnimations.tile) {
                    vm.showSearch = false
                    vm.searchText = ""
                    vm.searchResults = []
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(SomedayColors.grayMedium)
                    .frame(width: 24, height: 24)
                    .background(SomedayColors.grayLight)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
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
        .onAppear { startAIBorderAnimation() }
        .padding(.horizontal, 16)
        .transition(.scale(scale: 0.6, anchor: .topTrailing).combined(with: .opacity))
        .onReceive(suggestionTimer) { _ in
            guard vm.searchText.isEmpty else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                aiSuggestionIndex = (aiSuggestionIndex + 1) % aiSuggestions.count
            }
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(vm.searchResults) { result in
                    Button {
                        Task { await vm.addPlace(from: result) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: result.category?.systemImage ?? "mappin")
                                .font(.system(size: 14))
                                .foregroundColor(SomedayColors.primary)
                                .frame(width: 32, height: 32)
                                .background(SomedayColors.primaryLight)
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(SomedayColors.charcoal)
                                    .lineLimit(1)
                                Text(result.address)
                                    .font(.system(size: 13))
                                    .foregroundColor(SomedayColors.grayMedium)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(SomedayColors.primary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    Divider().padding(.leading, 60)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxHeight: 320)
        .background(.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
        .padding(.horizontal, 16)
        .padding(.top, 4)
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
                    withAnimation(SomedayAnimations.tile) {
                        vm.toggleOverlay(.addOptions)
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(SomedayColors.lime)
                            .frame(width: 48, height: 48)
                        Image(systemName: vm.showAddOptions ? "xmark" : "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(SomedayColors.charcoal)
                            .rotationEffect(.degrees(vm.showAddOptions ? 90 : 0))
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
            OnboardingFlowTile(appState: appState, vm: vm)
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
                onAdd: {
                    // Skip the preview step — import the places, also
                    // create a matching list in the user's Lists so the
                    // shared collection shows up next to their own,
                    // then surface the import summary so the user knows
                    // what landed.
                    withAnimation(SomedayAnimations.tile) {
                        vm.showShareRequest = false
                    }
                    vm.createList(
                        name: listName,
                        imageData: nil,
                        placeIDs: resolvedPlaces.map(\.id)
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
                    // Only `.idle` taps reach this callback now — the
                    // card intercepts `.ready` taps to toggle its inline
                    // booking-platforms panel, and `.loading` is non-
                    // interactive. So we just kick off the lookup.
                    if case .idle = vm.availabilityState(for: place.id) {
                        Task { await vm.checkAvailability(for: place) }
                    }
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
