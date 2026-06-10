import Foundation
import Supabase
import MapKit

// =============================================================================
// ChatService — context-aware AI chatbot for the user's map
// =============================================================================
//
// Single contract `ChatService.send(history:context:)` returns the next
// assistant turn given the conversation so far plus a structured digest
// of the user's data (places, lists, friends). Implementations:
//
//   • `SupabaseChatService` — calls the `chat` Edge Function which proxies
//     to Claude. Lives server-side so the Anthropic key stays off device.
//   • `MockChatService`     — canned replies based on simple keyword
//     matching. Used when the function isn't deployed yet so the UI flow
//     still works for development.
//
// The Edge Function builds the system prompt at the server side from the
// `ChatContext` block, so the iOS app never authors the prompt text —
// just hands over the user's data and lets the function decide how to
// present it to Claude.

protocol ChatService: Sendable {
    /// Returns the next assistant turn. `history` includes all prior
    /// turns (user + assistant) AND the just-typed user message at the
    /// end. `context` is the structured digest of the user's data.
    ///
    /// Convenience wrapper around `stream(...)` — drains the event
    /// stream and returns just the concatenated text deltas. Use this
    /// when you don't care about agent progress events.
    func send(history: [ChatMessage], context: ChatContext) async throws -> String

    /// Streaming entrypoint. The implementation should emit:
    ///   • `.step(id, icon, label)` whenever the agent starts a unit of
    ///      visible work (web search, list inspection, etc.).
    ///   • `.stepDone(id)` when that step completes.
    ///   • `.textDelta(String)` for each chunk of the assistant's reply.
    ///   • `.done` exactly once when the entire response is finished.
    ///
    /// Termination: the stream throws on transport / server failure and
    /// finishes normally otherwise. Callers should treat the stream as
    /// single-use.
    func stream(history: [ChatMessage], context: ChatContext) -> AsyncThrowingStream<ChatEvent, Error>
}

/// Wire-level event emitted by `ChatService.stream(...)`. Modelled
/// after the SSE event types the Edge Function produces, but a typed
/// enum so the UI doesn't have to know about transport details.
enum ChatEvent: Sendable, Equatable {
    /// Agent started a unit of visible work. `icon` is an SF Symbol
    /// name picked by the server; `label` is the human-readable
    /// description ("Searching the web for 'X'", "Reading list 'Y'").
    case step(id: String, icon: String, label: String, chips: [String])
    /// Server-issued mutation request: the chat agent wants the iOS
    /// client to apply a side-effecting change (create/delete list,
    /// create/delete place) that the Edge Function can't do itself
    /// because it isn't authed as the user. The chat view model
    /// forwards this to a `mutationApplier` closure the screen wires
    /// to the appropriate `MapViewModel` method.
    case mutation(ChatMutation)
    /// Step `id` finished. The UI flips its spinner to a checkmark.
    case stepDone(id: String)
    /// Token(s) of the assistant's reply. Append to the current
    /// assistant message. Multiple deltas per response.
    case textDelta(String)
    /// Stream complete. After this, no more events will arrive.
    case done
}

/// Side-effecting actions the chat agent can request via SSE `mutation`
/// events. The Edge Function emits one of these when the model calls
/// `create_list` / `delete_list` / `create_place` / `delete_place`, and
/// the iOS chat view model forwards it to `MapViewModel` for both the
/// optimistic local update and the Supabase write (which has to happen
/// here because the Edge Function isn't authed as the user).
enum ChatMutation: Equatable, Sendable {
    case createList(name: String)
    case deleteList(name: String)
    case createPlace(
        name: String,
        latitude: Double,
        longitude: Double,
        category: String,
        listName: String?
    )
    case deletePlace(id: String)
}

// MARK: - Wire types

