import Foundation
import Supabase

/// Single shared `SupabaseClient` for the app.
///
/// Construction is deferred until `SupabaseConfig.isConfigured` is true (i.e. a
/// valid `Secrets.plist` is present). If you reach `shared` without configuring,
/// that's a programmer error — `ServiceContainer` only wires the live stack when
/// `isConfigured` is true, so the force-unwrap can never fire in practice.
enum SupabaseClientProvider {
    /// Custom URL scheme used as the OAuth redirect target. Must match the
    /// `CFBundleURLSchemes` entry registered in the app target and the redirect
    /// URL whitelisted in the Supabase dashboard (Auth → URL Configuration).
    static let redirectURL = URL(string: "someday://auth-callback")!

    static let shared: SupabaseClient = {
        guard let url = SupabaseConfig.url, let anonKey = SupabaseConfig.anonKey else {
            preconditionFailure("SupabaseClientProvider.shared accessed before Secrets.plist was configured.")
        }
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    redirectToURL: redirectURL,
                    flowType: .pkce
                )
            )
        )
    }()
}
