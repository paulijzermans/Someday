import SwiftUI

/// Centered floating tile shown when the user taps the **Lists** tab.
///
/// One unified grid: the user's own lists first (no avatar overlay),
/// then friend-shared lists (each tile carries the curator's avatar in
/// the bottom-right corner so ownership is obvious at a glance), then
/// the "+ new list" tile at the end. The previous tab split made shared
/// lists feel like a separate inventory — they're really just lists
/// owned by someone else, so they live in the same wall.
///
/// Lives inside the map's ZStack rather than a system sheet, so it sits
/// in the middle of the screen with the same horizontal inset as the
/// bottom tab bar.
struct ListsGridView: View {
    let lists: [String: [String]]   // listName -> [placeID]
    /// User-created lists with optional cover photos.
    var customLists: [CustomList] = []
    /// Friends whose curated lists appear in the unified grid. Each
    /// shared list renders with the friend's avatar overlay.
    var friends: [UserProfile] = []
    /// Tap on one of the user's own lists.
    let onSelectList: (String) -> Void
    /// Tap on a shared list. Defaulted so the existing call sites that
    /// don't yet handle shared-list taps stay source-compatible.
    var onSelectSharedList: (UserProfile, String) -> Void = { _, _ in }
    /// User dropped list `source` onto list `target` via drag-and-drop.
    /// The parent (MapHomeView) raises the "Merge X with Y?" alert and
    /// — on confirm — calls `MapViewModel.mergeCustomList`. We keep the
    /// alert at the parent level rather than here because presenting an
    /// alert from a view that's about to dismiss races with the alert
    /// lifecycle and crashes on iOS.
    var onMergeRequested: (_ source: String, _ target: String) -> Void = { _, _ in }
    /// User picked "Delete list" from a tile's context menu. Same
    /// reasoning as merge — confirmation alert lives at MapHomeView.
    var onDeleteRequested: (_ name: String) -> Void = { _ in }
    let onCreateList: () -> Void
    let onDismiss: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var sortedListNames: [String] {
        lists.keys.sorted()
    }

    /// Flattened (friend, listName, placeIDs) for the Shared tab. Sorted
    /// by friend name then list name so the grid is stable.
    private var sharedEntries: [SharedListEntry] {
        var out: [SharedListEntry] = []
        for friend in friends {
            for (name, placeIDs) in friend.lists where !name.isEmpty {
                out.append(SharedListEntry(friend: friend, name: name, placeIDs: placeIDs))
            }
        }
        return out.sorted { lhs, rhs in
            if lhs.friend.name != rhs.friend.name { return lhs.friend.name < rhs.friend.name }
            return lhs.name < rhs.name
        }
    }

    var body: some View {
        tile.floatingTile(size: .large, onDismiss: onDismiss)
    }

    private var tile: some View {
        VStack(spacing: 14) {
            header
            unifiedGrid
        }
        .padding(.top, 16)
        // Glass + shadow + frame come from `.floatingTile(size: .large)`
        // in `body`.
    }

