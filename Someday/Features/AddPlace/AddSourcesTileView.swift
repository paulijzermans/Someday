import SwiftUI

/// Half-screen carousel tile shown when the user taps **+** in the tab bar.
/// Swipe between the three import sources (List → Maps → Socials), tap the
/// big circular icon to pick that source. Custom page dots below indicate
/// position and act as tap targets to jump between pages.
struct AddSourcesTileView: View {
    let onSelectList: () -> Void
    let onSelectMaps: () -> Void
    let onSelectSocials: () -> Void
    let onDismiss: () -> Void

    @State private var currentPage = 0

    var body: some View {
        tile.floatingTile(size: .half, onDismiss: onDismiss)
    }

    private var tile: some View {
        VStack(spacing: 0) {
            header

            TabView(selection: $currentPage) {
                page(
                    title: "List",
                    caption: "Paste places from your notes — AI sorts them onto the map.",
                    symbol: "list.bullet",
                    color: SomedayColors.primary,
                    action: onSelectList
                )
                .tag(0)

                page(
                    title: "Maps",
                    caption: "Import a saved list straight from your Google Maps.",
                    symbol: "map.fill",
                    color: SomedayColors.accentGreen,
                    action: onSelectMaps
                )
                .tag(1)

                page(
                    title: "Socials",
                    caption: "Drop in an Instagram Reel link — we'll pull out the places.",
                    symbol: "shared.with.you",
                    color: SomedayColors.coral,
                    action: onSelectSocials
                )
                .tag(2)
            }
            // Hide the system page dots; we render our own (smaller, scale-on-active).
            .tabViewStyle(.page(indexDisplayMode: .never))

            pageDots
                .padding(.bottom, 18)
        }
        .padding(.top, 14)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Add a place")
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
        .padding(.bottom, 6)
    }

    // MARK: - Single carousel page

    /// Each page is just an oversized tappable icon + label. No more "Use X"
    /// button — the icon IS the action.
    private func page(
        title: String,
        caption: String,
        symbol: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 130, height: 130)
                    Image(systemName: symbol)
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(color)
                }
            }
            // Plain release-on-tap so swiping the carousel doesn't
            // accidentally fire the source's action mid-swipe.
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundColor(SomedayColors.grayMedium)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 4)
        }
    }

    // MARK: - Custom page dots

    /// Smaller-than-default dots; the active one scales up a touch. Each dot
    /// is tappable so the user can jump straight to a page without swiping.
    private var pageDots: some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { i in
                Button {
                    withAnimation(SomedayAnimations.inTileNav) {
                        currentPage = i
                    }
                } label: {
                    Circle()
                        .fill(i == currentPage ? SomedayColors.charcoal : SomedayColors.grayMedium.opacity(0.35))
                        .frame(width: 6, height: 6)
                        .scaleEffect(i == currentPage ? 1.5 : 1.0)
                        .animation(SomedayAnimations.chipToggle, value: currentPage)
                        // Wider invisible hit target so tiny dots stay tappable.
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
