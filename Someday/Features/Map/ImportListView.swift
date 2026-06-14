import SwiftUI

struct ImportListView: View {
    let onImport: ([Place]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var listText: String = ImportListView.prefilledText

    static let prefilledText = """
    Cafe de Klepel
    Foodhallen
    Bar Centraal
    Cafe Brecht
    The Avocado Show
    Winkel 43
    """

    static let suggestedPlaces: [Place] = [
        Place(id: "import_1", name: "Cafe de Klepel", category: .food, latitude: 52.3702, longitude: 4.8835, source: .manual, neighborhood: "Jordaan", tags: ["Wine", "Cozy"], isSaved: true, ownerID: "user_paul"),
        Place(id: "import_2", name: "Foodhallen", category: .food, latitude: 52.3651, longitude: 4.8721, source: .manual, neighborhood: "Oud-West", tags: ["Food court", "Drinks"], isSaved: true, ownerID: "user_paul"),
        Place(id: "import_3", name: "Bar Centraal", category: .drinks, latitude: 52.3724, longitude: 4.8814, source: .manual, neighborhood: "Centrum", tags: ["Wine", "Tapas"], isSaved: true, ownerID: "user_paul"),
        Place(id: "import_4", name: "Cafe Brecht", category: .drinks, latitude: 52.3592, longitude: 4.8932, source: .manual, neighborhood: "De Pijp", tags: ["German", "Cozy"], isSaved: true, ownerID: "user_paul"),
        Place(id: "import_5", name: "The Avocado Show", category: .food, latitude: 52.3577, longitude: 4.8943, source: .manual, neighborhood: "De Pijp", tags: ["Brunch", "Healthy"], isSaved: true, ownerID: "user_paul"),
        Place(id: "import_6", name: "Winkel 43", category: .coffee, latitude: 52.3754, longitude: 4.8839, source: .manual, neighborhood: "Jordaan", tags: ["Apple pie", "Coffee"], isSaved: true, ownerID: "user_paul"),
    ]

    private var lineCount: Int {
        listText.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.system(size: 22))
                            .foregroundColor(SomedayColors.primary)
                            .frame(width: 44, height: 44)
                            .background(SomedayColors.primaryLight)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Paste a list")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(SomedayColors.charcoal)
                            Text("One place per line — we'll find them on the map")
                                .font(.system(size: 13))
                                .foregroundColor(SomedayColors.grayMedium)
                        }
                        Spacer()
                    }
                }
                .padding(16)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $listText)
                        .font(.system(size: 16))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .cleanTile(cornerRadius: 14)
                        .padding(.horizontal, 16)

                    if listText.isEmpty {
                        Text("Cafe Brecht\nFoodhallen\n...")
                            .font(.system(size: 16))
                            .foregroundColor(SomedayColors.grayMedium.opacity(0.6))
                            .padding(20)
                            .allowsHitTesting(false)
                    }
                }

                Spacer()

                Button {
                    let count = min(lineCount, Self.suggestedPlaces.count)
                    let toImport = Array(Self.suggestedPlaces.prefix(count))
                    onImport(toImport)
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Import \(lineCount) \(lineCount == 1 ? "place" : "places")")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(lineCount > 0 ? SomedayColors.primary : SomedayColors.grayMedium)
                    .foregroundColor(.white)
                    .cornerRadius(14)
                }
                .disabled(lineCount == 0)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(SomedayColors.anthropicWhite)
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(SomedayColors.charcoal)
                            .frame(width: 32, height: 32)
                            .background(Color.white)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                    }
                }
            }
        }
    }
}