    private var header: some View {
        HStack {
            Text("Lists")
                .font(.system(size: 18, weight: .bold))
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
        .padding(.horizontal, 18)
    }

    // MARK: - Unified grid
    //
    // One scroll view, one LazyVGrid. Render order:
    //   1) Own custom lists (with cover photos when set).
    //   2) Own dict-based lists from the user profile.
    //   3) Shared lists from friends — same tile silhouette, plus a
    //      24pt avatar chip overlaid in the bottom-right corner so the
    //      curator's identity is unambiguous.
    //   4) "+ new list" tile, always last so the create affordance is
    //      reachable but never interrupts the existing inventory.

    private var unifiedGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                // (1) User-created lists first — they have cover photos
                // and feel "more theirs", so they lead.
                //
                // Each is both `.draggable` (carrying its name as the
                // payload) and a `.dropDestination` that accepts another
                // list name. Dropping one onto another sets `pendingMerge`,
                // which raises the confirmation alert. Long-press is the
                // system default to start dragging — no extra gesture
                // recogniser needed.
                ForEach(customLists) { custom in
                    let style = ListVisualStyle.style(for: custom.name)
                    ListTile(
                        name: custom.name,
                        placeCount: custom.placeIDs.count,
                        style: style,
                        imageData: custom.imageData
                    ) {
                        onSelectList(custom.name)
                        onDismiss()
                    }
                    // iOS Home-Screen-style context menu — long-press
                    // brings up Delete. Coexists with `.draggable`: if
                    // the user lifts and releases, the menu shows; if
                    // they lift and start moving, drag takes over.
                    .contextMenu {
                        Button(role: .destructive) {
                            onDeleteRequested(custom.name)
                        } label: {
                            Label("Delete list", systemImage: "trash")
                        }
                    }
                    // Custom drag preview: just the icon tile, no caption
                    // beneath. Mirrors iOS Home Screen drag — the user
                    // sees a single floating chip following the finger.
                    .draggable(custom.name) {
                        DragTilePreview(
                            style: style,
                            imageData: custom.imageData
                        )
                    }
                    .dropDestination(for: String.self) { items, _ in
                        // Take the first dropped name; reject same-list
                        // drops (no-op merge) and drops from any source
                        // not in our own customLists (dict/shared lists
                        // aren't mergeable).
                        guard let source = items.first,
                              source != custom.name,
                              customLists.contains(where: { $0.name == source })
                        else { return false }
                        // Hop up to the parent — it owns the confirmation
                        // alert. We *don't* dismiss the tile here; the
                        // parent does that after the alert closes so the
                        // alert never overlaps a dismissing view.
                        onMergeRequested(source, custom.name)
                        return true
                    }
                    // Heavy "lift" haptic the moment the drag gesture
                    // crosses iOS's long-press threshold. `.draggable`
                    // doesn't expose a start hook, so we run a parallel
                    // `LongPressGesture` with the same minimum duration
                    // and fire on its `onEnded` — that lands exactly
                    // when the drag preview lifts off. The two
                    // gestures are kept independent via
                    // `simultaneousGesture` so neither swallows the
                    // other's events.
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.4)
                            .onEnded { _ in Haptics.heavy() }
                    )
                }

                // (2) Dict-based lists from the user model.
                ForEach(sortedListNames, id: \.self) { name in
                    ListTile(
                        name: name,
                        placeCount: lists[name]?.count ?? 0,
                        style: ListVisualStyle.style(for: name)
                    ) {
                        onSelectList(name)
                        onDismiss()
                    }
                }

                // (3) Shared lists — same tile, plus avatar overlay.
                ForEach(sharedEntries) { entry in
                    FriendListGridTile(
                        entry: entry,
                        style: ListVisualStyle.style(for: entry.name)
                    ) {
                        onSelectSharedList(entry.friend, entry.name)
                        onDismiss()
                    }
                }

                // (4) Always-last create tile.
                AddListTile(action: onCreateList)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .padding(.top, 6)
        }
    }
}

// MARK: - Shared list entry + tile

/// Flattened representation of a single friend-curated list — used as
/// the data source for the Shared tab's grid.
struct SharedListEntry: Identifiable, Hashable {
    let friend: UserProfile
    let name: String
    let placeIDs: [String]

    /// Stable composite id — same friend + same list name = same entry,
    /// so SwiftUI ForEach diffing works even though the underlying data
    /// is recomputed from the friends array on every render.
    var id: String { "\(friend.id)::\(name)" }
}

/// Like `ListTile` but smaller text and an avatar chip in the bottom-
/// right corner so the user sees whose list it is at a glance.
struct FriendListGridTile: View {
    let entry: SharedListEntry
    let style: ListVisualStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                tileBody
                    .overlay(alignment: .bottomTrailing) {
                        avatar
                            .padding(6)
                    }

                VStack(spacing: 1) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SomedayColors.charcoal)
                        .lineLimit(1)
                    Text("\(entry.friend.name.split(separator: " ").first.map(String.init) ?? entry.friend.name) · \(entry.placeIDs.count)")
                        .font(.system(size: 10))
                        .foregroundColor(SomedayColors.grayMedium)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Coloured-shape tile face. Same silhouette as the regular ListTile
    /// so own + shared lists feel like they live in one design system.
    private var tileBody: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(style.color.opacity(0.16))
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                Image(systemName: style.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(style.color)
            )
    }

    /// Small (24pt) avatar chip with a thin white ring — fits inside
    /// the tile's bottom-right corner without crowding the symbol.
    private var avatar: some View {
        AsyncImage(url: entry.friend.avatarURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Circle().fill(SomedayColors.primary.opacity(0.3))
                    .overlay(
                        Text(entry.friend.initials.prefix(1))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    )
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white, lineWidth: 2))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }
}

// MARK: - Tile

