import Foundation
import Supabase

// =============================================================================
// ReservationCheckService — "is there a table tonight?"
// =============================================================================
//
// Lives next to `AvailabilityService` (which does the AI "where can I book
// this?" lookup). This service answers a different, narrower question:
// for a venue we ALREADY know how to book on, does that platform have
// availability for the requested date + party size?
//
// Hits the `check-availability` Supabase Edge Function. That function
// reads `availability_cache.provider_ids` (populated by the previous AI
// step) and dispatches to a per-provider adapter — Zenchef today, more
// coming. No AI cost on this path; sub-second when the provider answers.
//
// Possible outcomes (mirrors the Edge Function's `status` field):
//   • .open(shifts, bookingURL)  → at least one shift accepts the party size
//   • .closed(bookingURL)        → provider knows the venue but no table
//   • .unknown                   → no adapter / no provider ID. Caller
//                                  should fall back to the platform list
//                                  from `find-reservation-platforms`.
//   • .error                     → provider call failed; treat like unknown.

protocol ReservationCheckService: Sendable {
    /// Ask the backend whether the venue has availability for `date` +
    /// `partySize`. `date` is venue-local — we don't convert timezones,
    /// the user picks "tonight" relative to where they are.
    func check(
        place: Place,
        date: Date,
        partySize: Int
    ) async throws -> AvailabilityCheck
}

// =============================================================================
// Wire types — exact mirror of `check-availability/index.ts` response shape
// =============================================================================

/// Outcome of a real-time availability check. The Edge Function returns
/// a JSON `{ status: "open" | "closed" | "unknown" | "error", ... }` —
/// we map it into a Swift enum so the UI can switch exhaustively on it.
enum AvailabilityCheck: Equatable {
    case open(shifts: [Shift], bookingURL: URL?, provider: String)
    case closed(bookingURL: URL?, provider: String)
    case unknown
    case error

    /// One bookable window in the venue's day — lunch, dinner, brunch,
    /// etc. The Zenchef adapter populates this from `shifts[]`; other
    /// adapters fill in what their provider returns.
    struct Shift: Equatable, Hashable {
        let name: String
        /// Last moment a booking is accepted for this shift, when the
        /// provider returns one. Surfaced as "book by 22:30" hints.
        let bookableUntil: Date?
    }

    /// Convenience flag used by the UI to colour the pill green vs grey
    /// without unwrapping the associated values.
    var isBookable: Bool {
        if case .open = self { return true }
        return false
    }
}

// =============================================================================
// Wire decode — handles the JSON shape from the Edge Function
// =============================================================================

/// Raw JSON shape — decoded then mapped to `AvailabilityCheck` so the
/// rest of the app never sees a stringly-typed status.
private struct CheckWireResponse: Decodable {
    let status: String
    let provider: String
    let shifts: [WireShift]
    let bookingURL: String?
    let date: String
    let partySize: Int

    struct WireShift: Decodable {
        let name: String
        let bookableUntil: String?
    }

    enum CodingKeys: String, CodingKey {
        case status, provider, shifts, bookingURL, date, partySize
    }
}

// =============================================================================
// Mock — plausible data so the UI works offline
// =============================================================================

struct MockReservationCheckService: ReservationCheckService {
    /// 800ms — slightly faster than the AI lookup since the live path
    /// usually answers in ~400ms (single provider HTTP call, no LLM).
    private let simulatedLatency: Duration = .milliseconds(800)

    func check(
        place: Place,
        date: Date,
        partySize: Int
    ) async throws -> AvailabilityCheck {
        try await Task.sleep(for: simulatedLatency)

        // Coarse heuristic that mirrors the mock platform classifier:
        // restaurants get open/closed on alternating days, hotels are
        // always "open" (rooms are bigger inventory), bars are
        // "unknown" (rarely take reservations), etc. Keeps the demo
        // experience varied without needing the backend.
        let isWeekend = Calendar.current.component(.weekday, from: date)
            >= 6
        switch place.category {
        case .food:
            return isWeekend
                ? .closed(bookingURL: nil, provider: "mock")
                : .open(
                    shifts: [.init(name: "Dinner", bookableUntil: nil)],
                    bookingURL: nil,
                    provider: "mock"
                )
        case .travel:
            return .open(
                shifts: [.init(name: "Stay", bookableUntil: nil)],
                bookingURL: nil,
                provider: "mock"
            )
        case .drinks, .coffee:
            return .unknown
        case .art, .activity:
            return .open(
                shifts: [.init(name: "Today", bookableUntil: nil)],
                bookingURL: nil,
                provider: "mock"
            )
        }
    }
}