enum ChatRole: String, Codable, Sendable {
    case user, assistant
}

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    var id: UUID = UUID()
    let role: ChatRole
    var content: String
    /// Visible work steps the assistant took to produce this message
    /// ("Searching the web…", "Reading list 'Amsterdam'", etc.). Empty
    /// for user messages and for non-streaming responses. Populated by
    /// `ChatViewModel` as `ChatEvent.step` arrives during streaming.
    /// Excluded from the wire format — `CodingKeys` only includes
    /// role/content so old non-streaming servers still parse cleanly.
    var steps: [ChatStep] = []
    /// When set, this bubble renders an inline "availability card" for
    /// the place with this id — the in-chat mini-pin pill followed by
    /// the booking platforms / tonight pill. Used by the place-card's
    /// "Availability" CTA, which now dismisses the card and surfaces
    /// the result inside the chat thread instead of an inline panel.
    /// Excluded from the wire format — it's pure UI state.
    var attachedPlaceID: String? = nil
    /// Which inline card an `attachedPlaceID` bubble renders:
    ///   • `.availability` — booking platforms / "tonight?" check (the
    ///      place-card "Availability" CTA).
    ///   • `.peek` — a lightweight place preview (image + name +
    ///      category + "View on map") used when the user taps a saved
    ///      pin in chat or asks the bot about a place. Keeps the chat
    ///      open instead of navigating away.
    /// Ignored when `attachedPlaceID` is nil. Pure UI state — excluded
    /// from the wire format.
    var attachmentKind: ChatAttachmentKind = .availability

    enum CodingKeys: String, CodingKey { case role, content }
    init(
        role: ChatRole,
        content: String,
        steps: [ChatStep] = [],
        attachedPlaceID: String? = nil,
        attachmentKind: ChatAttachmentKind = .availability
    ) {
        self.role = role
        self.content = content
        self.steps = steps
        self.attachedPlaceID = attachedPlaceID
        self.attachmentKind = attachmentKind
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.role = try c.decode(ChatRole.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
        self.steps = []
        self.attachedPlaceID = nil
        self.attachmentKind = .availability
    }
}

/// Distinguishes the two inline cards a chat bubble can carry for an
/// `attachedPlaceID`. See `ChatMessage.attachmentKind`.
enum ChatAttachmentKind: String, Codable, Sendable {
    case availability
    case peek
}

/// One unit of visible work the assistant did while producing a message.
/// Rendered as a small row above the final reply text — "🔎 Searching
/// the web for 'X'" or "📋 Reading list 'Amsterdam'" — with a checkmark
/// once `done` flips. Drives a per-step haptic via `.sensoryFeedback`.
struct ChatStep: Identifiable, Equatable, Codable, Sendable {
    /// Stable id from the server so `.stepDone` events can find their
    /// matching step.
    let id: String
    /// SF Symbol name chosen server-side for the step's icon
    /// (`magnifyingglass`, `list.bullet.rectangle.fill`, …).
    let icon: String
    /// Human-readable description shown next to the icon.
    let label: String
    /// Optional names rendered as stacked chips beneath the label — used
    /// by the upfront "Searching your lists" / "Searching friends'
    /// lists" steps to show WHAT is being considered. The bubble picks
    /// the rendering style based on `icon` (list pills for the lists
    /// step, friend avatars for the friends step).
    var chips: [String] = []
    /// Flips true on the matching `.stepDone` event. UI swaps the
    /// spinner for a checkmark.
    var done: Bool = false
}

/// Structured digest of the user's data, shipped with every request so
/// the assistant can reason about their map without the iOS side
/// authoring a giant prompt blob. The Edge Function templates this into
/// the system prompt.
///
/// Two tiers of data:
///   1. **On-screen** (`currentCity`, `viewport`, `visiblePlaces`,
///      `selectedPlace`) — the primary signal. Claude is told to lead
///      with this when answering.
///   2. **Off-screen summary** (`myPlaces`, `friendPlaces`, `lists`,
///      `friends`) — slim id/name/category-only digests so the model
///      can still answer "how many coffee spots do I have?" or
///      "what's in my Tokyo list?" without us shipping every row.
///
/// Naming mirrors the tools we'll expose if/when we migrate to
/// tool-calling (`get_current_city`, `get_visible_pins`,
/// `get_selected_pin`, `list_user_lists`, etc.), so the iOS-side
/// builders don't need to change at that migration.
struct ChatContext: Codable, Sendable {
    let userName: String
    let now: String         // ISO 8601 — gives the model a sense of "today"

