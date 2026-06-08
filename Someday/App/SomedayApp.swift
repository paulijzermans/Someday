import SwiftUI
import CoreText

@main
struct SomedayApp: App {
    @State private var appState = AppState()
    /// Persistent client-side prefs (subscription tier, map type, privacy
    /// toggles, notification choices). Injected into the environment so
    /// every settings sheet reads from the same source of truth.
    @State private var preferences = SomedayPreferences()
    /// Drives the splash overlay shown on cold launch. True for the
    /// first ~1.0s after the window appears, then flips to false and
    /// fades out — revealing the real first screen underneath.
    @State private var showingSplash = true

    init() {
        SomedayFonts.registerAll()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Real app content sits underneath the splash. The splash
                // overlay fades away on top so there's no visible
                // transition gap — content is already laid out when the
                // user first sees it.
                Group {
                    switch appState.currentScreen {
                    case .auth:
                        AuthView(appState: appState)
                    case .map:
                        // First-run users land here too — the
                        // OnboardingFlowTile overlays the map until
                        // `appState.isOnboarding` flips false.
                        MapHomeView(appState: appState)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: appState.currentScreen)

                // Brand splash: white background + centered balloon.
                // Stays for ~1.0s on cold launch so the brand mark
                // registers, then fades out. Tucked inside the ZStack so
                // it always sits above whatever first screen mounts —
                // user can't see auth/map flicker behind it.
                if showingSplash {
                    splashOverlay
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .onAppear {
                // ~1.0s feels like an intentional brand beat without
                // dragging. Tuned to match the system launch screen so
                // the perceived hand-off from LaunchScreen.storyboard /
                // launch image into SwiftUI is seamless.
                Task {
                    try? await Task.sleep(for: .milliseconds(1000))
                    withAnimation(.easeOut(duration: 0.35)) {
                        showingSplash = false
                    }
                }
            }
            .onOpenURL { url in
                // Triggered by Safari, the Share Extension, or any `someday://`
                // link. AppState parses it and stashes a PendingImport;
                // MapHomeView reads that value on appear / change.
                appState.handle(externalURL: url)
            }
            .environment(preferences)
        }
    }

    /// Cold-launch brand splash. Pure white background with the hot-air
    /// balloon mark centered — same asset used in the import summary's
    /// bounce animation, so the brand language is consistent end-to-end.
    /// The slogan sits below the mark so the very first moment of the
    /// app already reads as a complete brand expression.
    private var splashOverlay: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image("balloon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                Text("Save for Someday")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(SomedayColors.greenDark)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
