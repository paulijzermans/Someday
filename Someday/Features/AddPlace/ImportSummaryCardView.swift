import SwiftUI

/// Full-screen confirmation tile shown **after** an import finishes and
/// the pins have finished staggering onto the map. Lists every place we
/// just added, each as its own row tile, so the user gets a real summary
/// (not just a count) of what landed.
///
/// Visual rhythm matches the Lists / Activity / Add tiles — scrim +
/// centered glass card pinned between the search button and the profile
/// avatar — so confirmations feel like part of the same surface vocabulary.
struct ImportSummaryCardView: View {
    let summary: ImportSummary
    let onDismiss: () -> Void
    /// "Add" CTA next to "View on map". Hands the imported places off to
    /// the Lists picker so the user can stash them in one of their own
    /// custom lists in a single tap. Optional so existing call sites
    /// (e.g. unit tests) don't have to know about list-add.
    var onAdd: (() -> Void)? = nil

    /// Which place the slideshow is currently showing. Drives the page
    /// dots + the "n of m" counter; bound to the paging `TabView`.
    @State private var currentIndex: Int = 0
    /// Guards the one-shot "import landed" success haptic so SwiftUI
    /// re-renders don't re-fire it.
    @State private var didAnnounce: Bool = false

    var body: some View {
        // Results get the roomier `.half` tile so the slideshow cards have
        // space to breathe; loading / empty / region states stay snug in
        // the lower-third `.compact` tile.
        tile.floatingTile(size: tileSize, onDismiss: onDismiss)
    }

    private var tileSize: TileSize {
        if summary.isLoading || summary.isEmpty || allRegions { return .compact }
        return .half
    }

    /// Four render paths driven by the summary state. They share the
    /// outer padding and the close affordance so the tile feels stable
    /// when it morphs between states.
    ///
    /// `regionTile` fires when every imported item is a `.region` —
    /// the user shared a Google Maps country/city/area link rather
    /// than a real venue. We surface that explicitly rather than
    /// pretending a country is a pin.
    @ViewBuilder
    private var tile: some View {
        if summary.isLoading {
            loadingTile
        } else if summary.isEmpty {
            emptyTile
        } else if allRegions {
            regionTile
        } else {
            resultsTile
        }
    }

    /// True when the summary has at least one place AND every place is
    /// flagged as `.region`. Mixed venue+region imports still render as
    /// normal results — the venue rows are useful even if the region
    /// rows are noise; future iteration could filter the regions out
    /// of the list when there are venues alongside them.
    private var allRegions: Bool {
        !summary.places.isEmpty
            && summary.places.allSatisfy { $0.kind == .region }
    }

    // MARK: - Results variant
    //
    // Stripped of the source-icon circle and the "X places added" headline
    // per the redesign — the tile now leads straight with the place rows
    // and the "View on map" CTA. The close affordance moves to a small
    // floating × in the top-right so the body has the full width.

