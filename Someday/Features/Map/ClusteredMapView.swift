import SwiftUI
import MapKit

extension PlaceSource {
    /// Brand-aligned background color for the source badge on the map pin.
    var badgeColor: UIColor {
        switch self {
        case .manual: return UIColor.systemGray
        case .instagram: return UIColor(red: 0.88, green: 0.19, blue: 0.42, alpha: 1)
        case .facebook: return UIColor(red: 0.10, green: 0.47, blue: 0.95, alpha: 1)
        case .tiktok: return UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        case .googleMaps: return UIColor(red: 0.20, green: 0.65, blue: 0.32, alpha: 1)
        case .friend: return UIColor(SomedayColors.primary)
        }
    }

    /// Asset-catalog name for the brand logo image (nil = use SF Symbol fallback).
    var assetName: String? {
        switch self {
        case .instagram: return "instagram"
        case .facebook:  return "facebook"
        case .tiktok:    return "tiktok"
        default:         return nil
        }
    }
}

extension UIColor {
    /// Returns a darker variant by reducing brightness.
    func darkened(by factor: CGFloat = 0.3) -> UIColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        if getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha) {
            return UIColor(
                hue: hue,
                saturation: min(sat + factor * 0.15, 1),
                brightness: max(bri - factor, 0),
                alpha: alpha
            )
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let m = 1 - factor
        return UIColor(red: r * m, green: g * m, blue: b * m, alpha: a)
    }
}

class PlaceAnnotation: MKPointAnnotation {
    let place: Place
    /// Name of the custom list this place is in, when any. Drives the
    /// pin's fill colour via `ListVisualStyle.style(for:).color` so a
    /// pin's colour matches the list it lives in. Nil = no list →
    /// default pin colour (turquoise / friend tint).
    var listName: String?

    init(place: Place, listName: String? = nil) {
        self.place = place
        self.listName = listName
        super.init()
        coordinate = place.coordinate
        title = place.name
    }
}

/// Transient pin dropped by the AI chat when the user taps a
/// `someday://suggest?...` link. Held by `MapViewModel.suggestionPins`,
/// rendered in lime with a sparkle glyph so it reads as "AI proposed
/// this spot" — visually distinct from the user's saved pins. Tapping
/// it surfaces a small "Save to map" sheet (TBD); for now it just
/// flags the spot.
class SuggestionAnnotation: MKPointAnnotation {
    /// Stable identity for sync. We let the SwiftUI layer derive it
    /// from name+coord so two AI suggestions at slightly different
    /// coords don't collapse together.
    let suggestionID: String
    let name: String
    let category: String?

    init(id: String, name: String, category: String?, coordinate: CLLocationCoordinate2D) {
        self.suggestionID = id
        self.name = name
        self.category = category
        super.init()
        self.coordinate = coordinate
        title = name
        subtitle = category
    }
}

struct ClusteredMapView: UIViewRepresentable {
    let places: [Place]
    @Binding var region: MKCoordinateRegion
    let onSelectPlace: (Place) -> Void
    /// Resolver from `Place → optional list name`. When the closure
    /// returns a non-nil name, the pin renders in that list's
    /// deterministic colour (`ListVisualStyle.style(for:).color`).
    /// Default no-op keeps existing call sites compiling.
    var listNameFor: (Place) -> String? = { _ in nil }

    /// Transient pins dropped by the AI chat when the user taps a
    /// `someday://suggest?...` link. Rendered in lime so they read as
    /// "AI proposed this spot" — visually distinct from saved pins.
    /// Cleared from `MapViewModel.suggestionPins` after a few minutes
    /// or when the user dismisses them.
    var suggestions: [SuggestedPin] = []
    /// Tap callback for a suggestion pin. The parent decides what to do
    /// (currently: pulse the hint banner; future: open a save sheet).
    var onSelectSuggestion: (SuggestedPin) -> Void = { _ in }

    /// When true, the standard pulsing blue dot for the user's current
    /// location is rendered on the map. Flipped on by MapHomeView's
    /// locate-me button after the first successful permission grant,
    /// so we never show the dot before the user explicitly asked for
    /// it (matches the Info.plist promise of "only when you tap").
    var showsUserLocation: Bool = false

    /// IDs of the pins that should "breathe" — slowly scale up and
    /// down on a repeat-forever ease. Set by MapHomeView from the VM:
    /// the selected place card pin, and any AI-suggestion pin that
    /// the bottom info tile is currently showing. Either may be nil
    /// independently. Driving this via id rather than a separate
    /// "selected" flag means the annotation's identity stays stable
    /// across diff passes, and we can attach / remove the breath
    /// animation cleanly in `updateUIView`.
    var breathingPlaceID: String? = nil
    var breathingSuggestionID: String? = nil

    /// id of the pin currently "armed" for deletion via the long-press
    /// jiggle idiom (see `MapViewModel.deletingPlaceID`). When it matches
    /// a place annotation, that pin wiggles and shows a red × badge.
    var deletingPlaceID: String? = nil
    /// Long-press landed on a saved pin — parent arms it for deletion.
    var onLongPressPlace: (Place) -> Void = { _ in }
    /// User tapped the red × on an armed pin — parent deletes it.
    var onRequestDeletePlace: (Place) -> Void = { _ in }
    /// User tapped anywhere other than the × while a pin is armed —
    /// parent disarms and returns the map to normal.
    var onCancelDeleteMode: () -> Void = {}

    /// The travel route to draw between two saved pins, if any. Set from
    /// `MapViewModel.activeRoute?.polyline` — nil when no route is active.
    /// Rendered as a single rounded blue overlay via the coordinator's
    /// `rendererFor`. Swapping in a new polyline (a mode change) or nil
    /// (route cleared) is reconciled in `syncRouteOverlay`.
    var routePolyline: MKPolyline? = nil

