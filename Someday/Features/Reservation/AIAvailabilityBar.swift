import SwiftUI

// =============================================================================
// AIAvailabilityBar — floating result panel in the top-right of the map
// =============================================================================
//
// Appears after the user taps "Done" on PlaceCardSheet's Availability CTA.
// Visually echoes the existing aiChatBar (glass effect, animated gradient
// border, sparkles icon) so the AI motif is consistent — but this surface
// is read-only: it displays the AI's findings as a summary line + a list
// of tappable platform rows. Tapping a row with a URL opens the booking
// page in Safari. A close button dismisses the panel.
//
// State lives entirely on MapViewModel (`availabilityResult`,
// `availabilityResultPlace`) so MapHomeView just needs to overlay this
// view conditionally and the close action just nils out the result.

struct AIAvailabilityBar: View {
    let result: AvailabilityResult
    let place: Place
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL

    /// Drives the gradient-border angle rotation. Same idea as the
    /// aiChatBar's border — gives the panel a soft "alive" feel.
    @State private var borderStart: UnitPoint = .topLeading
    @State private var borderEnd: UnitPoint = .bottomTrailing
    @State private var borderOpacity: Double = 0.65
    /// Drives the sparkles pulse.
    @State private var sparklePulse = false

    private let aiGradient = LinearGradient(
        colors: [
            Color(red: 0.55, green: 0.45, blue: 1.0),
            SomedayColors.primary,
            Color(red: 1.0, green: 0.45, blue: 0.80)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            if result.platforms.isEmpty {
                emptyState
            } else {
                Divider().opacity(0.2)
                ForEach(result.platforms) { platform in
                    platformRow(platform)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 320, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.45, blue: 1.0).opacity(borderOpacity),
                            SomedayColors.primary.opacity(borderOpacity),
                            Color(red: 1.0, green: 0.45, blue: 0.80).opacity(borderOpacity)
                        ],
                        startPoint: borderStart,
                        endPoint: borderEnd
                    ),
                    lineWidth: 1.8
                )
        )
        .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
        .onAppear {
            sparklePulse = true
            withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
                borderStart = .bottomTrailing
                borderEnd = .topLeading
                borderOpacity = 0.95
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(aiGradient)
                .scaleEffect(sparklePulse ? 1.08 : 0.92)
                .opacity(sparklePulse ? 1.0 : 0.85)
                .animation(
                    .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                    value: sparklePulse
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(result.summary)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                    .lineLimit(2)
                Text(place.name)
                    .font(.system(size: 11))
                    .foregroundColor(SomedayColors.grayMedium)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(SomedayColors.grayMedium)
                    .frame(width: 24, height: 24)
                    .background(SomedayColors.grayLight)
                    .clipShape(Circle())
            }
        }
    }

    // MARK: - Platform row

    /// Tappable row when the AI found a direct URL; static label when it
    /// could only name the platform (e.g. "call the venue").
    @ViewBuilder
    private func platformRow(_ platform: BookingPlatform) -> some View {
        if let url = platform.url {
            Button { openURL(url) } label: { platformContent(platform) }
                .buttonStyle(.plain)
        } else {
            platformContent(platform)
        }
    }

    private func platformContent(_ platform: BookingPlatform) -> some View {
        HStack(spacing: 10) {
            // Tiny dot in the brand gradient — purely decorative, gives
            // each row a visual anchor without committing to per-platform
            // logos we don't have assets for.
            Circle()
                .fill(aiGradient)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(platform.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                if let note = platform.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(SomedayColors.grayMedium)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)

            if platform.url != nil {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
                    .foregroundColor(SomedayColors.grayMedium)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        Text("No bookable platforms found — try calling the venue.")
            .font(.system(size: 12))
            .foregroundColor(SomedayColors.grayMedium)
            .padding(.top, 2)
    }
}