    private var resultsTile: some View {
        VStack(spacing: 12) {
            closeRow

            // Horizontal slideshow — one pin-style card per imported
            // place. Swipe right to page through everything that landed,
            // one at a time, instead of scanning a long stacked list.
            TabView(selection: $currentIndex) {
                ForEach(Array(summary.places.enumerated()), id: \.element.id) { index, place in
                    importedPlaceCard(place, position: index)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxHeight: .infinity)

            if summary.places.count > 1 {
                pageIndicator
            }

            doneButton
        }
        .padding(18)
        .onChange(of: currentIndex) { _, _ in Haptics.tap() }
        .onAppear(perform: announceArrival)
    }

    /// One success haptic the first time the results land. (The old
    /// staggered per-row reveal was retired when the list became a
    /// swipeable slideshow.)
    private func announceArrival() {
        guard !didAnnounce else { return }
        didAnnounce = true
        Haptics.success()
    }

    // MARK: - Slideshow card + page indicator

    /// A single slide in the import slideshow. The content — a hero photo,
    /// the place name, and the category · neighborhood meta line — sits
    /// **directly on the floating tile's surface**. We deliberately do NOT
    /// wrap it in another white card: the slide already lives inside the
    /// floating glass tile, and a card-in-a-tile reads as a doubled border.
    /// `position` indexes the place for the page counter.
    private func importedPlaceCard(_ place: Place, position: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Hero photo — same image source as the pins + map_pin_tile (the
            // place's own photo, else a curated per-category fallback), with
            // the source badge bottom-left and an "added" check top-right.
            tilePhoto(for: place)
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    sourceBadge(for: place).padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white, SomedayColors.accentGreen)
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        .padding(8)
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(place.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Image(systemName: place.category.icon)
                        .font(.system(size: 12))
                    Text(place.category.displayName)
                    if !place.neighborhood.isEmpty {
                        Text("•")
                        Text(place.neighborhood)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.system(size: 13))
                .foregroundColor(SomedayColors.grayMedium)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Small source chip in the hero's bottom-left — mirrors the pin card.
    /// Manual / friend sources get no badge (nothing to link, the avatar
    /// already says "from a friend").
    @ViewBuilder
    private func sourceBadge(for place: Place) -> some View {
        if place.source == .manual || place.source == .friend {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                Image(systemName: place.source.icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(place.source.label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.white.opacity(0.92))
            .foregroundColor(SomedayColors.charcoal)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
    }

    /// Page dots + "n of m" counter under the slideshow. Tapping a dot
    /// jumps to that place.
    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(summary.places.indices, id: \.self) { i in
                Circle()
                    .fill(i == currentIndex ? SomedayColors.charcoal : SomedayColors.grayMedium.opacity(0.3))
                    .frame(width: 7, height: 7)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            currentIndex = i
                        }
                    }
            }
            Text("\(currentIndex + 1) of \(summary.places.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(SomedayColors.grayMedium)
                .monospacedDigit()
                .padding(.leading, 4)
        }
    }

    /// Tiny top-right close button so the user can dismiss without
    /// committing. Keeps the rest of the row free for content.
    private var closeRow: some View {
        HStack {
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(SomedayColors.grayMedium)
                    .frame(width: 26, height: 26)
                    .background(SomedayColors.grayLight)
                    .clipShape(Circle())
            }
        }
    }

    // MARK: - Loading variant
    //
    // Replaces the old "spinner + text" with a cluster of pulsing
    // brand-gradient sparkles. Feels like the AI is thinking instead of
    // a generic loader spinning. Centred in the tile so there's no
    // copy to read — the motion does the talking.

    private var loadingTile: some View {
        VStack(spacing: 0) {
            closeRow
            Spacer(minLength: 0)
            AISparkleConstellation()
                .frame(height: 140)
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    // MARK: - Region variant
    //
    // Shown when the shared link resolved to a country/city/area
    // instead of a real venue. We name the region(s) the user actually
    // shared so the message is concrete rather than generic.

    private var regionTile: some View {
        VStack(alignment: .leading, spacing: 14) {
            closeRow

            HStack(spacing: 12) {
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                    .frame(width: 40, height: 40)
                    .background(SomedayColors.grayLight)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("This is not a single place")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(SomedayColors.charcoal)
                    Text(regionSubtitle)
                        .font(.system(size: 12))
                        .foregroundColor(SomedayColors.grayMedium)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }

            // Show each region that came back, so the user sees what
            // got picked up. Each row uses the same row style as the
            // results tile so the visual language is consistent.
            VStack(spacing: 8) {
                ForEach(summary.places, id: \.id) { place in
                    regionRow(for: place)
                }
            }

            Spacer(minLength: 4)

            // Single CTA — dismiss. We deliberately don't offer
            // "Add anyway" because a country-as-pin would confuse the
            // map (cluster around the country centroid, etc.). The
            // user can re-share a more specific link.
            Button(action: onDismiss) {
                Text("Got it")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(SomedayColors.lime)
                    .foregroundColor(SomedayColors.charcoal)
                    .cornerRadius(14)
            }
        }
        .padding(18)
    }

    /// Concrete one-liner naming what the user shared. Uses the venue
    /// name(s) returned by the import so the message says e.g.
    /// "Bali" or "France, Italy" rather than a generic phrase.
    private var regionSubtitle: String {
        let names = summary.places.map(\.name)
        if names.count == 1 {
            return "Looks like \"\(names[0])\" is a country or region. Try sharing a specific venue instead."
        }
        let joined = names.joined(separator: ", ")
        return "Looks like \(joined) are regions, not venues. Try sharing a specific place."
    }

    /// Compact row for a single region — same silhouette as
    /// `placeRow`, but with a globe glyph instead of a category icon
    /// and no checkmark (the region isn't "added").
    private func regionRow(for place: Place) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(SomedayColors.grayLight)
                    .frame(width: 44, height: 44)
                Image(systemName: "map.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SomedayColors.grayMedium)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                    .lineLimit(1)
                Text("Region")
                    .font(.system(size: 12))
                    .foregroundColor(SomedayColors.grayMedium)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
    }

    // MARK: - Empty variant
    //
    // The AI ran but found no extractable venue in the post. Most common
    // cause: the venue is named only in the comments, not the caption /
    // overlay. We surface that hint plus an "Open post" deep-link so the
    // user can pop over and grab the link from a comment.

    private var emptyTile: some View {
        VStack(alignment: .leading, spacing: 12) {
            closeRow
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                    .frame(width: 36, height: 36)
                    .background(SomedayColors.grayLight)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("No location was found")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(SomedayColors.charcoal)
                    Text("Try the comments — sometimes people drop the venue there. Paste that URL here.")
                        .font(.system(size: 12))
                        .foregroundColor(SomedayColors.grayMedium)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }
            Spacer(minLength: 4)
            emptyCTAs
        }
        .padding(18)
    }

    /// "Open post" (only when we have a source URL) + "Got it" dismiss.
    /// Two-button row matching the results-tile rhythm so the layout
    /// feels stable across states.
    private var emptyCTAs: some View {
        HStack(spacing: 10) {
            Button(action: onDismiss) {
                Text("Got it")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(SomedayColors.lime)
                    .foregroundColor(SomedayColors.charcoal)
                    .cornerRadius(14)
            }
            if let url = summary.sourceURL {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .bold))
                        Text("Open post")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(SomedayColors.charcoal)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(SomedayColors.charcoal.opacity(0.18), lineWidth: 1.5)
                    )
                }
            }
        }
    }

    // MARK: - Footer
    //
    // Two side-by-side CTAs:
    //   • View on map (lime, primary)  — dismiss the tile, the pins are
    //     already on the map.
    //   • Add (outlined, secondary)    — hand off to the Lists picker so
    //     the user can stash these places in one of their own lists.
    // "Add" only appears if the parent supplied an `onAdd` callback —
    // keeps backwards-compat with any call site that doesn't care.

    private var doneButton: some View {
        HStack(spacing: 10) {
            Button(action: onDismiss) {
                Text("View on map")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(SomedayColors.lime)
                    .foregroundColor(SomedayColors.charcoal)
                    .cornerRadius(14)
            }
            if let onAdd {
                Button(action: onAdd) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                        Text("Add")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundColor(SomedayColors.charcoal)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(SomedayColors.charcoal.opacity(0.18), lineWidth: 1.5)
                    )
                }
            }
        }
    }

    /// The photo that fills the hero. Falls back to the category image,
    /// then to a tinted panel with the category glyph if the network image
    /// hasn't arrived (or fails) — so the card is never blank.
    @ViewBuilder
    private func tilePhoto(for place: Place) -> some View {
        let url = place.imageURL ?? Self.categoryFallbackImageURL(place.category)
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty:
                categoryColor(for: place.category).opacity(0.16)
            default:
                ZStack {
                    categoryColor(for: place.category).opacity(0.16)
                    Image(systemName: place.category.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(categoryColor(for: place.category))
                }
            }
        }
    }

    /// Curated per-category fallback photo — kept in sync with
    /// `PlaceCardSheet` and the map pins so the same place shows the same
    /// imagery everywhere. Pinned to a small crop so AsyncImage caches a
    /// tiny file per category.
    private static func categoryFallbackImageURL(_ category: PlaceCategory) -> URL? {
        let photoID: String
        switch category {
        case .food:     photoID = "photo-1414235077428-338989a2e8c0" // restaurant
        case .drinks:   photoID = "photo-1551024601-bec78aea704b"    // cocktail
        case .coffee:   photoID = "photo-1495474472287-4d71bcdd2085" // latte
        case .activity: photoID = "photo-1441974231531-c6227db76b6e" // trail
        case .art:      photoID = "photo-1531058020387-3be344556be6" // gallery
        case .travel:   photoID = "photo-1488646953014-85cb44e25828" // travel
        }
        return URL(string: "https://images.unsplash.com/\(photoID)?w=200&h=200&fit=crop&q=80")
    }

    // MARK: - Helpers

    private func categoryColor(for category: PlaceCategory) -> Color {
        switch category {
        case .food:     return SomedayColors.primary
        case .drinks:   return SomedayColors.coral
        case .coffee:   return SomedayColors.amber
        case .activity: return SomedayColors.accentGreen
        case .art:      return Color(red: 0.55, green: 0.35, blue: 1.0)
        case .travel:   return SomedayColors.cyan
        }
    }
}

