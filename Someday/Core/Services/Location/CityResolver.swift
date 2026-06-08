import Foundation
import CoreLocation

// =============================================================================
// CityResolver — "what city is the user looking at?"
// =============================================================================
//
// Wraps CLGeocoder.reverseGeocodeLocation with two layers of efficiency:
//
//   • In-memory cache keyed by a coarse-quantized coordinate. Pan within
//     ~1 km of a previously-resolved point → instant cache hit, no SDK
//     round-trip. Cache is keyed by 2-decimal lat/lon (~1.1 km grid at
//     the equator), which is the right grain for "what city is this":
//     fine enough that neighbouring metros don't collide, coarse enough
//     that nudging the camera doesn't blow the cache.
//
//   • Single-flight guard: if a resolve for the same key is already in
//     flight, callers `await` the same `Task` instead of starting a
//     second SDK request. CLGeocoder is rate-limited and any noticeable
//     concurrency burns its quota fast.
//
// The resolver is an `actor` so the cache and in-flight maps are safe
// across the chat-context-build / map-pan / share-import sites that all
// poke at it concurrently.
//
// Future swap: this is the natural home for a tool-callable
// `get_current_city()` once we migrate the chat off context-injection.

actor CityResolver {
    /// Singleton — there's no reason for multiple resolvers, and the
    /// cache is more useful when it's shared across the whole app.
    static let shared = CityResolver()

    private let geocoder = CLGeocoder()

    /// Resolved city names by quantized-coord key. `nil` value caches
    /// negative results so we don't keep retrying coords that don't
    /// reverse-geocode to anything (open ocean, restricted regions).
    private var cache: [String: String?] = [:]

    /// In-flight tasks by quantized-coord key. Lets concurrent callers
    /// share the same SDK request.
    private var inflight: [String: Task<String?, Never>] = [:]

    private init() {}

    /// Best-effort reverse geocode of `coord` → city name. Returns `nil`
    /// when CLGeocoder can't resolve, when it errors out, or when the
    /// request gets cancelled. Never throws — chat-context builders read
    /// the result inline and just omit the field when it's nil.
    func resolve(_ coord: CLLocationCoordinate2D) async -> String? {
        let key = Self.quantize(coord)
        if let cached = cache[key] {
            return cached
        }
        if let pending = inflight[key] {
            return await pending.value
        }
        let task = Task<String?, Never> {
            await Self.reverseGeocode(geocoder: geocoder, coord: coord)
        }
        inflight[key] = task
        let resolved = await task.value
        // Cache even nil results so a coord that resolves to nothing
        // doesn't keep round-tripping.
        cache[key] = resolved
        inflight[key] = nil
        return resolved
    }

    /// Coarse cache key. Rounds to 2 decimals so coords within ~1 km
    /// collapse to the same key — perfect grain for "what city".
    private static func quantize(_ coord: CLLocationCoordinate2D) -> String {
        let lat = (coord.latitude  * 100).rounded() / 100
        let lon = (coord.longitude * 100).rounded() / 100
        return String(format: "%.2f,%.2f", lat, lon)
    }

    /// Static helper so the actor body stays small. Uses `locality` as
    /// the primary signal ("Amsterdam"), falling back to
    /// `administrativeArea` ("North Holland") for rural coords where
    /// locality isn't populated.
    private static func reverseGeocode(
        geocoder: CLGeocoder,
        coord: CLLocationCoordinate2D
    ) async -> String? {
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let first = placemarks.first else { return nil }
            return first.locality
                ?? first.subAdministrativeArea
                ?? first.administrativeArea
        } catch {
            #if DEBUG
            print("[CityResolver] reverseGeocode failed: \(error)")
            #endif
            return nil
        }
    }
}