// =============================================================================
// Supabase — calls the `check-availability` Edge Function
// =============================================================================

struct SupabaseReservationCheckService: ReservationCheckService {
    let client: SupabaseClient

    /// Date format the Edge Function expects in the request body —
    /// YYYY-MM-DD in venue-local time. We DON'T convert timezones; the
    /// user's "tonight" is whatever their device says today is.
    private static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    /// Parses `bookableUntil` from the response. Zenchef returns
    /// `"2026-06-11 22:30:00"` (no timezone, venue-local). Tolerant
    /// of an ISO-with-T form too in case other providers differ.
    private static let bookableUntilParsers: [DateFormatter] = [
        {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }(),
        {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }(),
    ]

    init() {
        self.client = SupabaseClientProvider.shared
    }

    func check(
        place: Place,
        date: Date,
        partySize: Int
    ) async throws -> AvailabilityCheck {
        struct RequestBody: Encodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let date: String
            let partySize: Int
        }
        let body = RequestBody(
            name: place.name,
            latitude: place.latitude,
            longitude: place.longitude,
            date: Self.isoDate.string(from: date),
            partySize: partySize
        )
        let wire: CheckWireResponse = try await client.functions.invoke(
            "check-availability",
            options: FunctionInvokeOptions(body: body)
        )
        return Self.map(wire)
    }

    /// Translate the wire JSON to the strongly-typed Swift enum.
    private static func map(_ w: CheckWireResponse) -> AvailabilityCheck {
        let bookingURL = w.bookingURL.flatMap(URL.init(string:))
        let shifts = w.shifts.map { ws in
            AvailabilityCheck.Shift(
                name: ws.name,
                bookableUntil: ws.bookableUntil.flatMap(parseBookableUntil)
            )
        }
        switch w.status {
        case "open":    return .open(shifts: shifts, bookingURL: bookingURL, provider: w.provider)
        case "closed":  return .closed(bookingURL: bookingURL, provider: w.provider)
        case "unknown": return .unknown
        default:        return .error
        }
    }

    private static func parseBookableUntil(_ raw: String) -> Date? {
        for fmt in bookableUntilParsers {
            if let d = fmt.date(from: raw) { return d }
        }
        return nil
    }
}

// =============================================================================
// Router — picks live vs mock + per-place in-memory cache
// =============================================================================
//
// Same shape as `AvailabilityRouter`. The Edge Function already caches
// the AI-lookup result in Postgres, so this client-side cache is purely
// "don't re-fire the same network call within the session" — not a
// substitute for the shared cache.

actor ReservationCheckRouter: ReservationCheckService {
    private let live: ReservationCheckService?
    private let fallback: ReservationCheckService
    /// Cache key: `placeID|YYYY-MM-DD|partySize`. Lets the user change
    /// date or party size and still get a fresh check without flushing
    /// previous answers.
    private var cache: [String: AvailabilityCheck] = [:]

    init(live: ReservationCheckService?, fallback: ReservationCheckService) {
        self.live = live
        self.fallback = fallback
    }

    func check(
        place: Place,
        date: Date,
        partySize: Int
    ) async throws -> AvailabilityCheck {
        let key = Self.cacheKey(placeID: place.id, date: date, partySize: partySize)
        if let cached = cache[key] {
            return cached
        }
        let service = live ?? fallback
        let result: AvailabilityCheck
        do {
            result = try await service.check(place: place, date: date, partySize: partySize)
        } catch {
            #if DEBUG
            print("[ReservationCheckRouter] live check failed: \(error) — falling back to mock")
            #endif
            result = try await fallback.check(place: place, date: date, partySize: partySize)
        }
        cache[key] = result
        return result
    }

    private static func cacheKey(placeID: String, date: Date, partySize: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "\(placeID)|\(f.string(from: date))|\(partySize)"
    }
}
