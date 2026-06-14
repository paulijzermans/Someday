import SwiftUI

struct PlaceCardSheet: View {
    let place: Place
    let friends: [UserProfile]
    /// Current state of the AI Availability lookup for this place. Drives
    /// which label + animation the Availability button renders.
    let availabilityState: AvailabilityState
    /// Result of the real-time "tonight?" check (Zenchef etc.), or nil
    /// while it's mid-flight or hasn't been kicked off yet. Surfaced as
    /// a pill at the top of the inline platforms panel.
    let tonightCheck: AvailabilityCheck?
    /// True while the tonight check is in flight — drives the pill's
    /// spinner state.
    let isCheckingTonight: Bool
    /// The custom list this place currently belongs to, if any. Drives
    /// the visual state of the list button next to Availability:
    ///   • nil           → empty "+" affordance (outlined, neutral)
    ///   • some(list)    → filled chip in the list's deterministic colour
    let listForPlace: CustomList?
    let onDismiss: () -> Void
    let onReservation: (ReservationMode) -> Void
    /// Tap callback for the Availability CTA. The parent decides what
    /// happens based on `availabilityState`:
    ///   • .idle    → kick off the AI lookup
    ///   • .loading → no-op (button is non-interactive during the call)
    ///   • .ready   → dismiss card, present the result in the AI bar
    let onAvailabilityTap: () -> Void
    /// Tap callback used when the panel auto-expands (or the user
    /// re-taps "Done") — kicks off the tonight check via the parent so
    /// the result lands in `tonightCheckResults[place.id]`.
    let onCheckTonight: () -> Void
    /// Tap callback for the list button. Always opens the Lists picker —
    /// re-tapping when already in a list lets the user add it to another
    /// list too (the picker's commit dedupes against the existing list's
    /// `placeIDs`).
    let onAddToListTap: () -> Void
    /// Tap callback for the "Ask Someday" CTA — opens the chatbot with
    /// this pin bound as the conversation's context so the user can ask
    /// "is it any good?" / "what's nearby?" without retyping the name.
    /// Optional so the card still works in any preview / call site that
    /// doesn't wire chat.
    var onAskAI: (() -> Void)? = nil
    /// Environment-supplied URL opener — used by the source badge to
    /// deep-link back to the Instagram Reel / TikTok the place came from.
    @Environment(\.openURL) private var openURL
    @State private var dragOffset: CGFloat = 0
    /// Drives the sparkle scale/opacity pulse during the .loading state.
    /// Mirrors the aiChatBar's idle pulse so the AI motif is consistent.
    @State private var aiSparklePulse = false
    /// True when the user has tapped "Done" on the Availability button
    /// and we should reveal the booking platforms inline below the
    /// actions row. Local to this card — re-opening the same place
    /// after dismissing the card resets to the un-expanded view.
    @State private var availabilityExpanded = false
    /// Compact (false) vs. large (true) tile. Swiping UP on the grabber /
    /// card snaps to the large tile, revealing `expandedDetails` (tags,
    /// recommender, friend ratings, source + date). Swiping DOWN collapses
    /// it back to compact before a further downswipe dismisses. A crisp
    /// selection haptic marks each snap so it reads as a physical detent.
    @State private var expanded = false
    @State private var priceValue: Double = 5
    @State private var qualityValue: Double = 5
    @State private var serviceValue: Double = 5
    @State private var commentText: String = ""

