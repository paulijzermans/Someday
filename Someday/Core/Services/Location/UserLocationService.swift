import Foundation
import CoreLocation

/// Thin CLLocationManager wrapper used by the "Locate me" button under
/// the profile avatar. Async, single-shot. Walks the permission ladder
/// itself so callers just do `await service.currentLocation()` and get
/// either a `CLLocation` or `nil` (denied / restricted / failed).
///
/// Deliberately NOT `@Observable` — we want the imperative pull model,
/// not a stream. No background updates, no significant-location, no
/// region monitoring; the Info.plist string says "only when you tap
/// the button" and we keep that contract by never starting continuous
/// updates.
@MainActor
final class UserLocationService: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = UserLocationService()

    private let manager = CLLocationManager()
    /// Last seen authorization status. Cached so callers can short-
    /// circuit on `.denied` without spinning up a request.
    private(set) var authorizationStatus: CLAuthorizationStatus

    /// In-flight one-shot request. Resolved on the next location
    /// update / failure / permission-denied event, then cleared so the
    /// next button tap fires a fresh request.
    private var pending: CheckedContinuation<CLLocation?, Never>?

    override init() {
        self.authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        // Coarse-grained accuracy is plenty for centering the map —
        // we're not navigating turn-by-turn, just dropping the camera
        // at "around here". Saves battery and resolves faster.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    // MARK: - Public

    /// Single-shot location request. Walks the permission ladder
    /// (notDetermined → request prompt; authorized → ask for a fix;
    /// denied/restricted → return nil immediately). Callers `await`
    /// the result; the next CLLocation or failure resolves it.
    func currentLocation() async -> CLLocation? {
        // Cancel any older in-flight request — we never want two
        // continuations racing for the same delegate callback.
        if let p = pending { p.resume(returning: nil); pending = nil }

        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            return await withCheckedContinuation { cont in
                pending = cont
                manager.requestWhenInUseAuthorization()
                // The delegate's `didChangeAuthorization` will follow
                // up with `requestLocation()` once the user picks an
                // option in the system prompt.
            }
        case .restricted, .denied:
            return nil
        case .authorizedAlways, .authorizedWhenInUse:
            return await withCheckedContinuation { cont in
                pending = cont
                manager.requestLocation()
            }
        @unknown default:
            return nil
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        // If we were waiting on a permission prompt, react to the
        // user's decision now: ask for the fix on grant, or resolve
        // with nil on deny.
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if pending != nil { manager.requestLocation() }
        case .denied, .restricted:
            pending?.resume(returning: nil)
            pending = nil
        case .notDetermined:
            break  // still waiting on the user to choose
        @unknown default:
            pending?.resume(returning: nil)
            pending = nil
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let last = locations.last
        Task { @MainActor in
            self.pending?.resume(returning: last)
            self.pending = nil
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.pending?.resume(returning: nil)
            self.pending = nil
        }
    }
}
