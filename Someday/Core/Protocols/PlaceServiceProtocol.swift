import Foundation

protocol PlaceServiceProtocol: Sendable {
    func fetchPlaces(for userID: String) async throws -> [Place]
    func savePlace(_ place: Place) async throws
    func updatePlace(_ place: Place) async throws
    func deletePlace(_ placeID: String) async throws
    func toggleSaved(placeID: String, userID: String) async throws -> Bool
}
