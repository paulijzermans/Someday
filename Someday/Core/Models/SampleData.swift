import Foundation

enum SampleData {
    static let currentUser = UserProfile(
        id: "user_paul",
        name: "Paul",
        email: "paul@example.com",
        avatarURL: URL(string: "https://i.pravatar.cc/150?img=11")
    )

    static let friends: [UserProfile] = [
        UserProfile(id: "user_emma", name: "Emma", email: "emma@example.com", avatarURL: URL(string: "https://i.pravatar.cc/150?img=5"), friendIDs: ["user_paul"], lists: ["Barcelona": ["place_1", "place_3"], "Vegan": ["place_2", "place_6"]]),
        UserProfile(id: "user_lucas", name: "Lucas", email: "lucas@example.com", avatarURL: URL(string: "https://i.pravatar.cc/150?img=12"), friendIDs: ["user_paul"], lists: ["Tokyo": ["place_2", "place_6"], "Barcelona": ["place_3"]]),
        UserProfile(id: "user_sofia", name: "Sofia", email: "sofia@example.com", avatarURL: URL(string: "https://i.pravatar.cc/150?img=9"), friendIDs: ["user_paul"], lists: ["Vegan": ["place_4", "place_1"], "Tokyo": ["place_5"]]),
        UserProfile(id: "user_max", name: "Max", email: "max@example.com", avatarURL: URL(string: "https://i.pravatar.cc/150?img=7"), friendIDs: ["user_paul"], lists: ["Barcelona": ["place_1", "place_5"]]),
        UserProfile(id: "user_olivia", name: "Olivia", email: "olivia@example.com", avatarURL: URL(string: "https://i.pravatar.cc/150?img=25"), friendIDs: ["user_paul"], lists: ["Tokyo": ["place_2"]]),
        UserProfile(id: "user_noah", name: "Noah", email: "noah@example.com", avatarURL: URL(string: "https://i.pravatar.cc/150?img=53"), friendIDs: ["user_paul"], lists: ["Vegan": ["place_4", "place_5"]]),
    ]

    /// A specific friend who's sharing a list with you on first launch.
    /// Surfaced as a one-off "share request" tile that drops the user
    /// straight into list-preview mode when they tap Preview.
    static let bodil = UserProfile(
        id: "user_bodil",
        name: "Bodil",
        email: "bodil@example.com",
        // TODO: swap for a local asset once Bodil's actual photo is in
        // Assets.xcassets — drop a `BodilAvatar.imageset` in there and
        // route the avatar render through Image("BodilAvatar").
        avatarURL: URL(string: "https://i.pravatar.cc/300?img=44"),
        friendIDs: ["user_paul"],
        lists: [
            "Amsterdam": ["place_1", "place_3", "place_4", "place_7", "place_8", "place_9"]
        ]
    )

    /// People who follow you but you don't follow back yet — surfaced in the Activity feed.
    static let pendingFollowers: [UserProfile] = [
        UserProfile(
            id: "user_wouter",
            name: "Wouter",
            email: "wouter@example.com",
            avatarURL: URL(string: "https://i.pravatar.cc/150?img=33"),
            lists: [
                "Lisbon": ["place_2", "place_3", "place_5"],
                "Brunch": ["place_4", "place_7"],
                "Bookshops": ["place_6"]
            ]
        ),
        UserProfile(
            id: "user_julia",
            name: "Julia",
            email: "julia@example.com",
            avatarURL: URL(string: "https://i.pravatar.cc/150?img=47"),
            lists: [
                "Wine bars": ["place_3", "place_11", "place_12"],
                "Hidden gems": ["place_4", "place_9"]
            ]
        ),
    ]

