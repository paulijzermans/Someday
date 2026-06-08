import Foundation

@Observable
final class AuthViewModel {
    var email = ""
    var password = ""
    var name = ""
    var isLoading = false
    var error: String?
    var isSignUp = false
    /// Non-nil while we're waiting for the user to click the confirmation
    /// link emailed to them after sign-up. AuthView reads this and swaps
    /// the form for a "Check your email" panel.
    var pendingConfirmationEmail: String?

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

    /// Sign-in / sign-up entry point. Returns the signed-in profile when
    /// we're done; returns `nil` either because something failed (see
    /// `error`) OR because sign-up needs email confirmation first (see
    /// `pendingConfirmationEmail`). AuthView distinguishes the two by
    /// reading both properties.
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
                let result = try await authService.signUpWithEmail(email: email, password: password, name: name)
                switch result {
                case .signedIn(let user):
                    return user
                case .confirmationRequired(let address):
                    // Park the address so the AuthView can render the
                    // "Check your email" panel.
                    pendingConfirmationEmail = address
                    return nil
                }
            } else {
                return try await authService.signInWithEmail(email: email, password: password)
            }
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Called from the AuthView's "Back to sign in" button on the
    /// confirmation panel. Resets the pending state so the user can
    /// re-enter credentials.
    @MainActor
    func cancelPendingConfirmation() {
        pendingConfirmationEmail = nil
        password = ""
    }
}
