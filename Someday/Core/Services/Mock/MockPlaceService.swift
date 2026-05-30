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
}
