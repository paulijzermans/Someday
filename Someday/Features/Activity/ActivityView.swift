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
    let followingIDs: Set<String>
    var onSelectPlace: (Place) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(events) { event in
                        EventTile(event: event, onSelectPlace: onSelectPlace)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(SomedayColors.grayLight)
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UserProfile.self) { person in
                PersonProfileView(
                    person: person,
                    places: places,
                    isFollowing: followingIDs.contains(person.id),
                    onSelectPlace: onSelectPlace
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SomedayColors.primary)
                }
            }
        }
    }
}

// MARK: - Event tiles

private struct EventTile: View {
    let event: ActivityFeedEvent
    let onSelectPlace: (Place) -> Void

    var body: some View {
        switch event.kind {
        case .visited(let friend, let place):
            VisitedTile(friend: friend, place: place, date: event.date) { onSelectPlace(place) }
        case .startedFollowing(let person, let isRequest):
            FollowTile(person: person, isRequest: isRequest, date: event.date)
        case .sharedList(let friend, let name, let placeIDs):
            SharedListTile(friend: friend, listName: name, count: placeIDs.count, date: event.date)
        }
    }
}

/// Tappable avatar + name that pushes the person's profile.
private struct PersonHeaderLink: View {
    let user: UserProfile
    let caption: Text
    let date: Date
    let avatarSize: CGFloat

    var body: some View {
        NavigationLink(value: user) {
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
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PersonHeaderLink(
                    user: friend,
                    caption: Text(friend.name).fontWeight(.semibold) + Text(" visited"),
                    date: date,
                    avatarSize: 34
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
    @State private var followed = false

    var body: some View {
        HStack(spacing: 10) {
            PersonHeaderLink(
                user: person,
                caption: Text(person.name).fontWeight(.semibold) + Text(" started following you"),
                date: date,
                avatarSize: 32
            )

            Spacer(minLength: 8)

            Button {
                withAnimation(.spring(response: 0.3)) { followed = true }
            } label: {
                Text(followed ? "Following" : (isRequest ? "Accept" : "Follow back"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(followed ? SomedayColors.grayMedium : SomedayColors.butter)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(followed ? AnyShapeStyle(SomedayColors.grayLight) : AnyShapeStyle(SomedayColors.green))
                    .clipShape(Capsule())
            }
            .disabled(followed)
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

    var body: some View {
        NavigationLink(value: friend) {
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
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
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
        .background(SomedayColors.grayLight)
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
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
            withAnimation(.spring(response: 0.3)) { following.toggle() }
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
