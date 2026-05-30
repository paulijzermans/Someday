import SwiftUI
import MapKit

@Observable
final class MapViewModel {
    var places: [Place] = []
    var friends: [UserProfile] = []
    var selectedPlace: Place?
    var searchText = ""
    var searchResults: [LocationSearchResult] = []
    var isSearching = false
    var isLoading = false
    var showSavedToast = false
    var showAddOptions = false
    var showFriends = false
    var showActivity = false
    var showReservation = false
    var showSearch = true
    var showShareSheet = false
    var showImportList = false
    var filteredFriendID: String?
    var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.3676, longitude: 4.8900),
        span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
    )

    private let placeService: PlaceServiceProtocol
    private let userService: UserServiceProtocol
    private let searchService: LocationSearchProtocol
    private let userID: String

    init(services: ServiceContainer, userID: String) {
        self.placeService = services.places
        self.userService = services.users
        self.searchService = services.search
        self.userID = userID
    }

    @MainActor
    func loadData() async {
        isLoading = true
        defer { isLoading = false }

        async let fetchedPlaces = placeService.fetchPlaces(for: userID)
        async let fetchedFriends = userService.fetchFriends(for: userID)

        do {
            places = try await fetchedPlaces
            friends = try await fetchedFriends
        } catch {
            // Gracefully handle — keep existing data
        }

        // (toast suppressed for demo screenshot)
        // DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        //     withAnimation(.spring(response: 0.5)) {
        //         self.showSavedToast = true
        //     }
        // }
    }

    @MainActor
    func search() async {
        guard searchText.count >= 2 else {
            searchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        let center = region.center
        do {
            searchResults = try await searchService.search(query: searchText, near: center)
        } catch {
            searchResults = []
        }
    }

    @MainActor
    func addPlace(from result: LocationSearchResult) async {
        let place = Place(
            name: result.name,
            category: result.category ?? .food,
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude,
            source: .manual,
            neighborhood: result.address,
            isSaved: true,
            ownerID: userID
        )

        do {
            try await placeService.savePlace(place)
            places.append(place)
            searchText = ""
            searchResults = []
            showSearch = false
        } catch {
            // Handle error
        }
    }

    @MainActor
    func toggleSaved(_ place: Place) async {
        do {
            let newState = try await placeService.toggleSaved(placeID: place.id, userID: userID)
            if let index = places.firstIndex(where: { $0.id == place.id }) {
                places[index].isSaved = newState
            }
        } catch {
            // Handle error
        }
    }

    func selectPlace(_ place: Place) {
        withAnimation(.spring(response: 0.35)) {
            selectedPlace = place
        }
    }

    func dismissPlace() {
        withAnimation(.spring(response: 0.35)) {
            selectedPlace = nil
        }
    }

    func dismissToast() {
        withAnimation(.spring(response: 0.35)) {
            showSavedToast = false
        }
    }

    var filteredFriend: UserProfile? {
        guard let id = filteredFriendID else { return nil }
        return friends.first { $0.id == id }
    }

    var visiblePlaces: [Place] {
        guard let friendID = filteredFriendID else { return places }
        return places.filter { $0.visitedByIDs.contains(friendID) || $0.recommendedBy == friendID }
    }

    func showFriendPlaces(friendID: String) {
        withAnimation(.spring(response: 0.4)) {
            filteredFriendID = friendID
            showFriends = false
        }

        let friendPlaces = places.filter { $0.visitedByIDs.contains(friendID) || $0.recommendedBy == friendID }
        guard !friendPlaces.isEmpty else { return }

        let lats = friendPlaces.map(\.latitude)
        let lons = friendPlaces.map(\.longitude)
        let centerLat = (lats.min()! + lats.max()!) / 2
        let centerLon = (lons.min()! + lons.max()!) / 2
        let spanLat = max((lats.max()! - lats.min()!) * 1.5, 0.01)
        let spanLon = max((lons.max()! - lons.min()!) * 1.5, 0.01)

        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )
    }

    func clearFriendFilter() {
        withAnimation(.spring(response: 0.35)) {
            filteredFriendID = nil
        }
    }

    static let amsterdamOverview = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.3676, longitude: 4.8900),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )

    func zoomToOverview() {
        region = Self.amsterdamOverview
    }

    @MainActor
    func importPlaces(_ newPlaces: [Place]) async {
        let existingIDs = Set(places.map(\.id))
        let toAdd = newPlaces.filter { !existingIDs.contains($0.id) }
        guard !toAdd.isEmpty else { return }

        // Clear any active friend filter so the new pins are visible.
        filteredFriendID = nil

        // Wait briefly so the import sheet finishes dismissing before we touch the map.
        try? await Task.sleep(nanoseconds: 450_000_000)

        // Frame the camera to fit the incoming places.
        let lats = toAdd.map(\.latitude)
        let lons = toAdd.map(\.longitude)
        let centerLat = (lats.min()! + lats.max()!) / 2
        let centerLon = (lons.min()! + lons.max()!) / 2
        let spanLat = max((lats.max()! - lats.min()!) * 1.7, 0.02)
        let spanLon = max((lons.max()! - lons.min()!) * 1.7, 0.02)
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
        )

        // Slight wait so the camera settles before pins arrive.
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Stagger each place in.
        for place in toAdd {
            places.append(place)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    var shareText: String {
        let saved = places.filter(\.isSaved)
        guard !saved.isEmpty else { return "My Someday list is empty — time to explore!" }

        let grouped = Dictionary(grouping: saved) { $0.category }
        var lines = ["My Someday List", ""]
        for category in PlaceCategory.allCases {
            guard let items = grouped[category], !items.isEmpty else { continue }
            lines.append("\(category.displayName)")
            for item in items {
                let location = item.neighborhood.isEmpty ? "" : " — \(item.neighborhood)"
                lines.append("  \(item.name)\(location)")
            }
            lines.append("")
        }
        lines.append("Shared from Someday")
        return lines.joined(separator: "\n")
    }

    func friendProfile(for id: String) -> UserProfile? {
        friends.first { $0.id == id }
    }

    var activityFeed: [ActivityFeedEvent] {
        ActivityFeedBuilder.build(friends: friends, places: places)
    }
}
