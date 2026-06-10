import SwiftUI
import UIKit

// =============================================================================
// ChatMessageRenderer — inline flow layout for chat bodies
// =============================================================================
//
// The chat body needs to mix:
//   • plain text
//   • markdown links to https URLs (open in browser)
//   • `someday://place/<id>`   — tappable place link
//   • `someday://suggest?...`  — tappable AI suggestion (drops a pin)
//   • `someday://list/<name>`  — colored *pill* matching the list's identity
//
// A single SwiftUI `Text(AttributedString)` can colour and link text but
// can't embed real rounded pills (with padding, colored background, a
// small swatch inside). And we want pills to flow inline with the
// surrounding text and wrap naturally.
//
// Solution: parse the message into `InlineToken`s (one per word, plus
// one per link / pill), then position them with a custom `Layout`
// (`InlineFlowLayout`) that lays children left-to-right and wraps when
// the next child would overflow. Result: pills sit inline with words
// and break to the next line cleanly.
//
// Trade-off: markdown formatting *within* text segments (bold/italic)
// is intentionally not supported here. The system prompt doesn't ask
// the model to emit those, so we skip the complexity of word-level
// markdown attribution. Markdown links ARE parsed (that's the whole
// point), and bare URLs are auto-linked before parsing.

// MARK: - Token model

enum InlineToken: Identifiable, Equatable {
    case word(String)
    case listPill(name: String)
    /// `listHint` (optional) is the URL-encoded name of one of the user's
    /// lists this place belongs to. We use it to color the inline pin so
    /// it matches the place's identity on the map.
    case placeLink(name: String, idOrPrefix: String, listHint: String?)
    case suggestionLink(name: String, category: String, lat: Double, lon: Double)
    case webLink(name: String, url: URL)
    /// `someday://show?...` — a map-navigation pill (a country, city,
    /// neighbourhood, landmark). Tap flies the camera there; no pin.
    case showLink(name: String, lat: Double, lon: Double, span: Double?)

    /// Identity per occurrence so SwiftUI can diff across renders.
    var id: String {
        switch self {
        case .word(let w):                              return "w:\(w):\(UUID().uuidString.prefix(4))"
        case .listPill(let n):                          return "lp:\(n)"
        case .placeLink(let n, let id, _):              return "pl:\(id):\(n)"
        case .suggestionLink(let n, _, let la, let lo): return "sl:\(la),\(lo):\(n)"
        case .webLink(_, let url):                      return "wl:\(url.absoluteString)"
        case .showLink(let n, let la, let lo, _):       return "sh:\(la),\(lo):\(n)"
        }
    }
}

// MARK: - Parser