    // ----- User-tunable guardrails -----------------------------------
    /// Settings the user chose on the AI assistant page (tone, max
    /// places per answer, recommendation rules, custom instructions).
    /// Optional for forward-compat: old Edge Function builds that
    /// don't yet read this field just keep the previous behaviour.
    let aiSettings: AISettings?

    // ----- On-screen (primary signal) --------------------------------
    /// Best-effort city name resolved from the viewport centre via
    /// `CityResolver`. `nil` when the resolve hasn't completed yet, the
    /// coord doesn't reverse-geocode, or geocoding is rate-limited.
    let currentCity: String?
    /// Current map viewport (centre + bounding box). Lets Claude
    /// answer "anything good around here?" with spatial reasoning.
    let viewport: ViewportDigest?
    /// Places inside `viewport` right now. Capped at
    /// `MAX_VISIBLE_PLACES = 60` to keep the payload tight even when
    /// zoomed out; selected place always wins a slot.
    let visiblePlaces: [PlaceDigest]
    /// The pin the user has open in PlaceCardSheet, if any.
    let selectedPlace: PlaceDigest?

    // ----- Off-screen (summary tier) ---------------------------------
    /// Slim summary of every place the user owns (id, name, category,
    /// inLists only). Lets Claude answer roll-up questions without us
    /// shipping the full PlaceDigest fields. The full fields are only
    /// populated inside `visiblePlaces` + `selectedPlace`.
    let myPlaces: [PlaceDigest]
    /// Slim summary of friends' places visible via RLS.
    let friendPlaces: [PlaceDigest]
    let lists: [ListDigest]
    let friends: [FriendDigest]
}

/// Camera viewport sent to the model so it can reason about "around
/// here" / "this area" geographically. Bounding box is derived from
/// `MKCoordinateRegion`'s centre + span.
struct ViewportDigest: Codable, Sendable {
    let centerLat: Double
    let centerLon: Double
    let north: Double
    let south: Double
    let east: Double
    let west: Double

    init(region: MKCoordinateRegion) {
        let halfLat = region.span.latitudeDelta  / 2
        let halfLon = region.span.longitudeDelta / 2
        self.centerLat = region.center.latitude
        self.centerLon = region.center.longitude
        self.north = region.center.latitude  + halfLat
        self.south = region.center.latitude  - halfLat
        self.east  = region.center.longitude + halfLon
        self.west  = region.center.longitude - halfLon
    }
}

/// One place flattened to just what Claude needs.
///
/// All fields are optional except `id`/`name`/`category`/`inLists` so we
/// can ship two "shapes" of digest with one type:
///
///   • **Full** — used for `visiblePlaces` + `selectedPlace`. Includes
///     coords, area, rating, source, owner — everything the model needs
///     to talk about a specific pin in detail.
///   • **Slim** — used for the off-screen `myPlaces` / `friendPlaces`
///     roll-up. Only id/name/category/inLists populated; the heavy
///     fields are left nil so the wire stays small.
///
/// Use `PlaceDigest.full(from:)` / `PlaceDigest.slim(from:)` factories
/// rather than the initializer directly to make intent explicit at the
/// call site.
struct PlaceDigest: Codable, Sendable {
    let id: String
    let name: String
    let category: String
    /// Lists this place lives in (by name). Empty when uncategorised.
    let inLists: [String]

