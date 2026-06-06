import Foundation
import Supabase

// =============================================================================
// AvailabilityService — AI-driven "where can I book this place?" lookup
// =============================================================================
//
// Surface: a tap on the "Availability" CTA in PlaceCardSheet kicks off an
// async lookup. The service asks Claude (via the `find-reservation-platforms`
// Supabase Edge Function) which booking platforms support this specific
// venue — OpenTable, Resy, TheFork, the restaurant's own site, etc. — and
// returns a small list of options the user can tap to actually book.
//
// Architecture mirrors the extraction module:
//   • `AvailabilityService` is the protocol the app talks to.
//   • `SupabaseAvailabilityService` calls the Edge Function (live path).
//   • `MockAvailabilityService` returns plausible sample data so the UI
//      flow works offline / before the function is deployed.
//   • `AvailabilityRouter` picks live vs mock, owns the in-memory cache.
//
// Caching: results live in memory for the current session keyed by `placeID`.
// A re-tap on the same place returns instantly. Cleared on app launch.

protocol AvailabilityService: Sendable {
    /// Look up bookable platforms for the given place. May return an empty
    /// list (no online booking found) — the caller should still show the
    /// result and let the user decide what to do.
    func findPlatforms(for place: Place) async throws -> AvailabilityResult
}

// =============================================================================
// Wire types — what the iOS app shows, what the Edge Function returns
// =============================================================================

/// A single booking surface returned by the AI. `url` is the direct booking
/// page for this venue when the AI could find one; otherwise `nil` and the
/// UI just lists the platform name as a hint.
struct BookingPlatform: Codable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let url: URL?
    let note: String?

    init(name: String, url: URL? = nil, note: String? = nil) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.note = note
    }

    // Decoded from the Edge Function JSON. Wire shape has no `id`; we mint
    // one on decode so SwiftUI ForEach has stable identity.
    enum CodingKeys: String, CodingKey { case name, url, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.name = try c.decode(String.self, forKey: .name)
        if let raw = try? c.decode(String.self, forKey: .url), !raw.isEmpty {
            self.url = URL(string: raw)
        } else { self.url = nil }
        self.note = try? c.decode(String.self, forKey: .note)
    }
}

/// What the AI returns for a single place. `summary` is a one-line plain-
/// English explanation surfaced as the bar headline (e.g. "3 ways to book
/// this place"). `platforms` is the actionable list.
struct AvailabilityResult: Codable, Hashable {
    let summary: String
    let platforms: [BookingPlatform]
}

// =============================================================================
// Mock — sample data so the UI works offline
// =============================================================================

struct MockAvailabilityService: AvailabilityService {
    /// 1.2s feels like real AI work without being annoying. Tune up/down
    /// to taste — we're explicitly simulating latency so the loading
    /// state on the button is visible during development.
    private let simulatedLatency: Duration = .milliseconds(1200)

    func findPlatforms(for place: Place) async throws -> AvailabilityResult {
        try await Task.sleep(for: simulatedLatency)

        // Two-step classification:
        //   1) Name-based override — "Hotel Berlin", "Rijksmuseum" etc.
        //      should hit a more accurate path than the coarse category.
        //   2) Category fallback.
        // The result also makes the platform names land on a search-result
        // URL for THAT specific venue (e.g. opentable.com/s?term=Le+Petit)
        // instead of the bare homepage, so even the mock is half-useful
        // when the function isn't deployed.
        let kind = Self.classify(place)
        return Self.result(for: kind, place: place)
    }

    // MARK: - Classification

    private enum VenueKind {
        case restaurant
        case hotel
        case bar
        case cafe
        case museum
        case attraction
        case publicSpace
    }

    /// Coarse name + category heuristic. Mirrors what the Edge Function
    /// prompt asks Claude to do, just stupider — keyword matching on the
    /// venue name. Good enough for the demo / offline path.
    private static func classify(_ place: Place) -> VenueKind {
        let n = place.name.lowercased()
        let hotelWords  = ["hotel", "inn", "suites", "resort", "hostel", "b&b"]
        let museumWords = ["museum", "gallery", "galerij", "musée"]
        let tourWords   = ["tour", "cruise", "experience"]

        if hotelWords.contains(where: n.contains)  { return .hotel }
        if museumWords.contains(where: n.contains) { return .museum }
        if tourWords.contains(where: n.contains)   { return .attraction }

        switch place.category {
        case .food:     return .restaurant
        case .drinks:   return .bar
        case .coffee:   return .cafe
        case .art:      return .museum
        case .activity: return .attraction
        case .travel:   return .hotel    // travel + no name hit → most likely a hotel
        }
    }

    // MARK: - Per-kind canned responses

