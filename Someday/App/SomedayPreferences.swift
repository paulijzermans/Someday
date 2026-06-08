import SwiftUI
import MapKit

// =============================================================================
// SomedayPreferences — client-side settings store
// =============================================================================
//
// One @Observable bag of every preference the user can flip in Settings.
// Backed by UserDefaults so the choices survive cold launches without us
// having to round-trip through Supabase for things that only matter on
// this device (map type, default zoom, notification toggles, etc.).
//
// Server-stored fields (display name, phone for contact matching) are NOT
// in here — those live on `profiles` and flow through UserService. Anything
// that we'd want consistent across devices should go there instead.
//
// Lifecycle: created once at app launch by `SomedayApp` and injected via
// `@Environment(SomedayPreferences.self)`. View code reads `prefs.mapType`,
// mutates `prefs.mapType = .hybrid`, and the new value is persisted on
// the next runloop tick.

@Observable
@MainActor
final class SomedayPreferences {

    // MARK: - Subscription tier (mock)
    //
    // The product doesn't have payments wired yet, so this is a local
    // toggle for the Plan tile + any Pro-gated features. When RevenueCat
    // lands, this property becomes a read-through cache of the entitlement.

    enum Tier: String, CaseIterable {
        case free
        case pro

        var displayName: String { self == .pro ? "Pro" : "Free" }
    }

    var tier: Tier {
        didSet { persist(\.tier, oldValue.rawValue) }
    }

    // MARK: - Map settings

    /// MapKit map type. Maps to `MKMapType` at the call site.
    enum MapType: String, CaseIterable {
        case standard
        case hybrid
        case satellite

        var displayName: String {
            switch self {
            case .standard:  return "Standard"
            case .hybrid:    return "Hybrid"
            case .satellite: return "Satellite"
            }
        }
    }

    var mapType: MapType {
        didSet { persist(\.mapType, oldValue.rawValue) }
    }

    /// Coarse "how zoomed in is the map when the user opens it" setting.
    /// Converted to a `MKCoordinateSpan` by `defaultZoomSpan` below.
    enum DefaultZoom: String, CaseIterable {
        case close       // ~neighborhood
        case city        // ~city
        case wide        // ~region

        var displayName: String {
            switch self {
            case .close: return "Neighborhood"
            case .city:  return "City"
            case .wide:  return "Region"
            }
        }
    }

    var defaultZoom: DefaultZoom {
        didSet { persist(\.defaultZoom, oldValue.rawValue) }
    }