    /// Tag stamped on the red × delete button so the cancel-tap gesture
    /// can recognise (and ignore) touches that land on it — otherwise a
    /// tap on the × would both delete AND fire the "tapped elsewhere"
    /// cancel.
    fileprivate static let deleteButtonTag = 7731

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.setRegion(region, animated: false)
        mapView.showsUserLocation = showsUserLocation

        // Muted standard style with POIs hidden — calmer background so the colored pins shine.
        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        mapView.preferredConfiguration = config

        // Hide chrome we don't use
        mapView.showsCompass = false
        mapView.showsTraffic = false

        mapView.register(
            PlacePinAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier
        )
        mapView.register(
            ClusterPinAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier
        )
        mapView.register(
            SuggestionPinAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: SuggestionPinAnnotationView.reuseID
        )

        // Long-press to "arm" a saved pin for deletion (the iPhone
        // home-screen jiggle idiom). We hit-test the press location
        // against the place annotation views in the coordinator. Runs
        // alongside MapKit's own pan/zoom/tap recognisers — the short
        // press duration plus simultaneous recognition (see the gesture
        // delegate) keeps panning and pin-selection working as before.
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.45
        longPress.delegate = context.coordinator
        mapView.addGestureRecognizer(longPress)

        // Cancel-tap: while a pin is armed, any tap that ISN'T on the red
        // × badge disarms it. Inert (returns immediately) when nothing is
        // armed, so it never interferes with normal pin selection.
        let cancelTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleCancelTap(_:))
        )
        cancelTap.delegate = context.coordinator
        // Crucial: the cancel-tap must wait for the long-press to FAIL
        // before it can fire. Otherwise the finger-lift that ends the
        // arming long-press is itself read as a "tap elsewhere" and
        // immediately disarms the pin — so the × only showed while the
        // finger was held down. Requiring the long-press to fail means:
        //   • arming long-press → succeeds → cancel-tap never fires, the
        //     × stays put after you lift your finger; and
        //   • a later quick tap → long-press fails fast → cancel-tap
        //     fires → disarm.
        cancelTap.require(toFail: longPress)
        context.coordinator.cancelTapRecognizer = cancelTap
        mapView.addGestureRecognizer(cancelTap)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Refresh the coordinator's snapshot of `self` so its gesture
        // handlers read the current `deletingPlaceID` + callbacks rather
        // than the values captured at init time.
        context.coordinator.parent = self
        syncAnnotations(on: mapView)
        syncSuggestions(on: mapView)
        // Keep the user-location dot in sync with the parent's flag.
        // Toggled by MapHomeView once `UserLocationService` returns a
        // first fix — MKMapView then handles the pulsing blue dot
        // (and live updates) for us.
        if mapView.showsUserLocation != showsUserLocation {
            mapView.showsUserLocation = showsUserLocation
        }

        // Sync the breathing pulse — start it on whichever annotation
        // view matches `breathingPlaceID` / `breathingSuggestionID`,
        // stop it on every other annotation view. Idempotent: the
        // helper checks for an existing animation before adding a new
        // one, so running this on every updateUIView is cheap.
        syncBreathing(on: mapView)

        // Add / remove the red × badge + wiggle on whichever pin matches
        // `deletingPlaceID`. Cheap + idempotent, same as syncBreathing.
        syncDeleteBadges(on: mapView, coordinator: context.coordinator)

        // Reconcile the route polyline overlay against `routePolyline`.
        syncRouteOverlay(on: mapView)

        if Self.significantlyDifferent(mapView.region, region) {
            mapView.setRegion(region, animated: true)
        }
    }

    /// Reconcile the on-map route overlay with `routePolyline`. MapKit has
    /// no diff for overlays, so we compare by object identity: if the
    /// requested polyline is already the one on the map, leave it; otherwise
    /// drop every existing route line and add the new one (or just drop, when
    /// `routePolyline` went nil because the route was cleared). We only ever
    /// manage `MKPolyline` overlays here, so this never touches any other
    /// overlay type a future surface might add.
    private func syncRouteOverlay(on mapView: MKMapView) {
        let existing = mapView.overlays.compactMap { $0 as? MKPolyline }
        if let poly = routePolyline {
            if existing.contains(where: { $0 === poly }) { return }
            if !existing.isEmpty { mapView.removeOverlays(existing) }
            mapView.addOverlay(poly, level: .aboveRoads)
        } else if !existing.isEmpty {
            mapView.removeOverlays(existing)
        }
    }

    /// Walk every annotation view currently on screen and attach /
    /// detach the breathing pulse animation to match the active
    /// selection. Pin views are recycled via MapKit's reuse pool, so
    /// we always re-evaluate rather than tracking which view the
    /// animation is currently on — cheap, robust against scroll.
    private func syncBreathing(on mapView: MKMapView) {
        for ann in mapView.annotations {
            let view = mapView.view(for: ann)
            guard let view else { continue }
            let shouldBreathe: Bool
            if let pa = ann as? PlaceAnnotation {
                shouldBreathe = pa.place.id == breathingPlaceID
            } else if let sa = ann as? SuggestionAnnotation {
                shouldBreathe = sa.suggestionID == breathingSuggestionID
            } else {
                shouldBreathe = false
            }
            if shouldBreathe {
                ClusteredMapView.attachBreathingAnimation(to: view)
            } else {
                ClusteredMapView.removeBreathingAnimation(from: view)
            }
        }
    }

    /// Add the repeat-forever scale pulse to `view.layer` under the
    /// key `breathe`. No-op when the animation is already attached so
    /// we don't restart it on every updateUIView tick (the user would
    /// see a stutter on each render).
    static func attachBreathingAnimation(to view: MKAnnotationView) {
        guard view.layer.animation(forKey: "breathe") == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.20
        scale.duration = 1.1
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // Anchor the scale at the bottom of the pin so the tip stays
        // pinned to the coordinate while the bulb breathes. The
        // default anchor (.5, .5) would lift the tip off the spot.
        view.layer.anchorPoint = CGPoint(x: 0.5, y: 1.0)
        view.layer.add(scale, forKey: "breathe")
    }

    static func removeBreathingAnimation(from view: MKAnnotationView) {
        view.layer.removeAnimation(forKey: "breathe")
        // Reset the anchor so non-selected pins render normally
        // (their hit area assumes the default (.5, .5)). MapKit will
        // re-position the view on the next layout pass.
        if view.layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
            view.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }
    }

    // MARK: - Delete-mode badge + wiggle

    /// Walk every annotation view; on the one whose place matches
    /// `deletingPlaceID` attach the red × badge + wiggle, strip both off
    /// every other. Mirrors `syncBreathing` — pin views are recycled, so
    /// we re-evaluate from scratch on each pass rather than tracking the
    /// last-armed view.
    private func syncDeleteBadges(on mapView: MKMapView, coordinator: Coordinator) {
        for ann in mapView.annotations {
            guard let view = mapView.view(for: ann) else { continue }
            let armed = (ann as? PlaceAnnotation)?.place.id == deletingPlaceID
                && deletingPlaceID != nil
            if armed {
                ClusteredMapView.addDeleteBadge(to: view, target: coordinator)
                ClusteredMapView.attachWiggle(to: view)
            } else {
                ClusteredMapView.removeDeleteBadge(from: view)
                ClusteredMapView.removeWiggle(from: view)
            }
        }
    }

    /// Red, white-ringed × button overhanging the pin's top-right corner
    /// — the home-screen "delete" affordance. No-op if already present.
    /// The button targets the coordinator; at tap time it resolves its
    /// own place from the annotation view it lives on.
    static func addDeleteBadge(to view: MKAnnotationView, target: Coordinator) {
        guard view.viewWithTag(deleteButtonTag) == nil else { return }
        let size: CGFloat = 20
        let btn = UIButton(type: .custom)
        btn.tag = deleteButtonTag
        // Centre the × on the TILE's top-right corner, not the canvas's.
        // `renderTile` uses fixed geometry — 1.5pt left pad, a 40pt tile,
        // a 7pt pointer below — and event pins reserve extra top/right
        // room for a clock badge by GROWING the canvas, not by moving the
        // tile. So the tile's top-right corner is at a constant
        // (41.5, height − 47) regardless of pin type. Pinning the × there
        // means on an event pin it lands ON the clock badge (replacing
        // it) instead of stacking even higher above it.
        let tileRightX: CGFloat = 41.5             // leftPad 1.5 + tileSide 40
        let tileTopY = view.bounds.height - 47     // − tileSide 40 − pointerH 7
        btn.frame = CGRect(
            x: tileRightX - size / 2,
            y: tileTopY - size / 2,
            width: size,
            height: size
        )
        btn.backgroundColor = UIColor.systemRed
        btn.layer.cornerRadius = size / 2
        btn.layer.borderColor = UIColor.white.cgColor
        btn.layer.borderWidth = 1.5
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOpacity = 0.25
        btn.layer.shadowRadius = 2
        btn.layer.shadowOffset = CGSize(width: 0, height: 1)
        if let icon = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .heavy)
        )?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            btn.setImage(icon, for: .normal)
        }
        btn.addTarget(target, action: #selector(Coordinator.handleDeleteTap(_:)), for: .touchUpInside)
        view.addSubview(btn)
        // Spring pop-in so the badge "appears" rather than blinks.
        btn.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.4) {
            btn.transform = .identity
        }
    }

    static func removeDeleteBadge(from view: MKAnnotationView) {
        view.viewWithTag(deleteButtonTag)?.removeFromSuperview()
    }

    /// Gentle continuous rotation wiggle (~±2.5°) keyed `wiggle`, rotating
    /// about the view centre so the pin sways like a home-screen icon.
    /// Additive so it composes with any breathing scale already running.
    static func attachWiggle(to view: MKAnnotationView) {
        guard view.layer.animation(forKey: "wiggle") == nil else { return }
        let rot = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rot.values = [-0.045, 0.045, -0.045]
        rot.keyTimes = [0, 0.5, 1]
        rot.duration = 0.22
        rot.repeatCount = .infinity
        rot.isAdditive = true
        view.layer.add(rot, forKey: "wiggle")
    }

    static func removeWiggle(from view: MKAnnotationView) {
        view.layer.removeAnimation(forKey: "wiggle")
    }

    /// Diff `suggestions` against the AI-suggestion annotations already
    /// on the map. We drop ones whose ID is gone and add ones not yet
    /// present. Tiny lists (usually 1–3), so the naive sweep is fine.
    private func syncSuggestions(on mapView: MKMapView) {
        let existing = mapView.annotations.compactMap { $0 as? SuggestionAnnotation }
        let newIDs = Set(suggestions.map(\.id))
        let oldIDs = Set(existing.map(\.suggestionID))

        let toRemove = existing.filter { !newIDs.contains($0.suggestionID) }
        if !toRemove.isEmpty { mapView.removeAnnotations(toRemove) }

        let toAdd = suggestions
            .filter { !oldIDs.contains($0.id) }
            .map { SuggestionAnnotation(
                id: $0.id,
                name: $0.name,
                category: $0.category,
                coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            ) }
        if !toAdd.isEmpty { mapView.addAnnotations(toAdd) }
    }

    private func syncAnnotations(on mapView: MKMapView) {
        let existing = mapView.annotations.compactMap { $0 as? PlaceAnnotation }
        let newIDs = Set(places.map(\.id))

        // Two-purpose pass:
        //   • Drop annotations whose place is gone from `places`.
        //   • Drop + re-add annotations whose list membership changed
        //     since last render (no other way to force prepareForDisplay
        //     to re-fire and regenerate the pin image with a new colour).
        var toRemove: [PlaceAnnotation] = []
        var kept: Set<String> = []
        for ann in existing {
            if !newIDs.contains(ann.place.id) {
                toRemove.append(ann)
                continue
            }
            if ann.listName != listNameFor(ann.place) {
                toRemove.append(ann)
            } else {
                kept.insert(ann.place.id)
            }
        }
        if !toRemove.isEmpty { mapView.removeAnnotations(toRemove) }

        // Anything not in `kept` is either brand-new or was just re-added
        // due to a list-colour change — both paths construct a fresh
        // annotation with the up-to-date `listName`.
        let toAdd = places
            .filter { !kept.contains($0.id) }
            .map { PlaceAnnotation(place: $0, listName: listNameFor($0)) }
        if !toAdd.isEmpty { mapView.addAnnotations(toAdd) }
    }

    static func significantlyDifferent(_ a: MKCoordinateRegion, _ b: MKCoordinateRegion) -> Bool {
        abs(a.center.latitude - b.center.latitude) > 0.0001 ||
        abs(a.center.longitude - b.center.longitude) > 0.0001 ||
        abs(a.span.latitudeDelta - b.span.latitudeDelta) > 0.001 ||
        abs(a.span.longitudeDelta - b.span.longitudeDelta) > 0.001
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: ClusteredMapView
        private var isProgrammatic = false
        /// Held weakly so the gesture delegate can tell our cancel-tap
        /// apart from MapKit's own recognisers.
        weak var cancelTapRecognizer: UITapGestureRecognizer?

        init(_ parent: ClusteredMapView) {
            self.parent = parent
        }

        // MARK: Long-press delete mode

        /// Long-press began — hit-test the press point against the place
        /// pins on screen and arm the closest one for deletion. We test
        /// each annotation view's frame (converted into map coordinates)
        /// rather than nearest-coordinate, so the press has to actually
        /// land on a pin's tile, not just near its spot.
        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            var best: (place: Place, dist: CGFloat)?
            for ann in mapView.annotations {
                guard let pa = ann as? PlaceAnnotation,
                      let view = mapView.view(for: ann) else { continue }
                // The pin tile is small; pad the hit rect a touch so a
                // press just off the edge still counts.
                let frame = view.convert(view.bounds, to: mapView).insetBy(dx: -6, dy: -6)
                guard frame.contains(point) else { continue }
                let centre = CGPoint(x: frame.midX, y: frame.midY)
                let dist = hypot(centre.x - point.x, centre.y - point.y)
                if best == nil || dist < best!.dist { best = (pa.place, dist) }
            }
            if let best { parent.onLongPressPlace(best.place) }
        }

        /// A tap landed while a pin is armed (and NOT on the × badge —
        /// the gesture delegate filters those out). Disarm.
        @objc func handleCancelTap(_ gesture: UITapGestureRecognizer) {
            guard parent.deletingPlaceID != nil else { return }
            parent.onCancelDeleteMode()
        }

        /// The red × on an armed pin was tapped — resolve its place from
        /// the annotation view it lives on and ask the parent to delete.
        @objc func handleDeleteTap(_ sender: UIButton) {
            guard let view = sender.superview as? MKAnnotationView,
                  let pa = view.annotation as? PlaceAnnotation else { return }
            parent.onRequestDeletePlace(pa.place)
        }

        // MARK: UIGestureRecognizerDelegate

        /// Run our long-press / cancel-tap alongside MapKit's built-in
        /// pan, zoom, and selection recognisers instead of fighting them.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// Keep the cancel-tap from firing when the touch is on the red ×
        /// button — otherwise tapping the × would both delete the pin and
        /// register as a "tapped elsewhere" cancel.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer === cancelTapRecognizer {
                var node = touch.view
                while let current = node {
                    if current.tag == ClusteredMapView.deleteButtonTag { return false }
                    node = current.superview
                }
            }
            return true
        }

        /// Render the route polyline as a rounded brand-blue line with a
        /// soft white casing underneath, so it reads clearly over both the
        /// muted land and water of the map. MapKit asks for a renderer once
        /// per added overlay and caches it.
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor(SomedayColors.primary)
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isProgrammatic else {
                isProgrammatic = false
                return
            }
            parent.region = mapView.region
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            for view in views {
                guard view.annotation is PlaceAnnotation || view.annotation is MKClusterAnnotation else { continue }
                view.transform = CGAffineTransform(scaleX: 0.05, y: 0.05)
                view.alpha = 0
                UIView.animate(
                    withDuration: 0.45,
                    delay: 0,
                    usingSpringWithDamping: 0.55,
                    initialSpringVelocity: 0.6,
                    options: [.allowUserInteraction]
                ) {
                    view.transform = .identity
                    view.alpha = 1
                }
            }
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            mapView.deselectAnnotation(annotation, animated: false)

            if let pa = annotation as? PlaceAnnotation {
                parent.onSelectPlace(pa.place)
            } else if let sa = annotation as? SuggestionAnnotation {
                if let match = parent.suggestions.first(where: { $0.id == sa.suggestionID }) {
                    parent.onSelectSuggestion(match)
                }
            } else if let cluster = annotation as? MKClusterAnnotation {
                isProgrammatic = true
                mapView.setRegion(zoomedRegion(for: cluster, in: mapView), animated: true)
            }
        }

        /// Custom view selector for suggestion pins. The default
        /// dequeue uses the registered `PlacePinAnnotationView` for any
        /// `MKAnnotation` that isn't a cluster — but we want the lime
        /// AI pin for `SuggestionAnnotation` specifically.
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is SuggestionAnnotation {
                return mapView.dequeueReusableAnnotationView(
                    withIdentifier: SuggestionPinAnnotationView.reuseID,
                    for: annotation
                )
            }
            return nil   // fall back to the default registered class
        }

        /// Tight bounding-box region around the cluster's member annotations,
        /// padded so the pins have breathing room and clamped to a minimum
        /// span so a stack of pins at one coordinate doesn't zoom to the moon.
        private func zoomedRegion(for cluster: MKClusterAnnotation,
                                  in mapView: MKMapView) -> MKCoordinateRegion {
            let coords = cluster.memberAnnotations.map(\.coordinate)
            guard !coords.isEmpty else { return mapView.region }

            let lats = coords.map(\.latitude)
            let lons = coords.map(\.longitude)
            let minLat = lats.min()!, maxLat = lats.max()!
            let minLon = lons.min()!, maxLon = lons.max()!

            let centerLat = (minLat + maxLat) / 2
            let centerLon = (minLon + maxLon) / 2

            // 1.6× the bounding extent so pins aren't pressed against the edges.
            // Minimum span keeps single-coordinate clusters from over-zooming.
            let spanLat = max((maxLat - minLat) * 1.6, 0.004)
            let spanLon = max((maxLon - minLon) * 1.6, 0.004)

            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
            )
        }
    }
}

