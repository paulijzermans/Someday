import SwiftUI

struct FriendExplorer: Identifiable {
    let id: String
    let profile: UserProfile
    let tipCount: Int
    let topCategories: [PlaceCategory]
    let places: [Place]
}

struct FriendsListView: View {
    let places: [Place]
    let friends: [UserProfile]
    let onSelectFriend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expandedFriend: String?

    private var explorers: [FriendExplorer] {
        var results: [FriendExplorer] = []

        for friend in friends {
            let friendPlaces = places.filter { $0.visitedByIDs.contains(friend.id) || $0.recommendedBy == friend.id }

            var categories: [PlaceCategory] = []
            for place in friendPlaces where !categories.contains(place.category) {
                categories.append(place.category)
            }

            results.append(FriendExplorer(
                id: friend.id,
                profile: friend,
                tipCount: friendPlaces.count,
                topCategories: Array(categories.prefix(3)),
                places: friendPlaces
            ))
        }

        return results.sorted { $0.tipCount > $1.tipCount }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 13))
                            .foregroundColor(SomedayColors.green)
                        Text("Top Explorers")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(SomedayColors.green.opacity(0.65))
                        Spacer()
                    }
                    .padding(.horizontal, 4)

                    ForEach(Array(explorers.enumerated()), id: \.element.id) { index, explorer in
                        FriendTile(
                            explorer: explorer,
                            allPlaces: places,
                            rank: index + 1,
                            isExpanded: expandedFriend == explorer.id,
                            onTap: {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    expandedFriend = expandedFriend == explorer.id ? nil : explorer.id
                                }
                            },
                            onShowOnMap: {
                                onSelectFriend(explorer.id)
                            }
                        )
                    }
                }
                .padding(16)
            }
            .background(SomedayColors.grayLight)
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(SomedayColors.charcoal)
                            .frame(width: 32, height: 32)
                            .background(SomedayColors.grayLight)
                            .clipShape(Circle())
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {} label: {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 16))
                            .foregroundColor(SomedayColors.primary)
                    }
                }
            }
        }
    }
}

struct FriendTile: View {
    let explorer: FriendExplorer
    let allPlaces: [Place]
    let rank: Int
    let isExpanded: Bool
    let onTap: () -> Void
    let onShowOnMap: () -> Void

    @State private var selectedList: String?

    private var listNames: [String] {
        Array(explorer.profile.lists.keys).sorted()
    }

    private var visiblePlaces: [Place] {
        guard let list = selectedList,
              let placeIDs = explorer.profile.lists[list] else {
            return explorer.places
        }
        let idSet = Set(placeIDs)
        return allPlaces.filter { idSet.contains($0.id) }
    }

    private var rankDisplay: String {
        "#\(rank)"
    }

    /// Identity color tied to the friend (matches their map pin color).
    private var friendColor: Color {
        SomedayColors.friendColor(for: rank - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    ZStack(alignment: .bottomTrailing) {
                        AsyncImage(url: explorer.profile.avatarURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Circle().fill(friendColor.opacity(0.3))
                                    .overlay(
                                        Text(explorer.profile.initials.prefix(1))
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(.white)
                                    )
                            }
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(friendColor, lineWidth: 2.5))

                        if rank <= 3 {
                            Text("\(rank)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(SomedayColors.butter)
                                .frame(width: 20, height: 20)
                                .background(SomedayColors.green)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .offset(x: 4, y: 4)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(explorer.profile.name)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(SomedayColors.green)
                            if rank > 3 {
                                Text(rankDisplay)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(SomedayColors.green.opacity(0.55))
                            }
                        }
                        HStack(spacing: 6) {
                            HStack(spacing: 2) {
                                ForEach(explorer.topCategories, id: \.self) { cat in
                                    Image(systemName: cat.icon)
                                        .font(.system(size: 13))
                                        .foregroundColor(SomedayColors.green.opacity(0.7))
                                }
                            }
                            Text("\(explorer.tipCount) \(explorer.tipCount == 1 ? "tip" : "tips")")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(SomedayColors.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(SomedayColors.butter)
                                .cornerRadius(10)
                        }
                    }
                    Spacer()

                    Button(action: onShowOnMap) {
                        HStack(spacing: 4) {
                            Image(systemName: "map.fill")
                                .font(.system(size: 11))
                            Text("Map")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(SomedayColors.green)
                        .foregroundColor(SomedayColors.butter)
                        .cornerRadius(10)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SomedayColors.grayMedium)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(16)
            }

            if isExpanded {
                VStack(spacing: 0) {
                    Divider().padding(.horizontal, 16)

                    if !listNames.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ListPill(label: "All", isSelected: selectedList == nil) {
                                    withAnimation(.spring(response: 0.3)) { selectedList = nil }
                                }
                                ForEach(listNames, id: \.self) { name in
                                    ListPill(label: name, isSelected: selectedList == name) {
                                        withAnimation(.spring(response: 0.3)) {
                                            selectedList = selectedList == name ? nil : name
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(visiblePlaces) { place in
                                PlaceMiniTile(place: place)
                            }
                        }
                        .padding(16)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.white)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { selectedList = nil }
        }
    }
}

struct PlaceMiniTile: View {
    let place: Place

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(
                    colors: [SomedayColors.butter, SomedayColors.butterDeep],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 120, height: 80)
                .overlay(
                    Image(systemName: place.category.icon)
                        .font(.system(size: 28))
                        .foregroundColor(SomedayColors.green)
                )

            Text(place.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SomedayColors.green)
                .lineLimit(1)

            Text(place.neighborhood)
                .font(.system(size: 11))
                .foregroundColor(SomedayColors.green.opacity(0.55))
                .lineLimit(1)
        }
        .frame(width: 120)
    }
}

struct ListPill: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? SomedayColors.primary : .white)
                .foregroundColor(isSelected ? .white : SomedayColors.charcoal)
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(isSelected ? Color.clear : Color(.systemGray4), lineWidth: 1)
                )
        }
    }
}