    // ---- Full-only fields (nil for slim digests) -------------------
    let area: String?
    let latitude: Double?
    let longitude: Double?
    /// Average review score (price/quality/service / 3), nil when the
    /// user hasn't reviewed yet.
    let myRating: Double?
    /// "instagram" / "tiktok" / "googleMaps" / "manual" / etc.
    let source: String?
    /// Owner name for friends' places ("Bodil"); nil for the user's own
    /// places (the system prompt knows whose map it is).
    let owner: String?

    /// Full payload — for places currently on-screen.
    static func full(
        from p: Place,
        inLists: [String],
        ownerName: String?
    ) -> PlaceDigest {
        PlaceDigest(
            id: p.id,
            name: p.name,
            category: p.category.rawValue,
            inLists: inLists,
            area: p.area,
            latitude: p.latitude,
            longitude: p.longitude,
            myRating: p.review?.overall,
            source: p.source.rawValue,
            owner: ownerName
        )
    }

    /// Slim payload — for the off-screen summary tier.
    static func slim(
        from p: Place,
        inLists: [String]
    ) -> PlaceDigest {
        PlaceDigest(
            id: p.id,
            name: p.name,
            category: p.category.rawValue,
            inLists: inLists,
            area: nil,
            latitude: nil,
            longitude: nil,
            myRating: nil,
            source: nil,
            owner: nil
        )
    }
}

struct ListDigest: Codable, Sendable {
    let name: String
    let placeCount: Int
}

struct FriendDigest: Codable, Sendable {
    let name: String
}

// MARK: - AI link routing