// MARK: - Shared pin-tile renderer
//
// SINGLE source of truth for the map's pin geometry. Saved pins, AI
// suggestion pins, and clusters are all the *same* rounded photo-tile with
// a pointer tapering to the coordinate — they differ only in what fills the
// tile (photo / category icon / count), the colour of the pointer stem, and
// an optional corner badge. Historically each `…AnnotationView` redrew that
// geometry by hand in its own `renderTile`, so a tweak to one (corner
// radius, pointer size, badge overhang, the edge treatment) silently
// drifted from the others. Everything now funnels through
// `MapPinTile.render`, so there is exactly one place to change the pin look.
//
// Edge treatment: the tile wears the classic frame — a `edgeWidth`-thick
// ring (white for saved pins/clusters, lime for AI pins) around the photo,
// with the pointer stem in the same colour. `edgeWidth` defaults to 2.5;
// pass 0 for an edge-to-edge variant. A 0.5pt dark hairline is also stroked
// around the silhouette for legibility on light maps.
enum MapPinTile {
    // The one true geometry. Don't fork these into a caller.
    static let side: CGFloat = 40
    static let corner: CGFloat = 11
    static let pointerH: CGFloat = 7
    static let pointerHalf: CGFloat = 6.5
    static let badgeSize: CGFloat = 15
    static let edgePad: CGFloat = 1.5   // hairline + anti-alias breathing room

