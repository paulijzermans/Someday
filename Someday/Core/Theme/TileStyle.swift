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

// MARK: - The defined thin edge

extension Color {
    /// Someday's single source of truth for the "defined thin line" that
    /// frames every image box and every image-bearing card across the app.
    /// A light, clearly-visible outline — the modern, crisp edge that
    /// replaces the old heavier borders / white photo frames. Reference this
    /// instead of hand-rolling a one-off `Color.black.opacity(...)` so the
    /// whole app's edge treatment stays in lockstep.
    ///
    /// Repointed to Anthropic's warm tan `#B0AEA5` so every image-box edge
    /// and card border across the app reads in the earthy Anthropic neutral
    /// rather than the old cool `systemGray4`.
    static let somedayEdge = SomedayColors.anthropicTan
}

extension View {
    /// Someday's signature image-box edge — a clean ~1pt light-gray outline
    /// hugging the photo's rounded rectangle. Apply it to ANY image (or image
    /// placeholder) that sits inside a tile or card so all imagery across the
    /// app reads as one modern, consistent family: a thin defined line between
    /// the photo and whatever surrounds it.
    ///
    /// The view is clipped to the rounded rect, then a `lineWidth`-thick
    /// `somedayEdge` border is stroked on top. No white inset frame — the edge
    /// IS the line, so a photo sits flush inside its outline.
    ///
    /// - Parameters:
    ///   - cornerRadius: the corner radius (matches the surface's radius).
    ///   - lineWidth: edge thickness. ~1pt reads as a defined-but-light line.
    func photoTileEdge(cornerRadius: CGFloat = 16, lineWidth: CGFloat = 1) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.somedayEdge, lineWidth: lineWidth)
            )
    }

    /// The card / tile counterpart of `photoTileEdge`: wraps an image-bearing
    /// design element in the same defined thin `somedayEdge` outline so the
    /// whole surface and the photo inside it share one modern edge language.
    /// Use on the OUTER card surface (the one that already clips its content
    /// to `cornerRadius`).
    func somedayCardEdge(cornerRadius: CGFloat, lineWidth: CGFloat = 1) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.somedayEdge, lineWidth: lineWidth)
        )
    }
}

// MARK: - Layered surfaces (cream canvas + clean white tiles)

extension View {
    /// The app's page canvas — Anthropic's warm off-white `#F0EEE6`. Use on
    /// the *background* layer of a screen/sheet so the foreground cards (see
    /// `cleanTile`) read as clean white tiles floating on a warm surface.
    /// Ignores the safe area by default so the cream carries edge-to-edge.
    func anthropicCanvas(ignoresSafeArea: Bool = true) -> some View {
        self.background(
            SomedayColors.anthropicWhite
                .modifier(_MaybeIgnoreSafeArea(active: ignoresSafeArea))
        )
    }

    /// A clean white foreground tile floating on the `anthropicCanvas`: pure
    /// white fill, rounded corners, and a soft, light shadow that lifts it off
    /// the cream. Use for the cards / rows / sheets that sit *in front of* the
    /// page — the counterpart to `anthropicCanvas`. Replaces a bare
    /// `.background(.white)` / `.background(anthropicWhite)` on foreground
    /// elements so the whole app shares one tile language.
    func cleanTile(cornerRadius: CGFloat = 22,
                   shadowOpacity: Double = 0.06,
                   shadowRadius: CGFloat = 16,
                   shadowY: CGFloat = 8) -> some View {
        self
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowY)
    }
}

/// Tiny helper so `anthropicCanvas` can conditionally apply `ignoresSafeArea`
/// without two code paths at every call site.
private struct _MaybeIgnoreSafeArea: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.ignoresSafeArea() } else { content }
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
