import SwiftUI
import Contacts   // CNAuthorizationStatus for the friend-discovery sheet

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

// MARK: - Friend discovery sheet (onboarding "Find friends" on-ramp)

/// Contacts-based friend discovery, presented as a sheet from the chat
/// onboarding card. Ported from the old `OnboardingFlowTile` friends
/// step when the wizard was retired — the matching flow, permission
/// ladder, and add-request rows are unchanged; only the chrome moved
/// from an in-tile section to a standalone sheet so it can be launched
/// from the chat (and, later, from Profile) on demand.
struct FriendDiscoverySheet: View {
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var state: FriendsState = .idle
    @State private var matches: [MatchedContact] = []
    @State private var sentRequestIDs: Set<String> = []

    private enum FriendsState: Equatable {
        case idle
        case requestingPermission
        case scanning
        case noMatches
        case denied
        case showingMatches
        case errored(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(SomedayColors.primary)
                            .padding(.bottom, 2)
                        Text("Add the people who matter")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(SomedayColors.charcoal)
                            .multilineTextAlignment(.center)
                        Text("Your loved ones, not your acquaintances. Someday is for sharing with the few you really care about.")
                            .font(.system(size: 14))
                            .foregroundColor(SomedayColors.grayMedium)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                    }
                    .padding(.top, 8)

                    stateContent
                }
                .padding(20)
            }
            .navigationTitle("Find friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .idle:
            findButton.padding(.top, 8)

        case .requestingPermission, .scanning:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(SomedayColors.primary)
                Text(state == .requestingPermission
                     ? "Asking for permission…"
                     : "Checking your contacts…")
                    .font(.system(size: 13))
                    .foregroundColor(SomedayColors.grayMedium)
            }
            .padding(.top, 24)

        case .noMatches:
            infoBlock(
                icon: "person.crop.circle.badge.questionmark",
                title: "No matches yet",
                body: "None of your contacts are on Someday yet. Invite them — it's nicer with people."
            )

        case .denied:
            infoBlock(
                icon: "lock.fill",
                title: "Contacts permission off",
                body: "You can turn it on later in Settings → Privacy → Contacts → Someday."
            )

        case .errored(let msg):
            VStack(spacing: 8) {
                infoBlock(
                    icon: "exclamationmark.triangle.fill",
                    title: "Couldn't load matches",
                    body: msg,
                    tint: .orange
                )
                findButton.padding(.top, 8)
            }

        case .showingMatches:
            matchesList
        }
    }

    private func infoBlock(icon: String, title: String, body: String, tint: Color = SomedayColors.grayMedium) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(SomedayColors.charcoal)
            Text(body)
                .font(.system(size: 12))
                .foregroundColor(SomedayColors.grayMedium)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .padding(.top, 20)
    }

    private var findButton: some View {
        Button {
            Task { await startFriendDiscovery() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 14, weight: .bold))
                Text("Find friends from Contacts")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(SomedayColors.lime)
            .foregroundColor(SomedayColors.charcoal)
            .cornerRadius(14)
        }
    }

    private var matchesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(matches.count) on Someday")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
                Spacer()
                Text("Add the ones you love.")
                    .font(.system(size: 11))
                    .foregroundColor(SomedayColors.grayMedium)
            }
            VStack(spacing: 8) {
                ForEach(matches) { match in
                    matchRow(match)
                }
            }
        }
    }

    private func matchRow(_ match: MatchedContact) -> some View {
        let isSent = sentRequestIDs.contains(match.id)
        return HStack(spacing: 12) {
            AsyncImage(url: match.avatarURL) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default:
                    Circle().fill(SomedayColors.primary.opacity(0.18))
                        .overlay(
                            Text(match.name.first.map(String.init) ?? "?")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(SomedayColors.primary)
                        )
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(match.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                Text("Matched via \(match.matchedBy.rawValue)")
                    .font(.system(size: 11))
                    .foregroundColor(SomedayColors.grayMedium)
            }
            Spacer()

            Button {
                Task { await sendRequest(to: match) }
            } label: {
                Text(isSent ? "Sent" : "Add")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(isSent ? SomedayColors.grayLight : SomedayColors.lime)
                    .foregroundColor(isSent ? SomedayColors.grayMedium : SomedayColors.charcoal)
                    .cornerRadius(10)
            }
            .disabled(isSent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }

    // MARK: - Discovery flow

    @MainActor
    private func startFriendDiscovery() async {
        let svc = appState.services.contacts
        switch svc.authorizationStatus() {
        case .authorized:
            await runDiscovery(svc)
        case .denied, .restricted:
            state = .denied
        case .notDetermined:
            state = .requestingPermission
            let newStatus = await svc.requestAuthorization()
            if newStatus == .authorized {
                await runDiscovery(svc)
            } else {
                state = .denied
            }
        @unknown default:
            state = .errored("Unexpected permission state.")
        }
    }

    @MainActor
    private func runDiscovery(_ svc: ContactsServiceProtocol) async {
        state = .scanning
        do {
            let hashes = try await svc.collectContactHashes()
            if hashes.isEmpty {
                state = .noMatches
                return
            }
            let found = try await svc.findMatches(hashes)
            if found.isEmpty {
                state = .noMatches
            } else {
                matches = found
                state = .showingMatches
                Haptics.success()
            }
        } catch {
            #if DEBUG
            print("[FriendDiscoverySheet] runDiscovery failed: \(error)")
            #endif
            state = .errored(friendlyMessage(for: error))
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        let raw = error.localizedDescription.lowercased()
        if raw.contains("non-2xx") || raw.contains("functionshttp") || raw.contains("invalid jwt") {
            return "We couldn't reach the matching service. Confirm your email first, then try again."
        }
        if raw.contains("not authorized") || raw.contains("not authenticated") {
            return "Please sign in again to find friends."
        }
        return error.localizedDescription
    }

    @MainActor
    private func sendRequest(to match: MatchedContact) async {
        Haptics.tap()
        sentRequestIDs.insert(match.id)
        do {
            try await appState.services.contacts.sendFriendRequest(toUserID: match.id)
        } catch {
            sentRequestIDs.remove(match.id)
            Haptics.error()
            #if DEBUG
            print("[FriendDiscoverySheet] sendFriendRequest failed: \(error)")
            #endif
        }
    }
}
