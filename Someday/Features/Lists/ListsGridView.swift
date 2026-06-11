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
    /// User dragged list `source` onto list `target` while in edit
    /// (jiggle) mode — meaning they want to *reorder*, not merge. The
    /// parent forwards to `MapViewModel.reorderCustomList(named:beforeName:)`.
    var onReorderRequested: (_ source: String, _ beforeTarget: String) -> Void = { _, _ in }
    /// Membership-editor mode driver. When non-nil, the grid is in
    /// "toggle membership" mode for the carried place id:
    ///   • Each own-list tile renders with a coloured border when
    ///     `isMember(listName)` returns true.
    ///   • Tapping an own-list tile fires `onToggle(listName)` instead
    ///     of `onSelectList(listName)` — and DOES NOT dismiss the grid.
    ///   • The header swaps to "In which lists?" so the new affordance
    ///     reads clearly.
    ///   • The "+ new list" tile and the friend-shared tiles stay
    ///     un-bordered and un-tappable (membership in friends' lists
    ///     isn't yours to flip).
    var membershipMode: MembershipMode? = nil
    let onCreateList: () -> Void
    let onDismiss: () -> Void
    /// Edit (home-screen jiggle) mode. Long-pressing any tile flips
    /// this on for the whole grid. While on, tiles wiggle, show a ×
    /// badge in the top-left, and drag-and-drop reorders instead of
    /// merging. Tapping the "Done" pill or anywhere off-tile exits.
    @State private var isEditing = false
    /// Name of the tile currently being dragged in edit mode. Only one
    /// tile drags at a time. `nil` when idle.
    @State private var draggingName: String?
    /// Live translation applied to the dragged tile while the finger
    /// is down. Reset to `.zero` on drop / cancel.
    @State private var dragOffset: CGSize = .zero
    /// Recorded frame of every own-list tile, in the grid's coordinate
    /// space. Populated via a PreferenceKey + GeometryReader background
    /// on each tile, then read in the drag's `onEnded` to figure out
    /// which slot the user released over.
    @State private var tileFrames: [String: CGRect] = [:]

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    /// Carrier for the toggle-membership UI mode. See `membershipMode`
    /// above for behaviour. Held as a value type so `Equatable`
    /// re-renders are cheap.
    struct MembershipMode: Equatable {
        /// The pin whose list memberships are being edited. Captured
        /// here only for debugging / display — the toggle callback is
        /// what actually flips state.
        let placeID: String
        /// Pure predicate: does the named list currently contain the
        /// editing pin? Drives the per-tile highlight border.
        let isMember: (String) -> Bool
        /// Toggle handler — called with the list name on every tap of
        /// an own-list tile while in this mode. Idempotent.
        let onToggle: (String) -> Void

        static func == (lhs: MembershipMode, rhs: MembershipMode) -> Bool {
            lhs.placeID == rhs.placeID
        }
    }

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
        // Tap anywhere on the empty area of the lists tile to exit
        // edit mode — same iPhone Home Screen idiom (tap outside any
        // app to leave jiggle).
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditing {
                withAnimation(.easeOut(duration: 0.18)) { isEditing = false }
            }
        }
        // Glass + shadow + frame come from `.floatingTile(size: .large)`
        // in `body`.
    }

    private var header: some View {
        HStack {
            // Title swaps to a clear instruction when the grid is in
            // membership-editor mode so the new tap behaviour (toggle
            // membership instead of open list) reads as intentional.
            Text(membershipMode != nil ? "In which lists?" : "Lists")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(SomedayColors.charcoal)
            Spacer()
            // In edit mode, the close button is replaced by a "Done"
            // pill — same iPhone Home Screen idiom: tap Done to exit
            // the jiggle, not the screen.
            if isEditing {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { isEditing = false }
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(SomedayColors.primary))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(SomedayColors.grayMedium)
                        .frame(width: 28, height: 28)
                        .background(SomedayColors.grayLight)
                        .clipShape(Circle())
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 18)
        .animation(.easeInOut(duration: 0.2), value: isEditing)
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
                ForEach(Array(customLists.enumerated()), id: \.element.id) { idx, custom in
                    customListTile(custom: custom, index: idx)
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
            // Collect every own-list tile's frame in this named
            // coordinate space so the manual drag in edit mode can
            // hit-test the drop position against neighbours.
            .coordinateSpace(name: ListsGridView.coordSpace)
            .onPreferenceChange(TileFramePreferenceKey.self) { tileFrames = $0 }
        }
    }

    /// Coordinate space name shared by every own-list tile's frame
    /// reporter and the drag gesture's location math.
    fileprivate static let coordSpace = "listsGridReorder"

    /// One own-list tile + all the gesture / visual state attached to
    /// it. Extracted from the body so the (non-edit merge) and (edit
    /// reorder) branches can be expressed with `if isEditing` instead
    /// of stacking both gesture systems on every cell — which iOS would
    /// arbitrate unpredictably.
    @ViewBuilder
    private func customListTile(custom: CustomList, index: Int) -> some View {
        let style = ListVisualStyle.style(for: custom.name)
        let isThisDragging = (draggingName == custom.name)
        // Membership-editor highlights: only resolve `isMember` when the
        // mode is actually on so we don't re-evaluate the closure for
        // every tile on every unrelated render.
        let isMember = membershipMode?.isMember(custom.name) ?? false

        ListTile(
            name: custom.name,
            placeCount: custom.placeIDs.count,
            style: style,
            imageData: custom.imageData,
            isEditing: isEditing,
            wiggleSeed: index,
            onDeleteTap: { onDeleteRequested(custom.name) },
            isSelected: isMember,
            action: {
                // Tap is suppressed in edit mode — the × badge and the
                // tile movement own the gesture surface there.
                guard !isEditing else { return }
                // Membership-editor mode: tap toggles list membership
                // (in → remove, out → add) and DOES NOT dismiss the
                // grid — the user can keep flipping lists until they
                // close the overlay.
                if let mode = membershipMode {
                    mode.onToggle(custom.name)
                    return
                }
                onSelectList(custom.name)
                onDismiss()
            }
        )
        // Record this tile's resting frame so the drag's `onEnded` can
        // figure out which slot the user released over. We DON'T
        // record the offset-during-drag — only the natural frame —
        // because that's the slot the dragged tile would target.
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(
                        key: TileFramePreferenceKey.self,
                        value: [custom.name: geo.frame(in: .named(ListsGridView.coordSpace))]
                    )
            }
        )
        // Lift + offset while dragging. zIndex pulls the dragged tile
        // above its neighbours so it doesn't disappear behind them.
        // `animation(nil, value:)` skips animation on the drag offset
        // itself (we want it to track the finger 1:1) but the snap-
        // back on cancel still animates via the explicit
        // `withAnimation` in `onEnded`.
        .scaleEffect(isThisDragging ? 1.08 : 1.0)
        .opacity(isThisDragging ? 0.96 : 1.0)
        .shadow(color: .black.opacity(isThisDragging ? 0.18 : 0), radius: 10, y: 4)
        .offset(isThisDragging ? dragOffset : .zero)
        .zIndex(isThisDragging ? 100 : 0)
        .animation(.easeInOut(duration: 0.18), value: isThisDragging)
        // Non-edit mode keeps the system drag-and-drop merge: long-
        // press starts a system drag with a clean floating preview;
        // drop on another tile raises the merge alert. The context
        // menu also lives here — it's the entry point to edit mode.
        .modifier(NonEditDragAndDrop(
            isActive: !isEditing,
            name: custom.name,
            style: style,
            imageData: custom.imageData,
            customLists: customLists,
            onEnterEditMode: {
                Haptics.heavy()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                    isEditing = true
                }
            },
            onMergeRequested: onMergeRequested,
            onDeleteRequested: onDeleteRequested
        ))
        // Edit mode: a manual DragGesture that moves THIS tile as one
        // visual element. On release we hit-test the dropped position
        // against the recorded tileFrames and pick the slot to insert
        // before. No `.draggable` here — that double-attached the
        // gesture system and produced the "two elements" feeling.
        .gesture(
            isEditing
                ? DragGesture(coordinateSpace: .named(ListsGridView.coordSpace))
                    .onChanged { value in
                        if draggingName == nil {
                            draggingName = custom.name
                            Haptics.tap()
                        }
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        // Compute the centre of the tile in its
                        // *dropped* position — its resting frame plus
                        // the final translation — then find which
                        // recorded tile frame contains that point.
                        let dropped: String? = {
                            guard let mine = tileFrames[custom.name] else { return nil }
                            let centre = CGPoint(
                                x: mine.midX + value.translation.width,
                                y: mine.midY + value.translation.height
                            )
                            return tileFrames.first(where: { name, frame in
                                name != custom.name && frame.contains(centre)
                            })?.key
                        }()
                        if let target = dropped {
                            onReorderRequested(custom.name, target)
                        }
                        // Reset drag state. Use spring so a "no-drop"
                        // release snaps cleanly back to the slot.
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            draggingName = nil
                            dragOffset = .zero
                        }
                    }
                : nil
        )
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
            // Same outer wrapper as ListTile so own + shared + add
            // tiles share a single silhouette in the grid.
            .padding(10)
            .frame(maxWidth: .infinity)
            // Translucent liquid-glass material — the tile "floats"
            // over the map blur instead of sitting on an opaque white
            // card. Same `.glassEffect` material used by the floating
            // tile container itself and by the chat bubbles, so the
            // whole UI reads as one glass surface.
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            // Defined thin edge so shared-list tiles match the modern
            // outline of the own-list tiles beside them.
            .somedayCardEdge(cornerRadius: 20)
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
            .photoTileEdge(cornerRadius: 18)
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

