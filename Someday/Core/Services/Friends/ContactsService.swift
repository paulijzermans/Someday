import Foundation
import Contacts
import CryptoKit
import Supabase

// =============================================================================
// ContactsService — "find your loved ones on Someday"
// =============================================================================
//
// Pipeline:
//   1. Ask iOS for Contacts permission.
//   2. Read every contact's phone numbers + emails.
//   3. Normalize (E.164-style for phones, lowercase for emails) and
//      hash each value with SHA-256 ON DEVICE — raw contact data never
//      leaves the phone.
//   4. POST the hash arrays to the `find-friends-on-someday` Edge
//      Function, which matches against `profiles.email_hash` and
//      `profiles.phone_hash`.
//   5. Returns the matched profiles for the UI to display.
//
// Privacy posture matches Snapchat / WhatsApp / Signal: only opaque
// hashes are transmitted. We accept the standard limitation that SHA-256
// of a phone number is brute-forceable; future work could add a server-
// side secret salt for stronger k-anonymity.

protocol ContactsServiceProtocol: Sendable {
    /// Current permission state for Contacts.
    func authorizationStatus() -> CNAuthorizationStatus

    /// Prompt the user for Contacts permission. Returns the final
    /// status (the previous value if already determined).
    func requestAuthorization() async -> CNAuthorizationStatus

    /// Walk the address book, build hash arrays. Throws on permission
    /// errors / no-permission state.
    func collectContactHashes() async throws -> ContactHashes

    /// Ask the backend which of the supplied hashes belong to existing
    /// Someday users. Returns the matched profiles, or an empty array
    /// if none matched.
    func findMatches(_ hashes: ContactHashes) async throws -> [MatchedContact]

    /// Send a friend request from the current user to the given user.
    func sendFriendRequest(toUserID: String) async throws

    /// Fetch the list of pending friend requests addressed to the current
    /// user. The Activity tab inbox renders one row per result with
    /// Accept / Reject affordances.
    func fetchIncomingRequests() async throws -> [IncomingFriendRequest]

    /// Accept a pending request. Backed by the `accept_friend_request`
    /// SECURITY DEFINER RPC, which atomically inserts the bidirectional
    /// `friendships` rows and deletes the request.
    func acceptFriendRequest(fromUserID: String) async throws

    /// Reject (decline) a pending request. Just deletes the row — RLS
    /// allows either party to delete, so the receiver dropping it is
    /// sufficient. Re-requesting later is allowed because the row is gone.
    func rejectFriendRequest(fromUserID: String) async throws
}

// =============================================================================
// Wire types
// =============================================================================

/// Two parallel arrays — one of email hashes, one of phone hashes.
/// Sent verbatim to the Edge Function.
struct ContactHashes: Equatable, Sendable {
    let emailHashes: [String]
    let phoneHashes: [String]

    var isEmpty: Bool { emailHashes.isEmpty && phoneHashes.isEmpty }
}

/// A Someday user matched via the contact-discovery flow. Just enough
/// fields to render the row + send a friend request.
struct MatchedContact: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let avatarURL: URL?
    let matchedBy: MatchedBy

    enum MatchedBy: String, Sendable {
        case email
        case phone
    }
}

/// A pending friend request as seen by the *receiver*. `id` is the sender's
/// user ID — both the natural identifier for the Identifiable conformance
/// (the receiver's ID is always the current user) and the value the
/// Accept / Reject RPCs take.
struct IncomingFriendRequest: Identifiable, Hashable, Sendable {
    /// Sender's user ID. Doubles as the row's `Identifiable` key.
    let id: String
    let name: String
    let avatarURL: URL?
    let createdAt: Date
}

// =============================================================================
// Live implementation — Supabase + CNContactStore
// =============================================================================

struct ContactsService: ContactsServiceProtocol {
    private let store = CNContactStore()
    private let client: SupabaseClient

    init() {
        self.client = SupabaseClientProvider.shared
    }

    // MARK: - Authorization

    func authorizationStatus() -> CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    func requestAuthorization() async -> CNAuthorizationStatus {
        let current = authorizationStatus()
        // `.notDetermined` is the only state where the OS will show
        // the prompt. All other states (denied, authorized, restricted)
        // are sticky until the user changes them in Settings.
        guard current == .notDetermined else { return current }
        _ = try? await store.requestAccess(for: .contacts)
        return authorizationStatus()
    }

