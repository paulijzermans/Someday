import SwiftUI

struct PlaceCardSheet: View {
    let place: Place
    let friends: [UserProfile]
    let onDismiss: () -> Void
    let onReservation: () -> Void
    @State private var dragOffset: CGFloat = 0
    @State private var priceValue: Double = 5
    @State private var qualityValue: Double = 5
    @State private var serviceValue: Double = 5
    @State private var commentText: String = ""

    private var visitedFriends: [UserProfile] {
        friends.filter { place.visitedByIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color(.systemGray4))
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)
                    .padding(.bottom, 16)

                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(
                        colors: [SomedayColors.primary, SomedayColors.primaryDark],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(height: 180)
                    .overlay(alignment: .bottomLeading) {
                        sourceBadge
                            .padding(12)
                    }
                    .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(place.name)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(SomedayColors.charcoal)
                        Spacer()
                        if let review = place.review {
                            overallBadge(review.overallFormatted)
                        }
                    }
                    .padding(.top, 14)

                    HStack(spacing: 6) {
                        Image(systemName: place.category.icon)
                            .font(.system(size: 13))
                        Text(place.category.displayName)
                        Text("•")
                        Text(place.neighborhood)
                    }
                    .font(.system(size: 14))
                    .foregroundColor(SomedayColors.grayMedium)
                    .padding(.top, 4)
                    .padding(.bottom, 12)

                    if place.review != nil {
                        reviewSection
                    }

                    if !visitedFriends.isEmpty {
                        friendsSection
                    }

                    actionsSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(.white)
            .cornerRadius(20)
            .offset(y: max(dragOffset, 0))
            .gesture(
                DragGesture()
                    .onChanged { dragOffset = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height > 120 || value.velocity.height > 500 {
                            onDismiss()
                        } else {
                            withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                        }
                    }
            )
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            if let review = place.review {
                priceValue = review.price
                qualityValue = review.quality
                serviceValue = review.service
                commentText = review.comment
            }
        }
    }

    private func overallBadge(_ grade: String) -> some View {
        VStack(spacing: 0) {
            Text(grade)
                .font(.system(size: 20, weight: .heavy))
                .foregroundColor(SomedayColors.green)
            Text("/ 10")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(SomedayColors.green.opacity(0.7))
        }
        .frame(width: 52, height: 52)
        .background(SomedayColors.butter)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if let assetName = place.source.assetName, UIImage(named: assetName) != nil {
            Image(assetName)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        } else {
            HStack(spacing: 4) {
                Image(systemName: place.source.icon)
                    .font(.system(size: 11))
                Text(place.source.label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.white.opacity(0.9))
            .cornerRadius(8)
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13))
                    .foregroundColor(SomedayColors.primary)
                Text("Your review")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
            }

            ReviewSlider(label: "Price", icon: "eurosign.circle.fill", value: $priceValue)
            ReviewSlider(label: "Quality", icon: "star.fill", value: $qualityValue)
            ReviewSlider(label: "Service", icon: "hand.thumbsup.fill", value: $serviceValue)

            VStack(alignment: .leading, spacing: 6) {
                Text("Comments")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SomedayColors.grayMedium)
                TextField("Add a note...", text: $commentText, axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundColor(SomedayColors.charcoal)
                    .lineLimit(2...4)
                    .padding(10)
                    .background(.white)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )
            }
        }
        .padding(14)
        .background(SomedayColors.grayLight)
        .cornerRadius(14)
        .padding(.bottom, 12)
    }

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Friends who've been here")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SomedayColors.grayMedium)

            HStack(spacing: 10) {
                ForEach(visitedFriends) { friend in
                    VStack(spacing: 4) {
                        AsyncImage(url: friend.avatarURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Circle().fill(SomedayColors.primary.opacity(0.3))
                                    .overlay(
                                        Text(friend.initials.prefix(1))
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(.white)
                                    )
                            }
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(SomedayColors.primary.opacity(0.5), lineWidth: 2))

                        Text(friend.name)
                            .font(.system(size: 11))
                            .foregroundColor(SomedayColors.charcoal)
                    }
                }
                Spacer()
            }
        }
        .padding(.bottom, 12)
    }

    private var actionsSection: some View {
        HStack(spacing: 10) {
            Button(action: onReservation) {
                HStack(spacing: 6) {
                    if place.review != nil {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(place.review != nil ? "Save" : "Reservation")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(SomedayColors.primary)
                .foregroundColor(.white)
                .cornerRadius(14)
            }

            Button {} label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 16))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(.systemGray4), lineWidth: 1.5)
                    )
            }
            .foregroundColor(SomedayColors.charcoal)
        }
    }
}

struct ReviewSlider: View {
    let label: String
    let icon: String
    @Binding var value: Double

    private var displayValue: String {
        let rounded = (value * 10).rounded() / 10
        if rounded == floor(rounded) {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(SomedayColors.primary)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SomedayColors.charcoal)
                Spacer()
                Text(displayValue)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(SomedayColors.charcoal)
                    .frame(minWidth: 22, alignment: .trailing)
            }
            Slider(value: $value, in: 1...10, step: 0.5)
                .tint(SomedayColors.primary)
        }
    }
}