/// Single list cell — one rounded container that wraps the colored
/// icon square AND the title / count beneath, so the whole thing reads
/// as ONE iPhone-style app tile rather than a stack of two visuals.
///
/// In edit mode the tile wiggles (home-screen pattern) and shows a ×
/// badge in the top-left corner that fires `onDeleteTap`.
///
/// Public so the Activity feed can drop the same tile inside its
/// expandable person rows, keeping the visual language consistent.
struct ListTile: View {
    let name: String
    let placeCount: Int
    let style: ListVisualStyle
    /// Cover photo bytes if the user attached one when creating the list.
    /// When set, replaces the colored-shape background.
    var imageData: Data? = nil
    /// Home-screen jiggle mode flag (driven by `ListsGridView.isEditing`).
    /// While true, the tile wiggles, shows a × badge, and ignores taps.
    var isEditing: Bool = false
    /// Per-tile phase seed so adjacent tiles don't wiggle in unison.
    /// `ListsGridView` passes the tile's index here.
    var wiggleSeed: Int = 0
    /// Fired when the user taps the × badge while in edit mode. The
    /// parent typically forwards to its `onDeleteRequested` callback.
    var onDeleteTap: () -> Void = {}
    /// Highlight outline driven by the Lists overlay's "edit membership"
    /// mode. When true, the tile gets a 3pt list-colour border so the
    /// user can see at a glance which lists the active pin already lives
    /// in. Purely visual — taps still flow through `action`.
    var isSelected: Bool = false
    let action: () -> Void

