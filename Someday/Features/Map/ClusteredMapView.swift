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

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
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

        if Self.significantlyDifferent(mapView.region, region) {
            mapView.setRegion(region, animated: true)
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

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ClusteredMapView
        private var isProgrammatic = false

        init(_ parent: ClusteredMapView) {
            self.parent = parent
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

// MARK: - Individual Pin

class PlacePinAnnotationView: MKAnnotationView {
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = "place"
        collisionMode = .circle
        displayPriority = .defaultHigh
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForDisplay() {
        super.prepareForDisplay()
        guard let pa = annotation as? PlaceAnnotation else { return }

        let place = pa.place
        // Pass listName through so the renderer can swap in the list's
        // colour. Nil = use the default `pinColor(for:)` heuristic.
        let (img, offset) = Self.renderPin(place: place, listName: pa.listName)
        image = img
        centerOffset = offset

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    /// Single unified renderer:
    /// - White edge on every pin.
    /// - Visited (rated) pins use a darker fill and show the rating pill bottom-right.
    /// - Unvisited pins use the normal fill and show a source logo bottom-right (Instagram, Facebook, etc).
    private static func renderPin(place: Place, listName: String? = nil) -> (UIImage, CGPoint) {
        let borderWidth: CGFloat = 1.5
        let bulbRadius: CGFloat = 7        // radius of the round head
        let tipDrop: CGFloat = 11          // how far the point extends below the head center

        // List-colour override wins over the default heuristic so a pin's
        // colour matches the list it lives in (rose / blue / amber / …).
        let baseColor: UIColor
        let usingListColor: Bool
        if let listName, !listName.isEmpty {
            baseColor = UIColor(ListVisualStyle.style(for: listName).color)
            usingListColor = true
        } else {
            baseColor = Self.pinColor(for: place)
            usingListColor = false
        }
        // Visited-darkening only applies to default-coloured pins (no
        // list). When a pin's colour is dictated by its list, the list
        // identity is the signal we want to preserve — darkening it
        // would make pins in the same list visually disagree depending
        // on whether they happen to be reviewed. Keep them all on the
        // list's exact palette so the list reads as one cluster.
        let isVisited = place.displayedRating?.value != nil
        let fillColor = (isVisited && !usingListColor)
            ? baseColor.darkened(by: 0.35)
            : baseColor

        // Source-logo badge was previously rendered on the head for
        // unvisited, non-manual saves (Instagram pink, TikTok teal etc.)
        // — disabled because the third-party brand marks at this size
        // read as visual noise. The PlaceCardSheet's hero image still
        // shows the source badge for provenance.
        let showSourceBadge = false
        // Time-limited events get a small amber clock badge so they read
        // as "happening now / soon" and visually distinct from permanent
        // venues. Driven by `place.isEvent` (presence of an eventEnd).
        let isEvent = place.isEvent
        let badgeSize: CGFloat = isEvent ? 11 : 9
        let showBadge = showSourceBadge || isEvent

        // Pin region (head + point), before any badge extension.
        let pinW = bulbRadius * 2
        let pinH = bulbRadius + tipDrop

        // Badge sits on the upper-right of the head; it may extend the canvas up/right.
        var topExt: CGFloat = 0
        var rightExt: CGFloat = 0
        var badgeCenterInPin = CGPoint.zero
        if showBadge {
            badgeCenterInPin = CGPoint(x: pinW - 2.5, y: 2.5)
            let half = badgeSize / 2
            rightExt = max(0, badgeCenterInPin.x + half - pinW)
            topExt = max(0, half - badgeCenterInPin.y)
        }

        let canvasWidth = pinW + rightExt
        let canvasHeight = pinH + topExt

        // Everything is shifted down by topExt so nothing draws off-canvas.
        let center = CGPoint(x: bulbRadius, y: bulbRadius + topExt)
        let tip = CGPoint(x: center.x, y: center.y + tipDrop)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasWidth, height: canvasHeight))
        let image = renderer.image { _ in
            // White outline pin (the border)…
            UIColor.white.setFill()
            Self.pinPath(center: center, radius: bulbRadius, tipDrop: tipDrop).fill()
            // …then the colored body, inset by the border width.
            fillColor.setFill()
            Self.pinPath(center: center, radius: bulbRadius - borderWidth, tipDrop: tipDrop - borderWidth).fill()

            if showBadge {
                let badgeRect = CGRect(
                    x: badgeCenterInPin.x - badgeSize / 2,
                    y: badgeCenterInPin.y - badgeSize / 2 + topExt,
                    width: badgeSize,
                    height: badgeSize
                )

                if isEvent {
                    // Amber circle + white clock glyph, with a white halo so
                    // it separates cleanly from the pin head underneath.
                    UIColor.white.setFill()
                    UIBezierPath(ovalIn: badgeRect.insetBy(dx: -0.8, dy: -0.8)).fill()
                    UIColor(red: 0.98, green: 0.62, blue: 0.10, alpha: 1).setFill()
                    UIBezierPath(ovalIn: badgeRect).fill()

                    if let icon = UIImage(
                        systemName: "clock.fill",
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                    )?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                        icon.draw(in: CGRect(
                            x: badgeRect.midX - icon.size.width / 2,
                            y: badgeRect.midY - icon.size.height / 2,
                            width: icon.size.width,
                            height: icon.size.height
                        ))
                    }
                } else if let logo = UIImage(named: place.source.assetName ?? "") {
                    // Brand asset already has the correct shape; white halo separates it from the head.
                    UIColor.white.setFill()
                    UIBezierPath(ovalIn: badgeRect.insetBy(dx: -0.6, dy: -0.6)).fill()
                    logo.draw(in: badgeRect)
                } else {
                    // Fallback: colored circle + SF Symbol glyph
                    place.source.badgeColor.setFill()
                    UIBezierPath(ovalIn: badgeRect).fill()
                    UIColor.white.setStroke()
                    let stroke = UIBezierPath(ovalIn: badgeRect.insetBy(dx: 0.6, dy: 0.6))
                    stroke.lineWidth = 1.2
                    stroke.stroke()

                    if let icon = UIImage(
                        systemName: place.source.icon,
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 7, weight: .bold)
                    )?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                        icon.draw(in: CGRect(
                            x: badgeRect.midX - icon.size.width / 2,
                            y: badgeRect.midY - icon.size.height / 2,
                            width: icon.size.width,
                            height: icon.size.height
                        ))
                    }
                }
            }
        }

        // Anchor the pin's TIP on the coordinate.
        let offset = CGPoint(
            x: canvasWidth / 2 - tip.x,
            y: canvasHeight / 2 - tip.y
        )
        return (image, offset)
    }

    /// A classic map-pin outline: a circular head tapering to a point at the bottom.
    private static func pinPath(center: CGPoint, radius r: CGFloat, tipDrop L: CGFloat) -> UIBezierPath {
        let tip = CGPoint(x: center.x, y: center.y + L)
        let beta = acos(max(-1, min(1, r / L)))     // half-angle of the taper at the head center
        let rightAngle = CGFloat.pi / 2 - beta       // tangent point on the lower-right of the head
        let leftAngle = CGFloat.pi / 2 + beta        // tangent point on the lower-left
        let rightTangent = CGPoint(
            x: center.x + r * cos(rightAngle),
            y: center.y + r * sin(rightAngle)
        )

        let path = UIBezierPath()
        path.move(to: tip)
        path.addLine(to: rightTangent)
        // Sweep over the top of the head from the right tangent around to the left tangent.
        path.addArc(withCenter: center, radius: r, startAngle: rightAngle, endAngle: leftAngle, clockwise: false)
        path.close()
        return path
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
struct SuggestedPin: Identifiable, Equatable, Hashable, Sendable {
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
}

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

    override func prepareForDisplay() {
        super.prepareForDisplay()

        // Match `PlacePinAnnotationView` dimensions EXACTLY so the AI
        // suggestion pin reads as the same family of pin, just lime —
        // not a separate, oversized "AI banner" pin on the map. The
        // 7pt bulb radius / 11pt tipDrop / 1.5pt white border are the
        // saved-pin proportions; we just swap the fill for lime so the
        // user can spot AI proposals at a glance without breaking the
        // visual rhythm of the map.
        let bulbRadius: CGFloat = 7
        let tipDrop: CGFloat = 11
        let borderWidth: CGFloat = 1.5

        let canvasW = bulbRadius * 2
        let canvasH = bulbRadius + tipDrop
        let center = CGPoint(x: bulbRadius, y: bulbRadius)
        let tip = CGPoint(x: bulbRadius, y: bulbRadius + tipDrop)

        let limeUI = UIColor(SomedayColors.lime)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasW, height: canvasH))
        image = renderer.image { _ in
            // White outline pin path (head + point).
            UIColor.white.setFill()
            Self.pinPath(center: center, radius: bulbRadius, tipDrop: tipDrop).fill()

            // Lime body, inset by the border width on both bulb radius
            // AND tipDrop. Matches the two-pass fill PlacePinAnnotationView
            // uses, so the visual weight of the border is identical.
            limeUI.setFill()
            Self.pinPath(
                center: center,
                radius: bulbRadius - borderWidth,
                tipDrop: tipDrop - borderWidth
            ).fill()
        }

        // Anchor the pin's TIP on the coordinate — identical to the
        // saved-pin anchor maths so the lat/lon registers in the same
        // place visually.
        centerOffset = CGPoint(
            x: canvasW / 2 - tip.x,
            y: canvasH / 2 - tip.y
        )
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    /// Same teardrop shape as `PlacePinAnnotationView.pinPath` — same
    /// arguments, same maths, so the inner / outer pin layers inset
    /// identically. Kept as a private static here (rather than
    /// reaching across to PlacePinAnnotationView) to keep the two
    /// classes self-contained.
    private static func pinPath(center: CGPoint, radius r: CGFloat, tipDrop L: CGFloat) -> UIBezierPath {
        let tip = CGPoint(x: center.x, y: center.y + L)
        let beta = acos(max(-1, min(1, r / L)))
        let rightAngle = CGFloat.pi / 2 - beta
        let leftAngle = CGFloat.pi / 2 + beta
        let rightTangent = CGPoint(
            x: center.x + r * cos(rightAngle),
            y: center.y + r * sin(rightAngle)
        )
        let path = UIBezierPath()
        path.move(to: tip)
        path.addLine(to: rightTangent)
        path.addArc(withCenter: center, radius: r, startAngle: rightAngle, endAngle: leftAngle, clockwise: false)
        path.close()
        return path
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
        let size: CGFloat = 40

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

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        image = renderer.image { _ in
            color.withAlphaComponent(0.2).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size, height: size)).fill()

            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 5, y: 5, width: size - 10, height: size - 10)).fill()

            UIColor.white.setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: 5, y: 5, width: size - 10, height: size - 10))
            ring.lineWidth = 2
            ring.stroke()

            let text = "\(count)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = text.size(withAttributes: attrs)
            text.draw(
                at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
                withAttributes: attrs
            )
        }

        centerOffset = .zero
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }
}
