import SwiftUI

/// The user's profile screen. Visual language borrowed from the Airbnb
/// profile mock: large title, rounded white cards on a tinted background,
/// a hero card with photo + stats, then a row of action tiles, a promo
/// card, and a quiet settings row.
///
/// Each settings row routes to a dedicated sheet (Account, Notifications,
/// Privacy, Plan). Invite Friends uses a real `ShareLink`. Sign out is
/// the only inline action.
struct ProfileView: View {
    @Bindable var appState: AppState
    let placeCount: Int
    let reviewCount: Int
    let friendCount: Int
    let friendAvatars: [UserProfile]
    let onSignOut: () -> Void
    /// Called when the user taps the Friends action tile. The map sheet
    /// dismisses this view and presents the Activity tile on the Friends
    /// page. No-op default so previews + tests don't have to wire it.
    var onOpenFriends: () -> Void = {}

    @Environment(SomedayPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    // Which settings sheet (if any) is presented. `nil` = no sheet.
    @State private var presentedSheet: Sheet?

    private enum Sheet: String, Identifiable {
        case account, notifications, privacy, plan, ai
        var id: String { rawValue }
    }

    // Convenience: the deep-link URL we ask iOS to share in the Invite
    // promo card. Once we have a real install/landing page this can swap
    // to `https://someday.app/invite/<code>` and carry an attribution
    // token.
    private var inviteURL: URL {
        URL(string: "https://someday.app")!
    }

    private var inviteMessage: String {
        let inviter = appState.currentUser?.name ?? "I"
        return "\(inviter) is collecting places they love on Someday — join and share lists with them."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    actionRow
                    invitePromoCard
                    settingsLink
                    sloganFooter
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(SomedayColors.grayLight)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SomedayColors.charcoal)
                            .frame(width: 32, height: 32)
                            .background(.white)
                            .clipShape(Circle())
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    notificationBell
                }
            }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .account:       AccountSettingsView(appState: appState)
                case .notifications: NotificationsView()
                case .privacy:       PrivacyView(appState: appState)
                case .plan:          PlanView()
                case .ai:            AIAssistantSettingsView()
                }
            }
        }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        HStack(spacing: 18) {
            avatar

            statsColumn
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .cornerRadius(24)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    private var avatar: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: appState.currentUser?.avatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Circle().fill(SomedayColors.primaryLight)
                            .overlay(
                                Text(appState.currentUser?.initials ?? "?")
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundColor(SomedayColors.primary)
                            )
                    }
                }
                .frame(width: 110, height: 110)
                .clipShape(Circle())

                // Verified shield — borrowed straight from the Airbnb mock
                // as a small confidence cue.
                Circle()
                    .fill(SomedayColors.coral)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundColor(.white)
                    )
            }

            VStack(spacing: 2) {
                Text(appState.currentUser?.name ?? "—")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
                if let subtitle = membershipSubtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(SomedayColors.grayMedium)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
        }
    }

    private var statsColumn: some View {
        VStack(spacing: 0) {
            statRow(value: "\(placeCount)", label: "places")
            Divider()
            statRow(value: "\(friendCount)", label: friendCount == 1 ? "friend" : "friends")
            Divider()
            statRow(value: preferences.tier.displayName, label: "plan")
        }
        .frame(maxWidth: .infinity)
    }

    private func statRow(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(SomedayColors.charcoal)
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(SomedayColors.grayMedium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private var membershipSubtitle: String? {
        guard let user = appState.currentUser else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return "Joined \(formatter.string(from: user.createdAt))"
    }

    // MARK: - Action row
    //
    // Two action tiles side-by-side. Left = the user's subscription plan
    // (Free / Pro) — replaces the old "Your reviews" tile, since the plan
    // is the more useful surface to glance at and tap. Right = Friends,
    // unchanged.

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.tap()
                presentedSheet = .plan
            } label: {
                planActionTile
            }
            .buttonStyle(.plain)

            Button {
                Haptics.tap()
                // Dismiss this profile sheet, then defer the parent's
                // "open Activity / Friends page" callback until the
                // sheet animation finishes — presenting another tile
                // while a sheet is in the middle of dismissing causes
                // the new tile to also be dismissed by the system.
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    onOpenFriends()
                }
            } label: {
                friendsActionTile
            }
            .buttonStyle(.plain)
        }
    }

    private var planActionTile: some View {
        let isPro = preferences.tier == .pro
        return actionTileShell(
            title: "Plan",
            badge: preferences.tier.displayName,
            badgeTint: isPro ? SomedayColors.butterDeep : SomedayColors.charcoal,
            badgeBackground: AnyShapeStyle(
                isPro
                ? AnyShapeStyle(SomedayColors.amber.opacity(0.22))
                : AnyShapeStyle(SomedayColors.grayLight)
            )
        ) {
            Image(systemName: isPro ? "sparkles" : "balloon.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundColor(isPro ? SomedayColors.butterDeep : SomedayColors.primary)
        }
    }

    private var friendsActionTile: some View {
        actionTileShell(
            title: "Friends",
            badge: friendCount > 0 ? "\(friendCount)" : nil,
            badgeTint: .white,
            badgeBackground: AnyShapeStyle(SomedayColors.charcoal)
        ) {
            friendStack
        }
    }

    /// Shared chrome for the two action tiles — keeps the spacing,
    /// background, and shadow identical regardless of what's rendered in
    /// the icon slot or the badge color.
    private func actionTileShell<Icon: View>(
        title: String,
        badge: String?,
        badgeTint: Color,
        badgeBackground: AnyShapeStyle,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        VStack(spacing: 14) {
            icon()
                .frame(height: 64)
                .frame(maxWidth: .infinity)

            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(badgeTint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(badgeBackground)
                        .clipShape(Capsule())
                }
                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    private var friendStack: some View {
        HStack(spacing: -10) {
            ForEach(Array(friendAvatars.prefix(3).enumerated()), id: \.offset) { _, friend in
                AsyncImage(url: friend.avatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Circle().fill(SomedayColors.primaryLight)
                            .overlay(
                                Text(friend.initials.prefix(1))
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(SomedayColors.primary)
                            )
                    }
                }
                .frame(width: 50, height: 50)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white, lineWidth: 3))
            }
            if friendAvatars.isEmpty {
                // Empty state placeholder so the tile has a visible icon
                // even before the user has any friends.
                Circle().fill(SomedayColors.coral.opacity(0.15))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(SomedayColors.coral)
                    )
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Invite promo

    /// Promo card → opens the system share sheet with a deep link the
    /// recipient can tap to install + import the inviter's first list.
    /// `ShareLink` handles iMessage, WhatsApp, Mail, AirDrop, copy, etc.
    /// natively.
    private var invitePromoCard: some View {
        ShareLink(
            item: inviteURL,
            subject: Text("Try Someday with me"),
            message: Text(inviteMessage)
        ) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(SomedayColors.accentGreen.opacity(0.15))
                        .frame(width: 60, height: 60)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(SomedayColors.accentGreen)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Invite friends")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(SomedayColors.charcoal)
                    Text("Discover places together — share Someday with people you travel with.")
                        .font(.system(size: 13))
                        .foregroundColor(SomedayColors.grayMedium)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(SomedayColors.accentGreen)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .cornerRadius(20)
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        }
        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
    }

    // MARK: - Settings

    private var settingsLink: some View {
        VStack(spacing: 0) {
            settingsRow(icon: "gearshape.fill", title: "Account settings") {
                presentedSheet = .account
            }
            Divider().padding(.leading, 58)
            settingsRow(icon: "bell.fill", title: "Notifications") {
                presentedSheet = .notifications
            }
            Divider().padding(.leading, 58)
            settingsRow(icon: "lock.fill", title: "Privacy") {
                presentedSheet = .privacy
            }
            Divider().padding(.leading, 58)
            settingsRow(icon: "sparkles", title: "AI assistant") {
                presentedSheet = .ai
            }
            Divider().padding(.leading, 58)
            settingsRow(icon: "arrow.right.square", title: "Sign out", isDestructive: true) {
                onSignOut()
            }
        }
        .background(.white)
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    private func settingsRow(
        icon: String,
        title: String,
        showBadge: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isDestructive ? .red : SomedayColors.charcoal)
                        .frame(width: 30, height: 30)
                    if showBadge {
                        Circle()
                            .fill(SomedayColors.coral)
                            .frame(width: 8, height: 8)
                            .offset(x: 3, y: -3)
                    }
                }

                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isDestructive ? .red : SomedayColors.charcoal)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Slogan footer

    /// Soft brand sign-off below the settings card. Same line that opens
    /// the auth screen and the splash, so the user sees it the moment
    /// they sign up and every time they wander back into Profile.
    private var sloganFooter: some View {
        VStack(spacing: 6) {
            Text("Someday")
                .font(SomedayFonts.brand(size: 22))
                .foregroundColor(SomedayColors.green)
                .tracking(0.5)
            Text("Save for Someday")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SomedayColors.grayMedium)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: - Notification bell

    private var notificationBell: some View {
        Button {
            Haptics.tap()
            presentedSheet = .notifications
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                    .frame(width: 36, height: 36)
                    .background(.white)
                    .clipShape(Circle())
            }
        }
    }
}
