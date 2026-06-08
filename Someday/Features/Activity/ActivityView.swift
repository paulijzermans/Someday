import SwiftUI

// MARK: - Feed model

struct ActivityFeedEvent: Identifiable {
    let id = UUID()
    let kind: Kind
    let date: Date

    enum Kind {
        /// A friend you follow logged a new place.
        case visited(friend: UserProfile, place: Place)
        /// Someone started following you — `isRequest` shows an Accept vs Follow-back affordance.
        case startedFollowing(person: UserProfile, isRequest: Bool)
        /// A friend shared one of their lists with you.
        case sharedList(friend: UserProfile, listName: String, placeIDs: [String])
    }
}

/// Assembles a mock activity timeline from the loaded friends + places.
enum ActivityFeedBuilder {
    static func build(friends: [UserProfile], places: [Place]) -> [ActivityFeedEvent] {
        func friend(_ id: String) -> UserProfile? { friends.first { $0.id == id } }
        func place(_ id: String) -> Place? { places.first { $0.id == id } }

        let now = Date()
        var events: [ActivityFeedEvent] = []

        // Bodil sharing her Amsterdam list — same action that surfaces as
        // the launch tile. Mirrored here so the user can also act on it
        // from the Activity feed (tap her name → preview the list).
        events.append(.init(
            kind: .sharedList(
                friend: SampleData.bodil,
                listName: "Amsterdam",
                placeIDs: SampleData.bodil.lists["Amsterdam"] ?? []
            ),
            date: now.addingTimeInterval(-60 * 5)   // 5 min ago — top of feed
        ))

        // Newly visited places by people you follow.
        if let e = friend("user_emma"), let p = place("place_2") {
            events.append(.init(kind: .visited(friend: e, place: p), date: now.addingTimeInterval(-3600 * 2)))
        }
        if let l = friend("user_lucas"), let p = place("place_3") {
            events.append(.init(kind: .visited(friend: l, place: p), date: now.addingTimeInterval(-3600 * 6)))
        }
        if let s = friend("user_sofia"), let p = place("place_5") {
            events.append(.init(kind: .visited(friend: s, place: p), date: now.addingTimeInterval(-3600 * 27)))
        }

        // Shared lists.
        if let e = friend("user_emma") {
            events.append(.init(kind: .sharedList(friend: e, listName: "Barcelona", placeIDs: e.lists["Barcelona"] ?? []),
                                date: now.addingTimeInterval(-3600 * 9)))
        }
        if let l = friend("user_lucas") {
            events.append(.init(kind: .sharedList(friend: l, listName: "Tokyo", placeIDs: l.lists["Tokyo"] ?? []),
                                date: now.addingTimeInterval(-3600 * 31)))
        }

        // New followers.
        for (i, person) in SampleData.pendingFollowers.enumerated() {
            events.append(.init(kind: .startedFollowing(person: person, isRequest: i == 0),
                                date: now.addingTimeInterval(-3600 * Double(4 + i * 21))))
        }

        return events.sorted { $0.date > $1.date }
    }
}

// MARK: - Activity screen

struct ActivityView: View {
    let events: [ActivityFeedEvent]
    let places: [Place]
    let friends: [UserProfile]
    let followingIDs: Set<String>
    /// Pending friend requests addressed to the current user. Rendered
    /// as a real inbox at the top of the events page — distinct from the
    /// mock `.startedFollowing` events that also live in `events`.
    var incomingFriendRequests: [IncomingFriendRequest] = []
    /// Called with the request the user accepted. Parent runs the RPC
    /// + refreshes the friends list.
    var onAcceptFriendRequest: (IncomingFriendRequest) -> Void = { _ in }
    /// Called with the request the user rejected. Parent deletes the row.
    var onRejectFriendRequest: (IncomingFriendRequest) -> Void = { _ in }
    var onSelectPlace: (Place) -> Void
    /// Tapping a list tile inside an expanded person row routes here.
    /// The parent handles previewing the list on the map.
    var onSelectList: (UserProfile, String) -> Void = { _, _ in }
    let onDismiss: () -> Void

    /// In-tile "navigation" via state instead of a NavigationStack. Keeps
    /// the tile's own scale/fade transition crisp — a NavigationStack
    /// inside runs its own appearance animations that fight with ours.
    @State private var presentedPerson: UserProfile? = nil
    /// Carousel page: 0 = Activity feed, 1 = Friends list.
    @State private var currentPage: Int = 0

