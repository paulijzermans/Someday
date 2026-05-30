import Foundation

@Observable
final class ServiceContainer {
    let auth: AuthServiceProtocol
    let places: PlaceServiceProtocol
    let users: UserServiceProtocol
    let search: LocationSearchProtocol

    static let mock = ServiceContainer(
        auth: MockAuthService(),
        places: MockPlaceService(),
        users: MockUserService(),
        search: MapKitSearchService()
    )

    /// The live Supabase-backed stack. Only safe to construct when
    /// `SupabaseConfig.isConfigured` is true (a valid `Secrets.plist` is present).
    static let supabase = ServiceContainer(
        auth: SupabaseAuthService(),
        places: SupabasePlaceService(),
        users: SupabaseUserService(),
        search: MapKitSearchService()
    )

    /// Picks the live stack when credentials are present, otherwise the mock
    /// stack so the app keeps running (and previews work) without a backend.
    static var live: ServiceContainer {
        SupabaseConfig.isConfigured ? .supabase : .mock
    }

    init(
        auth: AuthServiceProtocol,
        places: PlaceServiceProtocol,
        users: UserServiceProtocol,
        search: LocationSearchProtocol
    ) {
        self.auth = auth
        self.places = places
        self.users = users
        self.search = search
    }
}
