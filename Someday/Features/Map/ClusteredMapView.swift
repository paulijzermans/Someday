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

    init(place: Place) {
        self.place = place
        super.init()
        coordinate = place.coordinate
        title = place.name
    }
}

struct ClusteredMapView: UIViewRepresentable {
    let places: [Place]
    @Binding var region: MKCoordinateRegion
    let onSelectPlace: (Place) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.setRegion(region, animated: false)

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

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        syncAnnotations(on: mapView)

        if Self.significantlyDifferent(mapView.region, region) {
            mapView.setRegion(region, animated: true)
        }
    }

    private func syncAnnotations(on mapView: MKMapView) {
        let existing = mapView.annotations.compactMap { $0 as? PlaceAnnotation }
        let existingIDs = Set(existing.map { $0.place.id })
        let newIDs = Set(places.map(\.id))

        let toRemove = existing.filter { !newIDs.contains($0.place.id) }
        if !toRemove.isEmpty { mapView.removeAnnotations(toRemove) }

        let toAdd = places.filter { !existingIDs.contains($0.id) }.map { PlaceAnnotation(place: $0) }
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
            } else if let cluster = annotation as? MKClusterAnnotation {
                isProgrammatic = true
                let zoomed = MKCoordinateRegion(
                    center: cluster.coordinate,
                    span: MKCoordinateSpan(
                        latitudeDelta: mapView.region.span.latitudeDelta * 0.4,
                        longitudeDelta: mapView.region.span.longitudeDelta * 0.4
                    )
                )
                mapView.setRegion(zoomed, animated: true)
            }
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
        let (img, offset) = Self.renderPin(place: place)
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
    private static func renderPin(place: Place) -> (UIImage, CGPoint) {
        let borderWidth: CGFloat = 1.5
        let bulbRadius: CGFloat = 7        // radius of the round head
        let tipDrop: CGFloat = 11          // how far the point extends below the head center

        let baseColor = Self.pinColor(for: place)
        let isVisited = place.displayedRating?.value != nil
        let fillColor = isVisited ? baseColor.darkened(by: 0.35) : baseColor

        // Small source logo on the head for unvisited, non-manual saves.
        let showSourceBadge = !isVisited && place.source != .manual
        let badgeSize: CGFloat = 9

        // Pin region (head + point), before any badge extension.
        let pinW = bulbRadius * 2
        let pinH = bulbRadius + tipDrop

        // Badge sits on the upper-right of the head; it may extend the canvas up/right.
        var topExt: CGFloat = 0
        var rightExt: CGFloat = 0
        var badgeCenterInPin = CGPoint.zero
        if showSourceBadge {
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

            if showSourceBadge {
                let badgeRect = CGRect(
                    x: badgeCenterInPin.x - badgeSize / 2,
                    y: badgeCenterInPin.y - badgeSize / 2 + topExt,
                    width: badgeSize,
                    height: badgeSize
                )

                if let logo = UIImage(named: place.source.assetName ?? "") {
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
        let color = UIColor(SomedayColors.primary)

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
