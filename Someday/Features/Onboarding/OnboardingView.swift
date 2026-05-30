import SwiftUI

private struct OnboardingPage {
    let icon: String
    let title: String
    let description: String
    let bgGradient: [Color]
    let iconBg: Color
}

struct OnboardingView: View {
    let appState: AppState
    @State private var currentPage = 0

    private let pages = [
        OnboardingPage(
            icon: "square.and.arrow.up.fill", title: "Share from Social",
            description: "Send Reels and TikToks directly to Someday. We'll find the place and pin it on your map.",
            bgGradient: [SomedayColors.primaryLight, .white],
            iconBg: SomedayColors.primary.opacity(0.15)
        ),
        OnboardingPage(
            icon: "person.2.fill", title: "Friend Recommendations",
            description: "Your close friends can suggest places they love. See their picks on your map.",
            bgGradient: [Color(red: 1.0, green: 0.94, blue: 0.88), .white],
            iconBg: Color.orange.opacity(0.15)
        ),
        OnboardingPage(
            icon: "list.bullet.rectangle.fill", title: "Import Your Lists",
            description: "Bring in your Google Maps saves and other lists. Populate your map instantly.",
            bgGradient: [Color(red: 0.91, green: 0.88, blue: 1.0), .white],
            iconBg: Color.purple.opacity(0.15)
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                ForEach(0..<pages.count, id: \.self) { index in
                    VStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 32)
                            .fill(pages[index].iconBg)
                            .frame(width: 120, height: 120)
                            .overlay(
                                Image(systemName: pages[index].icon)
                                    .font(.system(size: 48, weight: .medium))
                                    .foregroundColor(SomedayColors.charcoal.opacity(0.8))
                            )
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: pages[index].bgGradient, startPoint: .top, endPoint: .bottom))
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 0) {
                Text(pages[currentPage].title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
                    .padding(.bottom, 8)

                Text(pages[currentPage].description)
                    .font(.system(size: 16))
                    .foregroundColor(SomedayColors.grayMedium)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 28)

                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        Capsule()
                            .fill(index == currentPage ? SomedayColors.primary : Color(.systemGray4))
                            .frame(width: index == currentPage ? 24 : 8, height: 8)
                            .animation(.easeInOut(duration: 0.2), value: currentPage)
                    }
                }
                .padding(.bottom, 24)

                Button {
                    if currentPage < pages.count - 1 {
                        withAnimation { currentPage += 1 }
                    } else {
                        appState.completeOnboarding()
                    }
                } label: {
                    Text(currentPage == pages.count - 1 ? "Let's go!" : "Next")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(SomedayColors.primary)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }
                .padding(.horizontal, 30)

                if currentPage < pages.count - 1 {
                    Button("Skip") { appState.completeOnboarding() }
                        .font(.system(size: 15))
                        .foregroundColor(SomedayColors.grayMedium)
                        .padding(.top, 12)
                }
            }
            .padding(.bottom, 50)
        }
        .ignoresSafeArea(edges: .top)
    }
}
