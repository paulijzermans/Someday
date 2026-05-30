import Foundation

@Observable
final class AuthViewModel {
    var email = ""
    var password = ""
    var name = ""
    var isLoading = false
    var error: String?
    var isSignUp = false

    private let authService: AuthServiceProtocol

    init(authService: AuthServiceProtocol) {
        self.authService = authService
    }

    @MainActor
    func signInWithGoogle() async -> UserProfile? {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            return try await authService.signInWithGoogle()
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    @MainActor
    func signInWithEmail() async -> UserProfile? {
        guard !email.isEmpty, !password.isEmpty else {
            error = "Please fill in all fields."
            return nil
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            if isSignUp {
                return try await authService.signUpWithEmail(email: email, password: password, name: name)
            } else {
                return try await authService.signInWithEmail(email: email, password: password)
            }
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}
