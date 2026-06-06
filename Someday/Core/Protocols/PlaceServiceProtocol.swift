import Foundation

protocol PlaceServiceProtocol: Sendable {
    func fetchPlaces(for userID: String) async throws -> [Place]
    func savePlace(_ place: Place) async throws
    func updatePlace(_ place: Place) async throws
    func deletePlace(_ placeID: String) async throws
    func toggleSaved(placeID: String, userID: String) async throws -> Bool

    /// Parse a Google Maps URL into Place objects via the `parse-gmaps`
    /// Edge Function. Returned places are **not yet persisted** — the
    /// caller decides whether to import them.
    func importFromGoogleMaps(url: String, ownerID: String) async throws -> [Place]

    /// Parse an Instagram Reel / post URL into Place objects via the
    /// `parse-instagram` Edge Function. The function returns name + address;
    /// the implementation geocodes each on-device so callers always get
    /// fully-coordinated places ready for the map.
    func importFromInstagram(url: String, ownerID: String) async throws -> [Place]
}