// =============================================================================
// AISparkleConstellation — loading animation for the summary tile
// =============================================================================
//
// Replaced the old cluster-of-sparkles with the app's hot-air-balloon mark
// breathing in a bouncy oscillation. The balloon is the Someday icon —
// reusing it here ties the loading moment to the brand identity instead of
// a generic gradient-sparkles motif.
//
// Animation: scale oscillates between ~0.85 → 1.18 on an interpolating
// spring (low damping = bouncy overshoot). Repeats forever while the tile
// is on screen; the parent tile only renders this in the loading state, so
// there's no need to manually pause / cancel the animation.

private struct AISparkleConstellation: View {
    @State private var scale: CGFloat = 0.85

    var body: some View {
        Image("balloon")
            .resizable()
            .renderingMode(.original)        // keep the multi-colour stripes
            .interpolation(.high)            // crisp downscale to display size
            .scaledToFit()
            // Square frame the parent tile can centre. The aspect of the
            // balloon image is taller than wide — `scaledToFit` keeps the
            // proportions, so we set the *height* via the parent's
            // `.frame(height: …)` rather than constraining width here.
            .scaleEffect(scale)
            .onAppear {
                // Bouncy spring with low damping → the balloon overshoots
                // slightly at each extreme. `repeatForever(autoreverses:)`
                // gives the up-and-down oscillation; the spring profile
                // is what makes it feel "bouncy" instead of "breathing".
                withAnimation(
                    .interpolatingSpring(stiffness: 80, damping: 7)
                        .repeatForever(autoreverses: true)
                ) {
                    scale = 1.18
                }
            }
            // Slight drop shadow gives the balloon a sense of weight so
            // the scale oscillation reads as "rising and falling" rather
            // than just "growing and shrinking".
            .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
            // Accessibility: announce the AI is working so VoiceOver users
            // know there's progress even without the visual.
            .accessibilityLabel("Looking for places")
            .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Data model

struct ImportSummary: Identifiable, Equatable {
    var id: UUID = UUID()
    var places: [Place]
    var source: Source
    /// True while we're still parsing the shared URL — the tile shows a
    /// spinner and a friendly "Importing…" message until the results arrive.
    var isLoading: Bool = false
    /// True when the parse ran to completion but the AI couldn't find a
    /// venue in the post. The tile renders an empty-state view with a
    /// hint pointing at the comments + an "Open post" CTA.
    var isEmpty: Bool = false
    /// Original URL that triggered the import. Surfaced inside the
    /// empty-state tile so the "Open post" CTA can deep-link back to
    /// Instagram / TikTok so the user can check the comments.
    var sourceURL: URL? = nil

    static func loading(_ source: Source) -> ImportSummary {
        ImportSummary(places: [], source: source, isLoading: true)
    }

    /// "Parse ran, found nothing" terminal state. The url is what the
    /// "Open post" button in the empty tile opens (nil = button hidden).
    static func empty(_ source: Source, url: URL? = nil) -> ImportSummary {
        ImportSummary(places: [], source: source, isLoading: false, isEmpty: true, sourceURL: url)
    }

    enum Source: Equatable {
        case googleMaps
        case instagram
        case list

        var label: String {
            switch self {
            case .googleMaps: return "Google Maps"
            case .instagram:  return "Instagram"
            case .list:       return "your pasted list"
            }
        }

        var symbol: String {
            switch self {
            case .googleMaps: return "map.fill"
            case .instagram:  return "camera.fill"
            case .list:       return "list.bullet"
            }
        }

        var tint: Color {
            switch self {
            case .googleMaps: return SomedayColors.accentGreen
            case .instagram:  return SomedayColors.coral
            case .list:       return SomedayColors.primary
            }
        }
    }
}