    // MARK: - Hashing

    func collectContactHashes() async throws -> ContactHashes {
        let status = authorizationStatus()
        guard status == .authorized else {
            throw ContactsError.notAuthorized
        }

        // Run the address-book scan off the main thread — large
        // address books can take a noticeable beat to enumerate.
        return try await Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
            ]
            let req = CNContactFetchRequest(keysToFetch: keys)

            var emailHashes: Set<String> = []
            var phoneHashes: Set<String> = []

            try store.enumerateContacts(with: req) { contact, _ in
                for email in contact.emailAddresses {
                    let normalized = normalizeEmail(String(email.value))
                    if let h = sha256Hex(normalized) {
                        emailHashes.insert(h)
                    }
                }
                for phone in contact.phoneNumbers {
                    let normalized = normalizePhone(phone.value.stringValue)
                    if let h = sha256Hex(normalized) {
                        phoneHashes.insert(h)
                    }
                }
            }

            return ContactHashes(
                emailHashes: Array(emailHashes),
                phoneHashes: Array(phoneHashes)
            )
        }.value
    }

    // MARK: - Backend match

    func findMatches(_ hashes: ContactHashes) async throws -> [MatchedContact] {
        guard !hashes.isEmpty else { return [] }
        // Without an active session, the Edge Function returns 401 and
        // the SDK surfaces that as a generic "non-2xx" — fail early with
        // a precise error instead so the UI can guide the user to confirm
        // their email / re-auth.
        guard client.auth.currentUser != nil else {
            throw ContactsError.notAuthenticated
        }
        struct RequestBody: Encodable {
            let emailHashes: [String]
            let phoneHashes: [String]
        }
        struct Response: Decodable {
            struct Row: Decodable {
                let id: String
                let name: String
                let avatarUrl: String?
                let matchedBy: String
            }
            let matches: [Row]
        }
        let body = RequestBody(
            emailHashes: hashes.emailHashes,
            phoneHashes: hashes.phoneHashes
        )
        let resp: Response = try await client.functions.invoke(
            "find-friends-on-someday",
            options: FunctionInvokeOptions(body: body)
        )
        return resp.matches.map { row in
            MatchedContact(
                id: row.id,
                name: row.name,
                avatarURL: row.avatarUrl.flatMap(URL.init(string:)),
                matchedBy: row.matchedBy == "phone" ? .phone : .email
            )
        }
    }

    // MARK: - Friend requests

    func sendFriendRequest(toUserID: String) async throws {
        // The RLS policy enforces `auth.uid() = from_id`, so we let
        // PostgREST resolve from_id from the session JWT — we only
        // supply the target.
        struct Row: Encodable {
            let from_id: String
            let to_id: String
        }
        guard let me = client.auth.currentUser?.id.uuidString else {
            throw ContactsError.notAuthenticated
        }
        try await client
            .from("friend_requests")
            .insert(Row(from_id: me, to_id: toUserID))
            .execute()
    }

    // MARK: - Incoming requests inbox

    func fetchIncomingRequests() async throws -> [IncomingFriendRequest] {
        guard let me = client.auth.currentUser?.id.uuidString else {
            throw ContactsError.notAuthenticated
        }
        // PostgREST embedded-resource join: select the request row + the
        // sender's profile in a single round-trip. The relationship is
        // declared by the `friend_requests.from_id → profiles.id` foreign
        // key, so we hint it via `from:profiles!from_id(...)`.
        struct Row: Decodable {
            struct Sender: Decodable {
                let id: String
                let name: String?
                let avatar_url: String?
            }
            let from_id: String
            let created_at: Date
            let from: Sender?
        }
        let rows: [Row] = try await client
            .from("friend_requests")
            .select("from_id,created_at,from:profiles!from_id(id,name,avatar_url)")
            .eq("to_id", value: me)
            .order("created_at", ascending: false)
            .execute()
            .value
        return rows.map { row in
            IncomingFriendRequest(
                id: row.from_id,
                name: row.from?.name ?? "Someone",
                avatarURL: row.from?.avatar_url.flatMap(URL.init(string:)),
                createdAt: row.created_at
            )
        }
    }

    func acceptFriendRequest(fromUserID: String) async throws {
        struct Params: Encodable { let p_from_id: String }
        try await client.rpc(
            "accept_friend_request",
            params: Params(p_from_id: fromUserID)
        ).execute()
    }

    func rejectFriendRequest(fromUserID: String) async throws {
        guard let me = client.auth.currentUser?.id.uuidString else {
            throw ContactsError.notAuthenticated
        }
        // RLS `friend_requests_delete` already restricts deletion to the
        // two parties — we still scope by both keys so a malformed call
        // can't delete an unrelated row by accident.
        try await client
            .from("friend_requests")
            .delete()
            .eq("from_id", value: fromUserID)
            .eq("to_id", value: me)
            .execute()
    }
}

