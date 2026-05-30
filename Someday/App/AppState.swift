import SwiftUI

enum AppScreen {
    case auth
    case onboarding
    case map
}

@Observable
final class AppState {
    var currentScreen: AppScreen
    var currentUser: UserProfile?
    let services: ServiceContainer

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
        currentScreen = .onboarding
    }

    func completeOnboarding() {
        currentScreen = .map
    }

    func signOut() {
        try? services.auth.signOut()
        currentUser = nil
        currentScreen = .auth
    }
}
