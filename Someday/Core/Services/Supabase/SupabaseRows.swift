import Foundation

// ============================================================================
// Row DTOs — Codable mirrors of the Postgres tables in supabase/schema.sql.
//
// These intentionally have NO dependency on the Supabase SDK so they compile
// today and can be unit-tested. The live services (added once the Supabase
// Swift package is installed) decode/encode these and convert to/from the
// domain models in Core/Models.
//
// Postgres returns snake_case columns and ISO-8601 timestamp strings, hence the
// CodingKeys + string dates parsed via `SupabaseDate`.
// ============================================================================

/// ISO-8601 parsing that tolerates Postgres timestamps with or without
/// fractional seconds (e.g. "2026-05-29T12:00:00.123456+00:00").
enum SupabaseDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String?) -> Date {
        guard let string else { return .now }
        return withFraction.date(from: string) ?? plain.date(from: string) ?? .now
    }

    static func string(_ date: Date) -> String {
        withFraction.string(from: date)
    }
}

// MARK: - profiles

struct ProfileRow: Codable {
    let id: String
    var name: String
    var email: String
    var avatar_url: String?
    var created_at: String?

    /// Build the domain model. Friend IDs and lists live in separate tables,
    /// so the service passes them in after their own fetches.
    func toModel(friendIDs: [String] = [], lists: [String: [String]] = [:]) -> UserProfile {
        UserProfile(
            id: id,
            name: name,
            email: email,
            avatarURL: avatar_url.flatMap(URL.init(string:)),
            friendIDs: friendIDs,
            lists: lists,
            createdAt: SupabaseDate.parse(created_at)
        )
    }

    /// Payload for inserting/upserting the current user's own profile.
    static func upsertPayload(from user: UserProfile) -> ProfileRow {
        ProfileRow(
            id: user.id,
            name: user.name,
            email: user.email,
            avatar_url: user.avatarURL?.absoluteString,
            created_at: nil // let the DB default stand
        )
    }
}

// MARK: - places

struct PlaceRow: Codable {
    let id: String
    var owner_id: String
    var name: String
    var category: String
    var latitude: Double
    var longitude: Double
    var source: String
    var neighborhood: String
    var recommended_by: String?
    var visited_by_ids: [String]
    var tags: [String]
    var is_saved: Bool
    var created_at: String?

    /// Reviews/friendRatings are assembled from the `reviews` table and injected.
    func toModel(review: Review? = nil, friendRatings: [String: Double] = [:]) -> Place {
        Place(
            id: id,
            name: name,
            category: PlaceCategory(rawValue: category) ?? .food,
            latitude: latitude,
            longitude: longitude,
            source: PlaceSource(rawValue: source) ?? .manual,
            neighborhood: neighborhood,
            recommendedBy: recommended_by,
            visitedByIDs: visited_by_ids,
            tags: tags,
            isSaved: is_saved,
            review: review,
            friendRatings: friendRatings,
            createdAt: SupabaseDate.parse(created_at),
            ownerID: owner_id
        )
    }

    static func payload(from place: Place) -> PlaceRow {
        PlaceRow(
            id: place.id,
            owner_id: place.ownerID,
            name: place.name,
            category: place.category.rawValue,
            latitude: place.latitude,
            longitude: place.longitude,
            source: place.source.rawValue,
            neighborhood: place.neighborhood,
            recommended_by: place.recommendedBy,
            visited_by_ids: place.visitedByIDs,
            tags: place.tags,
            is_saved: place.isSaved,
            created_at: nil
        )
    }
}

// MARK: - reviews

struct ReviewRow: Codable {
    var place_id: String
    var author_id: String
    var price: Double
    var quality: Double
    var service: Double
    var comment: String
    var overall: Double?      // generated column — read-only
    var created_at: String?

    func toReview() -> Review {
        Review(price: price, quality: quality, service: service, comment: comment)
    }

    static func payload(placeID: String, authorID: String, review: Review) -> ReviewRow {
        ReviewRow(
            place_id: placeID,
            author_id: authorID,
            price: review.price,
            quality: review.quality,
            service: review.service,
            comment: review.comment,
            overall: nil,
            created_at: nil
        )
    }
}

// MARK: - friendships

struct FriendshipRow: Codable {
    var user_id: String
    var friend_id: String
    var created_at: String?
}

// MARK: - lists

struct ListRow: Codable {
    let id: String
    var owner_id: String
    var name: String
    var created_at: String?
}

struct ListPlaceRow: Codable {
    var list_id: String
    var place_id: String
    var position: Int
}