    private var pageTitle: String {
        if let person = presentedPerson { return person.name }
        return currentPage == 0 ? "Activity" : "Friends"
    }

    var body: some View {
        tile.floatingTile(size: .large, onDismiss: onDismiss)
    }

    private var tile: some View {
        VStack(spacing: 0) {
            header

            if let person = presentedPerson {
                personPage(person)
            } else {
                TabView(selection: $currentPage) {
                    eventsPage.tag(0)
                    friendsPage.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                iconPageDots
                    .padding(.bottom, 14)
            }
        }
        // Glass + shadow + frame applied by `.floatingTile(size: .large)`.
    }

    // MARK: - Header (replaces NavigationStack toolbar)

    private var header: some View {
        HStack {
            if presentedPerson != nil {
                Button {
                    withAnimation(SomedayAnimations.inTileNav) {
                        presentedPerson = nil
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(SomedayColors.charcoal)
                        .frame(width: 28, height: 28)
                        .background(SomedayColors.grayLight)
                        .clipShape(Circle())
                }
            } else {
                // Reserve the slot so the title doesn't shift left/right
                // when navigating in/out.
                Color.clear.frame(width: 28, height: 28)
            }

            Spacer()

            Text(pageTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(SomedayColors.charcoal)

            Spacer()

            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(SomedayColors.grayMedium)
                    .frame(width: 28, height: 28)
                    .background(SomedayColors.grayLight)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Pages

    private var eventsPage: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Real friend-request inbox at the very top of the feed.
                // Suppressed when empty so the events feed has the entire
                // page when nothing's pending.
                if !incomingFriendRequests.isEmpty {
                    friendRequestInbox
                }
                ForEach(events) { event in
                    EventTile(
                        event: event,
                        onSelectPlace: onSelectPlace,
                        onSelectList: onSelectList,
                        onSelectPerson: { user in
                            withAnimation(SomedayAnimations.inTileNav) {
                                presentedPerson = user
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    /// The inbox section. Header + one `FriendRequestTile` per row, with
    /// a fade-out animation when a row is accepted/rejected so the user
    /// sees a clean transition before the parent refreshes.
    private var friendRequestInbox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.primary)
                Text("Friend requests")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
                Spacer()
                Text("\(incomingFriendRequests.count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(SomedayColors.grayMedium)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(SomedayColors.grayLight)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 4)

            ForEach(incomingFriendRequests) { request in
                FriendRequestTile(
                    request: request,
                    onAccept: { onAcceptFriendRequest(request) },
                    onReject: { onRejectFriendRequest(request) }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .padding(.top, 4)
        .animation(SomedayAnimations.followCTA, value: incomingFriendRequests)
    }

    private func personPage(_ person: UserProfile) -> some View {
        PersonProfileView(
            person: person,
            places: places,
            isFollowing: followingIDs.contains(person.id),
            onSelectPlace: onSelectPlace
        )
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    /// Second carousel page — your friends list. Tap a row to drill into
    /// their profile (same destination as tapping their avatar in Activity).
    private var friendsPage: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if friends.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundColor(SomedayColors.grayMedium.opacity(0.6))
                        Text("No friends yet")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(SomedayColors.charcoal)
                        Text("Once you follow people they'll show up here.")
                            .font(.system(size: 13))
                            .foregroundColor(SomedayColors.grayMedium)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(friends) { friend in
                        Button {
                            withAnimation(SomedayAnimations.inTileNav) {
                                presentedPerson = friend
                            }
                        } label: {
                            HStack(spacing: 12) {
                                ActivityAvatar(user: friend, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friend.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(SomedayColors.charcoal)
                                    Text("\(friend.lists.count) \(friend.lists.count == 1 ? "list" : "lists")")
                                        .font(.system(size: 12))
                                        .foregroundColor(SomedayColors.grayMedium)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(SomedayColors.grayMedium)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity)
                            .glassEffect(.regular, in: .rect(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    // MARK: - Icon page dots

    /// Two-bubble page indicator: ⚡ for Activity, 👤 for Friends. Active
    /// bubble is filled with charcoal; inactive is muted. Tap to jump.
    /// Sizing tuned so the pair reads as a compact toggle rather than
    /// two oversized buttons — 22pt dots with 8pt spacing.
    private var iconPageDots: some View {
        HStack(spacing: 8) {
            iconDot(symbol: "bolt.fill", index: 0)
            iconDot(symbol: "person.fill", index: 1)
        }
    }

    private func iconDot(symbol: String, index: Int) -> some View {
        let isActive = (currentPage == index)
        return Button {
            withAnimation(SomedayAnimations.inTileNav) {
                currentPage = index
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isActive ? .white : SomedayColors.grayMedium)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(isActive
                            ? AnyShapeStyle(SomedayColors.charcoal)
                            : AnyShapeStyle(SomedayColors.grayLight))
                )
                .scaleEffect(isActive ? 1.12 : 1.0)
                .animation(SomedayAnimations.chipToggle, value: currentPage)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Event tiles

private struct EventTile: View {
    let event: ActivityFeedEvent
    let onSelectPlace: (Place) -> Void
    let onSelectList: (UserProfile, String) -> Void
    let onSelectPerson: (UserProfile) -> Void

    var body: some View {
        switch event.kind {
        case .visited(let friend, let place):
            VisitedTile(
                friend: friend, place: place, date: event.date,
                onSelectList: onSelectList, onSelectPerson: onSelectPerson
            ) { onSelectPlace(place) }
        case .startedFollowing(let person, let isRequest):
            FollowTile(
                person: person, isRequest: isRequest, date: event.date,
                onSelectList: onSelectList, onSelectPerson: onSelectPerson
            )
        case .sharedList(let friend, let name, let placeIDs):
            SharedListTile(
                friend: friend, listName: name, count: placeIDs.count, date: event.date,
                onSelectList: onSelectList, onSelectPerson: onSelectPerson
            )
        }
    }
}

/// Chevron + tap target that toggles the person-lists expansion drawer
/// in the activity tiles. Kept as its own view so each tile reads cleanly.
private struct ExpandChevron: View {
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(SomedayAnimations.inTileNav) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(SomedayColors.grayMedium)
                .frame(width: 28, height: 28)
                .background(SomedayColors.grayLight)
                .clipShape(Circle())
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .buttonStyle(.plain)
    }
}

/// In-tile drawer that reveals a person's lists when expanded. Reuses
/// `ListTile` so the visuals match the floating Lists screen exactly.
private struct PersonListsExpansion: View {
    let person: UserProfile
    let isExpanded: Bool
    let onSelectList: (UserProfile, String) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var sortedListNames: [String] {
        person.lists.keys.sorted()
    }

    var body: some View {
        if isExpanded {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                    .padding(.top, 2)

                if sortedListNames.isEmpty {
                    Text("\(person.name) hasn't shared any lists yet.")
                        .font(.system(size: 13))
                        .foregroundColor(SomedayColors.grayMedium)
                        .padding(.top, 4)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(sortedListNames, id: \.self) { name in
                            ListTile(
                                name: name,
                                placeCount: person.lists[name]?.count ?? 0,
                                style: ListVisualStyle.style(for: name)
                            ) {
                                onSelectList(person, name)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// Tappable avatar + name that switches the tile to the person's profile.
private struct PersonHeaderLink: View {
    let user: UserProfile
    let caption: Text
    let date: Date
    let avatarSize: CGFloat
    let onSelect: (UserProfile) -> Void

    var body: some View {
        Button {
            onSelect(user)
        } label: {
            HStack(spacing: 10) {
                ActivityAvatar(user: user, size: avatarSize)
                VStack(alignment: .leading, spacing: 1) {
                    caption
                        .font(.system(size: 14))
                        .foregroundColor(SomedayColors.charcoal)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ActivityTime.string(for: date))
                        .font(.system(size: 12))
                        .foregroundColor(SomedayColors.grayMedium)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct VisitedTile: View {
    let friend: UserProfile
    let place: Place
    let date: Date
    let onSelectList: (UserProfile, String) -> Void
    let onSelectPerson: (UserProfile) -> Void
    let action: () -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PersonHeaderLink(
                    user: friend,
                    caption: Text(friend.name).fontWeight(.semibold) + Text(" visited"),
                    date: date,
                    avatarSize: 34,
                    onSelect: onSelectPerson
                )
                Spacer()
                if let rating = place.displayedRating?.value {
                    Text(formatRating(rating))
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(SomedayColors.primary)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(SomedayColors.primaryLight)
                        .clipShape(Capsule())
                }
                ExpandChevron(isExpanded: $isExpanded)
            }

            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: place.category.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(SomedayColors.primary)
                        .frame(width: 38, height: 38)
                        .background(SomedayColors.primaryLight)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(SomedayColors.charcoal)
                        Text(place.neighborhood.isEmpty ? place.category.displayName : place.neighborhood)
                            .font(.system(size: 13))
                            .foregroundColor(SomedayColors.grayMedium)
                    }
                    Spacer()
                    Image(systemName: "map.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SomedayColors.primary)
                }
            }
            .buttonStyle(.plain)

            PersonListsExpansion(person: friend, isExpanded: isExpanded, onSelectList: onSelectList)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func formatRating(_ value: Double) -> String {
        let r = (value * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))" : String(format: "%.1f", r)
    }
}

private struct FollowTile: View {
    let person: UserProfile
    let isRequest: Bool
    let date: Date
    let onSelectList: (UserProfile, String) -> Void
    let onSelectPerson: (UserProfile) -> Void
    @State private var followed = false
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PersonHeaderLink(
                    user: person,
                    caption: Text(person.name).fontWeight(.semibold) + Text(" started following you"),
                    date: date,
                    avatarSize: 32,
                    onSelect: onSelectPerson
                )

                Spacer(minLength: 8)

                Button {
                    withAnimation(SomedayAnimations.followCTA) { followed = true }
                } label: {
                    Text(followed ? "Following" : (isRequest ? "Accept" : "Follow back"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(followed ? SomedayColors.grayMedium : SomedayColors.butter)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(followed ? AnyShapeStyle(SomedayColors.grayLight) : AnyShapeStyle(SomedayColors.green))
                        .clipShape(Capsule())
                }
                .disabled(followed)

                ExpandChevron(isExpanded: $isExpanded)
            }

            PersonListsExpansion(person: person, isExpanded: isExpanded, onSelectList: onSelectList)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

private struct SharedListTile: View {
    let friend: UserProfile
    let listName: String
    let count: Int
    let date: Date
    let onSelectList: (UserProfile, String) -> Void
    let onSelectPerson: (UserProfile) -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // Avatar + name route to the person's profile via the
                // tile's own state-based navigation (no NavigationStack).
                Button { onSelectPerson(friend) } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(SomedayColors.amber.opacity(0.22))
                                .frame(width: 44, height: 44)
                            Image(systemName: "list.bullet.rectangle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(SomedayColors.butterDeep)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            (Text(friend.name).fontWeight(.semibold) + Text(" shared a list"))
                                .font(.system(size: 14))
                                .foregroundColor(SomedayColors.charcoal)
                            HStack(spacing: 6) {
                                Text(listName)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(SomedayColors.charcoal)
                                Text("·").foregroundColor(SomedayColors.grayMedium)
                                Text("\(count) place\(count == 1 ? "" : "s")")
                                    .font(.system(size: 13))
                                    .foregroundColor(SomedayColors.grayMedium)
                            }
                            Text(ActivityTime.string(for: date))
                                .font(.system(size: 12))
                                .foregroundColor(SomedayColors.grayMedium)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()
                ExpandChevron(isExpanded: $isExpanded)
            }

            PersonListsExpansion(person: friend, isExpanded: isExpanded, onSelectList: onSelectList)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

// MARK: - Person profile (their lists + follow/subscribe)

struct PersonProfileView: View {
    let person: UserProfile
    let places: [Place]
    let onSelectPlace: (Place) -> Void

    @State private var following: Bool

    init(person: UserProfile, places: [Place], isFollowing: Bool, onSelectPlace: @escaping (Place) -> Void) {
        self.person = person
        self.places = places
        self.onSelectPlace = onSelectPlace
        self._following = State(initialValue: isFollowing)
    }

    private var sortedLists: [(name: String, ids: [String])] {
        person.lists.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private var savedCount: Int {
        Set(person.lists.values.flatMap { $0 }).count
    }

    private func place(_ id: String) -> Place? { places.first { $0.id == id } }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header

                if sortedLists.isEmpty {
                    emptyState
                } else {
                    ForEach(sortedLists, id: \.name) { list in
                        listCard(name: list.name, ids: list.ids)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        // Title + nav chrome handled by the surrounding ActivityView tile;
        // PersonProfileView is now embedded directly without a NavigationStack.
    }

    private var header: some View {
        VStack(spacing: 12) {
            ActivityAvatar(user: person, size: 84)

            Text(person.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(SomedayColors.charcoal)

            Text("\(person.lists.count) list\(person.lists.count == 1 ? "" : "s") · \(savedCount) place\(savedCount == 1 ? "" : "s")")
                .font(.system(size: 14))
                .foregroundColor(SomedayColors.grayMedium)

            subscribeButton
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var subscribeButton: some View {
        Button {
            withAnimation(SomedayAnimations.followCTA) { following.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: following ? "checkmark" : "plus")
                    .font(.system(size: 13, weight: .bold))
                Text(following ? "Following" : "Subscribe")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(following ? SomedayColors.charcoal : SomedayColors.butter)
            .padding(.horizontal, 22).padding(.vertical, 11)
            .background(following ? AnyShapeStyle(SomedayColors.grayLight) : AnyShapeStyle(SomedayColors.green))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(SomedayColors.grayMedium.opacity(following ? 0.25 : 0), lineWidth: 1)
            )
        }
    }

    private func listCard(name: String, ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.butterDeep)
                Text(name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
                Spacer()
                Text("\(ids.count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(SomedayColors.grayMedium)
            }

            VStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.offset) { index, id in
                    if let p = place(id) {
                        Button { onSelectPlace(p) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: p.category.icon)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(SomedayColors.primary)
                                    .frame(width: 32, height: 32)
                                    .background(SomedayColors.primaryLight)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(SomedayColors.charcoal)
                                    Text(p.neighborhood.isEmpty ? p.category.displayName : p.neighborhood)
                                        .font(.system(size: 12))
                                        .foregroundColor(SomedayColors.grayMedium)
                                }
                                Spacer()
                                Image(systemName: "map.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(SomedayColors.primary)
                            }
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        if index < ids.count - 1 {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundColor(SomedayColors.grayMedium)
            Text("No lists yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(SomedayColors.grayMedium)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Shared bits

private struct ActivityAvatar: View {
    let user: UserProfile
    let size: CGFloat

    var body: some View {
        AsyncImage(url: user.avatarURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Circle().fill(SomedayColors.friendColor(for: abs(user.id.hashValue)).opacity(0.3))
                    .overlay(
                        Text(user.initials.prefix(1))
                            .font(.system(size: size * 0.42, weight: .bold))
                            .foregroundColor(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white, lineWidth: size > 50 ? 3 : 1.5))
    }
}

enum ActivityTime {
    static func string(for date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        let minutes = Int(seconds / 60)
        let hours = Int(seconds / 3600)
        let days = Int(seconds / 86_400)
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        if hours < 24 { return "\(hours)h ago" }
        if days == 1 { return "Yesterday" }
        return "\(days)d ago"
    }
}

// MARK: - Friend request tile
//
// Distinct from `FollowTile` (which is for the mock `.startedFollowing`
// events). This one is wired to the real `friend_requests` table:
// Accept calls `accept_friend_request` RPC; Reject just deletes the row.

private struct FriendRequestTile: View {
    let request: IncomingFriendRequest
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            requestAvatar
            VStack(alignment: .leading, spacing: 2) {
                (Text(request.name).fontWeight(.semibold) + Text(" wants to be friends"))
                    .font(.system(size: 14))
                    .foregroundColor(SomedayColors.charcoal)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ActivityTime.string(for: request.createdAt))
                    .font(.system(size: 12))
                    .foregroundColor(SomedayColors.grayMedium)
            }

            Spacer(minLength: 8)

            // Reject — secondary, neutral chip.
            Button {
                Haptics.soft()
                onReject()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(SomedayColors.grayMedium)
                    .frame(width: 32, height: 32)
                    .background(SomedayColors.grayLight)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            // Accept — primary, brand green.
            Button {
                Haptics.medium()
                onAccept()
            } label: {
                Text("Accept")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.butter)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(SomedayColors.green)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    /// Avatar tile — reuses the same async-image + initials fallback the
    /// rest of Activity uses, so the visual reads consistently. Inlined
    /// (rather than reusing `ActivityAvatar`) because that view depends
    /// on `UserProfile`, which we don't have for a bare request — we
    /// only get id/name/avatarURL from the join.
    private var requestAvatar: some View {
        let size: CGFloat = 40
        let initial = request.name.first.map(String.init)?.uppercased() ?? "?"
        return AsyncImage(url: request.avatarURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Circle()
                    .fill(SomedayColors.friendColor(for: abs(request.id.hashValue)).opacity(0.3))
                    .overlay(
                        Text(initial)
                            .font(.system(size: size * 0.42, weight: .bold))
                            .foregroundColor(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white, lineWidth: 1.5))
    }
}