    /// The base (badge-less) tile canvas size + the `centerOffset` that
    /// anchors the pointer tip on the coordinate — the SAME geometry
    /// `render` produces for a no-badge pin (kept in lock-step with it).
    ///
    /// Used to give a place `MKAnnotationView` a stable collision frame at
    /// init, *before* `prepareForDisplay` draws the real image. MapKit's
    /// clustering pass measures each view's frame to decide what overlaps;
    /// our pin only gets a size once its image is drawn (and place photos
    /// load async after that), so the first cluster pass could run against a
    /// zero/default frame and skip merging overlapping pins. Seeding the
    /// known size here makes clustering deterministic from the first render.
    static var baseFrame: (size: CGSize, centerOffset: CGPoint) {
        let canvasW = edgePad + side + edgePad
        let canvasH = edgePad + side + pointerH
        let tip = CGPoint(x: edgePad + side / 2, y: edgePad + side + pointerH)
        let offset = CGPoint(x: canvasW / 2 - tip.x, y: canvasH / 2 - tip.y)
        return (CGSize(width: canvasW, height: canvasH), offset)
    }

    /// What fills the tile interior.
    enum Content {
        case photo(UIImage)
        case placeholder(icon: String, fill: UIColor)
        case count(Int, fill: UIColor)
    }

