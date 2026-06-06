import SwiftUI

/// Floating glass tile that lets the user fire off a quick piece of
/// feedback. Same surface treatment as the Lists / Activity / Add tiles —
/// scrim + centered glass card pinned between the search button and the
/// profile avatar — so feedback feels like the same kind of map-level
/// affordance, not a system sheet.
///
/// On Send we hand off to Mail with the category + message pre-composed,
/// so we don't need a server table yet. (We can move to a Supabase
/// `feedback` table later without changing the UI.)
struct FeedbackTileView: View {
    let onDismiss: () -> Void

    @State private var category: FeedbackCategory? = nil
    @State private var message: String = ""
    @Environment(\.openURL) private var openURL
    @FocusState private var messageFocused: Bool

    var body: some View {
        tile.floatingTile(size: .large, onDismiss: onDismiss)
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroHeader

            categoryRow

            messageBox

            Spacer(minLength: 4)

            actionRow
        }
        .padding(20)
        // Glass + shadow + frame applied by `.floatingTile(size: .large)`.
    }

    // MARK: - Hero header

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("We")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
                Text("❤️")
                    .font(.system(size: 26))
                Text("feedback")
                    .font(.system(size: 26, weight: .bold))
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

            Text("You are what makes this app great.")
                .font(.system(size: 15))
                .foregroundColor(SomedayColors.grayMedium)
        }
    }

    // MARK: - Category row

    private var categoryRow: some View {
        HStack(spacing: 10) {
            ForEach(FeedbackCategory.allCases) { cat in
                CategoryChip(
                    category: cat,
                    isSelected: category == cat
                ) {
                    withAnimation(SomedayAnimations.chipPick) {
                        category = (category == cat) ? nil : cat
                    }
                }
            }
        }
    }

    // MARK: - Message box

    private var messageBox: some View {
        ZStack(alignment: .topLeading) {
            if message.isEmpty {
                Text("Tell us what's on your mind…")
                    .font(.system(size: 15))
                    .foregroundColor(SomedayColors.grayMedium.opacity(0.7))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $message)
                .font(.system(size: 15))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .scrollContentBackground(.hidden)
                .focused($messageFocused)
        }
        .frame(minHeight: 100, maxHeight: 140)
        .background(.white)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(SomedayColors.grayMedium.opacity(0.25), lineWidth: 1)
        )
        .cornerRadius(14)
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                onDismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundColor(SomedayColors.charcoal)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(SomedayColors.grayMedium.opacity(0.35), lineWidth: 1.5)
                    )
            }

            Button {
                send()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Send")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(canSend ? SomedayColors.lime : SomedayColors.grayMedium.opacity(0.4))
                .foregroundColor(canSend ? SomedayColors.charcoal : .white)
                .cornerRadius(12)
            }
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        category != nil &&
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Send

    /// Compose a mailto URL with the picked category as subject prefix and
    /// the user's message in the body. Hands off to Mail; the user taps
    /// Send there. Dismiss after we attempt to open the URL.
    private func send() {
        guard let category, canSend else { return }

        let subject = "Someday [\(category.label)] feedback"
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = "\(category.emoji) \(category.label)\n\n\(trimmed)\n\n— Sent from Someday"

        var components = URLComponents(string: "mailto:paulijzermans@gmail.com")!
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        if let url = components.url {
            openURL(url)
        }
        onDismiss()
    }
}

// MARK: - Category model

enum FeedbackCategory: String, CaseIterable, Identifiable {
    case bug, improvement, idea

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bug:         return "Bug"
        case .improvement: return "Improvement"
        case .idea:        return "Idea"
        }
    }

    var emoji: String {
        switch self {
        case .bug:         return "🐛"
        case .improvement: return "🛠️"
        case .idea:        return "💡"
        }
    }

    var tint: Color {
        switch self {
        case .bug:         return Color(red: 1.0, green: 0.32, blue: 0.45)  // rose
        case .improvement: return SomedayColors.primary                    // blue
        case .idea:        return SomedayColors.amber                      // amber
        }
    }
}

// MARK: - Chip

private struct CategoryChip: View {
    let category: FeedbackCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(category.emoji)
                    .font(.system(size: 24))
                Text(category.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isSelected ? .white : SomedayColors.charcoal)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? AnyShapeStyle(category.tint) : AnyShapeStyle(category.tint.opacity(0.12)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? category.tint : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}
