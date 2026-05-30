import Foundation

/// Loads Supabase credentials from a gitignored `Secrets.plist` bundled with the app.
///
/// Only the **anon/public** key belongs here — it is safe to ship in the client
/// because Row-Level Security gates every row. The **service-role** key must NEVER
/// be embedded in the app; it lives only in Supabase Edge Functions / server env.
///
/// Setup:
///   1. Copy `Secrets.example.plist` → `Secrets.plist`
///   2. Fill in your project URL + anon key (Dashboard → Project Settings → API)
///   3. Add `Secrets.plist` to the app target in Xcode (Target Membership ✓)
enum SupabaseConfig {
    /// e.g. https://xxxxxxxxxxxx.supabase.co
    static let url: URL? = {
        guard let raw = value(for: "SUPABASE_URL"), let url = URL(string: raw) else { return nil }
        return url
    }()

    /// The public anon key (NOT the service-role key).
    static let anonKey: String? = value(for: "SUPABASE_ANON_KEY")

    /// True only when both values are present — used to decide whether to wire
    /// the live Supabase services or fall back to the mock stack.
    static var isConfigured: Bool { url != nil && (anonKey?.isEmpty == false) }

    // MARK: - Plist loading

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