    /// Optional badge overhanging the top-right corner.
    enum Badge {
        case event       // amber clock — a time-limited place
        case suggestion  // lime sparkle — an AI proposal

        var fill: UIColor {
            switch self {
            case .event: return UIColor(red: 0.98, green: 0.62, blue: 0.10, alpha: 1)
            case .suggestion: return UIColor(SomedayColors.lime)
            }
        }
        var icon: String {
            switch self {
            case .event: return "clock.fill"
            case .suggestion: return "sparkles"
            }
        }
    }

    /// Render a pin image + the offset that re-centres the pointer TIP on
    /// the coordinate.
    ///
    /// - Parameters:
    ///   - content: what fills the tile.
    ///   - edge: colour of the ring + pointer stem. Saved pins/clusters
    ///     pass `.white`; AI pins pass lime so the frame keeps the
    ///     suggestion identity.
    ///   - edgeWidth: ring thickness. Defaults to 2.5 (the classic framed
    ///     tile); pass 0 for an edge-to-edge photo variant.
    ///   - badge: optional corner badge.
    static func render(
        content: Content,
        edge: UIColor,
        edgeWidth: CGFloat = 2.5,
        badge: Badge? = nil
    ) -> (UIImage, CGPoint) {
        let hasBadge = badge != nil
        // Reserve overhang room top/right only when a badge is present;
        // otherwise just the hairline breathing room. Left is always the
        // breathing room so the tile centres predictably.
        let topPad: CGFloat = hasBadge ? badgeSize / 2 : edgePad
        let rightPad: CGFloat = hasBadge ? badgeSize / 2 : edgePad
        let leftPad: CGFloat = edgePad

        let canvasW = leftPad + side + rightPad
        let canvasH = topPad + side + pointerH
        let tileRect = CGRect(x: leftPad, y: topPad, width: side, height: side)
        let tip = CGPoint(x: leftPad + side / 2, y: topPad + side + pointerH)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasW, height: canvasH))
        let image = renderer.image { rctx in
            let cg = rctx.cgContext

            // --- Silhouette (rounded tile + pointer). Filled with the edge
            //     colour, but the content is painted over the tile, so with
            //     edgeWidth 0 only the pointer stem shows the colour. ---
            let silhouette = UIBezierPath(roundedRect: tileRect, cornerRadius: corner)
            let pointer = UIBezierPath()
            let baseY = tileRect.maxY - 0.5
            pointer.move(to: CGPoint(x: tip.x - pointerHalf, y: baseY))
            pointer.addLine(to: CGPoint(x: tip.x + pointerHalf, y: baseY))
            pointer.addLine(to: tip)
            pointer.close()
            silhouette.append(pointer)

            edge.setFill()
            silhouette.fill()
            // Soft dark hairline so an edge-to-edge photo still reads as a
            // discrete tile on a light map. This is the only edge left.
            UIColor.black.withAlphaComponent(0.10).setStroke()
            silhouette.lineWidth = 0.5
            silhouette.stroke()

            // --- Interior, clipped to the (optionally inset) rounded rect ---
            let innerRect = tileRect.insetBy(dx: edgeWidth, dy: edgeWidth)
            cg.saveGState()
            UIBezierPath(roundedRect: innerRect, cornerRadius: max(corner - edgeWidth, 1)).addClip()
            switch content {
            case .photo(let photo):
                drawAspectFill(photo, in: innerRect)
            case .placeholder(let icon, let fill):
                fill.setFill()
                UIRectFill(innerRect)
                drawCenteredSymbol(icon, pointSize: 17, weight: .semibold, in: innerRect)
            case .count(let count, let fill):
                fill.setFill()
                UIRectFill(innerRect)
                // Shrink the font for 3-digit clusters so "100+" stays in.
                let fontSize: CGFloat = count >= 100 ? 13 : 16
                let text = "\(count)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .heavy),
                    .foregroundColor: UIColor.white
                ]
                let textSize = text.size(withAttributes: attrs)
                text.draw(
                    at: CGPoint(
                        x: innerRect.midX - textSize.width / 2,
                        y: innerRect.midY - textSize.height / 2
                    ),
                    withAttributes: attrs
                )
            }
            cg.restoreGState()

            // --- Corner badge (white halo + coloured disc + glyph) ---
            if let badge {
                let badgeRect = CGRect(
                    x: tileRect.maxX - badgeSize * 0.62,
                    y: tileRect.minY - badgeSize * 0.38,
                    width: badgeSize,
                    height: badgeSize
                )
                UIColor.white.setFill()
                UIBezierPath(ovalIn: badgeRect.insetBy(dx: -1.0, dy: -1.0)).fill()
                badge.fill.setFill()
                UIBezierPath(ovalIn: badgeRect).fill()
                drawCenteredSymbol(badge.icon, pointSize: 9, weight: .bold, in: badgeRect)
            }
        }

        // Anchor the pointer TIP on the coordinate.
        let offset = CGPoint(x: canvasW / 2 - tip.x, y: canvasH / 2 - tip.y)
        return (image, offset)
    }

    /// Draw `image` filling `rect` (center-crop, no distortion). Caller is
    /// responsible for clipping to the rounded shape first.
    static func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        let s = image.size
        guard s.width > 0, s.height > 0 else { image.draw(in: rect); return }
        let scale = max(rect.width / s.width, rect.height / s.height)
        let drawSize = CGSize(width: s.width * scale, height: s.height * scale)
        let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        image.draw(in: CGRect(origin: origin, size: drawSize))
    }

    /// Tint an SF Symbol white and draw it centred in `rect`.
    private static func drawCenteredSymbol(_ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight, in rect: CGRect) {
        guard let icon = UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        )?.withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
        icon.draw(in: CGRect(
            x: rect.midX - icon.size.width / 2,
            y: rect.midY - icon.size.height / 2,
            width: icon.size.width,
            height: icon.size.height
        ))
    }
}

