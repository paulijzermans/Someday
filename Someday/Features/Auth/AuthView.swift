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
            // Brand background — the blue gradient image lives in
            // Assets.xcassets/loginBackground.imageset. Stretches to
            // the safe area edges so the hue carries the whole
            // screen. Used by both login and onboarding so the two
            // visually feel like one continuous moment.
            Image("loginBackground")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            // Centered hot-air-balloon silhouette — the same asset
            // used elsewhere in the app, so the brand mark lands on
            // the auth screen too. Mild bottom offset so it sits
            // above the hero / form rather than dead-centre behind
            // the title.
            Image("balloon")
                .resizable()
                .scaledToFit()
                .frame(width: 220)
                .foregroundStyle(.white.opacity(0.92))
                .offset(y: -120)
                .allowsHitTesting(false)

            // Tap outside the form to dismiss the keyboard. Without this
            // the keyboard sticks around after the user finishes typing
            // and the CTA hides behind it.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { focusedField = nil }

            // Single non-scrolling column. We rely on `ignoresSafeArea`
            // for the gradient + a fixed-height VStack so the screen
            // doesn't bounce when the keyboard comes up. The TextFields
            // still get pushed up by the system keyboard automatically.
            if let pending = vm.pendingConfirmationEmail {
                confirmationPanel(email: pending)
                    .padding(.horizontal, 28)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                VStack(spacing: 22) {
                    Spacer(minLength: 0)
                    hero
                    socialButtons
                    divider
                    emailForm
                    toggleRow
                    if let error = vm.error {
                        errorBanner(error)
                    }
                    Spacer(minLength: 0)
                    Text("By continuing, you agree to our\nTerms of Service & Privacy Policy")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }

            if vm.isLoading {
                Color.black.opacity(0.2).ignoresSafeArea()
                ProgressView().tint(.white).scaleEffect(1.2)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: vm.pendingConfirmationEmail)
        // The host app forwards the `someday://auth-callback#…` link the
        // user clicked in the confirmation email to AppState; that calls
        // `handleAuthCallback` which lands here through this binding so
        // we can flip out of the pending panel into the signed-in app.
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: 12) {
            // Small transparent hot-air-balloon mark sitting directly
            // above the wordmark — a literal brand badge crowning the
            // "Someday" title. Uses the pixelated cut-out asset so it
            // floats over the blue gradient cleanly with a playful,
            // retro feel.
            Image("airballoonPixelated")
                .resizable()
                .scaledToFit()
                .frame(width: 72)
                .allowsHitTesting(false)
            // Old mappin badge dropped — the centred balloon image
            // behind this stack is the brand mark now, and a second
            // square pin under "Someday" was visual noise.
            //
            // Upright wordmark: the whole word in the brand (non-italic)
            // face. We deliberately don't use `SomedayFonts.wordmark`
            // here — that slants the "some" half — because the welcome
            // hero reads cleaner straight. The slogan beneath was also
            // dropped to keep the hero to just the mark + wordmark.
            Text("Someday")
                .font(SomedayFonts.brand(size: 52))
                .foregroundColor(SomedayColors.butter)
                .tracking(1)
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

    // MARK: - Email confirmation panel
    //
    // Shown after sign-up when Supabase is configured to require email
    // confirmation. The body is the only thing on screen — no form, no
    // social buttons — so the user understands their next action lives
    // in their mailbox, not here.

    @ViewBuilder
    private func confirmationPanel(email: String) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(SomedayColors.butter.opacity(0.18))
                    .frame(width: 100, height: 100)
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundColor(SomedayColors.butter)
            }

            VStack(spacing: 10) {
                Text("Check your email")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(SomedayColors.butter)
                Text("We sent a confirmation link to")
                    .font(.system(size: 15))
                    .foregroundColor(SomedayColors.butter.opacity(0.85))
                Text(email)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text("Tap the link to land back here, signed in and ready to save your first place.")
                    .font(.system(size: 14))
                    .foregroundColor(SomedayColors.butter.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.top, 8)
                    .padding(.horizontal, 6)
            }

            Spacer(minLength: 0)

            Button {
                Task {
                    // Best-effort: try a sign-in with the same credentials
                    // they just used. If Supabase says "email not
                    // confirmed", we keep them on this panel.
                    if let user = await vm.signInWithEmail() {
                        appState.handleAuthSuccess(user: user)
                    }
                }
            } label: {
                Text("I've confirmed — sign in")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(SomedayColors.butter)
                    .foregroundColor(SomedayColors.greenDark)
                    .cornerRadius(12)
            }
            .disabled(vm.isLoading)

            Button {
                vm.cancelPendingConfirmation()
            } label: {
                Text("Use a different email")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.butter.opacity(0.8))
            }
            .padding(.bottom, 6)
        }
        .padding(.vertical, 40)
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
