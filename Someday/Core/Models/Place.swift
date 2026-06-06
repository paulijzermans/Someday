import Foundation
import CoreLocation

struct Place: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var category: PlaceCategory
    /// What kind of geographic thing this is.
    ///   • `.venue`  — a single bookable / visitable place (default).
    ///   • `.region` — a country, city, or area returned by an import
    ///                  whose coordinates aren't a real venue. Surfaced
    ///                  by `ImportSummaryCardView` with a "this is not
    ///                  a single place" notice rather than treated as a
    ///                  real pin to drop on the map.
    var kind: PlaceKind = .venue
    var latitude: Double
    var longitude: Double
    var source: PlaceSource
    var neighborhood: String
    var recommendedBy: String?
    var visitedByIDs: [String]
    var tags: [String]
    var isSaved: Bool
    var review: Review?
    var friendRatings: [String: Double]
    var createdAt: Date
    var ownerID: String
    /// Thumbnail URL surfaced by an import source (Google Maps photo,
    /// Instagram Reel cover). Nullable for places added manually or
    /// before this field was introduced.
    var imageURL: URL?
    /// Original post URL the place was imported from — the Instagram
    /// Reel / TikTok / Google Maps share link. Used by `PlaceCardSheet`
    /// to make the source badge tap-through to the actual post.
    /// Nil for manually-added places. Currently in-memory only; persists
    /// across an import session but not across app launches until we add
    /// a `source_url` column on the Supabase `place` table.
    var sourceURL: URL?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Rating to display on the map pin, plus the rater (nil = current user).
    var displayedRating: (value: Double, raterID: String?)? {
        if let r = review { return (r.overall, nil) }
        if let rid = recommendedBy, let r = friendRatings[rid] { return (r, rid) }
        if let first = friendRatings.first { return (first.value, first.key) }
        return nil
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        category: PlaceCategory,
        kind: PlaceKind = .venue,
        latitude: Double,
        longitude: Double,
        source: PlaceSource = .manual,
        neighborhood: String = "",
        recommendedBy: String? = nil,
        visitedByIDs: [String] = [],
        tags: [String] = [],
        isSaved: Bool = false,
        review: Review? = nil,
        friendRatings: [String: Double] = [:],
        createdAt: Date = .now,
        ownerID: String = "",
        imageURL: URL? = nil,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.kind = kind
        self.latitude = latitude
        self.longitude = longitude
        self.source = source
        self.neighborhood = neighborhood
        self.recommendedBy = recommendedBy
        self.visitedByIDs = visitedByIDs
        self.tags = tags
        self.isSaved = isSaved
        self.review = review
        self.friendRatings = friendRatings
        self.createdAt = createdAt
        self.ownerID = ownerID
        self.imageURL = imageURL
        self.sourceURL = sourceURL
    }
}

/// Whether a Place is a real bookable venue or a coarse region (country,
/// city, etc.) that the import system couldn't narrow to a single venue.
/// Region kinds get surfaced via the "this is not a single place" tile
/// rather than dropped as pins on the map.
enum PlaceKind: String, Codable, Hashable {
    case venue
    case region
}

enum PlaceCategory: String, Codable, CaseIterable, Hashable {
    case food, drinks, coffee, activity, art, travel

    var displayName: String {
        rawValue.capitalized
    }

    var icon: String {
        switch self {
        case .food: return "fork.knife"
        case .drinks: return "wineglass"
        case .coffee: return "cup.and.saucer"
        case .activity: return "figure.hiking"
        case .art: return "paintpalette"
        case .travel: return "airplane"
        }
    }

    var systemImage: String { icon }
}

enum PlaceSource: String, Codable, Hashable {
    case manual, instagram, facebook, tiktok, googleMaps, friend

    var label: String {
        switch self {
        case .manual: return "Added manually"
        case .instagram: return "from Instagram"
        case .facebook: return "from Facebook"
        case .tiktok: return "from TikTok"
        case .googleMaps: return "from Google Maps"
        case .friend: return "from a friend"
        }
    }

    var icon: String {
        switch self {
        case .manual: return "mappin"
        case .instagram: return "camera.fill"
        case .facebook: return "f.cursive"
        case .tiktok: return "music.note"
        case .googleMaps: return "map.fill"
        case .friend: return "person.fill"
        }
    }
}

struct Review: Codable, Hashable {
    var price: Double
    var quality: Double
    var service: Double
    var comment: String

    var overall: Double {
        (price + quality + service) / 3
    }

    var overallFormatted: String {
        let rounded = (overall * 10).rounded() / 10
        if rounded == floor(rounded) {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }
}