    private var visitedFriends: [UserProfile] {
        friends.filter { place.visitedByIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color(.systemGray4))
                    .frame(width: 36, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 12)

                // Header: square hero on the left, title + meta on the
                // right. Replaces the old full-width 180pt photo banner
                // so the card feels tighter and reads as a "place row"
                // rather than a poster. The 96pt square keeps the photo
                // tappable + recognisable without dominating.
                HStack(alignment: .top, spacing: 14) {
                    heroImage
                        .frame(width: 96, height: 96)
                        .photoTileEdge(cornerRadius: 18)
                        .overlay(alignment: .bottomLeading) {
                            sourceBadge
                                .padding(5)
                        }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            Text(place.name)
                                .font(.system(size: 19, weight: .bold))
                                .foregroundColor(SomedayColors.charcoal)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            if let review = place.review {
                                overallBadge(review.overallFormatted)
                            }
                        }

                        HStack(spacing: 6) {
                            Image(systemName: place.category.icon)
                                .font(.system(size: 12))
                            Text(place.category.displayName)
                            Text("•")
                            Text(place.neighborhood)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .font(.system(size: 13))
                        .foregroundColor(SomedayColors.grayMedium)

                        // Friends who've been here — compact chip with
                        // overlapping avatars + "N friend(s) visited". Sits
                        // beside the hero so the social proof is visible on
                        // first glance, not buried below the meta row as a
                        // separate section. Hidden when no one has been.
                        if !visitedFriends.isEmpty {
                            friendsVisitedChip
                                .padding(.top, 2)
                        }
                    }
                    // Top-align the text column to the photo so a short
                    // title sits at the photo's top edge, not floating
                    // in the middle of the row.
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

                VStack(alignment: .leading, spacing: 0) {
                    if place.review != nil {
                        reviewSection
                    }

                    // Friends section moved up next to the hero image as a
                    // compact chip. Old large stack of 36pt avatars retired —
                    // the meta column above already shows who's been.
                    actionsSection

                    // Inline booking-platforms panel that expands directly
                    // below the actions row when the user taps "Done" on
                    // the Availability button. Pushes the rest of the card
                    // upward (it's bottom-anchored) instead of opening a
                    // separate floating bar.
                    if availabilityExpanded,
                       case .ready(let result) = availabilityState {
                        availabilityResultSection(result)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Large-tile extras — revealed when the user swipes the
                    // grabber up. Surfaces detail that doesn't earn space on
                    // the compact card (tags, who recommended it, every
                    // friend's rating, source + saved date).
                    if expanded {
                        expandedDetails
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, 20)
                // Small breathing room at the bottom of the card. We no
                // longer extend behind the tab bar (the card now floats
                // above it as a `tile_bottom`-style surface), so the old
                // 116pt clearance is gone — 20pt is enough to keep the
                // action buttons from kissing the rounded corner.
                .padding(.bottom, 20)
            }
            // Match the tile_bottom visual language: same corner radius,
            // same primary-tinted hairline stroke. Background stays solid
            // white because the card carries dense content (photo,
            // sliders, dark text) that would lose contrast against the
            // glass blur tile_bottom uses for its empty state.
            .background(Color.white)
            .cornerRadius(16)
            // The card wears the same defined thin edge as the hero photo
            // inside it — one modern outline language across the whole
            // image-bearing surface.
            .somedayCardEdge(cornerRadius: 16)
            .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
            // Only the downward drag rubber-bands the card (max with 0);
            // an upward drag doesn't move the card — it snaps to the large
            // tile on release instead.
            .offset(y: max(dragOffset, 0))
            .gesture(
                DragGesture()
                    .onChanged { dragOffset = $0.translation.height }
                    .onEnded { value in
                        let dy = value.translation.height
                        // Swipe UP → snap to the large tile (reveal more
                        // info). Selection haptic = a crisp "click" detent.
                        if dy < -40 && !expanded {
                            Haptics.select()
                            withAnimation(SomedayAnimations.followCTA) {
                                expanded = true
                                dragOffset = 0
                            }
                            return
                        }
                        // Swipe DOWN while large → collapse back to compact
                        // first (one size step per swipe) rather than
                        // dismissing straight through.
                        if dy > 40 && expanded {
                            Haptics.select()
                            withAnimation(SomedayAnimations.followCTA) {
                                expanded = false
                                dragOffset = 0
                            }
                            return
                        }
                        // Compact tile: a firm downward swipe dismisses.
                        if dy > 120 || value.velocity.height > 500 {
                            onDismiss()
                        } else {
                            withAnimation(SomedayAnimations.followCTA) { dragOffset = 0 }
                        }
                    }
            )
            // tile_bottom positioning: 16pt horizontal inset (matches
            // TileTop / TileBottom in MapHomeView) and 96pt bottom
            // padding so the card's bottom edge sits the standard gap
            // above the floating capsule tab bar.
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .onAppear {
            if let review = place.review {
                priceValue = review.price
                qualityValue = review.quality
                serviceValue = review.service
                commentText = review.comment
            }
            // Toggle the AI sparkle so the .loading state's animation has
            // a value to oscillate against. Doing this unconditionally on
            // appear means the animation is "armed" the moment loading
            // starts — no perceived stutter when the user taps.
            aiSparklePulse = true
            // If the card mounts already in the .ready state (e.g. the
            // user re-opened the same place after a cached lookup),
            // reveal the panel immediately — no extra tap needed.
            if case .ready = availabilityState {
                availabilityExpanded = true
            }
        }
        // Auto-expand the booking panel the moment the lookup finishes.
        // Tapping "Done" still works to collapse/re-expand, but the user
        // doesn't have to wait for their own tap to see the result the
        // AI just produced.
        .onChange(of: availabilityState) { _, newState in
            if case .ready = newState {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    availabilityExpanded = true
                }
                Haptics.success()
                // Kick off the real-time "tonight?" check the moment the
                // platforms come in. The pill renders a spinner until the
                // result lands so the user sees we're working on it.
                onCheckTonight()
            }
        }
    }

