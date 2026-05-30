import SwiftUI

struct PlacePinView: View {
    let place: Place

    private var dotColor: Color {
        guard let recommenderID = place.recommendedBy else { return SomedayColors.primary }
        let hash = abs(recommenderID.hashValue)
        return SomedayColors.friendColor(for: hash)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(dotColor)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)

            if place.isSaved {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.white)
                    .frame(width: 14, height: 14)
                    .background(SomedayColors.primary)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .offset(x: 6, y: -6)
            }
        }
    }
}
