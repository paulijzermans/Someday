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

struct BottomTabButton: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        // The Button has a no-op action; the press-down behavior is
        // handled by `PressDownButtonStyle` below so the tile pops the
        // instant the finger touches the button instead of waiting for
        // release.
        Button {} label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: isActive ? .bold : .regular))
                Text(label)
                    .font(.system(size: 10, weight: isActive ? .bold : .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isActive ? AnyShapeStyle(SomedayColors.lime) : AnyShapeStyle(Color.clear))
                    .padding(.horizontal, 4)
            )
            .foregroundColor(SomedayColors.charcoal)
            // Ensure the entire button frame catches taps, not just the
            // glyph + label glyph shapes.
            .contentShape(Rectangle())
            .animation(SomedayAnimations.chipToggle, value: isActive)
        }
        .buttonStyle(PressDownButtonStyle(onPress: action))
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