/// A venue the AI suggested via `someday://suggest?...` that isn't on
/// the user's map yet. Held by `MapViewModel` while the transient
/// "AI suggested here" banner is visible, after the map recenters.
struct AISuggestionHint: Equatable, Sendable {
    let name: String
    let category: String?
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: AISuggestionHint, rhs: AISuggestionHint) -> Bool {
        lhs.name == rhs.name
            && lhs.category == rhs.category
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

// MARK: - Visibility

extension Place {
    /// True when the place's coordinate sits inside `region`'s bounding
    /// box. Handles the antimeridian-naive case (east > west); we don't
    /// ship anywhere that crosses 180°, so the simple form is fine.
    func isVisible(in region: MKCoordinateRegion) -> Bool {
        let halfLat = region.span.latitudeDelta  / 2
        let halfLon = region.span.longitudeDelta / 2
        let minLat = region.center.latitude  - halfLat
        let maxLat = region.center.latitude  + halfLat
        let minLon = region.center.longitude - halfLon
        let maxLon = region.center.longitude + halfLon
        return latitude  >= minLat && latitude  <= maxLat
            && longitude >= minLon && longitude <= maxLon
    }
}

extension Place {
    /// Best-effort label for the area: `neighborhood` if populated,
    /// otherwise a short coordinate stub so Claude has *something*.
    fileprivate var area: String {
        neighborhood.isEmpty
            ? String(format: "%.4f, %.4f", latitude, longitude)
            : neighborhood
    }
}

// MARK: - Context builder
//
// Lifted out of MapViewModel so the chat surface can build its own
// context payload without making the VM aware of chat concerns. Pure
// function — takes the data and returns the digest.
//
// Two-tier output: `visiblePlaces` + `selectedPlace` get the full
// `PlaceDigest` (lat/lon/rating/source/owner). `myPlaces`/`friendPlaces`
// get the slim summary form so the wire stays tight for users with
// hundreds of saved pins.

enum ChatContextBuilder {
    /// Cap on `visiblePlaces`. Zooming out to a continent-level view
    /// shouldn't dump every pin on the model; this is the ceiling.
    /// Selected place always wins a slot when one's set, even if the
    /// cap is reached.
    static let MAX_VISIBLE_PLACES = 60

    static func build(
        userName: String,
        region: MKCoordinateRegion,
        currentCity: String?,
        selectedPlace: Place?,
        myPlaces: [Place],
        friendPlaces: [Place],
        lists: [CustomList],
        friends: [UserProfile]
    ) -> ChatContext {
        // Lookup tables. O(N·M) one-time passes are fine for typical
        // sizes; swap to dictionaries keyed by placeID if a user
        // balloons past ~1k places.
        func listsContaining(_ placeID: String) -> [String] {
            lists.filter { $0.placeIDs.contains(placeID) }.map(\.name)
        }
        let friendByID = Dictionary(uniqueKeysWithValues: friends.map { ($0.id, $0.name) })

        // --- Visible slice ------------------------------------------
        // Order matters: selected place first (so it's never evicted by
        // the cap), then user's own visible places, then friends'
        // visible places. Cap at MAX_VISIBLE_PLACES total.
        var visibleOrdered: [Place] = []
        var seen: Set<String> = []
        func push(_ p: Place) {
            guard !seen.contains(p.id) else { return }
            seen.insert(p.id)
            visibleOrdered.append(p)
        }
        if let sel = selectedPlace { push(sel) }
        for p in myPlaces      where p.isVisible(in: region) { push(p) }
        for p in friendPlaces  where p.isVisible(in: region) { push(p) }

        let visible = visibleOrdered.prefix(MAX_VISIBLE_PLACES).map { p in
            PlaceDigest.full(
                from: p,
                inLists: listsContaining(p.id),
                ownerName: friendByID[p.ownerID]
            )
        }

        // --- Selected slice -----------------------------------------
        let selectedDigest = selectedPlace.map { p in
            PlaceDigest.full(
                from: p,
                inLists: listsContaining(p.id),
                ownerName: friendByID[p.ownerID]
            )
        }

        // --- Off-screen summary tier --------------------------------
        // Slim digest — id/name/category/inLists only. The model can
        // still answer "how many coffee spots do I have?" but the
        // payload stays small.
        let mine = myPlaces.map { p in
            PlaceDigest.slim(from: p, inLists: listsContaining(p.id))
        }
        let theirs = friendPlaces.map { p in
            PlaceDigest.slim(from: p, inLists: [])
        }

        return ChatContext(
            userName: userName,
            now: ISO8601DateFormatter().string(from: Date()),
            aiSettings: AISettingsStore.shared.settings,
            currentCity: currentCity,
            viewport: ViewportDigest(region: region),
            visiblePlaces: Array(visible),
            selectedPlace: selectedDigest,
            myPlaces: mine,
            friendPlaces: theirs,
            lists: lists.map { ListDigest(name: $0.name, placeCount: $0.placeIDs.count) },
            friends: friends.map { FriendDigest(name: $0.name) }
        )
    }
}

// =============================================================================
// Mock — keyword-matched canned replies so the UI flow works offline
// =============================================================================

struct MockChatService: ChatService {
    func send(history: [ChatMessage], context: ChatContext) async throws -> String {
        var text = ""
        for try await event in stream(history: history, context: context) {
            if case .textDelta(let delta) = event { text += delta }
        }
        return text
    }

    func stream(history: [ChatMessage], context: ChatContext) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let last = history.last(where: { $0.role == .user })?.content.lowercased() ?? ""

                // Pick a canned reply + a couple of fake progress steps
                // so the streaming UI is exercised even with no backend.
                let reply: String
                var steps: [(icon: String, label: String)] = []

                if last.contains("how many") || last.contains("count") {
                    reply = "You've saved \(context.myPlaces.count) places, organised into \(context.lists.count) list(s)."
                } else if last.contains("coffee") {
                    let coffees = context.myPlaces.filter { $0.category == "coffee" }
                    if coffees.isEmpty {
                        reply = "You haven't saved any coffee spots yet — want me to suggest some areas to explore?"
                    } else {
                        let names = coffees.prefix(3).map(\.name).joined(separator: ", ")
                        reply = "You've got \(coffees.count) coffee spot(s). A few to try: \(names)."
                    }
                    steps.append((icon: "list.bullet.rectangle.fill", label: "Reading your coffee places"))
                } else if last.contains("list") {
                    let names = context.lists.map(\.name).joined(separator: ", ")
                    reply = names.isEmpty
                        ? "You don't have any custom lists yet. Create one from the Lists tab."
                        : "Your lists: \(names)."
                    if !names.isEmpty {
                        steps.append((icon: "list.bullet.rectangle.fill", label: "Scanning your lists"))
                    }
                } else if last.isEmpty {
                    reply = "Hey! Ask me anything about your saved places."
                } else {
                    reply = "I can see \(context.myPlaces.count) places on your map and \(context.friends.count) friend(s). Ask me anything specific — what's good in a neighbourhood, what you've recently saved, places to compare."
                }

                do {
                    // Fire fake steps
                    for (i, step) in steps.enumerated() {
                        let id = "mock_step_\(i)"
                        continuation.yield(.step(id: id, icon: step.icon, label: step.label, chips: []))
                        try await Task.sleep(for: .milliseconds(400))
                        continuation.yield(.stepDone(id: id))
                    }
                    // Stream text in chunks for that just-typed feel
                    let chunks = reply.split(separator: " ").map(String.init)
                    for chunk in chunks {
                        continuation.yield(.textDelta(chunk + " "))
                        try await Task.sleep(for: .milliseconds(40))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// =============================================================================
// Supabase Edge Function client
// =============================================================================

struct SupabaseChatService: ChatService {
    let client: SupabaseClient

    init() {
        self.client = SupabaseClientProvider.shared
    }

    /// Convenience wrapper: drains `stream(...)` and returns only the
    /// concatenated text deltas. Discards step events. Use `stream(...)`
    /// directly when you want progress updates.
    func send(history: [ChatMessage], context: ChatContext) async throws -> String {
        var text = ""
        for try await event in stream(history: history, context: context) {
            if case .textDelta(let delta) = event { text += delta }
        }
        return text
    }

    /// Hits the `chat` Edge Function directly with `URLSession.bytes(for:)`
    /// so we can consume the SSE stream live. The Supabase Swift SDK's
    /// `client.functions.invoke` is request/response only and doesn't
    /// expose the body stream, so we bypass it here and just borrow the
    /// session token from the configured client.
    func stream(history: [ChatMessage], context: ChatContext) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let baseURL = SupabaseConfig.url,
                          let anonKey = SupabaseConfig.anonKey else {
                        throw ChatServiceError.serverUnreachable(underlying: "Supabase config missing")
                    }
                    let url = baseURL.appendingPathComponent("/functions/v1/chat")
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.setValue(anonKey, forHTTPHeaderField: "apikey")

                    // Bearer token: prefer the user's session JWT (so the
                    // function sees `req.auth.uid()` if it ever cares).
                    // Fall back to the anon key for unauthenticated calls,
                    // which is fine for an Edge Function that only reads
                    // body-supplied context.
                    let bearer: String
                    if let session = try? await client.auth.session {
                        bearer = session.accessToken
                    } else {
                        bearer = anonKey
                    }
                    req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

                    struct Body: Encodable {
                        let messages: [ChatMessage]
                        let context: ChatContext
                    }
                    req.httpBody = try JSONEncoder().encode(Body(messages: history, context: context))

                    #if DEBUG
                    print("[SupabaseChatService] POST \(url.absoluteString)")
                    print("[SupabaseChatService] auth bearer prefix=\(bearer.prefix(20))…")
                    #endif

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        #if DEBUG
                        print("[SupabaseChatService] response not HTTPURLResponse")
                        #endif
                        throw ChatServiceError.serverUnreachable(underlying: "response not HTTP")
                    }
                    #if DEBUG
                    print("[SupabaseChatService] HTTP \(http.statusCode) content-type=\(http.value(forHTTPHeaderField: "content-type") ?? "?")")
                    #endif
                    guard (200..<300).contains(http.statusCode) else {
                        // Drain the (small) error body so we can log it.
                        var errBody = ""
                        for try await line in bytes.lines {
                            errBody += line + "\n"
                            if errBody.count > 1024 { break }
                        }
                        #if DEBUG
                        print("[SupabaseChatService] error body: \(errBody)")
                        #endif
                        throw ChatServiceError.serverUnreachable(
                            underlying: "HTTP \(http.statusCode): \(errBody.prefix(300))"
                        )
                    }

                    // ---- SSE frame parser ---------------------------------
                    // Spec: blank line terminates an event. We accumulate
                    // `event:` and `data:` lines, then dispatch on the
                    // empty separator. Multiple `data:` lines join with \n.
                    var eventName: String? = nil
                    var dataBuffer = ""

                    func dispatch() {
                        defer { eventName = nil; dataBuffer = "" }
                        guard !dataBuffer.isEmpty else { return }
                        let name = eventName ?? "message"
                        if let event = Self.decode(eventName: name, data: dataBuffer) {
                            continuation.yield(event)
                        }
                    }

                    // SSE per the spec separates events with a blank
                    // line. In practice, `URLSession.AsyncLineSequence`
                    // on iOS sometimes elides empty lines, so we ALSO
                    // dispatch when we see a new `event:` line begin —
                    // that's the next-best signal that the previous
                    // event is complete. `dispatch()` is idempotent
                    // when the buffer's empty, so double-firing is
                    // harmless.
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty {
                            dispatch()
                            continue
                        }
                        // Comment lines (": keep-alive") are ignored.
                        if line.hasPrefix(":") { continue }
                        if let value = line.stripPrefix("event:") {
                            // Flush whatever's pending before we start
                            // a new event header.
                            dispatch()
                            eventName = value.trimmingCharacters(in: .whitespaces)
                        } else if let value = line.stripPrefix("data:") {
                            let chunk = value.trimmingCharacters(in: .whitespaces)
                            if !dataBuffer.isEmpty { dataBuffer += "\n" }
                            dataBuffer += chunk
                        }
                    }
                    // Final flush in case the stream ended without a trailing blank line.
                    dispatch()
                    continuation.finish()
                } catch {
                    #if DEBUG
                    print("[SupabaseChatService] stream threw: \(error)")
                    #endif
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // ---- Event decoding ----------------------------------------------
    //
    // Server emits one of: step / step_done / text / done / error. Each
    // `data:` payload is a JSON object. We tolerate unknown event names
    // (yield nothing) so future server additions don't crash old clients.

    private static func decode(eventName: String, data: String) -> ChatEvent? {
        guard let bytes = data.data(using: .utf8) else { return nil }
        switch eventName {
        case "step":
            struct Payload: Decodable {
                let id: String
                let icon: String
                let label: String
                /// Optional — only the upfront "Searching your lists" /
                /// "Searching friends' lists" steps carry chips. Older
                /// servers omit the field entirely, so we tolerate nil.
                let chips: [String]?
            }
            guard let p = try? JSONDecoder().decode(Payload.self, from: bytes) else { return nil }
            return .step(id: p.id, icon: p.icon, label: p.label, chips: p.chips ?? [])
        case "step_done":
            struct Payload: Decodable { let id: String }
            guard let p = try? JSONDecoder().decode(Payload.self, from: bytes) else { return nil }
            return .stepDone(id: p.id)
        case "text":
            struct Payload: Decodable { let delta: String }
            guard let p = try? JSONDecoder().decode(Payload.self, from: bytes) else { return nil }
            return .textDelta(p.delta)
        case "mutation":
            // Server payload shape (matches ToolMutation in chat/index.ts):
            //   { kind: "create_list" | "delete_list" | "create_place" | "delete_place",
            //     input: { ... varies by kind ... } }
            struct Wrapper: Decodable { let kind: String; let input: MutationInput }
            struct MutationInput: Decodable {
                let name: String?
                let latitude: Double?
                let longitude: Double?
                let category: String?
                let list_name: String?
                let id: String?
            }
            guard let p = try? JSONDecoder().decode(Wrapper.self, from: bytes) else { return nil }
            switch p.kind {
            case "create_list":
                guard let n = p.input.name else { return nil }
                return .mutation(.createList(name: n))
            case "delete_list":
                guard let n = p.input.name else { return nil }
                return .mutation(.deleteList(name: n))
            case "create_place":
                guard let n = p.input.name,
                      let lat = p.input.latitude,
                      let lon = p.input.longitude else { return nil }
                return .mutation(.createPlace(
                    name: n,
                    latitude: lat,
                    longitude: lon,
                    category: p.input.category ?? "food",
                    listName: p.input.list_name
                ))
            case "delete_place":
                guard let id = p.input.id else { return nil }
                return .mutation(.deletePlace(id: id))
            default:
                return nil
            }
        case "done":
            return .done
        case "error":
            // The router upgrades this to ChatServiceError.serverUnreachable
            // via the throwing path; we surface nothing here so the
            // continuation finishes normally after seeing the error event.
            // (Future: thread the error through a dedicated event type.)
            return nil
        default:
            return nil
        }
    }
}

private extension String {
    /// Returns the substring after `prefix` if self starts with it.
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

// =============================================================================
// Router — uses live when configured, mock only when no live service was
// injected (e.g. demo build). A live failure surfaces as an error so the
// chat sheet can show "server cannot be reached" instead of silently
// returning canned text that pretends to know the user's data.
// =============================================================================

enum ChatServiceError: LocalizedError {
    case serverUnreachable(underlying: String? = nil)

    var errorDescription: String? {
        switch self {
        case .serverUnreachable(let underlying):
            #if DEBUG
            if let u = underlying, !u.isEmpty {
                return "Server cannot be reached. Please try again.\n[debug] \(u)"
            }
            #endif
            return "Server cannot be reached. Please try again."
        }
    }
}

extension ChatContext {
    /// Empty fallback used when the parent view model has been
    /// deallocated by the time the chat sheet asks for context (rare
    /// race during sheet teardown). Keeps the sheet from crashing
    /// during edge-case dismiss flows.
    static let empty = ChatContext(
        userName: "",
        now: ISO8601DateFormatter().string(from: Date()),
        aiSettings: nil,
        currentCity: nil,
        viewport: nil,
        visiblePlaces: [],
        selectedPlace: nil,
        myPlaces: [],
        friendPlaces: [],
        lists: [],
        friends: []
    )
}

struct ChatRouter: ChatService {
    let live: ChatService?
    let fallback: ChatService

    func send(history: [ChatMessage], context: ChatContext) async throws -> String {
        var text = ""
        for try await event in stream(history: history, context: context) {
            if case .textDelta(let delta) = event { text += delta }
        }
        return text
    }

    func stream(history: [ChatMessage], context: ChatContext) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let upstream: AsyncThrowingStream<ChatEvent, Error>
                if let live {
                    upstream = live.stream(history: history, context: context)
                } else {
                    // Demo / preview build with no backend — fall through
                    // to the mock so the UI flow is still exercised.
                    upstream = fallback.stream(history: history, context: context)
                }
                do {
                    for try await event in upstream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    #if DEBUG
                    print("[ChatRouter] live chat stream failed: \(error)")
                    #endif
                    // Live failure → surface the canonical user-facing
                    // error rather than the raw transport error. If the
                    // underlying was already a ChatServiceError carrying
                    // a debug detail, preserve it; otherwise capture the
                    // raw description so DEBUG builds can diagnose.
                    if let svc = error as? ChatServiceError {
                        continuation.finish(throwing: svc)
                    } else {
                        continuation.finish(throwing: ChatServiceError.serverUnreachable(
                            underlying: String(describing: error)
                        ))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
