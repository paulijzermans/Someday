import SwiftUI

/// Compact floating tile announcing an incoming list share. Strips the
/// previous design down to just the message + CTAs: the place preview
/// and the big circular hero avatar are gone. The sender's avatar is
/// now a small decoration tucked into the bottom-right corner of the
/// tile, so the user reads the message first and the identity second.
///
/// Three actions:
///   • Maybe later — dismiss
///   • Preview     — drop the user onto the map in preview mode with
///                   Add / Cancel buttons under the pins
///   • Add ▼       — long-press or tap-and-hold reveals a menu where
///                   the user picks how long the list stays accessible
///                   (30 days, 90 days, or forever). Tapping the
///                   primary button is a shortcut for "forever".
struct ShareRequestTileView: View {
    let person: UserProfile
    let listName: String
    /// Real Place objects in the list — kept on the model so the count
    /// stays accurate and so the preview path downstream still has the
    /// data, even though we no longer render the place rows.
    let places: [Place]
    let onPreview: () -> Void
    /// Imports the places to the user's map. The `duration` parameter
    /// captures how long the receiver wants the shared list to remain
    /// accessible — `.forever` means a permanent add, `.days30` /
    /// `.days90` should mark the list with an expiry so a future
    /// background sweep can prune it.
    let onAdd: (ShareAccessDuration) -> Void
    let onDismiss: () -> Void

    private var placeCount: Int { places.count }

    var body: some View {
        // `.compact` sits in the lower third of the screen — small,
        // non-blocking, dismissable. Same size we use for the import
        // summary tile so the launch banner reads as part of the same
        // "compact confirmation" surface vocabulary.
        tile.floatingTile(size: .compact, onDismiss: onDismiss)
    }

    private var tile: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 14) {
                closeRow

                // Headline + subtitle. Right padding keeps the text out
                // from under the floating avatar so even long names like
                // "Maximiliaan wants to share an Amsterdam list" stay
                // readable at the wrap point.
                (
                    Text(person.name).fontWeight(.bold)
                    + Text(" wants to share an ")
                    + Text(listName).fontWeight(.bold)
                    + Text(" list")
                )
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(SomedayColors.charcoal)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 62)

                Text("\(placeCount) places picked just for you.")
                    .font(.system(size: 13))
                    .foregroundColor(SomedayColors.grayMedium)
                    .padding(.trailing, 62)

                Spacer(minLength: 4)

                buttons
            }
            .padding(18)

            // Small avatar tucked into the bottom-right corner of the
            // content area. Sits *above* the CTA row (padding.bottom 72
            // ≈ button height 46 + outer padding 18 + breathing room 8)
            // so the buttons remain the visual end of the tile, with the
            // avatar reading as a sender-identity sticker.
            smallAvatar
                .padding(.trailing, 18)
                .padding(.bottom, 72)
                .allowsHitTesting(false) // decorative, no interaction
        }
    }

    // MARK: - Pieces

    /// Close × in the top-right. Hoisted out of the body so the avatar
    /// floating overlay below doesn't fight it for hit-testing space.
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

    /// Small (44pt) avatar with a thin white ring + subtle shadow so it
    /// reads as a sender chip rather than a generic image. Falls back
    /// to initials on a primary-tinted disc if the URL doesn't load.
    private var smallAvatar: some View {
        AsyncImage(url: person.avatarURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Circle().fill(SomedayColors.primaryLight)
                    .overlay(
                        Text(person.initials)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(SomedayColors.primary)
                    )
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white, lineWidth: 2.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    /// Three actions:
    /// - **Maybe later** (outlined) — dismiss.
    /// - **Preview** (lime, primary) — see the pins on the map first.
    /// - **+ Add** (smaller, secondary) — skip preview, import straight away.
    private var buttons: some View {
        HStack(spacing: 8) {
            Button {
                onDismiss()
            } label: {
                Text("Maybe later")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundColor(SomedayColors.charcoal)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(SomedayColors.grayMedium.opacity(0.35), lineWidth: 1.5)
                    )
            }

            Button {
                onPreview()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("Preview")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(SomedayColors.lime)
                .foregroundColor(SomedayColors.charcoal)
                .cornerRadius(14)
            }

            // Add — the primary "yes, take this list" CTA. A native
            // Menu lets the user pick the access duration without
            // blowing up the tile's three-button footprint. Tapping the
            // chevron OR the body opens the menu; primary-press on the
            // label itself is the menu trigger.
            Menu {
                Button {
                    Haptics.tap()
                    onAdd(.days30)
                } label: {
                    Label("Add for 30 days", systemImage: "calendar")
                }
                Button {
                    Haptics.tap()
                    onAdd(.days90)
                } label: {
                    Label("Add for 90 days", systemImage: "calendar")
                }
                Button {
                    Haptics.tap()
                    onAdd(.forever)
                } label: {
                    Label("Add forever", systemImage: "infinity")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("Add")
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.7)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 13)
                .foregroundColor(SomedayColors.charcoal)
                .background(SomedayColors.butter)
                .cornerRadius(14)
            }
            .menuOrder(.fixed)
            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
        }
    }
}

// MARK: - Wire type

/// How long the receiver wants the shared list to stay accessible after
/// they tap Add. Persisted alongside the list membership so a future
/// "expire stale shared lists" sweep can revoke access at the right
/// time. `.forever` is the no-op case used for unrestricted adds.
enum ShareAccessDuration: Equatable, Sendable {
    case days30
    case days90
    case forever

    /// Concrete expiry date for a fresh accept, or `nil` for `.forever`.
    /// Anchored to the moment the user taps Add — call this once and
    /// stash the result on the list row.
    func expiryDate(from start: Date = .now) -> Date? {
        switch self {
        case .days30:  return Calendar.current.date(byAdding: .day, value: 30, to: start)
        case .days90:  return Calendar.current.date(byAdding: .day, value: 90, to: start)
        case .forever: return nil
        }
    }

    /// Compact label suitable for the "added until 14 Aug" footer chip
    /// we'll surface on shared-list tiles once they have expiries.
    var shortLabel: String {
        switch self {
        case .days30:  return "30 days"
        case .days90:  return "90 days"
        case .forever: return "Forever"
        }
    }
}
