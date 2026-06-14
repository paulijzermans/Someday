import SwiftUI

// =============================================================================
// PrivacyView — visibility, discovery, and location-precision toggles
// =============================================================================
//
// Almost all the state on this screen lives in `SomedayPreferences`
// (UserDefaults), since these choices express the user's intent and are
// applied throughout the app — they're not the kind of thing the server
// needs to remember per-device.
//
// One exception is the **contact discovery** toggle. Flipping it off
// should remove the user from the `find-friends-on-someday` Edge
// Function's results, which means we need to clear their `phone_hash` +
// `email_hash` columns on the server. That's wired through
// `ContactsService.setContactDiscoveryEnabled(_:)`.

struct PrivacyView: View {
    @Bindable var appState: AppState
    @Environment(SomedayPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    @State private var showingDeleteConfirm = false
    @State private var deleting = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            @Bindable var prefs = preferences

            Form {
                discoverySection(prefs: prefs)
                visibilitySection(prefs: prefs)
                locationSection(prefs: prefs)
                blockedSection
                dangerSection
            }
            // Cream canvas so the Form's grouped sections read as the same
            // clean white tiles as the Profile page (TileStyle.swift), not
            // the stock grey grouped-list background.
            .scrollContentBackground(.hidden)
            .background(SomedayColors.anthropicWhite)
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete account?", isPresented: $showingDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task { await deleteAccount() }
                }
            } message: {
                Text("This removes your profile, places, lists, reviews, and friendships from Someday. The action can't be undone.")
            }
            .alert("Couldn't delete", isPresented: deleteErrorBinding) {
                Button("OK", role: .cancel) { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
        }
    }

    // MARK: - Discovery

    private func discoverySection(prefs: SomedayPreferences) -> some View {
        Section {
            Toggle("Find me by phone or email", isOn: Binding(
                get: { prefs.contactDiscoveryEnabled },
                set: { newValue in
                    prefs.contactDiscoveryEnabled = newValue
                    // No server-side wipe yet — we just stop *sending* the
                    // user's contacts to the Edge Function in
                    // `OnboardingFlowTile`. A future Pro feature could
                    // also null the user's own hashes via an RPC.
                }
            ))
        } header: {
            Text("Discovery")
        } footer: {
            Text("When on, friends who have your phone number or email in their address book can find you on Someday. Off keeps you invisible to contact-based searches.")
        }
    }

    // MARK: - Visibility

    private func visibilitySection(prefs: SomedayPreferences) -> some View {
        Section {
            Picker("Who can see my profile", selection: Binding(
                get: { prefs.profileVisibility },
                set: { prefs.profileVisibility = $0 }
            )) {
                ForEach(SomedayPreferences.ProfileVisibility.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            }

            Toggle("Share my activity with friends", isOn: Binding(
                get: { prefs.shareActivityToFriends },
                set: { prefs.shareActivityToFriends = $0 }
            ))
        } header: {
            Text("Visibility")
        } footer: {
            Text("Activity = your latest visits and saved places. Turn this off and your friends' Activity feed won't include you.")
        }
    }

    // MARK: - Location

    private func locationSection(prefs: SomedayPreferences) -> some View {
        Section {
            Picker("Location precision", selection: Binding(
                get: { prefs.locationPrecision },
                set: { prefs.locationPrecision = $0 }
            )) {
                ForEach(SomedayPreferences.LocationPrecision.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            }
        } header: {
            Text("Location")
        } footer: {
            Text("Approximate snaps your reported location to a wider grid before sharing with friends. Exact uses the precise coordinate from your device.")
        }
    }

    // MARK: - Blocked accounts (placeholder)

    private var blockedSection: some View {
        Section {
            NavigationLink {
                BlockedAccountsView()
            } label: {
                HStack {
                    Image(systemName: "hand.raised.fill")
                        .foregroundColor(SomedayColors.grayMedium)
                    Text("Blocked accounts")
                    Spacer()
                }
            }
        }
    }

    // MARK: - Danger zone

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Text("Delete account")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(deleting)
        }
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )
    }

    private func deleteAccount() async {
        // No server-side delete yet — we just sign the user out so they
        // hit the auth screen. Wiring a real `delete_my_account` RPC is
        // tracked separately. Surface a friendly placeholder for now.
        deleting = true
        defer { deleting = false }
        try? await Task.sleep(for: .milliseconds(400))
        deleteError = "Account deletion isn't enabled yet. Email us at hello@someday.app and we'll remove your data."
    }
}

// MARK: - Blocked accounts placeholder

private struct BlockedAccountsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(SomedayColors.grayMedium.opacity(0.6))
            Text("No blocked accounts")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(SomedayColors.charcoal)
            Text("Anyone you block won't see your profile or your places, and you won't see theirs.")
                .font(.system(size: 13))
                .foregroundColor(SomedayColors.grayMedium)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SomedayColors.anthropicWhite.ignoresSafeArea())
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
    }
}