    /// Hero photo at the top of the card. Uses the imported `imageURL`
    /// when the place actually carries one (Instagram / TikTok / Maps
    /// imports ship their own photo); otherwise we show the brand-gradient
    /// + category glyph fallback. We no longer fabricate a category stock
    /// photo for photo-less places — a manually-typed or AI-saved place
    /// shows its category icon, not a stand-in restaurant/latte image that
    /// isn't really this place.
    @ViewBuilder
    private var heroImage: some View {
        if let url = place.imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    // Translucent placeholder while the AsyncImage is
                    // mid-fetch. Keeps the card from popping in too
                    // aggressively when the photo finally lands.
                    LinearGradient(
                        colors: [SomedayColors.primary.opacity(0.4), SomedayColors.primaryDark.opacity(0.4)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                default:
                    fallbackGradient
                }
            }
        } else {
            fallbackGradient
        }
    }

    private var fallbackGradient: some View {
        LinearGradient(
            colors: [SomedayColors.primary, SomedayColors.primaryDark],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: place.category.icon)
                .font(.system(size: 56, weight: .semibold))
                .foregroundColor(.white.opacity(0.4))
        )
    }

    private func overallBadge(_ grade: String) -> some View {
        VStack(spacing: 0) {
            Text(grade)
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(SomedayColors.green)
            Text("/ 10")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(SomedayColors.green.opacity(0.7))
        }
        .frame(width: 42, height: 42)
        .background(SomedayColors.butter)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Source badge in the bottom-left of the hero image. When the place
    /// has a `sourceURL` (Instagram Reel / TikTok / Maps share), the badge
    /// becomes a Button that deep-links back to the original post.
    /// Manually-added places get NO badge — the "Added manually" label was
    /// noise on the card's tight 96pt hero (there's nothing to link to and
    /// the user knows they typed it in).
    @ViewBuilder
    private var sourceBadge: some View {
        // Two cases produce no badge at all:
        //   • `.manual` — "Added manually" was noise. Nothing to
        //     link to and the user knows they typed it in.
        //   • `.friend` — "from a friend" is already obvious from the
        //     friend avatar / friend chip elsewhere on the card, so
        //     the badge just doubled the signal without paying for
        //     its visual weight on the 96pt hero.
        if place.source == .manual || place.source == .friend {
            EmptyView()
        } else if let url = place.sourceURL {
            Button { openURL(url) } label: { sourceBadgeContent }
                .buttonStyle(.plain)
        } else {
            sourceBadgeContent
        }
    }

    /// The visual content of the source badge, hoisted out so the
    /// tappable + non-tappable branches above share a single body.
    /// Sized to feel like a chip on the 96pt hero square — the asset
    /// is small enough to read at a glance without crowding the photo.
    @ViewBuilder
    private var sourceBadgeContent: some View {
        if let assetName = place.source.assetName, UIImage(named: assetName) != nil {
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        } else {
            HStack(spacing: 3) {
                Image(systemName: place.source.icon)
                    .font(.system(size: 9))
                Text(place.source.label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.9))
            .cornerRadius(6)
        }
    }

    // MARK: - Large-tile extras

    /// Friendly display name for a friend id, falling back gracefully when
    /// the recommender / rater isn't in the loaded friends list.
    private func friendName(_ id: String) -> String {
        friends.first(where: { $0.id == id })?.name ?? "A friend"
    }

    /// Medium-style saved date, e.g. "Jun 6, 2026".
    private var savedDateString: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: place.createdAt)
    }

    /// The detail block shown only on the large tile (after the user swipes
    /// the grabber up). Everything here is secondary to the compact card —
    /// useful once you're committed to looking closer, noise before then.
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
                .padding(.top, 4)

            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(SomedayColors.primary)
                Text("More details")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
            }

            // Tags — horizontally scrollable lime chips.
            if !place.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(place.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(SomedayColors.charcoal)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(SomedayColors.lime.opacity(0.25), in: Capsule())
                        }
                    }
                }
            }

            if let rid = place.recommendedBy {
                detailRow(icon: "hand.thumbsup.fill", text: "Recommended by \(friendName(rid))")
            }

            if let timing = place.eventTimingLabel {
                detailRow(icon: "clock.fill", text: timing)
            }

            // Every friend's score (the compact card only shows an overall
            // badge). Sorted highest-first.
            if !place.friendRatings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Friend ratings")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SomedayColors.grayMedium)
                    ForEach(place.friendRatings.sorted { $0.value > $1.value }, id: \.key) { entry in
                        HStack(spacing: 8) {
                            Text(friendName(entry.key))
                                .font(.system(size: 13))
                                .foregroundColor(SomedayColors.charcoal)
                            Spacer(minLength: 0)
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.yellow)
                                Text(String(format: "%.1f", entry.value))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(SomedayColors.charcoal)
                            }
                        }
                    }
                }
            }

            detailRow(icon: place.source.icon, text: "\(place.source.label) · Saved \(savedDateString)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// One icon + text line in the large-tile detail block.
    private func detailRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(SomedayColors.primary)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(SomedayColors.charcoal.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13))
                    .foregroundColor(SomedayColors.primary)
                Text("Your review")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
            }

            ReviewSlider(label: "Price", icon: "eurosign.circle.fill", value: $priceValue)
            ReviewSlider(label: "Quality", icon: "star.fill", value: $qualityValue)
            ReviewSlider(label: "Service", icon: "hand.thumbsup.fill", value: $serviceValue)

            VStack(alignment: .leading, spacing: 6) {
                Text("Comments")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
                TextField("Add a note...", text: $commentText, axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundColor(SomedayColors.charcoal)
                    .lineLimit(2...4)
                    .padding(10)
                    .background(SomedayColors.anthropicWhite)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(SomedayColors.anthropicTan, lineWidth: 1)
                    )
            }
        }
        .padding(14)
        .background(SomedayColors.grayLight)
        .cornerRadius(14)
        .padding(.bottom, 12)
    }

    /// Compact "friends who've been here" chip used inline in the header
    /// (right column, under the category/neighborhood row). Shows up to
    /// three overlapping mini-avatars and a label like "2 friends visited".
    /// Replaces the older large `friendsSection` row.
    @ViewBuilder
    private var friendsVisitedChip: some View {
        let avatarSize: CGFloat = 20
        let maxShown = 3
        let shown = Array(visitedFriends.prefix(maxShown))
        let extra = visitedFriends.count - shown.count
        let label = visitedFriends.count == 1
            ? "1 friend visited"
            : "\(visitedFriends.count) friends visited"

        HStack(spacing: 6) {
            // Overlapping avatar stack — same trick the iOS Photos app
            // uses for shared albums. Negative spacing pulls each into
            // the previous one's right edge.
            HStack(spacing: -6) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { _, friend in
                    AsyncImage(url: friend.avatarURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Circle()
                                .fill(SomedayColors.primary.opacity(0.35))
                                .overlay(
                                    Text(friend.initials.prefix(1))
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                )
                        }
                    }
                    .frame(width: avatarSize, height: avatarSize)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                }
                if extra > 0 {
                    Text("+\(extra)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: avatarSize, height: avatarSize)
                        .background(Circle().fill(SomedayColors.primary))
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                }
            }

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(SomedayColors.grayMedium)
                .lineLimit(1)
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 10) {
            if place.review != nil {
                // Already reviewed — keep the single "Save" CTA.
                Button {
                    onReservation(.tonight)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Save")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(SomedayColors.lime)
                    .foregroundColor(SomedayColors.charcoal)
                    .cornerRadius(14)
                }
            } else {
                // Single "Availability" CTA in poison green (lime). The
                // reservation sheet still uses ReservationMode under the
                // hood — we start from `.tonight` so the date picker opens
                // on today; the user can advance to any future date from
                // there. Merges what used to be two CTAs.
                availabilityButton
            }

            // List membership chip — empty "+" if the place isn't in
            // any list yet, otherwise filled in the list's deterministic
            // colour so it doubles as a visual indicator of which list
            // the place belongs to. Tap opens the Lists picker either
            // way, so re-adding to another list is the same gesture.
            listMembershipButton

            Button {} label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 16))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(SomedayColors.anthropicTan, lineWidth: 1.5)
                    )
            }
            .foregroundColor(SomedayColors.charcoal)

            // Ask Someday — hands this pin to the chatbot as bound
            // context. Only shown when the parent wired `onAskAI`.
            if let onAskAI {
                Button(action: onAskAI) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [SomedayColors.green, SomedayColors.lime],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(SomedayColors.lime.opacity(0.5), lineWidth: 1.5)
                        )
                }
                .accessibilityLabel("Ask Someday about this place")
            }
        }
    }

    /// Square pill that doubles as "add to a list" and as a chip showing
    /// which list the place is already in.
    /// - `listForPlace == nil` → outlined neutral square with a "+"
    ///                            (matching the visual weight of the
    ///                             location button next to it).
    /// - `listForPlace != nil` → filled in the list's
    ///                            `ListVisualStyle.color` with the
    ///                            list's deterministic symbol in white,
    ///                            so a glance tells you which list it's
    ///                            stashed in.
    private var listMembershipButton: some View {
        let style = listForPlace.map { ListVisualStyle.style(for: $0.name) }
        let isInList = listForPlace != nil

        return Button(action: onAddToListTap) {
            Image(systemName: isInList ? (style?.symbol ?? "checkmark") : "plus")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 22, height: 22)
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .foregroundColor(isInList ? .white : SomedayColors.charcoal)
                .background(isInList ? (style?.color ?? SomedayColors.primary) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isInList ? Color.clear : SomedayColors.anthropicTan, lineWidth: 1.5)
                )
                .cornerRadius(14)
        }
        // Subtle motion when membership flips — gives the user feedback
        // that the tap "landed" even before the picker scales in.
        .animation(.easeInOut(duration: 0.2), value: isInList)
    }

    /// AI-driven Availability CTA. Three visual states keyed off
    /// `availabilityState`:
    ///   • .idle    — calendar + "Availability". Tap kicks off the AI
    ///                lookup (parent decides; see `onAvailabilityTap`).
    ///   • .loading — animated sparkles + "Checking…". Non-interactive.
    ///   • .ready   — checkmark + "Done". Tap surfaces the result in the
    ///                floating AI bar.
    /// The pill stays in lime (poison green) across all states so it
    /// reads as one button morphing, not three different CTAs.
    @ViewBuilder
    private var availabilityButton: some View {
        Button {
            // Loading is non-interactive — we still wrap in a Button to
            // keep layout/animations identical across states.
            if case .loading = availabilityState { return }
            // .ready taps stay inside the card: toggle the inline
            // platforms panel rather than handing off to the parent.
            // .idle taps still bubble up — parent kicks off the lookup.
            if case .ready = availabilityState {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                    availabilityExpanded.toggle()
                }
                Haptics.tap()
                return
            }
            onAvailabilityTap()
        } label: {
            HStack(spacing: 6) {
                availabilityIcon
                Text(availabilityLabel)
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(SomedayColors.lime)
            .foregroundColor(SomedayColors.charcoal)
            .cornerRadius(14)
        }
        // Disable taps explicitly while loading so the press-down state
        // doesn't trigger animations.
        .disabled({ if case .loading = availabilityState { return true } else { return false } }())
    }

    /// Icon swap synchronised with the button state. The .loading icon
    /// uses the same sparkle pulse as the aiChatBar to maintain the AI
    /// motif across the app.
    @ViewBuilder
    private var availabilityIcon: some View {
        switch availabilityState {
        case .idle:
            Image(systemName: "calendar")
                .font(.system(size: 14, weight: .semibold))
        case .loading:
            // AI-stars animation: scale + opacity pulse keyed off
            // `aiSparklePulse`. Starts oscillating on `onAppear` of the
            // ZStack below. Matching the chat bar's pulse cadence (1.4s)
            // keeps the "AI is thinking" language consistent.
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .bold))
                .scaleEffect(aiSparklePulse ? 1.15 : 0.9)
                .opacity(aiSparklePulse ? 1.0 : 0.7)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: aiSparklePulse
                )
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
        }
    }

    /// Text that swaps with the state. Kept short so the button width
    /// stays consistent across the three labels.
    private var availabilityLabel: String {
        switch availabilityState {
        case .idle:    return "Availability"
        case .loading: return "Checking…"
        case .ready:   return "Done"
        }
    }

    // MARK: - Inline availability result panel
    //
    // Shown directly below `actionsSection` when the user taps "Done" on
    // the Availability button. The card is bottom-anchored, so adding
    // height here visually slides the whole card upward — no separate
    // floating bar, the booking options appear right where the user is
    // already looking.

    /// Renders the AI summary + a tappable row per booking platform.
    /// `result.platforms` is already clipped to <=4 server-side, so we
    /// don't paginate here.
    @ViewBuilder
    private func availabilityResultSection(_ result: AvailabilityResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Real-time "tonight?" pill — kicks off when the panel
            // expands, settles into an open/closed/unknown end-state.
            // For "unknown" providers (no Zenchef adapter match) the
            // pill quietly says so and the user falls back to the
            // platform links below.
            tonightCheckPill

            // Headline — small AI sparkle next to the model's one-line
            // summary. Same sparkle motif as the loading + chat states
            // so the user reads this as "the AI found this".
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(SomedayColors.primary)
                Text(result.summary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
                    .lineLimit(2)
            }

            if result.platforms.isEmpty {
                // Edge case — the AI couldn't find any platforms. Don't
                // collapse the panel silently; tell the user.
                Text("No online booking found. Try searching the venue's website.")
                    .font(.system(size: 13))
                    .foregroundColor(SomedayColors.grayMedium)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 8) {
                    ForEach(result.platforms) { platform in
                        platformRow(platform)
                    }
                }
            }
        }
        .padding(14)
        .background(SomedayColors.grayLight)
        .cornerRadius(14)
        .padding(.top, 10)
    }

    /// Tappable row for a single booking platform. Four render modes:
    ///   • URL platform        → chip + arrow, taps open the booking page.
    ///   • Phone-number entry  → chip + green call icon, taps dial
    ///                            directly via `tel:` URL scheme.
    ///   • Email entry         → chip + envelope icon, taps open the
    ///                            user's mail composer via `mailto:`.
    ///   • Note-only entry     → flat info row, not tappable (e.g.
    ///                            "Walk-in only", "Book direct").
    @ViewBuilder
    private func platformRow(_ platform: BookingPlatform) -> some View {
        if let phoneNumber = phoneNumber(in: platform) {
            // Phone reservations — dial directly with `tel:`.
            Button {
                guard let telURL = URL(string: "tel:\(phoneNumber.dialable)") else { return }
                Haptics.tap()
                openURL(telURL)
            } label: {
                platformRowContent(platform, kind: .phone(display: phoneNumber.display))
            }
            .buttonStyle(.plain)
        } else if let mailtoURL = emailURL(in: platform) {
            // Email reservations — opens the user's default mail app
            // with a pre-filled "Reservation request" subject. The
            // Edge Function emits the `mailto:` URL with the subject
            // already encoded.
            Button {
                Haptics.tap()
                openURL(mailtoURL)
            } label: {
                platformRowContent(platform, kind: .email)
            }
            .buttonStyle(.plain)
        } else if let url = platform.url {
            Button {
                Haptics.tap()
                openURL(url)
            } label: {
                platformRowContent(platform, kind: .link)
            }
            .buttonStyle(.plain)
        } else {
            platformRowContent(platform, kind: .infoOnly)
        }
    }

    /// What flavour of row we're rendering. Determines the trailing
    /// glyph and whether the row is tappable.
    private enum PlatformRowKind {
        case link
        /// `display` is the human-formatted version of the number for
        /// the label ("+33 1 42 61 05 88") — kept around so we can show
        /// it more compactly than the raw note when needed.
        case phone(display: String)
        case email
        case infoOnly
    }

    /// Detect an email row. Two flavours:
    ///   1) The Edge Function emitted a `mailto:` URL (preferred).
    ///   2) The platform name says "email" and the note contains an
    ///      email-shaped string.
    /// Returns the URL that should open in Mail, or nil if not an email.
    private func emailURL(in platform: BookingPlatform) -> URL? {
        if let url = platform.url, url.scheme?.lowercased() == "mailto" {
            return url
        }
        let nameLower = platform.name.lowercased()
        let looksLikeEmail = nameLower.contains("email") || nameLower.contains("mail")
        guard looksLikeEmail, let note = platform.note else { return nil }
        // Conservative email regex: a non-space run, `@`, host with a dot.
        let pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        guard let range = note.range(of: pattern, options: .regularExpression) else { return nil }
        let address = String(note[range])
        return URL(string: "mailto:\(address)?subject=Reservation%20request")
    }

    /// Detect a phone-reservation platform. Returns `(display, dialable)`
    /// where `display` is the human-readable number (kept as-is for the
    /// row label) and `dialable` is digits+ for the `tel:` URL scheme.
    /// Returns nil when no phone number is present.
    private func phoneNumber(in platform: BookingPlatform) -> (display: String, dialable: String)? {
        // 1) `tel:` URL — easy path.
        if let url = platform.url, url.scheme?.lowercased() == "tel" {
            let raw = url.absoluteString.replacingOccurrences(of: "tel:", with: "")
            return (raw, raw)
        }
        // 2) Pattern-match a phone number in the note. The Edge Function
        //    returns notes like "+33 1 42 61 05 88 – recommended for peak
        //    hours" for phone-reservation rows. We accept anything that
        //    starts with `+` followed by 7+ phone-shaped characters, or a
        //    run of 7+ digits possibly separated by spaces/dots/dashes.
        guard let note = platform.note else { return nil }
        let looksLikePhonePlatform = platform.name.lowercased().contains("phone")
            || platform.name.lowercased().contains("call")
        // Be conservative: only treat as a phone row if the platform is
        // *named* like a phone option AND the note contains a number.
        // Avoids false positives on platform notes that mention party
        // size limits etc. ("up to 12 guests").
        guard looksLikePhonePlatform else { return nil }
        // Greedy phone-character match. `+`, digits, spaces, parens,
        // dots, dashes. Must contain at least 7 digits to qualify.
        let pattern = #"\+?[\d][\d\s().\-]{6,}"#
        guard let range = note.range(of: pattern, options: .regularExpression) else { return nil }
        let display = String(note[range]).trimmingCharacters(in: .whitespaces)
        let dialable = display.filter { $0.isNumber || $0 == "+" }
        return (display, dialable)
    }

    /// "Tonight, party of 2 — open / closed / checking…" pill rendered
    /// at the top of the platforms panel. Three end states:
    ///   • loading      → spinner + "Checking tonight…"
    ///   • .open        → green check + "Open tonight" + "Book now →"
    ///   • .closed      → grey × + "No tables tonight"
    ///   • .unknown     → muted info icon + "Can't auto-check this venue"
    ///   • .error       → muted retry hint
    @ViewBuilder
    private var tonightCheckPill: some View {
        if isCheckingTonight || tonightCheck == nil {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking tonight…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(SomedayColors.anthropicWhite)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(SomedayColors.anthropicTan, lineWidth: 1)
            )
        } else if let check = tonightCheck {
            tonightCheckPillResolved(check)
        }
    }

    /// Resolved-state variant of the pill — switches on the check result.
    /// Pulled out so the loading branch stays clean.
    @ViewBuilder
    private func tonightCheckPillResolved(_ check: AvailabilityCheck) -> some View {
        switch check {
        case .open(let shifts, let bookingURL, _):
            Button {
                if let url = bookingURL {
                    Haptics.tap()
                    openURL(url)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(SomedayColors.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Open tonight")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(SomedayColors.charcoal)
                        if let shiftLabel = shifts.first?.name {
                            Text(shiftLabel)
                                .font(.system(size: 11))
                                .foregroundColor(SomedayColors.grayMedium)
                        }
                    }
                    Spacer()
                    if bookingURL != nil {
                        Text("Book")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(SomedayColors.green)
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(SomedayColors.green.opacity(0.08))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(SomedayColors.green.opacity(0.25), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

        case .closed:
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(SomedayColors.grayMedium)
                Text("No tables tonight")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(SomedayColors.anthropicWhite)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(SomedayColors.anthropicTan, lineWidth: 1)
            )

        case .unknown:
            // No adapter yet — quietly tell the user we can't check
            // automatically. They can still tap the platforms below.
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundColor(SomedayColors.grayMedium)
                Text("Use a link below to check tonight")
                    .font(.system(size: 13))
                    .foregroundColor(SomedayColors.grayMedium)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.white.opacity(0.7))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(SomedayColors.anthropicTan, lineWidth: 1)
            )

        case .error:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                Text("Couldn't check tonight — try a link below")
                    .font(.system(size: 13))
                    .foregroundColor(SomedayColors.grayMedium)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.white.opacity(0.7))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(SomedayColors.anthropicTan, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func platformRowContent(_ platform: BookingPlatform, kind: PlatformRowKind) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(platform.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                // For phone rows the note often carries the number itself
                // ("+33 1 42 61 05 88 — recommended for peak hours") — we
                // already extracted it for the trailing button, but show
                // the full note text so any extra context (peak hours
                // tip etc.) still reaches the user.
                if let note = platform.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundColor(SomedayColors.grayMedium)
                        .lineLimit(1)
                }
            }
            Spacer()
            // Trailing affordance changes with row kind. Phone gets a
            // green call pill — it's the only row that does a phone
            // action, so the green tint reads as "tap to call" without
            // a label.
            switch kind {
            case .link:
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.primary)
            case .phone:
                Image(systemName: "phone.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(SomedayColors.green)
                    .clipShape(Circle())
            case .email:
                // Same chip shape as phone, primary tint so the two
                // "direct action" affordances feel visually paired but
                // visually distinct from each other.
                Image(systemName: "envelope.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(SomedayColors.primary)
                    .clipShape(Circle())
            case .infoOnly:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(SomedayColors.anthropicWhite)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(SomedayColors.anthropicTan, lineWidth: 1)
        )
    }
}

/// A friend's list being previewed on the map. The user sees only this
/// list's pins until they hit **Add** (import them) or **Cancel** (return
/// to their own places). Lives alongside ReservationMode so both share the
/// "map-level UI state" namespace.
struct PreviewedList {
    let owner: UserProfile
    let name: String
    let places: [Place]
}

/// Which reservation flow the place card invokes.
/// - `.tonight` opens the sheet with today's date pre-selected.
/// - `.future` opens it pre-set to tomorrow so the date picker is the focal point.
enum ReservationMode {
    case tonight
    case future

    var initialDate: Date {
        switch self {
        case .tonight: return Date()
        case .future:  return Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        }
    }
}

struct ReviewSlider: View {
    let label: String
    let icon: String
    @Binding var value: Double

    private var displayValue: String {
        let rounded = (value * 10).rounded() / 10
        if rounded == floor(rounded) {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(SomedayColors.primary)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                Spacer()
                Text(displayValue)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
                    .frame(minWidth: 22, alignment: .trailing)
            }
            Slider(value: $value, in: 1...10, step: 0.5)
                .tint(SomedayColors.primary)
        }
    }
}
