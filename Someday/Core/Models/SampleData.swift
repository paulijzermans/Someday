import Foundation

enum SampleData {
    static let currentUser = UserProfile(
        id: "user_paul",
        name: "Paul",
        email: "paul@example.com",
        avatarURL: URL(string: "https://i.pravatar.cc/150?img=11")
    )

    /// Demo friends. Each one owns exactly ONE themed list pointing at
    /// real Amsterdam restaurants — the legacy generic-named lists
    /// (Barcelona / Vegan / Tokyo) referencing the older place_1…6
    /// placeholders have been removed, so the lists grid no longer
    /// reads as visually cluttered with mock data. The remaining lists
    /// each have a distinctive identity for the AI chat to surface
    /// ("what would Lucas pick in Jordaan?", "Sofia's tasting menus").
    static let friends: [UserProfile] = [
        UserProfile(
            id: "user_emma", name: "Emma", email: "emma@example.com",
            avatarURL: URL(string: "https://i.pravatar.cc/150?img=5"),
            friendIDs: ["user_paul"],
            lists: [
                "Fine dining": ["place_resto_1", "place_resto_2"],
            ]
        ),
        UserProfile(
            id: "user_lucas", name: "Lucas", email: "lucas@example.com",
            avatarURL: URL(string: "https://i.pravatar.cc/150?img=12"),
            friendIDs: ["user_paul"],
            lists: [
                "Jordaan favourites": ["place_resto_3", "place_resto_4"],
            ]
        ),
        UserProfile(
            id: "user_sofia", name: "Sofia", email: "sofia@example.com",
            avatarURL: URL(string: "https://i.pravatar.cc/150?img=9"),
            friendIDs: ["user_paul"],
            lists: [
                "Tasting menus": ["place_resto_5", "place_resto_6"],
            ]
        ),
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

        // ─────────────────────────────────────────────────────────────
        //  FRIEND RESTAURANT LISTS — 10 real Amsterdam places
        // ─────────────────────────────────────────────────────────────
        // Each of the five demo friends owns two well-known Amsterdam
        // restaurants on a curated list. They surface on the map (any
        // Place with coords + ownerID renders as a friend-tinted pin
        // and flows into the AI chat's `friendPlaces` context tier) so
        // the assistant can answer "what would <friend> recommend?" /
        // "where for fine dining?" with grounded suggestions.
        //
        // Coordinates are approximate to the actual addresses (street-
        // level — close enough for the pin to drop on the right block).
        // Categories use `.food` for restaurants; `recommendedBy` +
        // `friendRatings` tell the AI whose taste it's representing.

        // — Emma · Fine dining
        Place(
            id: "place_resto_1", name: "Restaurant De Kas",
            category: .food, latitude: 52.3406, longitude: 4.9332,
            source: .friend, neighborhood: "Watergraafsmeer",
            recommendedBy: "user_emma", visitedByIDs: ["user_emma"],
            tags: ["Farm-to-table", "Greenhouse", "Tasting menu", "€€€"],
            friendRatings: ["user_emma": 9.0],
            ownerID: "user_emma"
        ),
        Place(
            id: "place_resto_2", name: "Bougainville",
            category: .food, latitude: 52.3729, longitude: 4.8919,
            source: .friend, neighborhood: "Centrum",
            recommendedBy: "user_emma", visitedByIDs: ["user_emma"],
            tags: ["Hotel restaurant", "French-Asian", "Date night", "€€€€"],
            friendRatings: ["user_emma": 8.8],
            ownerID: "user_emma"
        ),

        // — Lucas · Jordaan favourites
        Place(
            id: "place_resto_3", name: "Toscanini",
            category: .food, latitude: 52.3789, longitude: 4.8839,
            source: .friend, neighborhood: "Jordaan",
            recommendedBy: "user_lucas", visitedByIDs: ["user_lucas"],
            tags: ["Italian", "Open kitchen", "Classic", "€€€"],
            friendRatings: ["user_lucas": 8.9],
            ownerID: "user_lucas"
        ),
        Place(
            id: "place_resto_4", name: "Restaurant Daalder",
            category: .food, latitude: 52.3796, longitude: 4.8835,
            source: .friend, neighborhood: "Jordaan",
            recommendedBy: "user_lucas", visitedByIDs: ["user_lucas"],
            tags: ["Modern Dutch", "Tasting menu", "Michelin", "€€€€"],
            friendRatings: ["user_lucas": 9.1],
            ownerID: "user_lucas"
        ),

        // — Sofia · Tasting menus
        Place(
            id: "place_resto_5", name: "Choux",
            category: .food, latitude: 52.3842, longitude: 4.9038,
            source: .friend, neighborhood: "Centrum",
            recommendedBy: "user_sofia", visitedByIDs: ["user_sofia"],
            tags: ["Plant-forward", "Tasting menu", "Natural wine", "€€€"],
            friendRatings: ["user_sofia": 9.2],
            ownerID: "user_sofia"
        ),
        Place(
            id: "place_resto_6", name: "Bridges",
            category: .food, latitude: 52.3705, longitude: 4.8946,
            source: .friend, neighborhood: "Centrum",
            recommendedBy: "user_sofia", visitedByIDs: ["user_sofia"],
            tags: ["Seafood", "Michelin", "Hotel restaurant", "€€€€"],
            friendRatings: ["user_sofia": 8.7],
            ownerID: "user_sofia"
        ),

        // — Max · Michelin starred
        Place(
            id: "place_resto_7", name: "Yamazato",
            category: .food, latitude: 52.3458, longitude: 4.8954,
            source: .friend, neighborhood: "De Pijp",
            recommendedBy: "user_max", visitedByIDs: ["user_max"],
            tags: ["Japanese", "Kaiseki", "Michelin", "€€€€"],
            friendRatings: ["user_max": 9.3],
            ownerID: "user_max"
        ),
        Place(
            id: "place_resto_8", name: "Vinkeles",
            category: .food, latitude: 52.3691, longitude: 4.8845,
            source: .friend, neighborhood: "Negen Straatjes",
            recommendedBy: "user_max", visitedByIDs: ["user_max"],
            tags: ["French", "Michelin", "Tasting menu", "€€€€"],
            friendRatings: ["user_max": 9.0],
            ownerID: "user_max"
        ),

        // — Olivia · Hidden gems
        Place(
            id: "place_resto_9", name: "Wilde Zwijnen",
            category: .food, latitude: 52.3622, longitude: 4.9407,
            source: .friend, neighborhood: "Indische Buurt",
            recommendedBy: "user_olivia", visitedByIDs: ["user_olivia"],
            tags: ["Modern Dutch", "Seasonal", "Neighbourhood gem", "€€€"],
            friendRatings: ["user_olivia": 8.8],
            ownerID: "user_olivia"
        ),
        Place(
            id: "place_resto_10", name: "Restaurant Sinne",
            category: .food, latitude: 52.3525, longitude: 4.8967,
            source: .friend, neighborhood: "De Pijp",
            recommendedBy: "user_olivia", visitedByIDs: ["user_olivia"],
            tags: ["Modern European", "Bib Gourmand", "Date night", "€€€"],
            friendRatings: ["user_olivia": 8.9],
            ownerID: "user_olivia"
        ),
    ]
}
