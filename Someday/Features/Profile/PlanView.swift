import SwiftUI

// =============================================================================
// PlanView — Free vs Pro side-by-side
// =============================================================================
//
// Replaces the old "Your reviews" tile on the profile screen. Single
// floating sheet listing what's in Free + what unlocks at Pro, with a
// CTA at the bottom.
//
// No payments yet — tapping the upgrade CTA just flips
// `preferences.tier = .pro` so the rest of the app can test gated
// behaviour without RevenueCat. When payments land, swap that flip for
// a `Purchases.shared.purchase(…)` call.

struct PlanView: View {
    let appState: AppState
    @Environment(SomedayPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    /// Lifetime usage for the signed-in user, loaded on appear. `nil`
    /// while the fetch is in flight so the tile can show a quiet
    /// placeholder rather than flashing zeros.
    @State private var usage: UsageStats?

    var body: some View {
        NavigationStack {
            @Bindable var prefs = preferences

            ScrollView {
                VStack(spacing: 16) {
                    currentPlanCard(tier: prefs.tier)
                    usageCard
                    featuresCard
                    if prefs.tier == .free {
                        upgradeButton(prefs: prefs)
                    } else {
                        manageButton(prefs: prefs)
                    }
                    Text("Cancel anytime. Restore purchases in the App Store.")
                        .font(.system(size: 12))
                        .foregroundColor(SomedayColors.grayMedium)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(20)
            }
            .background(SomedayColors.anthropicWhite)
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // Best-effort load — a failure just leaves the tile on its
                // zero/placeholder state rather than surfacing an error in
                // what's otherwise a marketing-y plan screen.
                let userID = appState.currentUser?.id ?? ""
                usage = try? await appState.services.usage.fetchUsage(for: userID)
            }
        }
    }

    // MARK: - Sections

    /// Usage overview — how much the user has leaned on the heavy bits
    /// (imports + AI tokens). Sits right under the plan card so a Free
    /// user can see how close they are to wanting Pro.
    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Your usage")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
                Spacer(minLength: 0)
                Text("All time")
                    .font(.system(size: 12))
                    .foregroundColor(SomedayColors.grayMedium)
            }

            HStack(spacing: 12) {
                usageMetric(
                    value: usage.map { "\($0.imports)" } ?? "—",
                    label: "places imported",
                    icon: "square.and.arrow.down.fill",
                    tint: SomedayColors.primary,
                    bg: SomedayColors.primaryLight
                )
                usageMetric(
                    value: usage.map { Self.compactNumber($0.tokensUsed) } ?? "—",
                    label: "AI tokens used",
                    icon: "sparkles",
                    tint: SomedayColors.butterDeep,
                    bg: SomedayColors.amber.opacity(0.22)
                )
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanTile(cornerRadius: 20)
    }

    private func usageMetric(value: String, label: String, icon: String, tint: Color, bg: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 30, height: 30)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(SomedayColors.charcoal)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(SomedayColors.grayMedium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(SomedayColors.grayMedium.opacity(0.12), lineWidth: 1)
        )
    }

    /// Compact thousands/millions formatting so a 1,284,500-token count
    /// reads "1.3M" rather than overflowing the metric tile.
    private static func compactNumber(_ n: Int) -> String {
        switch n {
        case 1_000_000...:
            return String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...:
            return String(format: "%.0fk", Double(n) / 1_000)
        case 1_000...:
            return String(format: "%.1fk", Double(n) / 1_000)
        default:
            return "\(n)"
        }
    }

    private func currentPlanCard(tier: SomedayPreferences.Tier) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tier == .pro
                          ? AnyShapeStyle(SomedayColors.amber.opacity(0.22))
                          : AnyShapeStyle(SomedayColors.primaryLight))
                    .frame(width: 56, height: 56)
                Image(systemName: tier == .pro ? "sparkles" : "balloon.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(tier == .pro ? SomedayColors.butterDeep : SomedayColors.primary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(tier == .pro ? "You're on Pro" : "You're on Free")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
                Text(tier == .pro
                     ? "Thanks for supporting Someday."
                     : "Most things still work — Pro just makes the heavy AI bits unlimited.")
                    .font(.system(size: 13))
                    .foregroundColor(SomedayColors.grayMedium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanTile(cornerRadius: 20)
    }

    private var featuresCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What's included")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(SomedayColors.grayMedium)

            featureRow(
                title: "Save unlimited places",
                tiers: "Free + Pro",
                icon: "mappin.circle.fill",
                proOnly: false
            )
            featureRow(
                title: "Import from Maps + Instagram",
                tiers: "Free + Pro",
                icon: "square.and.arrow.down.fill",
                proOnly: false
            )
            featureRow(
                title: "Find friends via contacts",
                tiers: "Free + Pro",
                icon: "person.2.fill",
                proOnly: false
            )
            Divider().padding(.vertical, 4)
            featureRow(
                title: "Unlimited AI booking checks",
                tiers: "Pro",
                icon: "sparkles",
                proOnly: true
            )
            featureRow(
                title: "Real-time table availability",
                tiers: "Pro",
                icon: "calendar.badge.clock",
                proOnly: true
            )
            featureRow(
                title: "AI chatbot ('what's open tonight?')",
                tiers: "Pro",
                icon: "bubble.left.and.bubble.right.fill",
                proOnly: true
            )
            featureRow(
                title: "Private + custom map themes",
                tiers: "Pro",
                icon: "paintpalette.fill",
                proOnly: true
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cleanTile(cornerRadius: 20)
    }

    private func featureRow(title: String, tiers: String, icon: String, proOnly: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(proOnly ? SomedayColors.butterDeep : SomedayColors.primary)
                .frame(width: 28, height: 28)
                .background(proOnly
                            ? AnyShapeStyle(SomedayColors.amber.opacity(0.22))
                            : AnyShapeStyle(SomedayColors.primaryLight))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                Text(tiers)
                    .font(.system(size: 12))
                    .foregroundColor(SomedayColors.grayMedium)
            }

            Spacer()

            if proOnly {
                Text("PRO")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(SomedayColors.butterDeep)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(SomedayColors.amber.opacity(0.22))
                    .clipShape(Capsule())
            }
        }
    }

    private func upgradeButton(prefs: SomedayPreferences) -> some View {
        Button {
            Haptics.success()
            withAnimation(SomedayAnimations.followCTA) {
                // Placeholder for the real RevenueCat purchase flow.
                prefs.tier = .pro
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .heavy))
                Text("Upgrade to Pro")
                    .font(.system(size: 17, weight: .bold))
            }
            .foregroundColor(SomedayColors.butter)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(SomedayColors.green)
            .cornerRadius(16)
            .shadow(color: SomedayColors.green.opacity(0.35), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func manageButton(prefs: SomedayPreferences) -> some View {
        Button {
            withAnimation(SomedayAnimations.followCTA) {
                prefs.tier = .free
            }
        } label: {
            Text("Switch back to Free")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(SomedayColors.grayMedium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white)
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(SomedayColors.grayMedium.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
