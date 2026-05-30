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

protocol AuthServiceProtocol: Sendable {
    func signInWithGoogle() async throws -> UserProfile
    func signInWithEmail(email: String, password: String) async throws -> UserProfile
    func signUpWithEmail(email: String, password: String, name: String) async throws -> UserProfile
    func signOut() throws
    func currentUser() -> UserProfile?
}