    static let places: [Place] = [
        Place(id: "place_1", name: "Luigi's Pizzeria", category: .food, latitude: 52.3738, longitude: 4.8910, source: .instagram, neighborhood: "Amsterdam Centrum", visitedByIDs: ["user_emma", "user_sofia", "user_paul"], tags: ["Date night", "Instagram", "€€"], isSaved: true, review: Review(price: 7, quality: 8.5, service: 8, comment: "Cozy spot, great wood-fired pizza. Service was attentive even on a busy Friday."), ownerID: "user_paul"),
        Place(id: "place_2", name: "Omakase Bar", category: .food, latitude: 52.3660, longitude: 4.8830, source: .friend, neighborhood: "De Pijp", recommendedBy: "user_emma", visitedByIDs: ["user_emma"], tags: ["Sushi", "Special occasion", "€€€"], friendRatings: ["user_emma": 9.2], ownerID: "user_emma"),
        Place(id: "place_3", name: "Rooftop 22", category: .drinks, latitude: 52.3700, longitude: 4.8980, source: .friend, neighborhood: "Oost", recommendedBy: "user_lucas", visitedByIDs: ["user_emma", "user_lucas", "user_sofia", "user_paul"], tags: ["Cocktails", "Views", "€€"], isSaved: true, review: Review(price: 6, quality: 8, service: 7.5, comment: "Stunning views but the drinks are pricey. Worth it for sunset."), ownerID: "user_lucas"),
        Place(id: "place_4", name: "Brew & Co", category: .coffee, latitude: 52.3620, longitude: 4.8850, source: .manual, neighborhood: "Jordaan", visitedByIDs: ["user_paul"], tags: ["Specialty coffee", "Work-friendly"], isSaved: true, review: Review(price: 8, quality: 9.5, service: 9, comment: "Best oat latte in Amsterdam. Friendly baristas, great vibe to work."), ownerID: "user_paul"),
        Place(id: "place_5", name: "Sunset Trail", category: .activity, latitude: 52.3580, longitude: 4.8750, source: .friend, neighborhood: "Vondelpark", recommendedBy: "user_sofia", visitedByIDs: ["user_lucas", "user_sofia"], tags: ["Hiking", "Sunset", "Free"], friendRatings: ["user_sofia": 8.5, "user_lucas": 7.3], ownerID: "user_sofia"),
        Place(id: "place_6", name: "Art Space", category: .art, latitude: 52.3600, longitude: 4.9000, source: .tiktok, neighborhood: "Plantage", recommendedBy: "user_emma", visitedByIDs: ["user_emma", "user_paul"], tags: ["Gallery", "Modern art", "€"], review: Review(price: 9, quality: 7, service: 6, comment: "Cool exhibits but felt a bit rushed by the staff."), ownerID: "user_paul"),

        // Not-yet-been: places the user saved from various sources but hasn't visited or rated yet.
        Place(id: "place_7", name: "Cottoncake", category: .coffee, latitude: 52.3554, longitude: 4.8892, source: .instagram, neighborhood: "De Pijp", tags: ["Brunch", "Cozy"], isSaved: true, ownerID: "user_paul"),
        Place(id: "place_8", name: "Pluk", category: .coffee, latitude: 52.3742, longitude: 4.8867, source: .instagram, neighborhood: "Negen Straatjes", tags: ["Smoothies", "Pretty"], isSaved: true, ownerID: "user_paul"),
        Place(id: "place_9", name: "De Plantage", category: .food, latitude: 52.3650, longitude: 4.9123, source: .facebook, neighborhood: "Plantage", tags: ["Brunch", "Garden"], isSaved: true, ownerID: "user_paul"),
        Place(id: "place_10", name: "Mediamatic ETEN", category: .food, latitude: 52.3712, longitude: 4.9075, source: .googleMaps, neighborhood: "Oost", tags: ["Greenhouse", "Vegan"], isSaved: true, ownerID: "user_paul"),
        Place(id: "place_11", name: "Cafe de Ceuvel", category: .drinks, latitude: 52.3989, longitude: 4.9117, source: .facebook, neighborhood: "Noord", tags: ["Sustainable", "Waterfront"], isSaved: true, ownerID: "user_paul"),
        Place(id: "place_12", name: "Bar Botanique", category: .drinks, latitude: 52.3604, longitude: 4.9265, source: .googleMaps, neighborhood: "Oost", tags: ["Tropical", "Plants"], isSaved: true, ownerID: "user_paul"),
    ]
}