/// Single list cell — colored shape + name + place count.
/// Public so the Activity feed can drop the same tile inside its expandable
/// person rows, keeping the visual language consistent across the app.
struct ListTile: View {
    let name: String
    let placeCount: Int
    let style: ListVisualStyle
    /// Cover photo bytes if the user attached one when creating the list.
    /// When set, replaces the colored-shape background.
    var imageData: Data? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                tileBody

                VStack(spacing: 1) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SomedayColors.charcoal)
                        .lineLimit(1)
                    Text("\(placeCount) \(placeCount == 1 ? "place" : "places")")
                        .font(.system(size: 10))
                        .foregroundColor(SomedayColors.grayMedium)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Square tile face — either the cover photo (with the deterministic
    /// shape icon overlaid for identity) or the colored-shape fallback.
    /// Both variants use the same `RoundedRectangle` shape used by
    /// `AddListTile` so all cells in the grid share one silhouette.
    @ViewBuilder
    private var tileBody: some View {
        if let imageData, let uiImage = UIImage(data: imageData) {
            // Square photo tile — the photo speaks for itself, no shape
            // overlay competing for attention. Subtle bottom gradient keeps
            // the place-count caption readable when the photo is bright.
            RoundedRectangle(cornerRadius: 18)
                .fill(style.color.opacity(0.16))
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                )
                .overlay(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.25)],
                        startPoint: .center, endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))
        } else {
            RoundedRectangle(cornerRadius: 18)
                .fill(style.color.opacity(0.16))
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Image(systemName: style.symbol)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(style.color)
                )
        }
    }
}

/// Minimal floating chip used as the drag preview when the user picks
/// up a list tile. Just the same rounded-corner icon square the cell
/// already shows — nothing else. iOS adds its own lift shadow + slight
/// scale around whatever view we hand it, so we deliberately omit a
/// background fill or our own shadow: stacking those on top of the
/// system effect was producing the cluttered "weird component" the
/// user reported. The result is one clean rounded square following
/// the finger.
struct DragTilePreview: View {
    let style: ListVisualStyle
    var imageData: Data? = nil

    var body: some View {
        Group {
            if let imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                // Same opacity/symbol pairing as the resting tile so
                // the visual is continuous from cell → drag preview.
                style.color.opacity(0.16)
                    .overlay(
                        Image(systemName: style.symbol)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(style.color)
                    )
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct AddListTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(SomedayColors.grayMedium.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                        .aspectRatio(1, contentMode: .fit)

                    Image(systemName: "plus")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(SomedayColors.grayMedium)
                }

                Text("New list")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Visual style mapping

/// Deterministic (shape, color) pair for a given list name. Same name
/// always produces the same tile, so users see a consistent identity for
/// each list without us having to persist styling to the database yet.
struct ListVisualStyle {
    let symbol: String
    let color: Color

    static let palette: [ListVisualStyle] = [
        ListVisualStyle(symbol: "heart.fill",       color: Color(red: 1.0, green: 0.32, blue: 0.45)),  // rose
        ListVisualStyle(symbol: "square.fill",      color: SomedayColors.primary),                     // blue
        ListVisualStyle(symbol: "circle.fill",      color: SomedayColors.accentGreen),                 // green
        ListVisualStyle(symbol: "star.fill",        color: SomedayColors.amber),                       // amber
        ListVisualStyle(symbol: "hexagon.fill",     color: Color(red: 0.55, green: 0.35, blue: 1.0)),  // purple
        ListVisualStyle(symbol: "diamond.fill",     color: SomedayColors.cyan),                        // cyan
        ListVisualStyle(symbol: "triangle.fill",    color: SomedayColors.coral),                       // coral
        ListVisualStyle(symbol: "leaf.fill",        color: Color(red: 0.10, green: 0.55, blue: 0.32)), // forest
        ListVisualStyle(symbol: "flame.fill",       color: Color(red: 1.0, green: 0.43, blue: 0.20)),  // orange
        ListVisualStyle(symbol: "moon.stars.fill",  color: Color(red: 0.30, green: 0.20, blue: 0.55)), // night
        ListVisualStyle(symbol: "bolt.fill",        color: Color(red: 1.0, green: 0.78, blue: 0.20)),  // gold
        ListVisualStyle(symbol: "cloud.fill",       color: Color(red: 0.40, green: 0.62, blue: 0.85))  // sky
    ]

    /// Stable hash of the name modulo palette size → consistent style.
    static func style(for name: String) -> ListVisualStyle {
        guard !palette.isEmpty else {
            return ListVisualStyle(symbol: "circle.fill", color: SomedayColors.primary)
        }
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}