// =============================================================================
// Mock — used by the .mock service container so previews + offline
// development don't try to access real contacts.
// =============================================================================

struct MockContactsService: ContactsServiceProtocol {
    func authorizationStatus() -> CNAuthorizationStatus { .authorized }
    func requestAuthorization() async -> CNAuthorizationStatus { .authorized }

    func collectContactHashes() async throws -> ContactHashes {
        // Two fake hashes so the mock flow surfaces a couple of
        // "matches" via `findMatches`. The mock match list is
        // hard-coded below — these don't actually have to correspond.
        ContactHashes(
            emailHashes: [String(repeating: "a", count: 64)],
            phoneHashes: [String(repeating: "b", count: 64)]
        )
    }

    func findMatches(_ hashes: ContactHashes) async throws -> [MatchedContact] {
        try await Task.sleep(for: .milliseconds(600))
        return [
            MatchedContact(id: "mock_friend_bodil", name: "Bodil", avatarURL: nil, matchedBy: .phone),
            MatchedContact(id: "mock_friend_anna", name: "Anna", avatarURL: nil, matchedBy: .email),
        ]
    }

    func sendFriendRequest(toUserID: String) async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    func fetchIncomingRequests() async throws -> [IncomingFriendRequest] {
        try await Task.sleep(for: .milliseconds(300))
        // Two synthetic pending requests so the inbox UI has something to
        // render in previews + offline-dev. Reusing the same mock profile
        // IDs the rest of the mock stack uses so avatars resolve.
        return [
            IncomingFriendRequest(
                id: "user_emma",
                name: "Emma",
                avatarURL: nil,
                createdAt: Date().addingTimeInterval(-3600 * 2)
            ),
            IncomingFriendRequest(
                id: "user_lucas",
                name: "Lucas",
                avatarURL: nil,
                createdAt: Date().addingTimeInterval(-3600 * 30)
            ),
        ]
    }

    func acceptFriendRequest(fromUserID: String) async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    func rejectFriendRequest(fromUserID: String) async throws {
        try await Task.sleep(for: .milliseconds(200))
    }
}

// =============================================================================
// Helpers
// =============================================================================

enum ContactsError: LocalizedError {
    case notAuthorized
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .notAuthorized:    return "Contacts permission isn't granted."
        case .notAuthenticated: return "You need to be signed in."
        }
    }
}

/// Normalize an email: trim + lowercase. Returns empty string for
/// inputs that don't have an `@`, which `sha256Hex` then treats as
/// "no hash" and skips.
private func normalizeEmail(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard trimmed.contains("@") else { return "" }
    return trimmed
}

/// Normalize a phone number: keep only digits and a leading `+`.
/// E.164 strings like "+31 6 12 34 56 78" collapse to "+31612345678".
/// Bare "+" or empty inputs are returned as "" → skipped by the hasher.
private func normalizePhone(_ raw: String) -> String {
    let allowed = Set("0123456789+")
    let stripped = String(raw.filter { allowed.contains($0) })
    // Drop any "+" that isn't at the very start — bad input.
    let cleaned: String
    if stripped.hasPrefix("+") {
        cleaned = "+" + stripped.dropFirst().filter { $0 != "+" }
    } else {
        cleaned = stripped.filter { $0 != "+" }
    }
    if cleaned.isEmpty || cleaned == "+" { return "" }
    return cleaned
}

/// SHA-256 of the input as a 64-char lowercase hex string. Returns nil
/// for empty input so callers can treat "couldn't normalize" the same
/// as "no value here".
private func sha256Hex(_ s: String) -> String? {
    guard !s.isEmpty else { return nil }
    let bytes = SHA256.hash(data: Data(s.utf8))
    return bytes.map { String(format: "%02x", $0) }.joined()
}
