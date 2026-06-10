import SwiftUI

// =============================================================================
// Tile sizes used across Someday — one source of truth so we stop hand-rolling
// the "floating glass card on a dim scrim" pattern in every feature.
//
//   .large   — full-screen floating overlay (Lists, Activity, Add, Feedback,
//              ShareRequest, ImportSummary). Pinned between the search button
//              and the profile avatar.
//
//   .half    — half-screen floating overlay. Same scrim treatment, but starts
//              partway down the screen so the map underneath is still partly
//              visible. Use for confirmations / smaller pickers.
//
//   .small   — inline tile (no scrim, no overlay). The colored shape tiles
//              that show up inside grids — Lists screen, the per-person
//              lists drawer in Activity, etc. Built directly with `ListTile`
//              et al; no overlay container needed.
// =============================================================================

enum TileSize {
    case large
    case half
    /// Snug confirmation card that sits in the lower third of the screen —
    /// used by `ImportSummaryCardView` so a "1 reel = a couple of places"
    /// import doesn't take over the full screen. Smaller than `.half`.
    case compact

    /// Top inset from the screen edge to where the tile begins.
    var topPadding: CGFloat {
        switch self {
        case .large:   return 8     // just below the search button row
        case .half:    return 240   // bottom half of the screen
        case .compact: return 400   // lower third
        }
    }

    /// Bottom inset to where the tile ends. Sits just above where the
    /// profile avatar normally floats so neither overlaps the other.
    var bottomPadding: CGFloat {
        switch self {
        case .large:   return 90
        case .half:    return 90
        case .compact: return 110
        }
    }

    /// Horizontal inset matches the tab bar so all map-level chrome lines up.
    var horizontalPadding: CGFloat {
        16
    }

    /// Rounded corner of the inner glass card.
    var cornerRadius: CGFloat {
        switch self {
        case .large:   return 24
        case .half:    return 22
        case .compact: return 22
        }
    }

    /// Anchor for the scale-in transition. Large tiles "pop" from center;
    /// half + compact tiles rise from the bottom which feels closer to a
    /// sheet.
    var scaleAnchor: UnitPoint {
        switch self {
        case .large:                 return .center
        case .half, .compact:        return .bottom
        }
    }
}

// MARK: - Photo-tile edge

extension View {
    /// Someday's signature "photo tile" edge — the thin white frame + faint
    /// hairline that wraps every map pin's image (`ClusteredMapView`'s pin
    /// renderer). Apply it to ANY image that sits inside a tile or card so all
    /// imagery across the app reads as one consistent family: a small white
    /// edge between the photo and whatever surrounds it.
    ///
    /// The view it's attached to is clipped to the INNER rounded rect; a
    /// `edge`-thick white margin and a 0.5pt black hairline frame it. Mirrors
    /// the pin's geometry (white silhouette + inner-clipped photo + 0.10 black
    /// hairline), just scaled up for card-sized imagery.
    ///
    /// - Parameters:
    ///   - cornerRadius: the OUTER corner radius (matches the surface's radius).
    ///   - edge: white frame thickness. Keep it small (~3pt) so it reads as a
    ///           hairline frame, not a border.
    func photoTileEdge(cornerRadius: CGFloat = 16, edge: CGFloat = 3) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: max(cornerRadius - edge, 0), style: .continuous))
            .padding(edge)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
            )
    }
}

// MARK: - Floating-tile modifier

extension View {
    /// Wrap this view in a centered floating glass tile with a tap-to-dismiss
    /// scrim. Animates in with scale+fade; scrim fades independently so the
    /// dark background doesn't "scale" into view.
    func floatingTile(size: TileSize, onDismiss: @escaping () -> Void) -> some View {
        FloatingTileContainer(size: size, onDismiss: onDismiss) { self }
    }
}

private struct FloatingTileContainer<Content: View>: View {
    let size: TileSize
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            // Scrim — fades only.
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
                .transition(.opacity)

            // Tile content — scales + fades.
            VStack(spacing: 0) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassEffect(.regular, in: .rect(cornerRadius: size.cornerRadius))
                    .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
                    .padding(.top, size.topPadding)
                    .padding(.bottom, size.bottomPadding)
            }
            .padding(.horizontal, size.horizontalPadding)
            .transition(.scale(scale: 0.92, anchor: size.scaleAnchor).combined(with: .opacity))
        }
    }
}
