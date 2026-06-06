import SwiftUI

enum AppScreen {
    case auth
    case map
}

@Observable
final class AppState {
    var currentScreen: AppScreen
    var currentUser: UserProfile?
    /// True between sign-up and onboarding completion. The map renders
    /// underneath, with the `OnboardingFlowTile` overlaid on top — so
    /// new users see the real product surface while they're walked
    /// through the import + friends steps. Old `.onboarding` screen
    /// case was removed.
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

    /// Parses `someday://import?url=…` and stashes the result for the
    /// map to pick up. Returns true if the URL was recognized.
    @discardableResult
    func handle(externalURL: URL) -> Bool {
        guard externalURL.scheme == "someday" else { return false }
        guard externalURL.host == "import" else { return false }

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