enum ChatMessageParser {
    /// Splits raw model output into `InlineToken`s.
    static func parse(_ raw: String) -> [InlineToken] {
        // 0. Strip Anthropic web_search citation markup.
        //    The server-side web_search tool wraps quoted source text
        //    in `<cite ...>...</cite>` (and occasionally bare
        //    `<citation .../>`) tags. These are meant to be rendered
        //    as inline citation chips by clients that understand them;
        //    our flow parser doesn't, so without stripping them the
        //    user sees raw `<cite index="0">Café Veneur</cite>` markup
        //    where a place pin or plain word should be.
        let stripped = stripCitationTags(raw)

        // 1. Auto-link bare URLs not already inside [..](..) markdown.
        let linked = autolinkBareURLs(stripped)

        // 2. Scan for markdown links `[label](url)` and split the string
        //    into alternating literal / link chunks.
        var tokens: [InlineToken] = []
        let pattern = #"\[([^\]]+)\]\(([^)\s]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            // Parser broken → fall back to word-splitting the raw string.
            return wordSplit(boldToUppercase(linked))
        }
        let ns = linked as NSString
        var cursor = 0
        for match in regex.matches(in: linked, range: NSRange(location: 0, length: ns.length)) {
            // Emit any literal text before this match as words. Bold
            // markdown (`**X**`) is translated to UPPERCASE here so
            // the AI's emphasis reads as a CAPS pattern in chat —
            // visually strong without needing a weighted Text run.
            if match.range.location > cursor {
                let lit = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                tokens.append(contentsOf: wordSplit(boldToUppercase(lit)))
            }
            let label = ns.substring(with: match.range(at: 1))
            let urlString = ns.substring(with: match.range(at: 2))
            if let token = classifyLink(label: label, urlString: urlString) {
                tokens.append(token)
            } else {
                // Couldn't parse the URL — degrade gracefully to just the label words.
                tokens.append(contentsOf: wordSplit(boldToUppercase(label)))
            }
            cursor = match.range.location + match.range.length
        }
        // Trailing literal.
        if cursor < ns.length {
            let lit = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            tokens.append(contentsOf: wordSplit(boldToUppercase(lit)))
        }
        return tokens
    }

    /// Replace every `**X**` span in the input with `X.uppercased()`,
    /// stripping the asterisks. Treats `**` markers as opaque so any
    /// inner characters survive (punctuation, accents, emoji). Single
    /// `*` (italic) is left intact — the system prompt only asks for
    /// bold, and we don't want to mangle stray asterisks in URLs or
    /// punctuation.
    private static func boldToUppercase(_ s: String) -> String {
        guard s.contains("**") else { return s }
        // Non-greedy match between two `**` pairs; `[^*]` content keeps
        // the matcher from gobbling across multiple bold runs on one
        // line. `.dotMatchesLineSeparators` is intentionally off — a
        // bold run shouldn't bridge a paragraph break.
        let pattern = #"\*\*([^*]+?)\*\*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        var out = s
        let ns = out as NSString
        let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
        // Walk matches in reverse so each replacement doesn't shift the
        // ranges of the matches we haven't processed yet.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let fullRange = Range(match.range, in: out) else { continue }
            let inner = (out as NSString).substring(with: match.range(at: 1))
            out.replaceSubrange(fullRange, with: inner.uppercased())
        }
        return out
    }

    /// Remove Anthropic web_search citation markup from a raw message.
    /// Keeps the INNER text of `<cite ...>…</cite>` pairs (it's the
    /// quoted source snippet, usually a venue name we want to keep
    /// visible) and drops empty `<citation />`-style self-closing tags.
    /// Also tolerates partial / unclosed tags that can arrive mid-
    /// stream — anything that looks like a `<cite…>` or `</cite>` tag
    /// is collapsed to its inner text or removed.
    private static func stripCitationTags(_ s: String) -> String {
        guard s.contains("<cite") || s.contains("</cite") || s.contains("<citation") else { return s }
        var out = s

        // 1. Paired `<cite …>INNER</cite>` → `INNER`. Non-greedy on the
        //    inner so adjacent citations don't collapse into each other.
        if let regex = try? NSRegularExpression(
            pattern: #"<cite\b[^>]*>([\s\S]*?)</cite>"#,
            options: [.caseInsensitive]
        ) {
            let ns = out as NSString
            let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let full = Range(match.range, in: out) else { continue }
                let inner = (out as NSString).substring(with: match.range(at: 1))
                out.replaceSubrange(full, with: inner)
            }
        }

        // 2. Drop any remaining stray `<cite …>`, `</cite>`, or
        //    `<citation … />` tags — these are unpaired fragments
        //    (mid-stream partials, malformed citations).
        if let regex = try? NSRegularExpression(
            pattern: #"</?(?:cite|citation)\b[^>]*/?>"#,
            options: [.caseInsensitive]
        ) {
            let ns = out as NSString
            let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard let r = Range(match.range, in: out) else { continue }
                out.removeSubrange(r)
            }
        }

        return out
    }

    /// Markdown-wrap any bare http(s) URL not already inside `[…](…)`.
    private static func autolinkBareURLs(_ raw: String) -> String {
        var out = raw
        let pattern = #"(?<![\(\[])https?://[^\s)\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return out }
        let range = NSRange(out.startIndex..., in: out)
        // Walk matches in reverse so each replacement doesn't shift the
        // ranges we haven't applied yet.
        for match in regex.matches(in: out, range: range).reversed() {
            guard let r = Range(match.range, in: out) else { continue }
            let url = String(out[r])
            out.replaceSubrange(r, with: "[\(url)](\(url))")
        }
        return out
    }

    /// Split a literal text run into one `.word` per whitespace-bounded
    /// chunk. Preserves line breaks as their own `.word("\n")` so the
    /// flow layout can honour them.
    private static func wordSplit(_ s: String) -> [InlineToken] {
        var out: [InlineToken] = []
        // Split into runs separated by whitespace; keep newlines as
        // explicit tokens so paragraph breaks survive.
        let lines = s.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            for w in words { out.append(.word(w)) }
            if i < lines.count - 1 { out.append(.word("\n")) }
        }
        return out
    }

    /// Classify a `[label](url)` link into one of our token cases.
    private static func classifyLink(label: String, urlString: String) -> InlineToken? {
        if urlString.hasPrefix("someday://list/") {
            let raw = String(urlString.dropFirst("someday://list/".count))
            let decoded = raw.removingPercentEncoding ?? raw
            return .listPill(name: decoded.isEmpty ? label : decoded)
        }
        if urlString.hasPrefix("someday://place/") {
            // The model may emit `someday://place/<id>?list=<encoded list name>`
            // — the optional `list` query tells us which list this place
            // belongs to so we can color the inline pin to match.
            guard let comps = URLComponents(string: urlString) else { return nil }
            let rawPath = comps.path
            let id = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
            let listHint = (comps.queryItems ?? [])
                .first(where: { $0.name == "list" })?
                .value?
                .removingPercentEncoding
            return .placeLink(name: label, idOrPrefix: id, listHint: listHint)
        }
        if urlString.hasPrefix("someday://suggest") {
            // Parse query string: lat, lon, name, category
            guard let comps = URLComponents(string: urlString) else { return nil }
            let items = comps.queryItems ?? []
            func q(_ k: String) -> String? { items.first(where: { $0.name == k })?.value }
            guard let latStr = q("lat"), let lat = Double(latStr),
                  let lonStr = q("lon"), let lon = Double(lonStr) else { return nil }
            let name = q("name")?.removingPercentEncoding ?? label
            let cat = q("category")?.removingPercentEncoding ?? ""
            return .suggestionLink(name: name, category: cat, lat: lat, lon: lon)
        }
        if urlString.hasPrefix("someday://show") {
            // `someday://show?lat=…&lon=…&name=…&span=…` — camera-only
            // navigation to an arbitrary place (country/city/region).
            guard let comps = URLComponents(string: urlString) else { return nil }
            let items = comps.queryItems ?? []
            func q(_ k: String) -> String? { items.first(where: { $0.name == k })?.value }
            guard let latStr = q("lat"), let lat = Double(latStr),
                  let lonStr = q("lon"), let lon = Double(lonStr) else { return nil }
            let name = q("name")?.removingPercentEncoding ?? label
            let span = q("span").flatMap(Double.init)
            return .showLink(name: name, lat: lat, lon: lon, span: span)
        }
        if let url = URL(string: urlString),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .webLink(name: label, url: url)
        }
        return nil
    }
}

