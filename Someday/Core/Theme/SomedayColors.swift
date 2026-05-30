import SwiftUI
import CoreText

enum SomedayFonts {
    /// Vintage display font for the brand wordmark "Someday".
    static func brand(size: CGFloat) -> Font {
        .custom("GondensDEMO-Regular", size: size)
    }

    /// Register custom font files bundled with the app. Call from `App.init`.
    static func registerAll() {
        let fontFiles = ["Gondens-DEMO"]
        for name in fontFiles {
            guard let url = Bundle.main.url(forResource: name, withExtension: "otf") else {
                print("Someday: font \(name).otf not found in bundle")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let err = error?.takeRetainedValue()
                print("Someday: failed to register \(name): \(String(describing: err))")
            }
        }
    }
}

enum SomedayColors {
    // Brand palette — the four vivid colors
    static let blue   = Color(red: 0.259, green: 0.447, blue: 1.0)     // #4272FF — primary
    static let cyan   = Color(red: 0.259, green: 0.918, blue: 1.0)     // #42EAFF — light accent
    static let amber  = Color(red: 1.0,   green: 0.702, blue: 0.263)   // #FFB343 — warm accent
    static let coralBright = Color(red: 1.0, green: 0.494, blue: 0.259) // #FF7E42 — highlight

    // Darker / utility variants
    static let blueDark = Color(red: 0.16, green: 0.28, blue: 0.78)

    // Backward-compatible aliases — keep old names mapping to new colors
    // so existing call sites keep compiling while we converge naming.
    static let butter     = cyan
    static let green      = blue
    static let greenDark  = blueDark
    static let butterDeep = amber

    // Semantic aliases used across the app
    static let primary       = blue
    static let primaryDark   = blueDark
    static let primaryLight  = cyan
    static let charcoal      = Color(red: 0.08, green: 0.12, blue: 0.22)  // deep navy text
    static let coral         = coralBright
    static let grayMedium    = Color(red: 0.44, green: 0.44, blue: 0.50)
    static let grayLight     = Color(red: 0.96, green: 0.97, blue: 1.0)   // cool light surface

    // Friend palette — uses the warm accents for visible identity on the map
    static let friendA = amber
    static let friendB = cyan
    static let friendC = coralBright

    static func friendColor(for index: Int) -> Color {
        let colors: [Color] = [friendA, friendB, friendC, .purple, .mint, .pink]
        return colors[index % colors.count]
    }
}
