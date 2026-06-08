import Foundation
import Supabase

/// Live authentication backed by Supabase Auth (GoTrue).
///
/// Google sign-in uses the hosted OAuth flow via `ASWebAuthenticationSession`
/// (handled internally by supabase-swift). On success the Postgres trigger
/// `handle_new_user()` has already created the matching `profiles` row, so we
/// map the returned auth user straight into a `UserProfile`.
final class SupabaseAuthService: AuthServiceProtocol, @unchecked Sendable {
    private let client: SupabaseClient

    init(client: SupabaseClient = SupabaseClientProvider.shared) {
        self.client = client
    }

    func signInWithGoogle() async throws -> UserProfile {
        do {
            let session = try await client.auth.signInWithOAuth(
                provider: .google,
                redirectTo: SupabaseClientProvider.redirectURL
            )
            return Self.profile(from: session.user)
        } catch {
            throw Self.mapError(error)
        }
    }

    func signInWithEmail(email: String, password: String) async throws -> UserProfile {
        do {
            let session = try await client.auth.signIn(email: email, password: password)
            return Self.profile(from: session.user)
        } catch {
            throw Self.mapError(error)
        }
    }

    func signUpWithEmail(email: String, password: String, name: String) async throws -> SignUpResult {
        do {
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["name": .string(name)],
                redirectTo: SupabaseClientProvider.redirectURL
            )
            // Email confirmation is configured on the Supabase project.
            // When it's enabled, `session` comes back nil — the user has
            // been created in `auth.users` but they can't act until they
            // click the link. We surface that state to the UI explicitly
            // so we never try to call protected endpoints (like
            // `find-friends-on-someday`) without a JWT.
            if response.session == nil {
                return .confirmationRequired(email: email)
            }
            return .signedIn(Self.profile(from: response.user))
        } catch {
            throw Self.mapError(error)
        }
    }

    func consumeAuthCallback(url: URL) async throws -> UserProfile {
        do {
            // The supabase-swift SDK reads the access/refresh-token fragment
            // off the URL and stores the session. After this the SDK's
            // `currentUser` is populated and protected calls succeed.
            try await client.auth.session(from: url)
            guard let user = client.auth.currentUser else {
                throw AuthError.unknown("Confirmation link didn't carry a session.")
            }
            return Self.profile(from: user)
        } catch {
            throw Self.mapError(error)
        }
    }

    func signOut() throws {
        Task { try? await client.auth.signOut() }
    }

    func currentUser() -> UserProfile? {
        client.auth.currentUser.map(Self.profile(from:))
    }

    // MARK: - Mapping

    /// Build a `UserProfile` from a Supabase auth `User`, reading the name and
    /// avatar that Google (or our email signup) stored in `user_metadata`.
    private static func profile(from user: User) -> UserProfile {
        let meta = user.userMetadata
        let name = meta["name"]?.stringValue
            ?? meta["full_name"]?.stringValue
            ?? user.email?.components(separatedBy: "@").first
            ?? "Someone"
        let avatar = (meta["avatar_url"]?.stringValue ?? meta["picture"]?.stringValue)
            .flatMap(URL.init(string:))

        return UserProfile(
            id: user.id.uuidString,
            name: name,
            email: user.email ?? "",
            avatarURL: avatar
        )
    }

    private static func mapError(_ error: Error) -> AuthError {
        if error is CancellationError { return .unknown("Sign-in cancelled.") }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .networkError }
        return .unknown(error.localizedDescription)
    }
}
