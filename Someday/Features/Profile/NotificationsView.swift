import SwiftUI

// =============================================================================
// NotificationsView — per-channel push-notification toggles
// =============================================================================
//
// The actual push infrastructure (APNs registration, server-side fanout)
// is still TODO, so this screen is intentionally just preference flags
// today. Once the server wiring lands, the toggles will gate the
// corresponding `device_subscriptions.kind = '…'` rows we send to the
// notification service.

struct NotificationsView: View {
    @Environment(SomedayPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            @Bindable var prefs = preferences

            Form {
                Section {
                    Toggle("Friend requests", isOn: Binding(
                        get: { prefs.notifyFriendRequests },
                        set: { prefs.notifyFriendRequests = $0 }
                    ))
                    Toggle("Shared lists", isOn: Binding(
                        get: { prefs.notifyListShares },
                        set: { prefs.notifyListShares = $0 }
                    ))
                    Toggle("Likes on my reviews", isOn: Binding(
                        get: { prefs.notifyReviewLikes },
                        set: { prefs.notifyReviewLikes = $0 }
                    ))
                } header: {
                    Text("Push notifications")
                } footer: {
                    Text("These are the moments we'll wake your phone for. Everything else stays in the Activity tab.")
                }

                Section {
                    Toggle("Weekly digest", isOn: Binding(
                        get: { prefs.notifyWeeklyDigest },
                        set: { prefs.notifyWeeklyDigest = $0 }
                    ))
                } header: {
                    Text("Email")
                } footer: {
                    Text("A Sunday-morning summary of new places your friends saved this week.")
                }
            }
            // Drop onto the shared cream canvas so the Form's sections read
            // as clean white tiles floating on warm off-white — the same
            // tile language as the Profile page (see `cleanTile` /
            // `anthropicCanvas` in TileStyle.swift), rather than the stock
            // grey grouped-list background.
            .scrollContentBackground(.hidden)
            .background(SomedayColors.anthropicWhite)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
