//  ChatAction.swift
//  Someday
//
//  The shared command vocabulary between the AI chat and the app's UI.
//
//  The assistant drives the interface by embedding `someday://` links in
//  its replies (and the place-card / membership UIs reuse the same
//  scheme). Historically each tap site re-parsed the raw URL inline. This
//  type centralises that parsing into ONE typed decode step so:
//
//    • every surface decodes a link the same way (no drift between the
//      chat renderer and the map handler),
//    • new bot-driven behaviours (open the membership editor, ask about a
//      place, frame a set) are a single new enum case + switch arm rather
//      than another bespoke string parse,
//    • the side effects (haptics, camera, VM mutation) stay in the view
//      layer — this file is pure data: URL in, intent out.
//
//  `ChatAction(url:)` returns nil for anything that isn't a recognised
//  `someday://` command, so callers can fall back to the system handler
//  (http(s) links still open in Safari).

import Foundation

/// A single intent the chat / UI can ask the map surface to perform.
/// Decoded from a `someday://` URL via `init?(url:)`. The view layer
/// switches over this and applies the matching side effects.
enum ChatAction: Equatable {
    /// `someday://place/<id>` — a saved pin. Recenter + open its card
    /// (or, in peek mode, surface it inline in the chat).
    case openPlace(id: String)

    /// `someday://suggest?lat=…&lon=…&name=…&…` — an AI-proposed venue
    /// or event that isn't on the user's map yet. Carries the full
    /// `SuggestedPin` so the carousel / hint can render without a
    /// second parse.
    case suggest(SuggestedPin)

    /// `someday://list/<name>` — focus the map on a saved list.
    case openList(name: String)

    /// `someday://create-list?name=<name>` — create (or focus, if it
    /// already exists) a list. The tap itself is the confirmation.
    case createList(name: String)

    /// `someday://edit-membership?place=<id>` — open the multi-list
    /// membership editor for a saved pin. Lets the assistant offer
    /// "want to file this somewhere?" and have the tap drop the user
    /// straight into the Lists overlay in toggle mode.
    case editMembership(placeID: String)

    /// `someday://ask?place=<id>` — open the chat with this saved pin
    /// bound as the conversation's context. Emitted by the "Ask
    /// Someday about this" affordance on the pin_tile.
    case askAbout(placeID: String)

    /// `someday://show?lat=…&lon=…&name=…&span=…` — fly the map camera
    /// to an arbitrary location (a country, city, neighbourhood,
    /// landmark) WITHOUT dropping a pin or opening a card. Lets the user
    /// say "show me France" / "take me to Lisbon" and have the map just
    /// go there. `span` is the camera's degree span (both axes); larger
    /// = more zoomed out (country ≈ 6, city ≈ 0.2, block ≈ 0.01).
    /// Optional — the view layer falls back to a sane default.
    case showOnMap(name: String, latitude: Double, longitude: Double, span: Double?)

    /// `someday://route?from=<id>&to=<id>` — draw a travel route between
    /// two of the user's SAVED pins. The map resolves both ids to their
    /// coordinates, computes the polyline via `MKDirections` (walking /
    /// driving / transit), frames both ends, and shows a floating mode
    /// toggle + ETA/distance readout. Carries only the two pin ids; the
    /// VM owns the coordinate lookup + the route computation so the link
    /// stays tiny and the model never has to know lat/lon for a route.
    case route(fromID: String, toID: String)

    /// `someday://plan` — re-frame the day plan the chat agent most
    /// recently built via `create_itinerary`. The plan itself arrives over
    /// the SSE `mutation` channel (not as a link), so this carries no
    /// payload; it just asks the map to fit the active itinerary's stops
    /// again. Lets the assistant close a planning reply with a "See the
    /// whole day" affordance.
    case planDay