// MARK: - Inline flow layout

/// Left-to-right wrapping container. Each subview is treated as a
/// single block and placed on the current line if it fits, otherwise
/// dropped to a new line. Word-token children supply their own size,
/// so wrapping happens at word boundaries naturally.
struct InlineFlowLayout: Layout {
    var hSpacing: CGFloat = 4
    var vSpacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widestLine: CGFloat = 0

        for sub in subviews {
            // Newline marker → break to next line.
            if sub[NewlineMarker.self] {
                widestLine = max(widestLine, x)
                x = 0
                y += lineHeight + vSpacing
                lineHeight = 0
                continue
            }
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                widestLine = max(widestLine, x)
                x = 0
                y += lineHeight + vSpacing
                lineHeight = 0
            }
            x += size.width + hSpacing
            lineHeight = max(lineHeight, size.height)
        }
        widestLine = max(widestLine, x - hSpacing)
        let h = y + lineHeight
        return CGSize(width: min(maxWidth, max(widestLine, 0)), height: h)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for sub in subviews {
            if sub[NewlineMarker.self] {
                x = bounds.minX
                y += lineHeight + vSpacing
                lineHeight = 0
                continue
            }
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + vSpacing
                lineHeight = 0
            }
            sub.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + hSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// LayoutValueKey marking a subview as a "newline" — the layout
/// breaks to the next line when it encounters one.
private struct NewlineMarker: LayoutValueKey {
    static let defaultValue: Bool = false
}

extension View {
    fileprivate func chatNewline(_ on: Bool = true) -> some View {
        layoutValue(key: NewlineMarker.self, value: on)
    }
}

// MARK: - Pill / link views

