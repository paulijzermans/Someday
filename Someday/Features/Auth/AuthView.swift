import SwiftUI

struct AuthView: View {
    let appState: AppState
    @State private var vm: AuthViewModel

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

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(SomedayColors.butter.opacity(0.18))
                        .frame(width: 80, height: 80)
                        .overlay(
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(SomedayColors.butter)
                        )

                    Text("Someday")
                        .font(SomedayFonts.brand(size: 64))
                        .foregroundColor(SomedayColors.butter)
                        .tracking(1)

                    Text("Discover amazing places.\nSave them for someday.")
                        .font(.system(size: 17))
                        .foregroundColor(SomedayColors.butter.opacity(0.75))
                        .multilineTextAlignment(.center)
                }

                Spacer().frame(height: 60)

                VStack(spacing: 12) {
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
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(SomedayColors.butter)
                        .foregroundColor(SomedayColors.green)
                        .cornerRadius(14)
                    }

                    Button {
                        Task {
                            vm.email = "demo@someday.app"
                            vm.password = "demo"
                            if let user = await vm.signInWithEmail() {
                                appState.handleAuthSuccess(user: user)
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "envelope.fill").font(.system(size: 18))
                            Text("Continue with Email")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(SomedayColors.butter.opacity(0.12))
                        .foregroundColor(SomedayColors.butter)
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(SomedayColors.butter.opacity(0.4), lineWidth: 1.5)
                        )
                    }
                }
                .padding(.horizontal, 40)
                .disabled(vm.isLoading)
                .opacity(vm.isLoading ? 0.6 : 1)

                if vm.isLoading {
                    ProgressView()
                        .tint(.white)
                        .padding(.top, 16)
                }

                if let error = vm.error {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.6))
                        .cornerRadius(8)
                        .padding(.top, 12)
                }

                VStack(spacing: 16) {
                    Text("By continuing, you agree to our\nTerms of Service & Privacy Policy")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.top, 20)
                }

                Spacer().frame(height: 40)
            }
        }
    }
}