// MARK: - Individual Pin

class PlacePinAnnotationView: MKAnnotationView {
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = "place"
        collisionMode = .circle
        displayPriority = .defaultHigh
        // Seed a stable collision frame up front. MapKit's clustering pass
        // measures each annotation view's frame to decide what overlaps, but
        // our tile only gets a size once `prepareForDisplay` draws its image
        // (and place photos load async after that). Without a size here, the
        // first cluster pass can run against a zero/default frame and decide
        // NOT to merge overlapping pins — which is exactly why clustering
        // looked intermittent on first render. Starting from the known tile
        // geometry makes the decision deterministic; `prepareForDisplay` then
        // refreshes the image at the same size.
        let base = MapPinTile.baseFrame
        bounds = CGRect(origin: .zero, size: base.size)
        centerOffset = base.centerOffset
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The red × delete badge overhangs this view's bounds (it sits on
    /// the tile's top-right corner and pokes up-and-right). UIKit only
    /// delivers touches to subviews within the parent's bounds, so
    /// without this override a tap on the overhanging part of the × falls
    /// straight through and the pin never gets deleted. Explicitly
    /// hit-test the badge first, then fall back to normal behaviour.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let badge = viewWithTag(ClusteredMapView.deleteButtonTag) {
            let local = convert(point, to: badge)
            if badge.bounds.contains(local) { return badge }
        }
        return super.hitTest(point, with: event)
    }

    /// Bumped on every `prepareForDisplay`. An in-flight async photo load
    /// captures the value at kickoff and only applies its result if the
    /// generation still matches — so a reused view (MapKit recycles
    /// annotation views) never gets a late image for the wrong place.
    private var loadGeneration = 0

    override func prepareForDisplay() {
        super.prepareForDisplay()
        guard let pa = annotation as? PlaceAnnotation else { return }

        let place = pa.place
        let listName = pa.listName

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1.5)

        loadGeneration &+= 1
        let gen = loadGeneration

        // Photo source mirrors PlaceCardSheet: the imported `imageURL` when
        // the place has one (Google Maps photo, Reel cover). Photo-less
        // places render the category-coloured tile + glyph (handled by
        // `renderTile` when `photo` is nil) rather than a stand-in stock
        // photo — same as the card the user taps through to.
        let photoURL = place.imageURL

        // Draw the tile immediately. If we already have the photo cached,
        // use it; otherwise show the category placeholder and fetch.
        let cached = photoURL.flatMap { Self.imageCache.object(forKey: $0 as NSURL) }
        apply(Self.renderTile(place: place, listName: listName, photo: cached))

        if cached == nil, let url = photoURL {
            Task { [weak self] in
                guard let img = await Self.loadThumbnail(url) else { return }
                await MainActor.run {
                    guard let self,
                          self.loadGeneration == gen,
                          (self.annotation as? PlaceAnnotation)?.place.id == place.id
                    else { return }
                    self.apply(Self.renderTile(place: place, listName: listName, photo: img))
                }
            }
        }
    }

    private func apply(_ result: (UIImage, CGPoint)) {
        image = result.0
        centerOffset = result.1
    }

    /// In-memory thumbnail cache, keyed by source URL. Shared across all
    /// pin views so panning back to a place doesn't re-download its photo.
    fileprivate static let imageCache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 300
        return c
    }()

    /// Download + downsample a place photo to a pin-sized thumbnail. Result
    /// is cached so subsequent pins for the same URL are instant.
    fileprivate static func loadThumbnail(_ url: URL) async -> UIImage? {
        if let cached = imageCache.object(forKey: url as NSURL) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let raw = UIImage(data: data) else { return nil }
        let thumb = downsample(raw, maxPoints: 120)
        imageCache.setObject(thumb, forKey: url as NSURL)
        return thumb
    }

    /// Shrink an image so its longest side is at most `maxPoints` (in points,
    /// at screen scale). Keeps pin photos tiny in memory — the tile is 40pt.
    private static func downsample(_ image: UIImage, maxPoints: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxPoints else { return image }
        let ratio = maxPoints / longest
        let target = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Rounded photo-tile pin: the place's photo (or a category-coloured
    /// placeholder) in the shared `MapPinTile` geometry, wrapped in the
    /// white edge. Time-limited events get the amber clock badge. All
    /// geometry lives in `MapPinTile.render` — this just supplies the
    /// place-specific content + accent.
    private static func renderTile(place: Place, listName: String?, photo: UIImage?) -> (UIImage, CGPoint) {
        // Accent = list colour if the pin belongs to a list, else the
        // default per-place heuristic. Used for the no-photo placeholder.
        let accent: UIColor = {
            if let listName, !listName.isEmpty {
                return UIColor(ListVisualStyle.style(for: listName).color)
            }
            return Self.pinColor(for: place)
        }()

        let content: MapPinTile.Content = photo.map { .photo($0) }
            ?? .placeholder(icon: place.category.icon, fill: accent)

        return MapPinTile.render(
            content: content,
            edge: .white,
            badge: place.isEvent ? .event : nil
        )
    }

    private static func pinColor(for place: Place) -> UIColor {
        // If the user has personally reviewed, use primary turquoise.
        if place.review != nil {
            return UIColor(SomedayColors.primary)
        }
        // Else color by recommender or whoever rated it.
        if let rid = place.recommendedBy {
            return UIColor(SomedayColors.friendColor(for: abs(rid.hashValue)))
        }
        if let rid = place.friendRatings.keys.first {
            return UIColor(SomedayColors.friendColor(for: abs(rid.hashValue)))
        }
        return UIColor(SomedayColors.primary)
    }
}