/// Colored pill matching the list's deterministic identity from
/// `ListVisualStyle.style(for: name)`. Tap opens the list (via
/// `OpenURLAction` on the surrounding chat panel).
struct ListPillView: View {
    let name: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        let style = ListVisualStyle.style(for: name)
        Button {
            // The map view installs an OpenURLAction that intercepts
            // someday://list/<name>. Encode the name in case it has
            // spaces or punctuation.
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            if let url = URL(string: "someday://list/\(encoded)") {
                openURL(url)
            }
        } label: {
            HStack(spacing: 5) {
                // Small rounded square swatch — the "map color" cue.
                RoundedRectangle(cornerRadius: 3)
                    .fill(style.color)
                    .frame(width: 10, height: 10)
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(style.color)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Camera-only "take me there" pill. Tapping flies the map to an
/// arbitrary location (country / city / region) via
/// `someday://show?lat=…&lon=…&name=…&span=…` — no pin dropped, no
/// card opened. Styled with a globe glyph to read as navigation rather
/// than a saved place.
struct ShowPillView: View {
    let name: String
    let lat: Double
    let lon: Double
    let span: Double?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            var comps = URLComponents()
            comps.scheme = "someday"
            comps.host = "show"
            var items: [URLQueryItem] = [
                URLQueryItem(name: "lat", value: String(lat)),
                URLQueryItem(name: "lon", value: String(lon)),
                URLQueryItem(name: "name", value: name)
            ]
            if let span { items.append(URLQueryItem(name: "span", value: String(span))) }
            comps.queryItems = items
            if let url = comps.url { openURL(url) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.14))
            )
            .overlay(
                Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Inline mini map-pin
//
// When the model mentions a place — either one the user already has
// saved (`someday://place/<id>?list=<name>`) or a fresh proposal
// (`someday://suggest?...`) — the chat embeds a miniature of the same
// pin the map uses. Saved places get the LIST's color (matching the
// pin on the map); AI proposals get the brand lime + sparkles glyph
// (matching `SuggestionPinAnnotationView`). The whole pill is tappable;
// `MapHomeView.handleChatLinkTap` routes the URL to either
// `focusOnPlaceLink` or `focusOnAISuggestion`.

/// Teardrop shape that mirrors the on-map `PlacePinAnnotationView.pinPath`
/// exactly — circle head at the top of `rect`, tapered to a tip at
/// `rect.maxY`. Same `acos(r / L)` half-angle calculation so the curve
/// where the head meets the taper is identical to the rendered pin on
/// the map. Use this with a head:total-height ratio of 7:18 (= the
/// bulbRadius:bulbRadius+tipDrop the map pin uses) to get a pin shape
/// indistinguishable from the map one.
struct MapPinShape: Shape {
    /// Uniform-thickness inset from the outer teardrop. 0 = the
    /// natural outer pin filling `rect`. Positive values shrink the
    /// head radius and the tipDrop by the SAME absolute amount while
    /// keeping the head centre fixed — so the inner teardrop sits
    /// parallel to the outer one with uniform border thickness all
    /// around. Matches `PlacePinAnnotationView.pinPath`'s two-pass
    /// fill (outer white, inner colour = pinPath(r - bw, tipDrop - bw)).
    ///
    /// Using `.padding(borderWidth)` on the inner shape doesn't give a
    /// uniform border because shrinking the bounding box uniformly
    /// re-derives r and tipDrop from the new width and height — and a
    /// teardrop's aspect ratio doesn't preserve under scaling, so the
    /// tip-side border ends up thicker than the head-side. The
    /// explicit `inset` parameter avoids that by shrinking the two
    /// geometric parameters independently, the way the map renderer does.
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        // Outer head radius + tipDrop derived from rect. The inner
        // shape gets the same head centre but smaller r and L.
        let outerR = rect.width / 2
        let outerL = rect.height - outerR
        let r = max(0.01, outerR - inset)
        let L = max(0.01, outerL - inset)
        // Head centre is anchored to the OUTER head's natural centre,
        // not the inset rect — so concentric heads, uniform border.
        let center = CGPoint(x: rect.midX, y: rect.minY + outerR)
        let tip = CGPoint(x: center.x, y: center.y + L)
        let beta = acos(max(-1, min(1, r / L)))
        let rightAngle = CGFloat.pi / 2 - beta
        let leftAngle = CGFloat.pi / 2 + beta
        let rightTangent = CGPoint(
            x: center.x + r * cos(rightAngle),
            y: center.y + r * sin(rightAngle)
        )
        var p = Path()
        p.move(to: tip)
        p.addLine(to: rightTangent)
        // `clockwise: false` traces the shorter counter-clockwise arc
        // over the top of the head — same convention as the UIKit
        // version on the map (both follow CGPath / y-down semantics).
        p.addArc(
            center: center,
            radius: r,
            startAngle: .radians(rightAngle),
            endAngle: .radians(leftAngle),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

/// Inline pin used in chat. Renders the same teardrop the map uses
/// (`MapPinShape`) at the same head:tipDrop ratio (7:11) as
/// `PlacePinAnnotationView`, with a proportionally-scaled white border
/// — so the chat pin and the map pin are visibly the same element,
/// just sized for inline text rather than the map canvas.
///
/// Parameterised so a single view backs both saved-place pills (colored
/// from the list, no glyph) and AI suggestion pills (lime + sparkles
/// glyph + soft lime halo behind the head).
private struct MiniPin: View {
    let color: Color
    /// Optional SF Symbol drawn centred on the pin's HEAD (not the
    /// geometric centre of the whole teardrop, which would sit too low).
    let glyph: String?
    /// Width of the head (= 2 × bulbRadius). The full height follows
    /// from the 7:11 head-radius-to-tipDrop ratio used by the map pin.
    let headSize: CGFloat

    init(color: Color, glyph: String? = nil, headSize: CGFloat = 18) {
        self.color = color
        self.glyph = glyph
        self.headSize = headSize
    }

    /// Total pin height = head diameter (2r) + tipDrop − r. The map pin
    /// uses bulbRadius = 7, tipDrop = 11 → canvas = 7 + 11 = 18 high
    /// for 14 wide. So height = width × 18/14 = width × 9/7.
    private var totalHeight: CGFloat { headSize * 9 / 7 }
    /// Border width scaled from the map pin's 1.5pt on 14pt width.
    private var borderWidth: CGFloat { headSize * 1.5 / 14 }
    /// Glyph point size — 45% of the head diameter reads as a bold
    /// glyph without crowding the white border.
    private var glyphSize: CGFloat { headSize * 0.45 }
    /// The head's geometric centre relative to the pin's frame. We
    /// position the glyph at this Y so it sits on the head, not on the
    /// taper. headRadius from top = headSize / 2.
    private var headCenterY: CGFloat { headSize / 2 }

    var body: some View {
        // Render via UIKit (UIBezierPath + UIGraphicsImageRenderer) to
        // get an image pixel-identical to the on-map pin renderer.
        // Going through SwiftUI Path had subtle arc-direction issues
        // depending on the OS rev; bouncing through UIImage sidesteps
        // them entirely and guarantees the chat pin is the same shape
        // the map pin draws every time.
        Image(uiImage: PinImageRenderer.render(
            color: UIColor(color),
            glyph: glyph,
            headSize: headSize,
            totalHeight: totalHeight,
            borderWidth: borderWidth,
            glyphSize: glyphSize
        ))
        .frame(width: headSize, height: totalHeight)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
    }
}

/// Renders the chat-side mini pin using the exact same UIKit drawing
/// primitives the on-map `PlacePinAnnotationView` / `SuggestionPinAnnotationView`
/// use. Output is a `UIImage` SwiftUI consumes via `Image(uiImage:)`.
///
/// Why this instead of a pure-SwiftUI `Shape`: SwiftUI Path's `addArc`
/// `clockwise` semantics aren't 100% stable across OS revs / SDK
/// versions, which produced the wrong shape in chat at certain device
/// builds. UIBezierPath's semantics are well-defined (clockwise: false
/// = CCW visually on screen), and the on-map renderer already proves
/// the path is right. We render once per (color, glyph, size) tuple —
/// the cache below keeps repeated MiniPin renders cheap.
private enum PinImageRenderer {
    /// Cache key — same (color, glyph, head size) always produces the
    /// same image, so we memoize.
    private struct Key: Hashable {
        let r: Int; let g: Int; let b: Int; let a: Int
        let glyph: String
        let head: Int
    }
    /// Small per-process cache so the same pin (same colour + same
    /// glyph + same size) doesn't re-render on every chat re-layout.
    /// Bounded at a reasonable size; if a user has 100 distinct list
    /// colours this'll still fit in memory.
    private static var cache: [Key: UIImage] = [:]

    static func render(
        color: UIColor,
        glyph: String?,
        headSize: CGFloat,
        totalHeight: CGFloat,
        borderWidth: CGFloat,
        glyphSize: CGFloat
    ) -> UIImage {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let key = Key(
            r: Int(round(r * 255)),
            g: Int(round(g * 255)),
            b: Int(round(b * 255)),
            a: Int(round(a * 255)),
            glyph: glyph ?? "",
            head: Int(round(headSize))
        )
        if let cached = cache[key] { return cached }

        let bulbRadius = headSize / 2
        let canvasW = headSize
        let canvasH = totalHeight
        // Outer head centre — same as on-map renderer. The tip sits at
        // the bottom of the canvas; the head sits at the top.
        let centerOuter = CGPoint(x: bulbRadius, y: bulbRadius)
        let tipOuter = CGPoint(x: bulbRadius, y: canvasH)

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: canvasW, height: canvasH)
        )
        let image = renderer.image { _ in
            // 1. White outer outline (the border).
            UIColor.white.setFill()
            pinPath(center: centerOuter, radius: bulbRadius, tip: tipOuter).fill()

            // 2. Coloured body, inset by borderWidth on both head r AND
            //    tipDrop — so the border thickness is uniform all
            //    around. Same trick the map renderer uses.
            let centerInner = centerOuter   // concentric head
            let innerR = max(0.5, bulbRadius - borderWidth)
            let innerTip = CGPoint(x: tipOuter.x, y: tipOuter.y - borderWidth)
            color.setFill()
            pinPath(center: centerInner, radius: innerR, tip: innerTip).fill()

            // 3. Optional SF Symbol glyph centred on the head.
            if let glyph,
               let icon = UIImage(
                systemName: glyph,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: glyphSize, weight: .bold)
               )?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                let drawSize = icon.size
                icon.draw(in: CGRect(
                    x: centerOuter.x - drawSize.width / 2,
                    y: centerOuter.y - drawSize.height / 2,
                    width: drawSize.width,
                    height: drawSize.height
                ))
            }
        }

        // Render at scale matching the screen so the pin stays crisp.
        let scaled = image.withRenderingMode(.alwaysOriginal)
        cache[key] = scaled
        return scaled
    }

    /// Teardrop pin path — copied verbatim from `SuggestionPinAnnotationView.pinPath`
    /// so the chat pin and the map pin share one source of truth for
    /// the shape. Move to tip → line up to the right tangent → arc
    /// over the top of the head → close.
    private static func pinPath(center: CGPoint, radius r: CGFloat, tip: CGPoint) -> UIBezierPath {
        let L = tip.y - center.y
        let beta = acos(max(-1, min(1, r / L)))
        let rightAngle = CGFloat.pi / 2 - beta
        let leftAngle = CGFloat.pi / 2 + beta
        let rightTangent = CGPoint(
            x: center.x + r * cos(rightAngle),
            y: center.y + r * sin(rightAngle)
        )
        let path = UIBezierPath()
        path.move(to: tip)
        path.addLine(to: rightTangent)
        path.addArc(
            withCenter: center,
            radius: r,
            startAngle: rightAngle,
            endAngle: leftAngle,
            clockwise: false
        )
        path.close()
        return path
    }
}

/// Inline pill containing a `MiniPin` + the venue name. Tapping the
/// whole pill opens `someday://suggest?...`, which `MapHomeView`
/// intercepts to recenter the map and drop a real lime pin at the
/// coordinate. The role-equivalent for AI-proposed venues.
struct SuggestionPinPillView: View {
    let name: String
    let category: String
    let lat: Double
    let lon: Double
    @Environment(\.openURL) private var openURL

