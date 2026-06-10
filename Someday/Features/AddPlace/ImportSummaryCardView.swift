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

    /// How many of `summary.places` have been revealed so far. Starts
    /// at 0 on appear, ramps to `summary.places.count` over a staggered
    /// sequence — each increment fires a haptic tick so the user feels
    /// every place "land" in the list. Animating in one by one (vs all
    /// at once) gives the gestalt of "importing now" rather than "here's
    /// a static list of results".
    @State private var revealedCount: Int = 0
    /// Tracks whether the per-row reveal sequence has been kicked off so
    /// SwiftUI's view churn (re-mounts on parent state change) doesn't
    /// retrigger it and double-haptic.
    @State private var didStartReveal: Bool = false

    var body: some View {
        // `.compact` sits in the lower third of the screen — small,
        // dismissible, and doesn't take over the map.
        tile.floatingTile(size: .compact, onDismiss: onDismiss)
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
        VStack(alignment: .leading, spacing: 12) {
            closeRow
            ScrollView {
                VStack(spacing: 10) {
                    // Only render rows up to `revealedCount`. Each new
                    // index is inserted with a top-slide + fade transition
                    // and accompanied by a haptic tick (fired from the
                    // reveal Task in `onAppear`).
                    ForEach(Array(summary.places.prefix(revealedCount).enumerated()), id: \.element.id) { _, place in
                        placeRow(for: place)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                .padding(.horizontal, 2)
            }
            doneButton
        }
        .padding(18)
        .onAppear(perform: startStaggeredReveal)
    }

    /// Drive the per-row reveal sequence. Idempotent — guarded by
    /// `didStartReveal` so SwiftUI re-renders don't restart the loop
    /// and double-haptic. Cadence:
    ///   • Total reveal time roughly bounded to 1.4s.
    ///   • Per-item delay clamped to [50ms, 150ms]. Short lists feel
    ///     deliberate, long lists feel fast — both still rhythmic.
    private func startStaggeredReveal() {
        guard !didStartReveal else { return }
        didStartReveal = true
        let total = summary.places.count
        guard total > 0 else {
            revealedCount = 0
            return
        }
        // Clamp delay so cadence stays felt across small/large imports.
        let perItemMs = min(150, max(50, 1400 / total))
        let delay = Duration.milliseconds(perItemMs)
        Task { @MainActor in
            for i in 0..<total {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    revealedCount = i + 1
                }
                Haptics.importTick()
                // Don't sleep after the last item — the success notification
                // immediately follows so the rhythm closes cleanly.
                if i < total - 1 {
                    try? await Task.sleep(for: delay)
                }
            }
            // Final beat — distinct from the per-row tick so the user
            // feels "and we're done" without confusing it with another row.
            Haptics.success()
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

    // MARK: - Stacked place row tiles

    private func placeRow(for place: Place) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: place)

            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                    .lineLimit(1)
                Text(subtitle(for: place))
                    .font(.system(size: 12))
                    .foregroundColor(SomedayColors.grayMedium)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(SomedayColors.accentGreen)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
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

    /// Thumbnail rendered in the **pin_tile format** — the same rounded
    /// photo tile with a white edge we draw on the map pins. Always shows
    /// an image: the place's own photo when the import supplied one, else
    /// a curated per-category photo (matching the pins + the place card),
    /// so a freshly-loaded list reads like a row of little pins rather
    /// than a grid of flat category icons.
    private func thumbnail(for place: Place) -> some View {
        let side: CGFloat = 48
        let corner: CGFloat = 14
        let border: CGFloat = 2.5
        return ZStack {
            // White silhouette = the "slight edge" around the photo.
            RoundedRectangle(cornerRadius: corner)
                .fill(.white)
            tilePhoto(for: place)
                .frame(width: side - border * 2, height: side - border * 2)
                .clipShape(RoundedRectangle(cornerRadius: corner - border, style: .continuous))
        }
        .frame(width: side, height: side)
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 2.5, y: 1)
    }

    /// The photo that fills the tile. Falls back to the category image, then
    /// to a tinted square with the category glyph if the network image
    /// hasn't arrived (or fails) — so the tile is never blank.
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

    private func subtitle(for place: Place) -> String {
        let pieces: [String] = [place.neighborhood, place.category.displayName]
        return pieces.filter { !$0.isEmpty }.joined(separator: " · ")
    }

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
