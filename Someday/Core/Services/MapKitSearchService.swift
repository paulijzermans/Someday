import Foundation
import MapKit

final class MapKitSearchService: LocationSearchProtocol, @unchecked Sendable {
    func search(query: String, near coordinate: CLLocationCoordinate2D?) async throws -> [LocationSearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let coordinate {
            request.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 10_000,
                longitudinalMeters: 10_000
            )
        }

        let search = MKLocalSearch(request: request)
        let response = try await search.start()

        return response.mapItems.compactMap { item in
            guard let name = item.name, let location = item.placemark.location else { return nil }
            let address = [item.placemark.thoroughfare, item.placemark.locality]
                .compactMap { $0 }
                .joined(separator: ", ")
            let category = mapCategory(from: item.pointOfInterestCategory)

            return LocationSearchResult(
                name: name,
                address: address,
                coordinate: location.coordinate,
                category: category
            )
        }
    }

    private func mapCategory(from poi: MKPointOfInterestCategory?) -> PlaceCategory? {
        guard let poi else { return nil }
        switch poi {
        case .restaurant, .bakery: return .food
        case .cafe: return .coffee
        case .nightlife, .brewery, .winery: return .drinks
        case .museum, .theater: return .art
        case .park, .beach, .nationalPark: return .activity
        case .airport: return .travel
        default: return nil
        }
    }
}
