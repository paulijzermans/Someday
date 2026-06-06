import Foundation

actor MockPlaceService: PlaceServiceProtocol {
    private var places: [Place] = SampleData.places

    func fetchPlaces(for userID: String) async throws -> [Place] {
        try await Task.sleep(for: .milliseconds(300))
        return places
    }

    func savePlace(_ place: Place) async throws {
        places.append(place)
    }

    func updatePlace(_ place: Place) async throws {
        guard let index = places.firstIndex(where: { $0.id == place.id }) else { return }
        places[index] = place
    }

    func deletePlace(_ placeID: String) async throws {
        places.removeAll { $0.id == placeID }
    }

    func toggleSaved(placeID: String, userID: String) async throws -> Bool {
        guard let index = places.firstIndex(where: { $0.id == placeID }) else { return false }
        places[index].isSaved.toggle()
        return places[index].isSaved
    }

    func importFromGoogleMaps(url: String, ownerID: String) async throws -> [Place] {
        // Demo mode has no backend — return a couple of mock places so the
        // UI flow can still be exercised offline. Stamp the input URL onto
        // each so the source badge in PlaceCardSheet can tap-through back
        // to the originating Google Maps link (matches live behaviour).
        try await Task.sleep(for: .milliseconds(800))
        let origin = URL(string: url)
        return Array(SampleData.places.prefix(3)).map { place in
            var copy = place
            copy.source = .googleMaps
            copy.sourceURL = origin
            return copy
        }
    }

    func importFromInstagram(url: String, ownerID: String) async throws -> [Place] {
        try await Task.sleep(for: .milliseconds(800))
        let origin = URL(string: url)
        return Array(SampleData.places.prefix(2)).map { place in
            var copy = place
            copy.source = .instagram
            copy.sourceURL = origin
            return copy
        }
    }
}