    var body: some View {
        let lime = SomedayColors.lime
        Button {
            let encName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            let encCat = category.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? category
            if let url = URL(string: "someday://suggest?lat=\(lat)&lon=\(lon)&name=\(encName)&category=\(encCat)") {
                openURL(url)
            }
        } label: {
            HStack(spacing: 4) {
                // Inline pills use the same `mappin.circle.fill` SF
                // Symbol the chat's intermediary step rows use —
                // visually smaller than the teardrop `MiniPin`, so
                // pin references no longer break chat line height
                // / disrupt the flow. The pill colour still carries
                // the "this is a suggestion" lime identity.
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(lime)
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(lime)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Inline pill for one of the user's SAVED places. The pin head is
/// colored from the place's list (when the model passes `?list=<name>`)
/// so the badge matches the on-map identity. Tap → `someday://place/<id>`
/// → `MapHomeView` recenters on the pin and opens its card.
struct SavedPlacePinPillView: View {
    let name: String
    let idOrPrefix: String
    /// URL-decoded name of one of the user's lists this place belongs to,
    /// passed by the model in the `?list=` query param. Drives the pin
    /// color so the inline badge matches the place's pin on the map.
    let listHint: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        // Fall back to Someday primary if the model didn't include a
        // list hint — still reads as "a saved pin", just generic.
        let color: Color = {
            if let l = listHint, !l.isEmpty {
                return ListVisualStyle.style(for: l).color
            }
            return SomedayColors.primary
        }()

        Button {
            let encId = idOrPrefix.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? idOrPrefix
            if let url = URL(string: "someday://place/\(encId)") {
                openURL(url)
            }
        } label: {
            HStack(spacing: 4) {
                // Match the slimmer `mappin.circle.fill` glyph the
                // suggestion pill uses — uniform look across both
                // pill flavours, and keeps chat line height down.
                // The list-tinted colour still carries the
                // identity that mattered about the teardrop pin.
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(color)
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(color)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - In-chat availability card
//
// Surface for the "Availability" CTA on the place card. Tapping the
// CTA now dismisses the card and inserts an assistant chat bubble whose
// `attachedPlaceID` points at the place. ChatBubbleView spots that
// and renders this view instead of (or alongside) the plain text body.
//
// Visual: the same SavedPlacePinPillView used everywhere else in chat
// at the top — so the user sees the place identity in chat-native
// vocabulary — followed by a tonight pill (when checked), an AI
// summary, and one tappable row per booking platform. Mirrors the
// inline panel that previously lived inside the place card.

/// Renders the in-chat availability card. Driven entirely by the data
/// passed in by the parent (typically `ChatBubbleView`, which looks
/// state up from `MapViewModel`). No service calls happen here — the
/// `onCheckTonight` closure lets the parent kick off the tonight check
/// when the card first mounts in a `.ready` state.
struct ChatAvailabilityCardView: View {
    let placeName: String
    let placeID: String
    let listHint: String?
    let state: AvailabilityState
    let tonightCheck: AvailabilityCheck?
    let isCheckingTonight: Bool
    /// Fired once when the card first appears with a `.ready` state so
    /// the tonight check kicks off automatically (matches the in-card
    /// behaviour where the panel auto-fires it on expand).
    let onAppearWithReady: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The pin pill the user already recognises from the rest
            // of chat. Tap routes back to the map via the standard
            // `someday://place/<id>` interceptor.
            SavedPlacePinPillView(
                name: placeName,
                idOrPrefix: placeID,
                listHint: listHint
            )

            // State-dependent body. Loading and idle both render a
            // single status row; .ready renders the full panel.
            switch state {
            case .idle:
                statusRow(icon: "calendar",
                          text: "Tap the pin to check availability",
                          tint: SomedayColors.grayMedium)

            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking availability…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SomedayColors.grayMedium)
                }
                .padding(.vertical, 4)

            case .ready(let result):
                resultBody(result)
            }
        }
        .padding(12)
        .background(SomedayColors.grayLight)
        .cornerRadius(14)
        .onAppear {
            if case .ready = state {
                onAppearWithReady()
            }
        }
        .onChange(of: state) { _, newValue in
            // Same auto-fire on state transition — covers the common
            // case where the bubble is inserted in `.loading` and
            // flips to `.ready` while it's already on screen.
            if case .ready = newValue {
                onAppearWithReady()
            }
        }
    }

    // MARK: - Result body (tonight pill + summary + platforms)

    @ViewBuilder
    private func resultBody(_ result: AvailabilityResult) -> some View {
        // Tonight pill — pulled from parent state.
        tonightPill

        // One-line AI summary with the sparkle motif.
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(SomedayColors.primary)
            Text(result.summary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SomedayColors.grayMedium)
                .fixedSize(horizontal: false, vertical: true)
        }

        if result.platforms.isEmpty {
            Text("No online booking found. Try the venue's website.")
                .font(.system(size: 13))
                .foregroundColor(SomedayColors.grayMedium)
        } else {
            VStack(spacing: 6) {
                ForEach(result.platforms) { platform in
                    platformButton(platform)
                }
            }
        }
    }

    // MARK: - Tonight pill (compact)

    @ViewBuilder
    private var tonightPill: some View {
        if isCheckingTonight || tonightCheck == nil {
            statusRow(icon: nil,
                      progress: true,
                      text: "Checking tonight…",
                      tint: SomedayColors.grayMedium)
        } else if let check = tonightCheck {
            switch check {
            case .open(let shifts, let bookingURL, _):
                Button {
                    if let url = bookingURL {
                        Haptics.tap()
                        openURL(url)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(SomedayColors.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Open tonight")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(SomedayColors.charcoal)
                            if let shiftLabel = shifts.first?.name {
                                Text(shiftLabel)
                                    .font(.system(size: 10))
                                    .foregroundColor(SomedayColors.grayMedium)
                            }
                        }
                        Spacer()
                        if bookingURL != nil {
                            Text("Book")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(SomedayColors.green)
                                .cornerRadius(7)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(SomedayColors.green.opacity(0.08))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(SomedayColors.green.opacity(0.25), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

            case .closed:
                statusRow(icon: "xmark.circle.fill",
                          text: "No tables tonight",
                          tint: SomedayColors.grayMedium)
            case .unknown:
                statusRow(icon: "info.circle",
                          text: "Use a button below to check tonight",
                          tint: SomedayColors.grayMedium)
            case .error:
                statusRow(icon: "exclamationmark.triangle.fill",
                          text: "Couldn't check tonight",
                          tint: .orange)
            }
        }
    }

    // MARK: - Platform button (one row per booking platform)

    @ViewBuilder
    private func platformButton(_ platform: BookingPlatform) -> some View {
        if let phone = phoneNumber(in: platform) {
            Button {
                guard let url = URL(string: "tel:\(phone.dialable)") else { return }
                Haptics.tap()
                openURL(url)
            } label: {
                platformContent(platform, trailing: .phone)
            }
            .buttonStyle(.plain)
        } else if let mailto = emailURL(in: platform) {
            Button {
                Haptics.tap()
                openURL(mailto)
            } label: {
                platformContent(platform, trailing: .email)
            }
            .buttonStyle(.plain)
        } else if let url = platform.url {
            Button {
                Haptics.tap()
                openURL(url)
            } label: {
                platformContent(platform, trailing: .link)
            }
            .buttonStyle(.plain)
        } else {
            platformContent(platform, trailing: .none)
        }
    }

    private enum PlatformTrailing { case link, phone, email, none }

    @ViewBuilder
    private func platformContent(_ platform: BookingPlatform, trailing: PlatformTrailing) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(platform.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                if let note = platform.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(SomedayColors.grayMedium)
                        .lineLimit(1)
                }
            }
            Spacer()
            switch trailing {
            case .link:
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SomedayColors.primary)
            case .phone:
                Image(systemName: "phone.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(SomedayColors.green)
                    .clipShape(Circle())
            case .email:
                Image(systemName: "envelope.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(SomedayColors.primary)
                    .clipShape(Circle())
            case .none:
                EmptyView()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.systemGray5), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusRow(
        icon: String? = nil,
        progress: Bool = false,
        text: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            if progress {
                ProgressView().controlSize(.mini)
            } else if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(tint)
            }
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tint)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.systemGray5), lineWidth: 1)
        )
    }

    /// Dial-able phone extraction — mirrors the one inside PlaceCardSheet
    /// so the chat surface behaves identically. Kept local so the two
    /// surfaces can evolve independently if needed.
    private func phoneNumber(in platform: BookingPlatform) -> (display: String, dialable: String)? {
        if let url = platform.url, url.scheme?.lowercased() == "tel" {
            let raw = url.absoluteString.replacingOccurrences(of: "tel:", with: "")
            return (raw, raw)
        }
        guard let note = platform.note else { return nil }
        let lower = platform.name.lowercased()
        guard lower.contains("phone") || lower.contains("call") else { return nil }
        let pattern = #"\+?[\d][\d\s().\-]{6,}"#
        guard let range = note.range(of: pattern, options: .regularExpression) else { return nil }
        let display = String(note[range]).trimmingCharacters(in: .whitespaces)
        let dialable = display.filter { $0.isNumber || $0 == "+" }
        return (display, dialable)
    }

    /// Mailto extraction — same shape as phoneNumber above.
    private func emailURL(in platform: BookingPlatform) -> URL? {
        if let url = platform.url, url.scheme?.lowercased() == "mailto" {
            return url
        }
        let lower = platform.name.lowercased()
        guard lower.contains("email") || lower.contains("mail"),
              let note = platform.note else { return nil }
        let pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        guard let range = note.range(of: pattern, options: .regularExpression) else { return nil }
        let address = String(note[range])
        return URL(string: "mailto:\(address)?subject=Reservation%20request")
    }
}

// =============================================================================
// ChatPlacePeekCard — lightweight in-chat preview of a saved pin
// =============================================================================
//
// Rendered inside an assistant bubble whose `attachmentKind == .peek`.
// Surfaces a saved place WITHOUT leaving the chat: cover image, the
// recognisable pin pill, a category·neighbourhood subtitle, the user's
// own one-line review if they wrote one, and a "View on map" CTA that
// hands off to the full navigate-and-open-card flow. This is the
// "keep the chat open, show me the place" affordance — tapping a chat
// pin peeks here first; "View on map" is the deliberate jump out.

struct ChatPlacePeekCard: View {
    let place: Place
    /// List colour identity for the pin pill — resolved the same way the
    /// map renderer resolves it so the pill matches the on-map pin.
    let listHint: String?
    /// Fires when the user taps "View on map" — the parent performs the
    /// heavy-haptic collapse-chrome + recenter + open-card navigation.
    let onOpenMap: () -> Void

