import Foundation

final class MockAuthService: AuthServiceProtocol, @unchecked Sendable {
    private var loggedInUser: UserProfile?

    func signInWithGoogle() async throws -> UserProfile {
        try await Task.sleep(for: .milliseconds(800))
        loggedInUser = SampleData.currentUser
        return SampleData.currentUser
    }

    func signInWithEmail(email: String, password: String) async throws -> UserProfile {
        try await Task.sleep(for: .milliseconds(800))
        guard !email.isEmpty, !password.isEmpty else {
            throw AuthError.invalidCredentials
        }
        loggedInUser = SampleData.currentUser
        return SampleData.currentUser
    }

    func signUpWithEmail(email: String, password: String, name: String) async throws -> SignUpResult {
        try await Task.sleep(for: .milliseconds(800))
        // Mock mirrors the real flow's "confirmation required" branch so
        // the UI path can be exercised offline. To test the auto-signed-in
        // branch, prefix the address with `direct+` (e.g. `direct+me@x.com`).
        if email.lowercased().hasPrefix("direct+") {
            let user = UserProfile(id: UUID().uuidString, name: name, email: email)
            loggedInUser = user
            return .signedIn(user)
        }
        return .confirmationRequired(email: email)
    }

    func consumeAuthCallback(url: URL) async throws -> UserProfile {
        // Mock just pretends the link worked.
        try await Task.sleep(for: .milliseconds(400))
        let user = loggedInUser ?? SampleData.currentUser
        loggedInUser = user
        return user
    }

    func signOut() throws {
        loggedInUser = nil
    }

    func currentUser() -> UserProfile? {
        loggedInUser
    }
}
