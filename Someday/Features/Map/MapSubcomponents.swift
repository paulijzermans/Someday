import SwiftUI

// =============================================================================
// Small reusable subcomponents used by the Map experience. These were
// originally tucked at the bottom of MapHomeView.swift; pulled out here so
// the main view file stays focused on layout + behaviour and these
// rendering helpers are findable on their own.
// =============================================================================

// MARK: - Saved toast (post-save confirmation card)

struct SavedToastCard: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(
                    colors: [SomedayColors.primary, SomedayColors.primaryDark],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(height: 160)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundColor(.white)
                        Text("TikTok")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                )
                .padding(.horizontal, 24)

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(SomedayColors.primary)
                    Text("Saved to your map")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(SomedayColors.grayMedium)
                }
                .padding(.top, 16)

                Text("Berlini")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)

                HStack(spacing: 6) {
                    Image(systemName: "fork.knife").font(.system(size: 13))
                    Text("Italian Restaurant")
                    Text("•")
                    Text("Mitte, Berlin")
                }
                .font(.system(size: 14))
                .foregroundColor(SomedayColors.grayMedium)
                .padding(.bottom, 20)

                Button(action: onDismiss) {
                    Text("Got it!")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(SomedayColors.lime)
                        .foregroundColor(SomedayColors.charcoal)
                        .cornerRadius(14)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(.white)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        .padding(.horizontal, 32)
    }
}

// MARK: - Tab bar button

/// Icon-only tab element for the glass bottom bar. Follows the modern
/// Instagram pattern: a single line-weight SF Symbol that swaps to its
/// filled variant (and a slightly heavier weight) when its surface is
/// active — no text label, no pill background. A `disabled` slot dims the
/// glyph and stops taps, so a reserved-for-later tab reads as "coming
/// soon" without looking broken.
struct GlassTabIcon: View {
    /// Outline symbol shown when inactive (e.g. "bell").
    let icon: String
    /// Filled symbol shown when active (e.g. "bell.fill"). Falls back to
    /// `icon` when nil — fine for glyphs without a `.fill` variant.
    var activeIcon: String? = nil
    var isActive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        // No-op Button label; the press-down behaviour (instant tile pop +
        // haptic on touch-down) is handled by `PressDownButtonStyle`.
        Button {} label: {
            Image(systemName: isActive ? (activeIcon ?? icon) : icon)
                .font(.system(size: 22, weight: isActive ? .semibold : .regular))
                .foregroundColor(
                    isEnabled
                        ? SomedayColors.charcoal
                        : SomedayColors.charcoal.opacity(0.28)
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                // Whole slot catches taps, not just the glyph silhouette.
                .contentShape(Rectangle())
                .animation(SomedayAnimations.chipToggle, value: isActive)
        }
        .buttonStyle(PressDownButtonStyle(onPress: action))
        .disabled(!isEnabled)
        .allowsHitTesting(isEnabled)
    }
}

// MARK: - Press-down button style

/// Button style that fires its action on touch-down rather than on
/// release, so an overlay tile (Lists, Activity, etc.) appears as soon
/// as the finger lands on the button. Also gives a small scale feedback
/// while pressed so the user knows the touch registered.
struct PressDownButtonStyle: ButtonStyle {
    let onPress: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(SomedayAnimations.pressFeedback, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    // Selection-style tick is the iOS-native feel for
                    // switching between mutually-exclusive options
                    // (Lists / Activity / Add / etc.).
                    Haptics.select()
                    onPress()
                }
            }
    }
}

// MARK: - UIKit bridges

/// Wraps `UIActivityViewController` so the SwiftUI side can present the
/// standard iOS share sheet via `.sheet(...)`.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
