import Foundation

// =============================================================================
// ExtractorConfig — credentials + URL for Pipeline 2 (Railway extractor)
// =============================================================================
//
// Read from the same gitignored `Secrets.plist` Supabase uses. Kept in a
// separate type so the Extraction module has no compile-time dependency on
// `SupabaseConfig` — the two concerns can evolve independently.
//
// Required keys in `Secrets.plist`:
//   EXTRACTOR_URL       — e.g. https://extractor-production-3a29.up.railway.app
//   EXTRACTOR_API_KEY   — shared secret sent in the `X-Api-Key` header
//
// `isConfigured` is the gate the router consults before attempting Pipeline 2.
// If the keys aren't filled in, Pipeline 2 throws `.notConfigured` and the
// caller can either fall back or surface a useful error.

enum ExtractorConfig {
    /// Base URL of the extractor service. Trailing slashes are tolerated —
    /// `Pipeline2Service` builds paths via `URL(string:relativeTo:)`.
    static let url: URL? = {
        guard let raw = value(for: "EXTRACTOR_URL"), let u = URL(string: raw) else {
            return nil
        }
        return u
    }()

    /// Shared secret. Sent verbatim as the `X-Api-Key` header value.
    static let apiKey: String? = value(for: "EXTRACTOR_API_KEY")

    /// True only when both the URL and the API key are present. Router checks
    /// this before kicking off a Pipeline 2 run.
    static var isConfigured: Bool {
        url != nil && (apiKey?.isEmpty == false)
    }

    // MARK: - Plist loading
    //
    // Read once at first access and cache. We use NSDictionary for tolerance —
    // Secrets.plist is hand-edited and any odd whitespace would otherwise blow
    // up a stricter PropertyListDecoder pass.

    private static let secrets: [String: Any] = {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return [:]
        }
        return dict
    }()

    private static func value(for key: String) -> String? {
        guard let v = secrets[key] as? String, !v.isEmpty,
              !v.hasPrefix("YOUR_") else { return nil }
        return v
    }
}
