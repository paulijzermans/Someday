import SwiftUI

enum AppScreen {
    case auth
    case map
}

@Observable
final class AppState {
    var currentScreen: AppScreen
    var currentUser: UserProfile?
    /// True between sign-up and onboarding completion. Onboarding now
    /// happens INSIDE the chat panel on the map — `MapHomeView` opens the
    /// AI bar with an on-ramp card (Import Maps / Reels / Paste a list /
    /// Find friends) pinned atop the transcript, and the assistant runs
    /// in ONBOARDING mode — so new users see the real product surface
    /// while they add their first places. Old `.onboarding` screen case
    /// and the standalone `OnboardingFlowTile` wizard were both removed.
    var isOnboarding: Bool = false
    let services: ServiceContainer

    /// A URL handed in by the Share Extension (or any external `someday://`
    /// link). MapHomeView observes this and pops the right import sheet
    /// once the user lands on the map.
    var pendingImportURL: PendingImport?

    enum PendingImport: Equatable {
        case instagram(URL)
        case googleMaps(URL)
    }

    /// Parses any `someday://…` deep link and routes it to the right
    /// handler. Returns true if the URL was recognised.
    ///
    /// Recognised hosts:
    ///   • `someday://import?url=…` — Share Extension / external import
    ///     hand-off; stashes a `PendingImport` for the map to pick up.
    ///   • `someday://auth-callback…` — Supabase email-confirmation
    ///     redirect. The fragment carries the access/refresh tokens,
    ///     which we feed to the SDK so the user lands signed in.
    @discardableResult
    func handle(externalURL: URL) -> Bool {
        guard externalURL.scheme == "someday" else { return false }

        switch externalURL.host {
        case "import":
            return handleImportURL(externalURL)
        case "auth-callback":
            handleAuthCallback(externalURL)
            return true
        default:
            return false
        }
    }

    /// Hand off a `someday://auth-callback#access_token=…` payload to
    /// the auth service. Fires off the consume + state-update on a Task
    /// so the deep-link handler can return immediately.
    private func handleAuthCallback(_ url: URL) {
        Task { @MainActor in
            do {
                let user = try await services.auth.consumeAuthCallback(url: url)
                handleAuthSuccess(user: user)
            } catch {
                #if DEBUG
                print("[AppState] consumeAuthCallback failed: \(error)")
                #endif
                // Stay on the auth screen — the user can hit
                // "I've confirmed" or try again. We don't surface this
                // error in the UI because the user already saw it via
                // the confirmation panel.
            }
        }
    }

    private func handleImportURL(_ externalURL: URL) -> Bool {
        let comps = URLComponents(url: externalURL, resolvingAgainstBaseURL: false)
        guard let raw = comps?.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: raw) else {
            return false
        }

        let host = (target.host ?? "").lowercased()
        if host.contains("instagram.com") {
            pendingImportURL = .instagram(target)
        } else if host.contains("google.com") || host.contains("goo.gl") || host.contains("maps.app.goo.gl") {
            pendingImportURL = .googleMaps(target)
        } else {
            // Default to Google Maps for unknown links — the parser tolerates
            // either origin, so this is a safe fallback.
            pendingImportURL = .googleMaps(target)
        }
        return true
    }

    init(services: ServiceContainer = .live) {
        self.services = services

        if SupabaseConfig.isConfigured {
            // Real backend: restore an existing session if one is cached,
            // otherwise drop the user on the auth screen to sign in with Google.
            if let user = services.auth.currentUser() {
                self.currentUser = user
                self.currentScreen = .map
            } else {
                self.currentUser = nil
                self.currentScreen = .auth
            }
        } else {
            // No backend yet — keep the offline demo with sample data.
            self.currentUser = SampleData.currentUser
            self.currentScreen = .map
        }
    }

    func handleAuthSuccess(user: UserProfile) {
        currentUser = user
        currentScreen = .map
        // First-run flag — the map will show the in-map onboarding
        // overlay until this is cleared by `completeOnboarding`.
        isOnboarding = true
    }

    func completeOnboarding() {
        isOnboarding = false
    }

    func signOut() {
        try? services.auth.signOut()
        currentUser = nil
        currentScreen = .auth
    }
}
