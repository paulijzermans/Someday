import SwiftUI
import MapKit

struct MapHomeView: View {
    let appState: AppState
    @State private var vm: MapViewModel
    @State private var aiSuggestionIndex = 0

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
            bottomBarLayer
            profileLayer
            placeCardLayer
        }
        .sheet(isPresented: $vm.showFriends) {
            FriendsListView(places: vm.places, friends: vm.friends) { friendID in
                vm.showFriendPlaces(friendID: friendID)
            }
        }
        .sheet(isPresented: $vm.showActivity) {
            ActivityView(
                events: vm.activityFeed,
                places: vm.places,
                followingIDs: Set(vm.friends.map(\.id)),
                onSelectPlace: { place in
                    vm.showActivity = false
                    vm.selectPlace(place)
                }
            )
        }
        .sheet(isPresented: $vm.showReservation) {
            if let place = vm.selectedPlace {
                ReservationView(place: place) {
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
                Task { await vm.importPlaces(newPlaces) }
            }
        }
        .task { await vm.loadData() }
    }

    // MARK: - Map

    private var mapLayer: some View {
        ClusteredMapView(
            places: vm.visiblePlaces,
            region: $vm.region,
            onSelectPlace: { vm.selectPlace($0) }
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
                    aiButton
                    Spacer()
                }
            }
            .padding(.top, 8)

            if vm.showSearch && !vm.searchResults.isEmpty {
                searchResultsList
            }

            Spacer()
        }
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
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
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
        .padding(.leading, 16)
        .transition(.scale(scale: 0.5, anchor: .topLeading).combined(with: .opacity))
    }

    // Floating profile avatar, anchored in the bottom-right corner above the tab bar.
    private var profileLayer: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                profileButton
            }
            .padding(.trailing, 18)
            .padding(.bottom, 96)
        }
    }

    private var profileButton: some View {
        Button {
            // TODO: profile menu
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
            .overlay(Circle().stroke(SomedayColors.butter, lineWidth: 2))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
    }

    private var aiChatBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(aiGradient)

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
            .frame(maxHeight: 20)
            .clipped()

            if vm.isSearching {
                ProgressView().scaleEffect(0.8)
            }

            Button {
                withAnimation(.spring(response: 0.3)) {
                    vm.showSearch = false
                    vm.searchText = ""
                    vm.searchResults = []
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
                    .frame(width: 22, height: 22)
                    .background(SomedayColors.grayLight)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .overlay(
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.45),
                            SomedayColors.primary.opacity(0.45),
                            Color(red: 1.0, green: 0.45, blue: 0.80).opacity(0.45)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        )
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
                            Text(result.address)
                                .font(.system(size: 13))
                                .foregroundColor(SomedayColors.grayMedium)
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

    // MARK: - Bottom Bar

    private var bottomBarLayer: some View {
        VStack(spacing: 4) {
            Spacer()

            if vm.showAddOptions {
                addOptionsMenu
            }

            HStack(spacing: 0) {
                BottomTabButton(icon: "bell.fill", label: "Activity") {
                    vm.showActivity = true
                }

                Button {
                    withAnimation(.spring(response: 0.3)) { vm.showAddOptions.toggle() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(SomedayColors.green)
                            .frame(width: 48, height: 48)
                        Image(systemName: vm.showAddOptions ? "xmark" : "plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(SomedayColors.butter)
                            .rotationEffect(.degrees(vm.showAddOptions ? 90 : 0))
                    }
                    .shadow(color: SomedayColors.green.opacity(0.3), radius: 8, y: 3)
                }
                .frame(maxWidth: .infinity)

                BottomTabButton(icon: "list.bullet.rectangle.fill", label: "Lists") {
                    vm.zoomToOverview()
                }
            }
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .shadow(color: .black.opacity(0.08), radius: 12, y: -2)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var addOptionsMenu: some View {
        VStack(spacing: 0) {
            AddOptionRow(icon: "list.bullet", label: "List", sublabel: "Paste from your notes") {
                withAnimation { vm.showAddOptions = false }
                vm.showImportList = true
            }
            Divider().padding(.horizontal, 16)
            AddOptionRow(icon: "map.fill", label: "Maps", sublabel: "Import from Google Maps") {
                withAnimation { vm.showAddOptions = false }
            }
            Divider().padding(.horizontal, 16)
            AddOptionRow(icon: "shared.with.you", label: "Socials", sublabel: "Share from Instagram & TikTok") {
                withAnimation { vm.showAddOptions = false }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.1), radius: 12, y: -2)
        .padding(.horizontal, 40)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Place Card

    @ViewBuilder
    private var placeCardLayer: some View {
        if let place = vm.selectedPlace {
            PlaceCardSheet(
                place: place,
                friends: vm.friends,
                onDismiss: { vm.dismissPlace() },
                onReservation: { vm.showReservation = true }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Subcomponents

struct SavedToastCard: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [SomedayColors.primary, SomedayColors.primaryDark],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(height: 160)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundColor(.white)
                        Text("TikTok")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                )
                .padding(.horizontal, 24)

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(SomedayColors.primary)
                    Text("Saved to your map")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(SomedayColors.grayMedium)
                }
                .padding(.top, 16)

                Text("Berlini")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)

                HStack(spacing: 6) {
                    Image(systemName: "fork.knife").font(.system(size: 13)); Text("Italian Restaurant"); Text("•"); Text("Mitte, Berlin")
                }
                .font(.system(size: 14))
                .foregroundColor(SomedayColors.grayMedium)
                .padding(.bottom, 20)

                Button(action: onDismiss) {
                    Text("Got it!")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(SomedayColors.primary)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(.white)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        .padding(.horizontal, 32)
    }
}

struct BottomTabButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 17))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .foregroundColor(SomedayColors.charcoal)
        }
    }
}

struct AddOptionRow: View {
    let icon: String
    let label: String
    let sublabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(SomedayColors.primary)
                    .frame(width: 36, height: 36)
                    .background(SomedayColors.primaryLight)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SomedayColors.charcoal)
                    Text(sublabel)
                        .font(.system(size: 13))
                        .foregroundColor(SomedayColors.grayMedium)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SomedayColors.grayMedium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