// MARK: - AI Suggestion Pin

/// Value type shipped from `MapViewModel` into `ClusteredMapView` for
/// each AI-proposed venue. Kept simple so the SwiftUI side can stash
/// them in an array and let `syncSuggestions` diff by id.
struct SuggestedPin: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let category: String?
    /// One- or two-sentence blurb the AI shipped with the suggestion.
    /// Shown in the bottom info tile when the user taps the pin and in
    /// the "Discover all" carousel. Nil when the suggest link didn't
    /// carry a `description=` query item (older messages, or the model
    /// being terse — in which case the tile falls back to category +
    /// neighbourhood).
    let description: String?
    /// Opening hours blurb the AI shipped, free-form ("Tue–Sun, 09–17").
    /// Surfaced in the expanded suggestion tile when present.
    let hours: String?
    /// Ticket / entry pricing blurb ("€22 · free under 18", "Free entry").
    /// Same expand-only treatment as `hours`.
    let price: String?
    /// Official website URL the AI surfaced. Rendered as a tappable
    /// link in the expanded tile when present and well-formed.
    let website: String?
    /// Phone number string (raw, including spaces / + prefix). Rendered
    /// as a tappable tel: link in the expanded tile.
    let phone: String?
    let latitude: Double
    let longitude: Double
    /// Wall-clock moment the suggestion first landed on the map. Defaults
    /// to "now" so freshly-built pins start their clock immediately, but
    /// it's `Codable` and preserved across upserts + app restarts so a
    /// suggestion expires exactly 24h after it first appeared — not 24h
    /// after the most recent relaunch. See `lifetime` / `isExpired`.
    var createdAt: Date = .now

    // MARK: Expiry

    /// How long a chatbot-suggested pin lingers on the map before it's
    /// swept away if the user never saves it to a list: one real day.
    static let lifetime: TimeInterval = 24 * 60 * 60

    /// The wall-clock instant this suggestion drops off the map.
    var expiresAt: Date { createdAt.addingTimeInterval(Self.lifetime) }

    /// True once the 24h window has elapsed — the sweep timer removes it.
    var isExpired: Bool { expiresAt <= Date() }

    /// Seconds left before expiry, floored at zero. Drives the countdown
    /// pill in the suggestion tile.
    var secondsRemaining: TimeInterval { max(0, expiresAt.timeIntervalSinceNow) }

    // MARK: Identity
    //
    // Equality / hashing deliberately ignore `createdAt` so a re-suggested
    // pin (same venue, fresher payload) compares equal to the lingering
    // one and the upsert logic can choose which to keep without the clock
    // tick making every pin look "changed" to SwiftUI's diffing.

    static func == (lhs: SuggestedPin, rhs: SuggestedPin) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.category == rhs.category &&
        lhs.description == rhs.description &&
        lhs.hours == rhs.hours &&
        lhs.price == rhs.price &&
        lhs.website == rhs.website &&
        lhs.phone == rhs.phone &&
        lhs.latitude == rhs.latitude &&
        lhs.longitude == rhs.longitude
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension SuggestedPin: Hashable {}

