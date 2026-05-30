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

    func signUpWithEmail(email: String, password: String, name: String) async throws -> UserProfile {
        try await Task.sleep(for: .milliseconds(800))
        let user = UserProfile(id: UUID().uuidString, name: name, email: email)
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
