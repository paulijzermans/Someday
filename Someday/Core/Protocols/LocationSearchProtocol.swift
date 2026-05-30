import Foundation
import MapKit

struct LocationSearchResult: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
    let category: PlaceCategory?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LocationSearchResult, rhs: LocationSearchResult) -> Bool {
        lhs.id == rhs.id
    }
}

protocol LocationSearchProtocol: Sendable {
    func search(query: String, near coordinate: CLLocationCoordinate2D?) async throws -> [LocationSearchResult]
}
