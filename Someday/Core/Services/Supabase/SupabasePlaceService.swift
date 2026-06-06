import Foundation
import CoreLocation
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

    // MARK: - Google Maps import (Edge Function)

    /// Calls the `parse-gmaps` Edge Function with a Google Maps share URL
    /// and maps its response into in-memory `Place` objects owned by the
    /// current user. Nothing is written to the DB at this stage — the
    /// caller previews the result and decides whether to import.
    func importFromGoogleMaps(url: String, ownerID: String) async throws -> [Place] {
        struct RequestBody: Encodable { let url: String }
        let response: ParseGmapsResponse = try await client.functions.invoke(
            "parse-gmaps",
            options: FunctionInvokeOptions(body: RequestBody(url: url))
        )
        // Top-level `sourceUrl` echoes back the input — every place from a
        // single import shares the same origin link, so we tag them all so
        // the source badge can tap-through to the actual post. Falls back
        // to the URL we passed in if the Edge Function didn't echo it.
        let origin = response.sourceUrl.flatMap(URL.init(string:)) ?? URL(string: url)
        return response.places.map { row in
            Place(
                name: row.name,
                category: PlaceCategory(rawValue: row.category) ?? .food,
                // Wire `kind` from the Edge Function so the iOS summary
                // tile can distinguish "this is a venue" from "this is
                // a country/region" rather than pretending the second
                // is a normal pin.
                kind: (row.kind == "region") ? .region : .venue,
                latitude: row.latitude,
                longitude: row.longitude,
                source: .googleMaps,
                neighborhood: row.address ?? "",
                isSaved: true,
                ownerID: ownerID,
                imageURL: row.imageUrl.flatMap(URL.init(string:)),
                sourceURL: origin
            )
        }
    }

    private struct ParseGmapsResponse: Decodable {
        let places: [ParsedPlace]
        let sourceUrl: String?
    }

    private struct ParsedPlace: Decodable {
        let name: String
        let address: String?
        let latitude: Double
        let longitude: Double
        let category: String
        let imageUrl: String?
        /// Optional — older function versions don't emit it. iOS
        /// defaults to `.venue` when absent.
        let kind: String?
    }

    // MARK: - Instagram import (Edge Function + on-device geocoding)

    /// Calls the `parse-instagram` Edge Function with a Reel / post URL,
    /// then resolves each returned place to a real coordinate using
    /// CLGeocoder. Places that can't be geocoded are dropped silently —
    /// better to surface fewer real pins than fake ones.
    func importFromInstagram(url: String, ownerID: String) async throws -> [Place] {
        struct RequestBody: Encodable { let url: String }
        let response: ParseInstagramResponse = try await client.functions.invoke(
            "parse-instagram",
            options: FunctionInvokeOptions(body: RequestBody(url: url))
        )

        // Geocode sequentially. CLGeocoder rate-limits aggressive concurrent
        // calls; for a Reel (usually 1–3 places) sequential is fine.
        //
        // Every place from this Reel keeps a reference to the original post
        // URL — used by the source badge in PlaceCardSheet to tap-through to
        // Instagram. Falls back to the URL we passed in if the Edge Function
        // didn't echo it back.
        let origin = response.sourceUrl.flatMap(URL.init(string:)) ?? URL(string: url)
        var resolved: [Place] = []
        for row in response.places {
            guard let coord = await Self.geocode(name: row.name, address: row.address) else {
                continue
            }
            resolved.append(
                Place(
                    name: row.name,
                    category: PlaceCategory(rawValue: row.category) ?? .food,
                    latitude: coord.latitude,
                    longitude: coord.longitude,
                    source: .instagram,
                    neighborhood: row.address,
                    isSaved: true,
                    ownerID: ownerID,
                    imageURL: row.imageUrl.flatMap(URL.init(string:)),
                    sourceURL: origin
                )
            )
        }
        return resolved
    }

    private struct ParseInstagramResponse: Decodable {
        let places: [InstagramPlace]
        let sourceUrl: String?
    }

    private struct InstagramPlace: Decodable {
        let name: String
        let address: String
        let category: String
        let imageUrl: String?
    }

    /// One-shot geocode helper. Searches for "<name>, <address>" first, then
    /// falls back to just the name if the joined query yields nothing.
    private static func geocode(name: String, address: String) async -> CLLocationCoordinate2D? {
        let queries = [
            address.isEmpty ? name : "\(name), \(address)",
            name
        ]
        let geocoder = CLGeocoder()
        for query in queries {
            if let placemarks = try? await geocoder.geocodeAddressString(query),
               let coord = placemarks.first?.location?.coordinate {
                return coord
            }
        }
        return nil
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
