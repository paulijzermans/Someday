import SwiftUI
import CoreText

@main
struct SomedayApp: App {
    @State private var appState = AppState()

    init() {
        SomedayFonts.registerAll()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch appState.currentScreen {
                case .auth:
                    AuthView(appState: appState)
                case .onboarding:
                    OnboardingView(appState: appState)
                case .map:
                    MapHomeView(appState: appState)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: appState.currentScreen)
        }
    }
}
