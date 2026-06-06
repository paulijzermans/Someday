import SwiftUI

/// The user's profile screen. Visual language borrowed from the Airbnb
/// profile mock the user shared: large title, rounded white cards on a
/// tinted background, a hero card with photo + stats, then a row of
/// action tiles, a promo card, and a quiet settings row.
struct ProfileView: View {
    let user: UserProfile
    let placeCount: Int
    let reviewCount: Int
    let friendCount: Int
    let friendAvatars: [UserProfile]
    let onSignOut: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    actionRow
                    invitePromoCard
                    settingsLink
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
                AsyncImage(url: user.avatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Circle().fill(SomedayColors.primaryLight)
                            .overlay(
                                Text(user.initials)
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
                Text(user.name)
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
            statRow(value: "\(reviewCount)", label: "reviews")
            Divider()
            statRow(value: "\(friendCount)", label: friendCount == 1 ? "friend" : "friends")
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
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return "Joined \(formatter.string(from: user.createdAt))"
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 12) {
            actionTile(
                title: "Your reviews",
                badge: reviewCount > 0 ? "\(reviewCount)" : nil,
                tint: SomedayColors.primary
            ) {
                AnyView(
                    Image(systemName: "star.bubble.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(SomedayColors.primary)
                )
            }

            actionTile(
                title: "Friends",
                badge: friendCount > 0 ? "\(friendCount)" : nil,
                tint: SomedayColors.coral
            ) {
                AnyView(friendStack)
            }
        }
    }

    private func actionTile(
        title: String,
        badge: String?,
        tint: Color,
        @ViewBuilder content: () -> AnyView
    ) -> some View {
        VStack(spacing: 14) {
            content()
                .frame(height: 64)

            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(SomedayColors.charcoal)
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
            Spacer(minLength: 0)
        }
    }

    // MARK: - Invite promo

    private var invitePromoCard: some View {
        Button {
            // TODO: open invite flow / share Someday link.
        } label: {
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
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .cornerRadius(20)
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Settings

    private var settingsLink: some View {
        VStack(spacing: 0) {
            settingsRow(icon: "gearshape.fill", title: "Account settings", showBadge: true) {
                // TODO: open settings.
            }
            Divider().padding(.leading, 58)
            settingsRow(icon: "bell.fill", title: "Notifications") {
                // TODO: notifications.
            }
            Divider().padding(.leading, 58)
            settingsRow(icon: "lock.fill", title: "Privacy") {
                // TODO: privacy.
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
        Button(action: action) {
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

    // MARK: - Notification bell

    private var notificationBell: some View {
        Button { /* TODO: open notifications */ } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                    .frame(width: 36, height: 36)
                    .background(.white)
                    .clipShape(Circle())
                Circle()
                    .fill(SomedayColors.coral)
                    .frame(width: 8, height: 8)
                    .offset(x: -3, y: 3)
            }
        }
    }
}