    private static func result(for kind: VenueKind, place: Place) -> AvailabilityResult {
        // Build search-result URLs for the venue name so taps land on
        // SOMETHING relevant even in mock mode.
        let q = place.name
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? place.name

        switch kind {
        case .restaurant:
            return AvailabilityResult(
                summary: "3 ways to book \(place.name)",
                platforms: [
                    BookingPlatform(
                        name: "OpenTable",
                        url: URL(string: "https://www.opentable.com/s?term=\(q)"),
                        note: "Up to 30 days out"
                    ),
                    BookingPlatform(
                        name: "TheFork",
                        url: URL(string: "https://www.thefork.com/search/?cityName=\(q)"),
                        note: "Same-day availability often"
                    ),
                    BookingPlatform(
                        name: "Resy",
                        url: URL(string: "https://resy.com/search?query=\(q)"),
                        note: nil
                    ),
                ]
            )

        case .hotel:
            return AvailabilityResult(
                summary: "Book a stay at \(place.name)",
                platforms: [
                    BookingPlatform(
                        name: "Booking.com",
                        url: URL(string: "https://www.booking.com/searchresults.html?ss=\(q)"),
                        note: "Free cancellation often available"
                    ),
                    BookingPlatform(
                        name: "Hotels.com",
                        url: URL(string: "https://www.hotels.com/search.do?q-destination=\(q)"),
                        note: nil
                    ),
                    BookingPlatform(
                        name: "Expedia",
                        url: URL(string: "https://www.expedia.com/Hotel-Search?destination=\(q)"),
                        note: "Bundle with flights for savings"
                    ),
                    BookingPlatform(
                        name: "Book direct",
                        url: nil,
                        note: "Often best rate on the hotel's own site"
                    ),
                ]
            )

        case .bar:
            return AvailabilityResult(
                summary: "Most bars take walk-ins",
                platforms: [
                    BookingPlatform(
                        name: "Resy",
                        url: URL(string: "https://resy.com/search?query=\(q)"),
                        note: "Cocktail bars sometimes take reservations"
                    ),
                    BookingPlatform(
                        name: "Walk-in",
                        url: nil,
                        note: "Early evening is the easy window"
                    ),
                ]
            )

        case .cafe:
            return AvailabilityResult(
                summary: "\(place.name) is walk-in only",
                platforms: [
                    BookingPlatform(
                        name: "No reservations needed",
                        url: nil,
                        note: "Busiest 9–11am on weekends"
                    ),
                ]
            )

        case .museum:
            return AvailabilityResult(
                summary: "Get tickets for \(place.name)",
                platforms: [
                    BookingPlatform(
                        name: "Tiqets",
                        url: URL(string: "https://www.tiqets.com/en/search?q=\(q)"),
                        note: "Often includes skip-the-line"
                    ),
                    BookingPlatform(
                        name: "GetYourGuide",
                        url: URL(string: "https://www.getyourguide.com/s/?q=\(q)"),
                        note: nil
                    ),
                    BookingPlatform(
                        name: "Official site",
                        url: nil,
                        note: "Cheapest if you only need entry"
                    ),
                ]
            )

        case .attraction:
            return AvailabilityResult(
                summary: "Book \(place.name)",
                platforms: [
                    BookingPlatform(
                        name: "GetYourGuide",
                        url: URL(string: "https://www.getyourguide.com/s/?q=\(q)"),
                        note: "Free cancellation up to 24h"
                    ),
                    BookingPlatform(
                        name: "Viator",
                        url: URL(string: "https://www.viator.com/searchResults/all?text=\(q)"),
                        note: nil
                    ),
                ]
            )

        case .publicSpace:
            return AvailabilityResult(
                summary: "\(place.name) is open to the public",
                platforms: [
                    BookingPlatform(
                        name: "No booking needed",
                        url: nil,
                        note: "Free entry"
                    ),
                ]
            )
        }
    }
}

// =============================================================================
// Supabase — calls the `find-reservation-platforms` Edge Function
// =============================================================================

struct SupabaseAvailabilityService: AvailabilityService {
    let client: SupabaseClient

    init() {
        self.client = SupabaseClientProvider.shared
    }

    func findPlatforms(for place: Place) async throws -> AvailabilityResult {
        // The Edge Function takes name + address + category and returns the
        // AvailabilityResult shape directly — see
        // `supabase/functions/find-reservation-platforms/index.ts`.
        struct RequestBody: Encodable {
            let name: String
            let address: String
            let category: String
            let latitude: Double
            let longitude: Double
        }
        let body = RequestBody(
            name: place.name,
            address: place.neighborhood,
            category: place.category.rawValue,
            latitude: place.latitude,
            longitude: place.longitude
        )
        let response: AvailabilityResult = try await client.functions.invoke(
            "find-reservation-platforms",
            options: FunctionInvokeOptions(body: body)
        )
        return response
    }
}

// =============================================================================
// Router — picks live vs mock + in-memory cache
// =============================================================================
//
// In-memory cache is per service instance, scoped to the app session. A
// dictionary keyed by place.id; mock and live results coexist (they're the
// same shape). Thread-safety via an actor so concurrent taps from the UI
// can't race.

actor AvailabilityRouter: AvailabilityService {
    private let live: AvailabilityService?
    private let fallback: AvailabilityService
    private var cache: [String: AvailabilityResult] = [:]

    init(live: AvailabilityService?, fallback: AvailabilityService) {
        self.live = live
        self.fallback = fallback
    }

    func findPlatforms(for place: Place) async throws -> AvailabilityResult {
        if let cached = cache[place.id] {
            return cached
        }
        let service = live ?? fallback
        let result: AvailabilityResult
        do {
            result = try await service.findPlatforms(for: place)
        } catch {
            // Live path failed (function not deployed, rate limit, etc.) —
            // fall back to mock so the user still gets a usable result.
            // Devs see the misconfiguration in Xcode logs.
            #if DEBUG
            print("[AvailabilityRouter] live lookup failed: \(error) — falling back to mock")
            #endif
            result = try await fallback.findPlatforms(for: place)
        }
        cache[place.id] = result
        return result
    }
}