    private var subtitle: String {
        let cat = place.category.displayName
        let hood = place.neighborhood.trimmingCharacters(in: .whitespaces)
        return hood.isEmpty ? cat : "\(cat) · \(hood)"
    }

    /// List identity colour for the chip / note accent — resolved the same
    /// way the map renderer resolves it so it matches the on-map pin.
    private var listColor: Color? {
        guard let l = listHint, !l.isEmpty else { return nil }
        return ListVisualStyle.style(for: l).color
    }

    /// Cover photo. Prefer the place's own imported image; otherwise fall
    /// back to the same category-keyed stock imagery the AI-suggestion
    /// tile uses, so a peek of a photo-less pin still reads as a card
    /// rather than an empty grey banner.
    private var heroURL: URL? {
        if let url = place.imageURL { return url }
        let photoID: String
        switch place.category {
        case .food:     photoID = "photo-1414235077428-338989a2e8c0"
        case .drinks:   photoID = "photo-1551024601-bec78aea704b"
        case .coffee:   photoID = "photo-1495474472287-4d71bcdd2085"
        case .activity: photoID = "photo-1441974231531-c6227db76b6e"
        case .art:      photoID = "photo-1531058020387-3be344556be6"
        case .travel:   photoID = "photo-1488646953014-85cb44e25828"
        }
        return URL(string: "https://images.unsplash.com/\(photoID)?w=600&h=400&fit=crop&q=80")
    }