    var defaultZoomSpan: MKCoordinateSpan {
        switch defaultZoom {
        case .close: return MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)
        case .city:  return MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        case .wide:  return MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
        }
    }

    var showTraffic: Bool {
        didSet { persist(\.showTraffic, oldValue) }
    }

    /// Whether nearby points of interest (other restaurants, cafes, etc.)
    /// render under the user's own pins. Off by default — keeps the map
    /// focused on places the user + their friends curated.
    var showPOI: Bool {
        didSet { persist(\.showPOI, oldValue) }
    }

    // MARK: - Privacy

    /// Allow other users with this user's phone or email in their address
    /// book to find them via the contact-discovery flow. Off = the user's
    /// `phone_hash` + `email_hash` columns are cleared and re-set, so they
    /// drop out of `find-friends-on-someday` matches.
    var contactDiscoveryEnabled: Bool {
        didSet { persist(\.contactDiscoveryEnabled, oldValue) }
    }

    enum ProfileVisibility: String, CaseIterable {
        case everyone
        case friendsOnly
        case privateMode = "private"

        var displayName: String {
            switch self {
            case .everyone:     return "Everyone"
            case .friendsOnly:  return "Friends only"
            case .privateMode:  return "Private"
            }
        }
    }

    var profileVisibility: ProfileVisibility {
        didSet { persist(\.profileVisibility, oldValue.rawValue) }
    }

    var shareActivityToFriends: Bool {
        didSet { persist(\.shareActivityToFriends, oldValue) }
    }

    enum LocationPrecision: String, CaseIterable {
        case exact
        case approximate

        var displayName: String {
            self == .approximate ? "Approximate" : "Exact"
        }
    }

    var locationPrecision: LocationPrecision {
        didSet { persist(\.locationPrecision, oldValue.rawValue) }
    }

    // MARK: - Notifications

    var notifyFriendRequests: Bool {
        didSet { persist(\.notifyFriendRequests, oldValue) }
    }
    var notifyListShares: Bool {
        didSet { persist(\.notifyListShares, oldValue) }
    }
    var notifyReviewLikes: Bool {
        didSet { persist(\.notifyReviewLikes, oldValue) }
    }
    var notifyWeeklyDigest: Bool {
        didSet { persist(\.notifyWeeklyDigest, oldValue) }
    }

    // MARK: - Storage

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store

        // Load — fall back to sensible defaults when the key is missing.
        self.tier = Tier(rawValue: store.string(forKey: Keys.tier) ?? "") ?? .free
        self.mapType = MapType(rawValue: store.string(forKey: Keys.mapType) ?? "") ?? .standard
        self.defaultZoom = DefaultZoom(rawValue: store.string(forKey: Keys.defaultZoom) ?? "") ?? .close
        self.showTraffic = store.object(forKey: Keys.showTraffic) as? Bool ?? false
        self.showPOI = store.object(forKey: Keys.showPOI) as? Bool ?? false
        self.contactDiscoveryEnabled = store.object(forKey: Keys.contactDiscoveryEnabled) as? Bool ?? true
        self.profileVisibility = ProfileVisibility(rawValue: store.string(forKey: Keys.profileVisibility) ?? "") ?? .everyone
        self.shareActivityToFriends = store.object(forKey: Keys.shareActivityToFriends) as? Bool ?? true
        self.locationPrecision = LocationPrecision(rawValue: store.string(forKey: Keys.locationPrecision) ?? "") ?? .exact
        self.notifyFriendRequests = store.object(forKey: Keys.notifyFriendRequests) as? Bool ?? true
        self.notifyListShares = store.object(forKey: Keys.notifyListShares) as? Bool ?? true
        self.notifyReviewLikes = store.object(forKey: Keys.notifyReviewLikes) as? Bool ?? false
        self.notifyWeeklyDigest = store.object(forKey: Keys.notifyWeeklyDigest) as? Bool ?? true
    }

    /// Persist a new value when its `didSet` fires. `oldValue` is unused
    /// at runtime but kept in the signature so callers stay symmetric and
    /// future-us has somewhere to plumb change tracking / analytics.
    private func persist<T>(_ keyPath: KeyPath<SomedayPreferences, T>, _ oldValue: Any) {
        switch keyPath {
        case \.tier:                    store.set(tier.rawValue, forKey: Keys.tier)
        case \.mapType:                 store.set(mapType.rawValue, forKey: Keys.mapType)
        case \.defaultZoom:             store.set(defaultZoom.rawValue, forKey: Keys.defaultZoom)
        case \.showTraffic:             store.set(showTraffic, forKey: Keys.showTraffic)
        case \.showPOI:                 store.set(showPOI, forKey: Keys.showPOI)
        case \.contactDiscoveryEnabled: store.set(contactDiscoveryEnabled, forKey: Keys.contactDiscoveryEnabled)
        case \.profileVisibility:       store.set(profileVisibility.rawValue, forKey: Keys.profileVisibility)
        case \.shareActivityToFriends:  store.set(shareActivityToFriends, forKey: Keys.shareActivityToFriends)
        case \.locationPrecision:       store.set(locationPrecision.rawValue, forKey: Keys.locationPrecision)
        case \.notifyFriendRequests:    store.set(notifyFriendRequests, forKey: Keys.notifyFriendRequests)
        case \.notifyListShares:        store.set(notifyListShares, forKey: Keys.notifyListShares)
        case \.notifyReviewLikes:       store.set(notifyReviewLikes, forKey: Keys.notifyReviewLikes)
        case \.notifyWeeklyDigest:      store.set(notifyWeeklyDigest, forKey: Keys.notifyWeeklyDigest)
        default: break
        }
    }

    private enum Keys {
        static let tier                     = "prefs.tier"
        static let mapType                  = "prefs.map.type"
        static let defaultZoom              = "prefs.map.defaultZoom"
        static let showTraffic              = "prefs.map.showTraffic"
        static let showPOI                  = "prefs.map.showPOI"
        static let contactDiscoveryEnabled  = "prefs.privacy.contactDiscovery"
        static let profileVisibility        = "prefs.privacy.profileVisibility"
        static let shareActivityToFriends   = "prefs.privacy.shareActivity"
        static let locationPrecision        = "prefs.privacy.locationPrecision"
        static let notifyFriendRequests     = "prefs.notify.friendRequests"
        static let notifyListShares         = "prefs.notify.listShares"
        static let notifyReviewLikes        = "prefs.notify.reviewLikes"
        static let notifyWeeklyDigest       = "prefs.notify.weeklyDigest"
    }
}
