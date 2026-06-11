import Foundation

@Observable
final class ServiceContainer {
    let auth: AuthServiceProtocol
    let places: PlaceServiceProtocol
    let users: UserServiceProtocol
    let search: LocationSearchProtocol
    /// CRUD on the user's custom lists + their place memberships.
    /// Real path = `SupabaseListService`; demo = `MockListService`.
    let lists: ListServiceProtocol
    /// URL→[Place] extraction (the "import a link" pipeline). Backed by
    /// `ExtractionRouter`, which dispatches each call to either Pipeline 1
    /// (existing Supabase Edge Functions) or Pipeline 2 (Erik's Railway
    /// video extractor) based on the `ExtractionPipelineSelector` toggle.
    /// See `Core/Services/Extraction/URLExtractionService.swift` for the
    /// full module overview.
    let extraction: URLExtractionService
    /// AI-driven "where can I book this?" lookup. Backed by the
    /// `find-reservation-platforms` Supabase Edge Function with a mock
    /// fallback. See `Core/Services/Reservation/AvailabilityService.swift`.
    let availability: AvailabilityService
    /// Real-time "is there a table tonight?" lookup. Calls the
    /// `check-availability` Edge Function, which dispatches per-provider
    /// (Zenchef today). Falls back to a mock that returns plausible
    /// open/closed states based on category. See
    /// `Core/Services/Reservation/ReservationCheckService.swift`.
    let reservationCheck: ReservationCheckService
    /// Context-aware AI chatbot. Backed by the `chat` Edge Function with
    /// a keyword-matched mock fallback. See `Core/Services/Chat/ChatService.swift`.
    let chat: ChatService
    /// Persists a chat-built day plan (`create_itinerary`). Backed by
    /// `ItineraryRouter`; no live backend yet, so it runs on the mock
    /// fallback everywhere — drop a live service into its `live:` slot when
    /// an itinerary table / Edge Function lands. See `ChatService.swift`.
    let itinerary: ItineraryService
    /// Contacts permission + on-device contact hashing + Edge Function
    /// match. Drives the "find your loved ones on Someday" flow inside
    /// the onboarding tile. Real on Supabase stack, mock otherwise.
    let contacts: ContactsServiceProtocol

    static let mock: ServiceContainer = {
        let places = MockPlaceService()
        return ServiceContainer(
            auth: MockAuthService(),
            places: places,
            users: MockUserService(),
            search: MapKitSearchService(),
            lists: MockListService(),
            extraction: ExtractionRouter(
                pipeline1: Pipeline1Service(placeService: places),
                pipeline2: Pipeline2Service()
            ),
            availability: AvailabilityRouter(
                live: nil,
                fallback: MockAvailabilityService()
            ),
            reservationCheck: ReservationCheckRouter(
                live: nil,
                fallback: MockReservationCheckService()
            ),
            chat: ChatRouter(live: nil, fallback: MockChatService()),
            itinerary: ItineraryRouter(live: nil, fallback: MockItineraryService()),
            contacts: MockContactsService()
        )
    }()

    /// The live Supabase-backed stack. Only safe to construct when
    /// `SupabaseConfig.isConfigured` is true (a valid `Secrets.plist` is present).
    static let supabase: ServiceContainer = {
        let places = SupabasePlaceService()
        return ServiceContainer(
            auth: SupabaseAuthService(),
            places: places,
            users: SupabaseUserService(),
            search: MapKitSearchService(),
            lists: SupabaseListService(),
            extraction: ExtractionRouter(
                pipeline1: Pipeline1Service(placeService: places),
                pipeline2: Pipeline2Service()
            ),
            availability: AvailabilityRouter(
                // Live path = the Supabase Edge Function. Falls back to the
                // mock if the function isn't deployed yet or errors out, so
                // the UI flow stays functional during incremental rollout.
                live: SupabaseAvailabilityService(),
                fallback: MockAvailabilityService()
            ),
            reservationCheck: ReservationCheckRouter(
                // Live = `check-availability` Edge Function. Same fallback
                // pattern as Availability — mock keeps the UI working if
                // the function 500s or no provider adapter matches yet.
                live: SupabaseReservationCheckService(),
                fallback: MockReservationCheckService()
            ),
            chat: ChatRouter(
                // Edge Function `chat`. Falls back to keyword-matched mock
                // replies when the function isn't deployed yet.
                live: SupabaseChatService(),
                fallback: MockChatService()
            ),
            // No itinerary backend yet — live stays nil, so the router runs
            // on the mock. The chat agent's create_itinerary flow still
            // works end-to-end (plan is framed on the map); it just isn't
            // persisted server-side until a backing service lands.
            itinerary: ItineraryRouter(live: nil, fallback: MockItineraryService()),
            contacts: ContactsService()
        )
    }()

    /// Picks the live stack when credentials are present, otherwise the mock
    /// stack so the app keeps running (and previews work) without a backend.
    static var live: ServiceContainer {
        SupabaseConfig.isConfigured ? .supabase : .mock
    }

    init(
        auth: AuthServiceProtocol,
        places: PlaceServiceProtocol,
        users: UserServiceProtocol,
        search: LocationSearchProtocol,
        lists: ListServiceProtocol,
        extraction: URLExtractionService,
        availability: AvailabilityService,
        reservationCheck: ReservationCheckService,
        chat: ChatService,
        itinerary: ItineraryService,
        contacts: ContactsServiceProtocol
    ) {
        self.auth = auth
        self.places = places
        self.users = users
        self.search = search
        self.lists = lists
        self.extraction = extraction
        self.availability = availability
        self.reservationCheck = reservationCheck
        self.chat = chat
        self.itinerary = itinerary
        self.contacts = contacts
    }
}