/// Distinct pin renderer for AI suggestions. Lime fill + sparkle glyph
/// reads instantly as "this is an AI proposal, not one of your saved
/// pins". Disables clustering so a tight cluster of suggestions still
/// stands out next to the user's pin clusters.
class SuggestionPinAnnotationView: MKAnnotationView {
    static let reuseID = "SuggestionPin"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = nil       // never cluster with saved pins
        collisionMode = .circle
        displayPriority = .required      // outrank place pins when overlapping
        canShowCallout = true            // small native callout w/ name
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Bumped per `prepareForDisplay` so a recycled view never applies a
    /// late photo for the wrong suggestion. Mirrors `PlacePinAnnotationView`.
    private var loadGeneration = 0

    override func prepareForDisplay() {
        super.prepareForDisplay()
        guard let sa = annotation as? SuggestionAnnotation else { return }

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1.5)

        // Resolve the AI's free-form category string to our enum so the
        // photo-less tile shows the right glyph.
        let category = sa.category
            .flatMap { PlaceCategory(rawValue: $0.lowercased()) } ?? .food

        // AI suggestions never carry a real photo, so render the lime
        // category-glyph tile directly. We no longer fabricate a category
        // stock photo — the pin shows its category icon instead.
        apply(Self.renderTile(category: category, photo: nil))
    }

    private func apply(_ result: (UIImage, CGPoint)) {
        image = result.0
        centerOffset = result.1
    }

    /// Photo-tile pin for AI suggestions: the same shared `MapPinTile`
    /// geometry as saved pins, but the edge is lime and a sparkle badge
    /// always rides the corner — so an AI proposal reads as distinct while
    /// sharing the one tile language. The no-photo placeholder fills lime
    /// too.
    private static func renderTile(category: PlaceCategory, photo: UIImage?) -> (UIImage, CGPoint) {
        let lime = UIColor(SomedayColors.lime)
        let content: MapPinTile.Content = photo.map { .photo($0) }
            ?? .placeholder(icon: category.icon, fill: lime)
        return MapPinTile.render(content: content, edge: lime, badge: .suggestion)
    }
}

// MARK: - Cluster

class ClusterPinAnnotationView: MKAnnotationView {
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .circle
        displayPriority = .defaultHigh
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        guard let cluster = annotation as? MKClusterAnnotation else { return }

        let count = cluster.memberAnnotations.count

        // List affinity: if every clustered place belongs to the SAME
        // custom list, tint the cluster in that list's deterministic
        // colour so the cluster visually reads as "this is part of <list>".
        // Mixed-list clusters (or any pin not in a list) fall back to
        // brand primary — the existing default.
        //
        // `syncAnnotations` in the SwiftUI wrapper drops + re-adds any
        // annotation whose listName changed, so prepareForDisplay fires
        // again and the cluster recolours automatically when the user
        // moves a pin between lists.
        let members = cluster.memberAnnotations.compactMap { $0 as? PlaceAnnotation }
        let allMembersArePlace = members.count == count
        let listNames = Set(members.compactMap(\.listName))
        let allMembersListed = members.allSatisfy { $0.listName != nil }
        let color: UIColor
        if allMembersArePlace,
           allMembersListed,
           listNames.count == 1,
           let unifiedName = listNames.first {
            color = UIColor(ListVisualStyle.style(for: unifiedName).color)
        } else {
            color = UIColor(SomedayColors.primary)
        }

        let (img, offset) = Self.renderCountTile(count: count, accent: color)
        image = img
        centerOffset = offset

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1.5)
    }

    /// Cluster tile in the **same photo-tile format** as the place pins —
    /// a rounded tile with a little pointer tapering to the coordinate —
    /// filled with the accent colour and the member count instead of a
    /// photo. Uses the shared `MapPinTile` geometry so a cluster reads as
    /// "a stack of those tiles" rather than a different shape entirely.
    private static func renderCountTile(count: Int, accent: UIColor) -> (UIImage, CGPoint) {
        MapPinTile.render(content: .count(count, fill: accent), edge: .white)
    }
}
