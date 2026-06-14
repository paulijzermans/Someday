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
    /// Drives the splash balloon's slow wobble — a gentle rocking sway
    /// (a few degrees each way, autoreversing forever) so the mark feels
    /// like it's drifting on a breeze rather than sitting still. Flipped
    /// true in the overlay's `.onAppear`.
    @State private var balloonWobble = false

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
                        // First-run users land here too — onboarding runs
                        // inside the chat panel (an on-ramp card atop the
                        // transcript) until `appState.isOnboarding` flips
                        // false.
                        MapHomeView(appState: appState)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: appState.currentScreen)

                // Brand splash: Anthropic off-white + centered wordmark.
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
                // ~2.5s brand beat. Long enough that the balloon's slow
                // wobble reads as a continuous sway (a couple of gentle
                // swings) rather than a single half-tilt before the screen
                // fades. Then a calm fade-out.
                Task {
                    try? await Task.sleep(for: .milliseconds(2500))
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

    /// Cold-launch brand splash. The warm Anthropic off-white (`#F0EEE6`)
    /// fills the whole screen, with the pixel-balloon mark crowning the
    /// upright "Someday" wordmark, centered in the geometric middle —
    /// nothing else. A single, calm brand beat (no italic flourish): the
    /// same mark + wordmark pairing the auth hero wears, so the very first
    /// moment matches the welcome screen exactly.
    private var splashOverlay: some View {
        ZStack {
            SomedayColors.anthropicWhite
                .ignoresSafeArea()
                // Flip the wobble flag the moment the splash mounts. The
                // repeating animation itself is attached directly to the
                // rotated Image below via `.animation(_:value:)` — that's the
                // reliable way to drive a forever-loop. (A `withAnimation`
                // .repeatForever kicked off here can get cut short by SwiftUI
                // instead of looping cleanly, which made the balloon visibly
                // stop swaying partway through the 2.5s hold.)
                .onAppear { balloonWobble = true }
            VStack(spacing: 10) {
                // Pixel-art hot-air-balloon brand mark above the wordmark,
                // mirroring the auth hero. Same transparent cut-out asset.
                Image("airballoonPixelated")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48)
                    // Gentle rocking sway — ±3.5° around the top so the
                    // balloon pivots from its crown like it's hanging on a
                    // breeze. The animation kicks off in the overlay's
                    // `.onAppear`.
                    .rotationEffect(.degrees(balloonWobble ? 3.5 : -3.5), anchor: .top)
                    // Slow, looping sway — eases between the two tilt extremes
                    // forever so the balloon rocks gently the whole time the
                    // splash is up. Attached here (rather than via a
                    // `withAnimation` in `.onAppear`) so the loop runs cleanly
                    // for the full hold instead of stopping partway.
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: balloonWobble)
                    .allowsHitTesting(false)
                // Upright wordmark — the whole word in the brand (non-
                // italic) face. No lean, no animation.
                Text("Someday")
                    .font(SomedayFonts.brand(size: 30))
                    .tracking(0.5)
                    .foregroundColor(SomedayColors.anthropicInk)
            }
        }
    }
}
