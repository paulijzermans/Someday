import Foundation
import Supabase

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
    func send(history: [ChatMessage], context: ChatContext) async throws -> String
}

// MARK: - Wire types

enum ChatRole: String, Codable, Sendable {
    case user, assistant
}

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    var id: UUID = UUID()
    let role: ChatRole
    var content: String

    enum CodingKeys: String, CodingKey { case role, content }
    init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.role = try c.decode(ChatRole.self, forKey: .role)
        self.content = try c.decode(String.self, forKey: .content)
    }
}

/// Structured digest of the user's data, shipped with every request so
/// the assistant can reason about their map without the iOS side
/// authoring a giant prompt blob. The Edge Function templates this into
/// the system prompt.
struct ChatContext: Codable, Sendable {
    let userName: String
    let now: String         // ISO 8601 — gives the model a sense of "today"
    let myPlaces: [PlaceDigest]
    let friendPlaces: [PlaceDigest]   // friends' visible places via RLS
    let lists: [ListDigest]
    let friends: [FriendDigest]
}

/// One place flattened to just what Claude needs — keeps payload small
/// even for users with hundreds of places.
struct PlaceDigest: Codable, Sendable {
    let id: String
    let name: String
    let category: String
    let area: String        // `place.neighborhood`
    let latitude: Double
    let longitude: Double
    /// Average review score (price/quality/service / 3), nil when the
    /// user hasn't reviewed yet.
    let myRating: Double?
    /// "instagram" / "tiktok" / "googleMaps" / "manual" / etc.
    let source: String
    /// Lists this place lives in (by name). Empty when uncategorised.
    let inLists: [String]
    /// Owner name for friends' places ("Bodil"); nil for the user's own
    /// places (the system prompt knows whose map it is).
    let owner: String?
}

struct ListDigest: Codable, Sendable {
    let name: String
    let placeCount: Int
}

struct FriendDigest: Codable, Sendable {
    let name: String
}

// MARK: - Context builder
//
// Lifted out of MapViewModel so the chat surface can build its own
// context payload without making the VM aware of chat concerns. Pure
// function — takes the data and returns the digest.

enum ChatContextBuilder {
    static func build(
        userName: String,
        myPlaces: [Place],
        friendPlaces: [Place],
        lists: [CustomList],
        friends: [UserProfile]
    ) -> ChatContext {
        // Lookup table: placeID → list names. O(N·M) one-time pass is
        // fine for typical sizes; if a user balloons past ~1k places we
        // can swap to a Dictionary keyed by placeID.
        func listsContaining(_ placeID: String) -> [String] {
            lists.filter { $0.placeIDs.contains(placeID) }.map(\.name)
        }

        let friendByID = Dictionary(uniqueKeysWithValues: friends.map { ($0.id, $0.name) })

        let mine = myPlaces.map { p in
            PlaceDigest(
                id: p.id,
                name: p.name,
                category: p.category.rawValue,
                area: p.area,
                latitude: p.latitude,
                longitude: p.longitude,
                myRating: p.review?.overall,
                source: p.source.rawValue,
                inLists: listsContaining(p.id),
                owner: nil
            )
        }
        let theirs = friendPlaces.map { p in
            PlaceDigest(
                id: p.id,
                name: p.name,
                category: p.category.rawValue,
                area: p.area,
                latitude: p.latitude,
                longitude: p.longitude,
                myRating: nil,
                source: p.source.rawValue,
                inLists: [],
                owner: friendByID[p.ownerID]
            )
        }

        return ChatContext(
            userName: userName,
            now: ISO8601DateFormatter().string(from: Date()),
            myPlaces: mine,
            friendPlaces: theirs,
            lists: lists.map { ListDigest(name: $0.name, placeCount: $0.placeIDs.count) },
            friends: friends.map { FriendDigest(name: $0.name) }
        )
    }
}

private extension Place {
    /// Best-effort label for the area: `neighborhood` if populated,
    /// otherwise a short coordinate stub so Claude has *something*.
    var area: String {
        neighborhood.isEmpty
            ? String(format: "%.4f, %.4f", latitude, longitude)
            : neighborhood
    }
}

// =============================================================================
// Mock — keyword-matched canned replies so the UI flow works offline
// =============================================================================

struct MockChatService: ChatService {
    func send(history: [ChatMessage], context: ChatContext) async throws -> String {
        try await Task.sleep(for: .milliseconds(900))

        guard let last = history.last(where: { $0.role == .user })?.content.lowercased() else {
            return "Hey! Ask me anything about your saved places."
        }

        // Dirt-cheap heuristics — gives the demo something coherent
        // without an API key. Real responses come from the Edge Function.
        if last.contains("how many") || last.contains("count") {
            return "You've saved \(context.myPlaces.count) places, organised into \(context.lists.count) list(s)."
        }
        if last.contains("coffee") {
            let coffees = context.myPlaces.filter { $0.category == "coffee" }
            if coffees.isEmpty {
                return "You haven't saved any coffee spots yet — want me to suggest some areas to explore?"
            }
            let names = coffees.prefix(3).map(\.name).joined(separator: ", ")
            return "You've got \(coffees.count) coffee spot(s). A few to try: \(names)."
        }
        if last.contains("list") {
            let names = context.lists.map(\.name).joined(separator: ", ")
            return names.isEmpty
                ? "You don't have any custom lists yet. Create one from the Lists tab."
                : "Your lists: \(names)."
        }
        return "I can see \(context.myPlaces.count) places on your map and \(context.friends.count) friend(s). Ask me anything specific — what's good in a neighbourhood, what you've recently saved, places to compare."
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

    func send(history: [ChatMessage], context: ChatContext) async throws -> String {
        struct RequestBody: Encodable {
            let messages: [ChatMessage]
            let context: ChatContext
        }
        struct Response: Decodable {
            let reply: String
        }
        let body = RequestBody(messages: history, context: context)
        let response: Response = try await client.functions.invoke(
            "chat",
            options: FunctionInvokeOptions(body: body)
        )
        return response.reply
    }
}

// =============================================================================
// Router — picks live, falls back to mock on any failure
// =============================================================================

extension ChatContext {
    /// Empty fallback used when the parent view model has been
    /// deallocated by the time the chat sheet asks for context (rare
    /// race during sheet teardown). Keeps the sheet from crashing
    /// during edge-case dismiss flows.
    static let empty = ChatContext(
        userName: "",
        now: ISO8601DateFormatter().string(from: Date()),
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
        if let live {
            do {
                return try await live.send(history: history, context: context)
            } catch {
                #if DEBUG
                print("[ChatRouter] live chat failed: \(error) — falling back to mock")
                #endif
                // Fall through to mock
            }
        }
        return try await fallback.send(history: history, context: context)
    }
}