    var body: some View {
        VStack(spacing: 0) {
            // The hero wears the app-wide photo-tile edge: a thin white frame
            // + hairline between the photo and the card, matching the map pins.
            hero
                .photoTileEdge(cornerRadius: 18)
            footer
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    // MARK: Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            heroImage
                .frame(height: 158)
                .frame(maxWidth: .infinity)
                .clipped()

            // Bottom scrim so the white title stays legible over any photo.
            LinearGradient(
                colors: [.clear, .black.opacity(0.15), .black.opacity(0.72)],
                startPoint: .center, endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                Text(subtitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(height: 158)
        .overlay(alignment: .topLeading) { identityChip.padding(10) }
        .overlay(alignment: .topTrailing) { ratingBadge.padding(10) }
    }

    /// Top-left glass chip: the list it lives in (with its colour dot) when
    /// known, otherwise the category. Anchors the card to where the pin
    /// sits on the map.
    @ViewBuilder
    private var identityChip: some View {
        HStack(spacing: 5) {
            if let c = listColor, let l = listHint, !l.isEmpty {
                Circle().fill(c).frame(width: 7, height: 7)
                Text(l)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            } else {
                Image(systemName: place.category.icon)
                    .font(.system(size: 10, weight: .bold))
                Text(place.category.displayName)
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundColor(SomedayColors.charcoal)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// Top-right glass star badge when the place carries a rating.
    @ViewBuilder
    private var ratingBadge: some View {
        if let r = place.displayedRating {
            HStack(spacing: 3) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.yellow)
                Text(String(format: "%.1f", r.value))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The user's own note, if any — a personal anchor for the peek.
            if let review = place.review,
               !review.comment.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(listColor ?? SomedayColors.primary)
                    Text(review.comment)
                        .font(.system(size: 13))
                        .foregroundColor(SomedayColors.charcoal.opacity(0.82))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: onOpenMap) {
                HStack(spacing: 7) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("View on map")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(SomedayColors.charcoal)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(SomedayColors.lime, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    /// Cover photo with a translucent placeholder while loading and a
    /// brand-gradient fallback (category glyph) if the fetch fails.
    @ViewBuilder
    private var heroImage: some View {
        AsyncImage(url: heroURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty:
                ZStack {
                    Rectangle().fill(SomedayColors.grayLight)
                    ProgressView().controlSize(.small)
                }
            default:
                LinearGradient(
                    colors: [SomedayColors.primary, SomedayColors.primaryDark],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay(
                    Image(systemName: place.category.icon)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                )
            }
        }
    }
}

/// Tappable link tinted in lime ("poison green") — the Someday CTA colour.
private struct ChatLinkText: View {
    let name: String
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            Text(name)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(SomedayColors.lime)
                .underline()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ChatMessageBody — the entry point used by ChatBubbleView

/// Renders a chat message's body as a flowed sequence of words, pills
/// and tappable links. Replaces the old `Text(AttributedString)` path.
struct ChatMessageBody: View {
    let raw: String
    /// Foreground for plain words (charcoal for assistant bubbles, white
    /// for user bubbles). Links / pills use their own brand colours.
    let textColor: Color

    var body: some View {
        let tokens = ChatMessageParser.parse(raw)
        InlineFlowLayout(hSpacing: 4, vSpacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                tokenView(token)
            }
        }
    }

    @ViewBuilder
    private func tokenView(_ token: InlineToken) -> some View {
        switch token {
        case .word(let w):
            if w == "\n" {
                // Zero-width spacer that marks a line break.
                Color.clear.frame(width: 0, height: 0).chatNewline()
            } else {
                Text(w)
                    .font(.system(size: 14))
                    .foregroundColor(textColor)
                    .fixedSize()
            }
        case .listPill(let name):
            ListPillView(name: name)
        case .placeLink(let name, let id, let listHint):
            // Saved places get the same mini-pin treatment as AI
            // proposals, but colored from the list to match the on-map
            // identity. Tapping routes through `someday://place/<id>` →
            // `MapHomeView.handleChatLinkTap` → `focusOnPlaceLink`.
            SavedPlacePinPillView(name: name, idOrPrefix: id, listHint: listHint)
        case .suggestionLink(let name, let cat, let lat, let lon):
            // Render the venue inline as a mini lime sparkles-pin pill so
            // it matches the on-map `SuggestionPinAnnotationView`. Tapping
            // routes through `OpenURLAction` to drop a real pin.
            SuggestionPinPillView(name: name, category: cat, lat: lat, lon: lon)
        case .showLink(let name, let lat, let lon, let span):
            // Camera-only "take me there" pill — tapping flies the map to
            // an arbitrary place without dropping a pin or opening a card.
            ShowPillView(name: name, lat: lat, lon: lon, span: span)
        case .webLink(let name, let url):
            ChatLinkText(name: name, url: url)
        }
    }
}