    /// Decode a `someday://` command URL. Returns nil for unrecognised
    /// schemes / hosts so callers can defer to the system handler.
    init?(url: URL) {
        guard url.scheme == "someday" else { return nil }

        switch url.host {
        case "place":
            // `URL.path` looks like "/<id>"; drop the leading slash. The
            // model may emit `someday://place/<id>?list=<name>` — we only
            // need the id here.
            let raw = url.path.split(separator: "/").first.map(String.init)
                ?? url.lastPathComponent
            guard !raw.isEmpty else { return nil }
            self = .openPlace(id: raw)

        case "suggest":
            guard let pin = ChatAction.parseSuggestedPin(from: url) else { return nil }
            self = .suggest(pin)

        case "list":
            let raw = url.path.hasPrefix("/")
                ? String(url.path.dropFirst())
                : url.path
            let decoded = raw.removingPercentEncoding ?? raw
            guard !decoded.isEmpty else { return nil }
            self = .openList(name: decoded)

        case "create-list":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard
                let name = comps?.queryItems?
                    .first(where: { $0.name == "name" })?.value?
                    .removingPercentEncoding,
                !name.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            self = .createList(name: name.trimmingCharacters(in: .whitespaces))

        case "edit-membership":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard
                let id = comps?.queryItems?
                    .first(where: { $0.name == "place" })?.value,
                !id.isEmpty
            else { return nil }
            self = .editMembership(placeID: id)

        case "ask":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard
                let id = comps?.queryItems?
                    .first(where: { $0.name == "place" })?.value,
                !id.isEmpty
            else { return nil }
            self = .askAbout(placeID: id)

        case "show":
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            guard
                let items = comps?.queryItems,
                let latStr = items.first(where: { $0.name == "lat" })?.value,
                let lonStr = items.first(where: { $0.name == "lon" })?.value,
                let lat = Double(latStr),
                let lon = Double(lonStr)
            else { return nil }
            let name = items.first(where: { $0.name == "name" })?.value?
                .removingPercentEncoding ?? "Location"
            let span = items.first(where: { $0.name == "span" })?.value
                .flatMap(Double.init)
            self = .showOnMap(name: name, latitude: lat, longitude: lon, span: span)

        case "route":
            // `someday://route?from=<id>&to=<id>` — both ids must be
            // present; the VM resolves them to saved pins (and discards
            // if either isn't on the map).
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = comps?.queryItems ?? []
            guard
                let from = items.first(where: { $0.name == "from" })?.value,
                let to = items.first(where: { $0.name == "to" })?.value,
                !from.isEmpty, !to.isEmpty
            else { return nil }
            self = .route(fromID: from, toID: to)

        case "plan":
            // No payload — the plan lives on the VM (set when the
            // create_itinerary mutation was applied). The tap just re-frames it.
            self = .planDay

        default:
            return nil
        }
    }

    /// Build a `SuggestedPin` from a `someday://suggest?...` URL. Shared
    /// by `init?(url:)` and the chat bubble's bulk-suggestion scanner so
    /// the two never disagree on how a suggest link maps to a pin
    /// (id-derivation included).
    static func parseSuggestedPin(from url: URL) -> SuggestedPin? {
        guard
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = comps.queryItems,
            let latStr = items.first(where: { $0.name == "lat" })?.value,
            let lonStr = items.first(where: { $0.name == "lon" })?.value,
            let lat = Double(latStr),
            let lon = Double(lonStr)
        else { return nil }
        let name = items.first(where: { $0.name == "name" })?.value ?? "Suggested place"
        let category = items.first(where: { $0.name == "category" })?.value
        let description = items.first(where: { $0.name == "description" })?.value
        let hours = items.first(where: { $0.name == "hours" })?.value
        let price = items.first(where: { $0.name == "price" })?.value
        let website = items.first(where: { $0.name == "website" })?.value
        let phone = items.first(where: { $0.name == "phone" })?.value
        return SuggestedPin(
            id: ChatAction.suggestionID(name: name, lat: lat, lon: lon),
            name: name,
            category: category,
            description: description,
            hours: hours,
            price: price,
            website: website,
            phone: phone,
            latitude: lat,
            longitude: lon
        )
    }

    /// Stable id for an AI suggestion, derived from its name + rounded
    /// coordinate. Same recipe the carousel / map upsert keys off, so a
    /// pin parsed here dedupes against one dropped via `focusOnAISuggestion`.
    static func suggestionID(name: String, lat: Double, lon: Double) -> String {
        let key = String(format: "%@@%.5f,%.5f", name.lowercased(), lat, lon)
        return key.data(using: .utf8)?.base64EncodedString() ?? key
    }
}
