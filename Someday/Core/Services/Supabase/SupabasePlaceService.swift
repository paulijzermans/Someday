import Foundation
import Supabase

/// Live place storage backed by Postgres via PostgREST.
///
/// Row-Level Security scopes every query: `fetchPlaces` returns the caller's own
/// places plus those owned by friends, so we don't filter by owner here — the DB
/// does it. Reviews live in a separate table and are stitched back onto each
/// place: the owner's own review becomes `review`, everyone else's overall score
/// feeds `friendRatings`.
final class SupabasePlaceService: PlaceServiceProtocol, @unchecked Sendable {
    private let client: SupabaseClient

    init(client: SupabaseClient = SupabaseClientProvider.shared) {
        self.client = client
    }

    func fetchPlaces(for userID: String) async throws -> [Place] {
        let placeRows: [PlaceRow] = try await client
            .from("places")
            .select()
            .execute()
            .value

        guard !placeRows.isEmpty else { return [] }

        let reviewRows: [ReviewRow] = try await client
            .from("reviews")
            .select()
            .execute()
            .value

        let reviewsByPlace = Dictionary(grouping: reviewRows, by: \.place_id)

        return placeRows.map { row in
            let reviews = reviewsByPlace[row.id] ?? []
            let ownReview = reviews.first { $0.author_id == row.owner_id }?.toReview()
            var ratings: [String: Double] = [:]
            for r in reviews where r.author_id != row.owner_id {
                ratings[r.author_id] = r.overall ?? ((r.price + r.quality + r.service) / 3)
            }
            return row.toModel(review: ownReview, friendRatings: ratings)
        }
    }

    func savePlace(_ place: Place) async throws {
        try await client
            .from("places")
            .insert(PlaceRow.payload(from: place))
            .execute()

        if let review = place.review {
            try await client
                .from("reviews")
                .upsert(ReviewRow.payload(placeID: place.id, authorID: place.ownerID, review: review))
                .execute()
        }
    }

    func updatePlace(_ place: Place) async throws {
        try await client
            .from("places")
            .update(PlaceRow.payload(from: place))
            .eq("id", value: place.id)
            .execute()

        if let review = place.review {
            try await client
                .from("reviews")
                .upsert(ReviewRow.payload(placeID: place.id, authorID: place.ownerID, review: review))
                .execute()
        }
    }

    func deletePlace(_ placeID: String) async throws {
        try await client
            .from("places")
            .delete()
            .eq("id", value: placeID)
            .execute()
    }

    func toggleSaved(placeID: String, userID: String) async throws -> Bool {
        // Read the current flag, flip it, write it back.
        let rows: [PlaceRow] = try await client
            .from("places")
            .select("id,is_saved,owner_id,name,category,latitude,longitude,source,neighborhood,recommended_by,visited_by_ids,tags,created_at")
            .eq("id", value: placeID)
            .limit(1)
            .execute()
            .value

        let current = rows.first?.is_saved ?? false
        let newState = !current

        try await client
            .from("places")
            .update(["is_saved": newState])
            .eq("id", value: placeID)
            .execute()

        return newState
    }
}
