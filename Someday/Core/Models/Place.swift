import Foundation
import CoreLocation

struct Place: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var category: PlaceCategory
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
        ownerID: String = ""
    ) {
        self.id = id
        self.name = name
        self.category = category
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
    }
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
