import Foundation

enum AuthError: LocalizedError {
    case invalidCredentials
    case networkError
    case userNotFound
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "Invalid email or password."
        case .networkError: return "Network error. Please try again."
        case .userNotFound: return "No account found with that email."
        case .unknown(let msg): return msg
        }
    }
}

/// Result of an email sign-up. When email confirmation is enabled on the
/// Supabase project, the user creation succeeds but there's no live
/// session — we get the auth user back but can't act on their behalf
/// until they click the link in the confirmation email. The auth UI
/// branches on this to either drop the user straight into the app
/// (`.signedIn`) or surface a "Check your email" screen
/// (`.confirmationRequired`).
enum SignUpResult: Sendable {
    case signedIn(UserProfile)
    case confirmationRequired(email: String)
}

protocol AuthServiceProtocol: Sendable {
    func signInWithGoogle() async throws -> UserProfile
    func signInWithEmail(email: String, password: String) async throws -> UserProfile
    func signUpWithEmail(email: String, password: String, name: String) async throws -> SignUpResult
    func signOut() throws
    func currentUser() -> UserProfile?

    /// Hand a `someday://auth-callback#…` URL (delivered by Supabase to
    /// the user after they click the confirmation link) to the SDK so it
    /// hydrates the session locally. Returns the now-signed-in profile,
    /// or throws if the URL doesn't carry a valid auth payload.
    func consumeAuthCallback(url: URL) async throws -> UserProfile
}
