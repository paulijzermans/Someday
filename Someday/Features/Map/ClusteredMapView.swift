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
        // the place has one (Google Maps photo, Reel cover), otherwise a
        // category-keyed stock photo so every pin shows imagery — same as
        // the card the user taps through to.
        let photoURL = place.imageURL ?? Self.categoryFallbackImageURL(place.category)

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

    /// Same curated Unsplash stock photo per category that PlaceCardSheet
    /// uses, but requested at pin size (small crop → ~tens of kB). Keeps a
    /// pin's photo consistent with the card you tap through to.
    fileprivate static func categoryFallbackImageURL(_ category: PlaceCategory) -> URL? {
        let photoID: String
        switch category {
        case .food:     photoID = "photo-1414235077428-338989a2e8c0"
        case .drinks:   photoID = "photo-1551024601-bec78aea704b"
        case .coffee:   photoID = "photo-1495474472287-4d71bcdd2085"
        case .activity: photoID = "photo-1441974231531-c6227db76b6e"
        case .art:      photoID = "photo-1531058020387-3be344556be6"
        case .travel:   photoID = "photo-1488646953014-85cb44e25828"
        }
        return URL(string: "https://images.unsplash.com/\(photoID)?w=160&h=160&fit=crop&q=80")
    }

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

    /// Rounded photo-tile pin: a small rounded-square showing the place's
    /// photo (or a category-coloured placeholder when there's none), wrapped
    /// in a white edge, with a little pointer tapering to the coordinate.
    /// Time-limited events keep the amber clock badge on the top-right.
    private static func renderTile(place: Place, listName: String?, photo: UIImage?) -> (UIImage, CGPoint) {
        let tileSide: CGFloat = 40
        let corner: CGFloat = 11
        let border: CGFloat = 2.5          // the white edge thickness
        let pointerH: CGFloat = 7
        let pointerHalf: CGFloat = 6.5

        let isEvent = place.isEvent
        let badgeSize: CGFloat = 15
        // Reserve room top/right for the event badge overhang (and a hair of
        // padding for the outer hairline + anti-aliasing on every pin).
        let topPad: CGFloat = isEvent ? badgeSize / 2 : 1.5
        let rightPad: CGFloat = isEvent ? badgeSize / 2 : 1.5
        let leftPad: CGFloat = 1.5

        let canvasW = leftPad + tileSide + rightPad
        let canvasH = topPad + tileSide + pointerH

        let tileRect = CGRect(x: leftPad, y: topPad, width: tileSide, height: tileSide)
        let tip = CGPoint(x: leftPad + tileSide / 2, y: topPad + tileSide + pointerH)

        // Accent = list colour if the pin belongs to a list, else the
        // default per-place heuristic. Used for the no-photo placeholder.
        let accent: UIColor = {
            if let listName, !listName.isEmpty {
                return UIColor(ListVisualStyle.style(for: listName).color)
            }
            return Self.pinColor(for: place)
        }()

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasW, height: canvasH))
        let image = renderer.image { rctx in
            let cg = rctx.cgContext

            // --- White silhouette (rounded tile + pointer) = the edge ---
            let silhouette = UIBezierPath(roundedRect: tileRect, cornerRadius: corner)
            let pointer = UIBezierPath()
            let baseY = tileRect.maxY - 0.5
            pointer.move(to: CGPoint(x: tip.x - pointerHalf, y: baseY))
            pointer.addLine(to: CGPoint(x: tip.x + pointerHalf, y: baseY))
            pointer.addLine(to: tip)
            pointer.close()
            silhouette.append(pointer)

            UIColor.white.setFill()
            silhouette.fill()
            // Subtle outer hairline so the white edge stays legible on light maps.
            UIColor.black.withAlphaComponent(0.10).setStroke()
            silhouette.lineWidth = 0.5
            silhouette.stroke()

            // --- Inner content, clipped to a rounded rect inset by the edge ---
            let innerRect = tileRect.insetBy(dx: border, dy: border)
            cg.saveGState()
            UIBezierPath(roundedRect: innerRect, cornerRadius: corner - border).addClip()
            if let photo {
                drawAspectFill(photo, in: innerRect)
            } else {
                accent.setFill()
                UIRectFill(innerRect)
                if let icon = UIImage(
                    systemName: place.category.icon,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
                )?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                    icon.draw(in: CGRect(
                        x: innerRect.midX - icon.size.width / 2,
                        y: innerRect.midY - icon.size.height / 2,
                        width: icon.size.width,
                        height: icon.size.height
                    ))
                }
            }
            cg.restoreGState()

            // --- Event clock badge (top-right, overhanging the tile) ---
            if isEvent {
                let badgeRect = CGRect(
                    x: tileRect.maxX - badgeSize * 0.62,
                    y: tileRect.minY - badgeSize * 0.38,
                    width: badgeSize,
                    height: badgeSize
                )
                UIColor.white.setFill()
                UIBezierPath(ovalIn: badgeRect.insetBy(dx: -1.0, dy: -1.0)).fill()
                UIColor(red: 0.98, green: 0.62, blue: 0.10, alpha: 1).setFill()
                UIBezierPath(ovalIn: badgeRect).fill()
                if let icon = UIImage(
                    systemName: "clock.fill",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
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

        // Anchor the pointer TIP on the coordinate.
        let offset = CGPoint(x: canvasW / 2 - tip.x, y: canvasH / 2 - tip.y)
        return (image, offset)
    }

    /// Draw `image` filling `rect` (center-crop, no distortion). Caller is
    /// responsible for clipping to the rounded shape first.
    fileprivate static func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        let s = image.size
        guard s.width > 0, s.height > 0 else { image.draw(in: rect); return }
        let scale = max(rect.width / s.width, rect.height / s.height)
        let drawSize = CGSize(width: s.width * scale, height: s.height * scale)
        let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        image.draw(in: CGRect(origin: origin, size: drawSize))
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

        // Resolve the AI's free-form category string to our enum so we can
        // pick the same category-keyed stock photo a saved pin would use.
        let category = sa.category
            .flatMap { PlaceCategory(rawValue: $0.lowercased()) } ?? .food

        loadGeneration &+= 1
        let gen = loadGeneration

        // Suggestions never carry their own image, so always fall back to
        // the category stock photo — same source PlaceCardSheet / saved
        // pins use, so the photo-tile reads consistently.
        let photoURL = PlacePinAnnotationView.categoryFallbackImageURL(category)
        let cached = photoURL.flatMap {
            PlacePinAnnotationView.imageCache.object(forKey: $0 as NSURL)
        }
        apply(Self.renderTile(category: category, photo: cached))

        if cached == nil, let url = photoURL {
            Task { [weak self] in
                guard let img = await PlacePinAnnotationView.loadThumbnail(url) else { return }
                await MainActor.run {
                    guard let self,
                          self.loadGeneration == gen,
                          (self.annotation as? SuggestionAnnotation)?.suggestionID == sa.suggestionID
                    else { return }
                    self.apply(Self.renderTile(category: category, photo: img))
                }
            }
        }
    }

    private func apply(_ result: (UIImage, CGPoint)) {
        image = result.0
        centerOffset = result.1
    }

    /// Photo-tile pin for AI suggestions: identical rounded-square / pointer
    /// geometry to `PlacePinAnnotationView.renderTile`, but the white edge is
    /// swapped for lime so an AI proposal still reads as distinct from the
    /// user's saved pins while sharing the same tile language.
    private static func renderTile(category: PlaceCategory, photo: UIImage?) -> (UIImage, CGPoint) {
        let tileSide: CGFloat = 40
        let corner: CGFloat = 11
        let border: CGFloat = 2.5
        let pointerH: CGFloat = 7
        let pointerHalf: CGFloat = 6.5
        let pad: CGFloat = 1.5

        let canvasW = pad + tileSide + pad
        let canvasH = pad + tileSide + pointerH
        let tileRect = CGRect(x: pad, y: pad, width: tileSide, height: tileSide)
        let tip = CGPoint(x: pad + tileSide / 2, y: pad + tileSide + pointerH)

        let limeUI = UIColor(SomedayColors.lime)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasW, height: canvasH))
        let image = renderer.image { rctx in
            let cg = rctx.cgContext

            // --- Lime silhouette (rounded tile + pointer) = the edge ---
            let silhouette = UIBezierPath(roundedRect: tileRect, cornerRadius: corner)
            let pointer = UIBezierPath()
            let baseY = tileRect.maxY - 0.5
            pointer.move(to: CGPoint(x: tip.x - pointerHalf, y: baseY))
            pointer.addLine(to: CGPoint(x: tip.x + pointerHalf, y: baseY))
            pointer.addLine(to: tip)
            pointer.close()
            silhouette.append(pointer)

            limeUI.setFill()
            silhouette.fill()
            UIColor.black.withAlphaComponent(0.10).setStroke()
            silhouette.lineWidth = 0.5
            silhouette.stroke()

            // --- Inner content, clipped to a rounded rect inset by the edge ---
            let innerRect = tileRect.insetBy(dx: border, dy: border)
            cg.saveGState()
            UIBezierPath(roundedRect: innerRect, cornerRadius: corner - border).addClip()
            if let photo {
                PlacePinAnnotationView.drawAspectFill(photo, in: innerRect)
            } else {
                limeUI.setFill()
                UIRectFill(innerRect)
                if let icon = UIImage(
                    systemName: category.icon,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
                )?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                    icon.draw(in: CGRect(
                        x: innerRect.midX - icon.size.width / 2,
                        y: innerRect.midY - icon.size.height / 2,
                        width: icon.size.width,
                        height: icon.size.height
                    ))
                }
            }
            cg.restoreGState()

            // --- Sparkle badge (top-right) so the AI identity stays legible
            // even when the photo fills the tile ---
            let badgeSize: CGFloat = 15
            let badgeRect = CGRect(
                x: tileRect.maxX - badgeSize * 0.62,
                y: tileRect.minY - badgeSize * 0.38,
                width: badgeSize,
                height: badgeSize
            )
            UIColor.white.setFill()
            UIBezierPath(ovalIn: badgeRect.insetBy(dx: -1.0, dy: -1.0)).fill()
            limeUI.setFill()
            UIBezierPath(ovalIn: badgeRect).fill()
            if let icon = UIImage(
                systemName: "sparkles",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            )?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                icon.draw(in: CGRect(
                    x: badgeRect.midX - icon.size.width / 2,
                    y: badgeRect.midY - icon.size.height / 2,
                    width: icon.size.width,
                    height: icon.size.height
                ))
            }
        }

        // Anchor the pointer TIP on the coordinate.
        let offset = CGPoint(x: canvasW / 2 - tip.x, y: canvasH / 2 - tip.y)
        return (image, offset)
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
    /// a rounded square wrapped in a white edge with a little pointer
    /// tapering to the coordinate — but filled with the accent colour and
    /// the member count instead of a photo. Geometry mirrors
    /// `PlacePinAnnotationView.renderTile` so a cluster reads as "a stack
    /// of those tiles" rather than a different shape entirely.
    private static func renderCountTile(count: Int, accent: UIColor) -> (UIImage, CGPoint) {
        let tileSide: CGFloat = 40
        let corner: CGFloat = 11
        let border: CGFloat = 2.5          // the white edge thickness
        let pointerH: CGFloat = 7
        let pointerHalf: CGFloat = 6.5
        let pad: CGFloat = 1.5             // hairline + anti-alias breathing room

        let canvasW = pad + tileSide + pad
        let canvasH = pad + tileSide + pointerH

        let tileRect = CGRect(x: pad, y: pad, width: tileSide, height: tileSide)
        let tip = CGPoint(x: pad + tileSide / 2, y: pad + tileSide + pointerH)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasW, height: canvasH))
        let image = renderer.image { rctx in
            let cg = rctx.cgContext

            // --- White silhouette (rounded tile + pointer) = the edge ---
            let silhouette = UIBezierPath(roundedRect: tileRect, cornerRadius: corner)
            let pointer = UIBezierPath()
            let baseY = tileRect.maxY - 0.5
            pointer.move(to: CGPoint(x: tip.x - pointerHalf, y: baseY))
            pointer.addLine(to: CGPoint(x: tip.x + pointerHalf, y: baseY))
            pointer.addLine(to: tip)
            pointer.close()
            silhouette.append(pointer)

            UIColor.white.setFill()
            silhouette.fill()
            UIColor.black.withAlphaComponent(0.10).setStroke()
            silhouette.lineWidth = 0.5
            silhouette.stroke()

            // --- Accent fill + count, clipped to the inset rounded rect ---
            let innerRect = tileRect.insetBy(dx: border, dy: border)
            cg.saveGState()
            UIBezierPath(roundedRect: innerRect, cornerRadius: corner - border).addClip()
            accent.setFill()
            UIRectFill(innerRect)

            // Shrink the font a touch for 3-digit clusters so "100+" stays
            // inside the tile.
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
            cg.restoreGState()
        }

        // Anchor the pointer TIP on the coordinate — same as the place pins.
        let offset = CGPoint(x: canvasW / 2 - tip.x, y: canvasH / 2 - tip.y)
        return (image, offset)
    }
}
