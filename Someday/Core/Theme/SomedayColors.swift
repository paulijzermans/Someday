import SwiftUI
import CoreText

enum SomedayFonts {
    /// Display font for the brand wordmark "Someday" — Google Sans Bold (SIL
    /// Open Font License, safe for distribution). We originally tried Flow
    /// Circular, but that's an *abstract* concept face: it replaces every
    /// glyph with a flowing shape, so any word renders as a solid rounded
    /// bar — unreadable. Google Sans is a clean geometric sans that actually
    /// shows the letters (and the wordmark's synthetic italic on "some").
    /// The PostScript name is `GoogleSans-Bold`, which is what `Font.custom`
    /// resolves against once the file is registered.
    static func brand(size: CGFloat) -> Font {
        .custom("GoogleSans-Bold", size: size)
    }

    /// The italic companion to `brand` — Google Sans **Bold Italic**. We use
    /// the *real* italic face (not SwiftUI's synthetic `.italic()`) because
    /// `Font.custom` won't synthesize a slant for a family that has no italic
    /// registered, so the "some" run was rendering upright. PostScript name
    /// `GoogleSans-BoldItalic`.
    static func brandItalic(size: CGFloat) -> Font {
        .custom("GoogleSans-BoldItalic", size: size)
    }

    /// The "Someday" wordmark rendered as a single, unbroken word but with
    /// the "some" half italicised and the "day" half upright. Built by
    /// concatenating two `Text` runs (no space between them) so it still
    /// reads as one word while the slant draws the eye across the break. Each
    /// run carries its own face (italic vs. upright), so the caller passes a
    /// `size` here instead of applying `.font(...)` afterwards — colour and
    /// tracking still apply to the whole concatenated result at the call
    /// site, letting each placement (splash / auth hero / profile footer)
    /// size and tint it independently.
    static func wordmark(size: CGFloat) -> Text {
        Text("some").font(brandItalic(size: size))
            + Text("day").font(brand(size: size))
    }

    /// Register custom font files bundled with the app. Call from `App.init`.
    /// Each entry pairs the resource filename with its extension so we can
    /// mix `.otf` and `.ttf` faces (Gondens ships as OTF, Flow Circular as
    /// TTF).
    static func registerAll() {
        let fontFiles: [(name: String, ext: String)] = [
            ("Gondens-DEMO", "otf"),
            ("GoogleSans-Bold", "ttf"),
            ("GoogleSans-BoldItalic", "ttf"),
        ]
        for font in fontFiles {
            guard let url = Bundle.main.url(forResource: font.name, withExtension: font.ext) else {
                print("Someday: font \(font.name).\(font.ext) not found in bundle")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let err = error?.takeRetainedValue()
                print("Someday: failed to register \(font.name): \(String(describing: err))")
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
    /// Secondary text across the app (captions, metadata, meta rows).
    /// Repointed to Anthropic's warm gray `#666663` so all lower-emphasis
    /// copy reads in the earthy Anthropic neutral instead of the old cool
    /// gray. ~174 call sites flow through this one token, so the swap is
    /// app-wide. See `anthropicGray`.
    static let grayMedium    = anthropicGray
    static let grayLight     = Color(red: 0.96, green: 0.97, blue: 1.0)   // cool light surface

    /// Anthropic's warm paper white — the soft cream Anthropic uses for
    /// backgrounds instead of pure white. A neutral, slightly warm surface
    /// tone that reads as "off-white" against the app's cooler `grayLight`.
    static let anthropicWhite = Color(red: 0.941, green: 0.933, blue: 0.902) // #F0EEE6

    /// Anthropic's warm tan — the lighter of the two earthy neutrals. Use
    /// for hairline borders and the lowest-emphasis secondary text (hints,
    /// disabled labels) on the warm `anthropicWhite` surface, where the
    /// cool `grayMedium` would read out of place.
    static let anthropicTan  = Color(red: 0.690, green: 0.682, blue: 0.647) // #B0AEA5

    /// Anthropic's warm gray — the darker earthy neutral. Use for standard
    /// secondary text (captions, metadata) in the Anthropic theme; pairs
    /// with `anthropicTan` borders the way `grayMedium` pairs with the
    /// cooler palette.
    static let anthropicGray = Color(red: 0.400, green: 0.400, blue: 0.388) // #666663

    /// Anthropic's near-black ink — the high-emphasis text/mark color on the
    /// warm `anthropicWhite` surface. Use where pure black would read too
    /// harsh but the blue/cyan accents wash out (e.g. the cold-launch
    /// wordmark on the cream splash).
    static let anthropicInk  = Color(red: 0.098, green: 0.098, blue: 0.098) // #191919

    /// Poison-green / chartreuse — the app's signature accent. Used as
    /// the dominant CTA color (Send, Preview, Add, Import, etc.) and as
    /// the "verified / added" status indicator wherever `accentGreen` is
    /// referenced. Pairs with charcoal text — the brightness is too high
    /// to read white text comfortably.
    static let lime          = Color(red: 0.83, green: 0.94, blue: 0.38)  // ≈ #D4F061

    /// Alias kept for backward compatibility with call sites that
    /// historically used `accentGreen` for status badges and check
    /// marks. Resolves to the same poison green so the whole app stays
    /// on one accent.
    static let accentGreen   = lime

    // Friend palette — uses the warm accents for visible identity on the map
    static let friendA = amber
    static let friendB = cyan
    static let friendC = coralBright

    static func friendColor(for index: Int) -> Color {
        let colors: [Color] = [friendA, friendB, friendC, .purple, .mint, .pink]
        return colors[index % colors.count]
    }
}
