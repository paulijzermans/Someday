import SwiftUI

struct AuthView: View {
    let appState: AppState
    @State private var vm: AuthViewModel

    /// Focused field, used by the keyboard avoidance + return-key
    /// chaining. SwiftUI's @FocusState lets the password field receive
    /// focus when the user hits "next" on the email field, then the
    /// submit fires when they hit "done" on password.
    @FocusState private var focusedField: Field?
    private enum Field { case email, password, name }

    init(appState: AppState) {
        self.appState = appState
        self._vm = State(initialValue: AuthViewModel(authService: appState.services.auth))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [SomedayColors.green, SomedayColors.greenDark],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Tap outside the form to dismiss the keyboard. Without this
            // the keyboard sticks around after the user finishes typing
            // and the CTA hides behind it.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { focusedField = nil }

            ScrollView {
                VStack(spacing: 28) {
                    hero
                    socialButtons
                    divider
                    emailForm
                    toggleRow
                    if let error = vm.error {
                        errorBanner(error)
                    }
                    Text("By continuing, you agree to our\nTerms of Service & Privacy Policy")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 60)
            }
            .scrollDismissesKeyboard(.interactively)

            if vm.isLoading {
                Color.black.opacity(0.2).ignoresSafeArea()
                ProgressView().tint(.white).scaleEffect(1.2)
            }
        }
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 24)
                .fill(SomedayColors.butter.opacity(0.18))
                .frame(width: 76, height: 76)
                .overlay(
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 38))
                        .foregroundColor(SomedayColors.butter)
                )
            Text("Someday")
                .font(SomedayFonts.brand(size: 56))
                .foregroundColor(SomedayColors.butter)
                .tracking(1)
            Text("Discover amazing places.\nSave them for someday.")
                .font(.system(size: 15))
                .foregroundColor(SomedayColors.butter.opacity(0.75))
                .multilineTextAlignment(.center)
        }
    }

    private var socialButtons: some View {
        Button {
            Task {
                if let user = await vm.signInWithGoogle() {
                    appState.handleAuthSuccess(user: user)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "g.circle.fill")
                    .font(.system(size: 20))
                Text("Continue with Google")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(SomedayColors.lime)
            .foregroundColor(SomedayColors.charcoal)
            .cornerRadius(12)
        }
        .disabled(vm.isLoading)
    }

    /// Thin horizontal rule with "or" centered — visually separates the
    /// social CTA from the email form below.
    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(SomedayColors.butter.opacity(0.35))
                .frame(height: 1)
            Text("or")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SomedayColors.butter.opacity(0.7))
            Rectangle()
                .fill(SomedayColors.butter.opacity(0.35))
                .frame(height: 1)
        }
    }

    // MARK: - Email form

    private var emailForm: some View {
        VStack(spacing: 10) {
            // Name only shows on sign-up — it's the new-account display
            // name written into `profiles.name`. Order: name → email →
            // password keeps the keyboard-flow intuitive.
            if vm.isSignUp {
                authField(
                    label: "Name",
                    text: $vm.name,
                    icon: "person.fill",
                    isSecure: false,
                    contentType: .name,
                    keyboard: .default,
                    submitLabel: .next,
                    field: .name,
                    onSubmit: { focusedField = .email }
                )
            }
            authField(
                label: "Email",
                text: $vm.email,
                icon: "envelope.fill",
                isSecure: false,
                contentType: .emailAddress,
                keyboard: .emailAddress,
                submitLabel: .next,
                field: .email,
                onSubmit: { focusedField = .password }
            )
            authField(
                label: "Password",
                text: $vm.password,
                icon: "lock.fill",
                isSecure: true,
                contentType: vm.isSignUp ? .newPassword : .password,
                keyboard: .default,
                submitLabel: .go,
                field: .password,
                onSubmit: submitEmailForm
            )

            Button(action: submitEmailForm) {
                Text(vm.isSignUp ? "Create account" : "Sign in")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(SomedayColors.butter)
                    .foregroundColor(SomedayColors.greenDark)
                    .cornerRadius(12)
            }
            .disabled(vm.isLoading)
            .padding(.top, 6)
        }
    }

    /// Generic styled text field used by every row in the email form.
    /// Keeps autocorrect/autocapitalize disabled for credentials to
    /// avoid the classic "your email got capitalised" frustration.
    @ViewBuilder
    private func authField(
        label: String,
        text: Binding<String>,
        icon: String,
        isSecure: Bool,
        contentType: UITextContentType,
        keyboard: UIKeyboardType,
        submitLabel: SubmitLabel,
        field: Field,
        onSubmit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(SomedayColors.butter.opacity(0.7))
                .frame(width: 16)
            Group {
                if isSecure {
                    SecureField(label, text: text)
                } else {
                    TextField(label, text: text)
                }
            }
            .textContentType(contentType)
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(field == .name ? .words : .never)
            .submitLabel(submitLabel)
            .onSubmit(onSubmit)
            .focused($focusedField, equals: field)
            .foregroundColor(.white)
            .tint(SomedayColors.butter)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(SomedayColors.butter.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SomedayColors.butter.opacity(focusedField == field ? 0.6 : 0.3), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private var toggleRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                vm.isSignUp.toggle()
                vm.error = nil
            }
        } label: {
            HStack(spacing: 4) {
                Text(vm.isSignUp ? "Have an account?" : "New here?")
                    .foregroundColor(.white.opacity(0.7))
                Text(vm.isSignUp ? "Sign in" : "Create an account")
                    .foregroundColor(SomedayColors.butter)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 14))
        }
    }

    @ViewBuilder
    private func errorBanner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.red.opacity(0.6))
            .cornerRadius(10)
    }

    // MARK: - Submit

    /// Fires sign-in or sign-up via the view model, then routes to the
    /// onboarding overlay on success. The VM enforces required fields
    /// and surfaces backend errors into `vm.error`.
    private func submitEmailForm() {
        focusedField = nil
        Task {
            if let user = await vm.signInWithEmail() {
                appState.handleAuthSuccess(user: user)
            }
        }
    }
}