    /// Animation phase that toggles to drive `.rotationEffect`. Flipped
    /// in `.onChange(of: isEditing)` so the rotation only animates
    /// while editing — wiggling at rest would be distracting.
    @State private var wigglePhase = false

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
            // ONE rounded container around the icon + text. The fill
            // is near-white with a hairline border so the wrapper reads
            // as a single tile (the iPhone-icon-with-label gestalt)
            // without competing visually with the colored icon inside.
            .padding(10)
            .frame(maxWidth: .infinity)
            // Translucent liquid-glass material — the tile "floats"
            // over the map blur instead of sitting on an opaque white
            // card. Same `.glassEffect` material used by the floating
            // tile container itself and by the chat bubbles, so the
            // whole UI reads as one glass surface.
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            // Defined thin edge so the whole tile reads as one crisp,
            // modern element — same outline language as the icon face
            // inside it and the cards elsewhere in the app.
            .somedayCardEdge(cornerRadius: 20)
            // Membership-edit highlight. When this tile represents a
            // list the active pin already belongs to, draw a thick
            // border in the list's own colour so the user can see at a
            // glance which lists they're already in. Tap = toggle.
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        isSelected ? style.color : Color.clear,
                        lineWidth: 3
                    )
                    .animation(.easeInOut(duration: 0.18), value: isSelected)
            )
        }
        .buttonStyle(.plain)
        // ---- Home-screen jiggle + × badge ----
        // Rotation alternates between ±1.5° on a repeat-forever
        // animation. Seed-based delay keeps adjacent tiles out of
        // phase. Lift the rotation back to .zero when editing flips
        // off so old tiles don't stay tilted.
        .rotationEffect(
            isEditing
                ? .degrees(wigglePhase ? 1.5 : -1.5)
                : .zero
        )
        .animation(
            isEditing
                ? .easeInOut(duration: 0.13)
                    .repeatForever(autoreverses: true)
                    .delay(Double(wiggleSeed % 4) * 0.03)
                : .easeOut(duration: 0.18),
            value: wigglePhase
        )
        .onChange(of: isEditing) { _, on in
            // Kick the phase so the repeating animation starts. The
            // `.animation` modifier above only animates `wigglePhase`
            // changes, so toggling it here is what arms / disarms the
            // wiggle.
            wigglePhase = on
        }
        .overlay(alignment: .topLeading) {
            if isEditing {
                Button {
                    Haptics.tap()
                    onDeleteTap()
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.85)))
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                // Counter-rotate the badge so it stays still while the
                // tile beneath wiggles — same trick iOS uses on the
                // home screen so the × doesn't visually shake.
                .rotationEffect(
                    isEditing
                        ? .degrees(wigglePhase ? -1.5 : 1.5)
                        : .zero
                )
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    /// Square colored icon face — either the cover photo (with the
    /// deterministic shape icon overlaid for identity) or the
    /// colored-shape fallback. Same silhouette across both variants.
    @ViewBuilder
    private var tileBody: some View {
        if let imageData, let uiImage = UIImage(data: imageData) {
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
                // Defined thin edge around the icon face — same modern
                // outline language as the photo boxes across the app.
                .photoTileEdge(cornerRadius: 18)
        } else {
            RoundedRectangle(cornerRadius: 18)
                .fill(style.color.opacity(0.16))
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Image(systemName: style.symbol)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(style.color)
                )
                .photoTileEdge(cornerRadius: 18)
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
            // Match the floating glass treatment used by the other
            // tiles so all four cell variants (own, dict, friend, add)
            // share one silhouette.
            .padding(10)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            // Defined thin edge so the add tile matches the modern
            // outline of the list tiles beside it.
            .somedayCardEdge(cornerRadius: 20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reorder plumbing

/// Collects every own-list tile's frame (in the grid's named
/// coordinate space) so the manual drag in edit mode can hit-test
/// which slot the user released over. SwiftUI merges per-tile values
/// into a single dictionary at the parent.
private struct TileFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// `.draggable` + `.dropDestination` + `.contextMenu` — only attached
/// when we're NOT in edit mode. Wrapping these as a ViewModifier (vs
/// inline) lets the call site cleanly toggle the whole system drag-
/// and-drop off, so the manual `DragGesture` we attach for edit-mode
/// reorder doesn't fight iOS's gesture arbiter.
private struct NonEditDragAndDrop: ViewModifier {
    let isActive: Bool
    let name: String
    let style: ListVisualStyle
    let imageData: Data?
    let customLists: [CustomList]
    let onEnterEditMode: () -> Void
    let onMergeRequested: (_ source: String, _ target: String) -> Void
    let onDeleteRequested: (_ name: String) -> Void

    func body(content: Content) -> some View {
        if isActive {
            content
                .contextMenu {
                    Button {
                        onEnterEditMode()
                    } label: {
                        Label("Edit lists", systemImage: "square.grid.2x2")
                    }
                    Button(role: .destructive) {
                        onDeleteRequested(name)
                    } label: {
                        Label("Delete list", systemImage: "trash")
                    }
                }
                .draggable(name) {
                    DragTilePreview(style: style, imageData: imageData)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let source = items.first,
                          source != name,
                          customLists.contains(where: { $0.name == source })
                    else { return false }
                    onMergeRequested(source, name)
                    return true
                }
        } else {
            content
        }
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
