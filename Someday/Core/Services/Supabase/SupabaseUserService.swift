import Foundation
import Supabase

/// Live user/profile + friendship + list reads backed by Postgres.
final class SupabaseUserService: UserServiceProtocol, @unchecked Sendable {
    private let client: SupabaseClient

    init(client: SupabaseClient = SupabaseClientProvider.shared) {
        self.client = client
    }

    func fetchUser(id: String) async throws -> UserProfile {
        let rows: [ProfileRow] = try await client
            .from("profiles")
            .select()
            .eq("id", value: id)
            .limit(1)
            .execute()
            .value

        guard let row = rows.first else { throw AuthError.userNotFound }
        let lists = try await listsByName(ownerIDs: [id])[id] ?? [:]
        return row.toModel(lists: lists)
    }

    func fetchFriends(for userID: String) async throws -> [UserProfile] {
        // 1. Friend IDs (directional rows where I'm the user_id).
        let edges: [FriendshipRow] = try await client
            .from("friendships")
            .select()
            .eq("user_id", value: userID)
            .execute()
            .value

        let friendIDs = edges.map(\.friend_id)
        guard !friendIDs.isEmpty else { return [] }

        // 2. Their profiles.
        let profiles: [ProfileRow] = try await client
            .from("profiles")
            .select()
            .in("id", values: friendIDs)
            .execute()
            .value

        // 3. Their lists, grouped by owner.
        let listsByOwner = try await listsByName(ownerIDs: friendIDs)

        return profiles.map { row in
            row.toModel(lists: listsByOwner[row.id] ?? [:])
        }
    }

    func addFriend(userID: String, friendID: String) async throws {
        try await client
            .from("friendships")
            .insert(FriendshipRow(user_id: userID, friend_id: friendID, created_at: nil))
            .execute()
    }

    func removeFriend(userID: String, friendID: String) async throws {
        try await client
            .from("friendships")
            .delete()
            .eq("user_id", value: userID)
            .eq("friend_id", value: friendID)
            .execute()
    }

    func updateProfile(
        userID: String,
        name: String?,
        phone: String?
    ) async throws -> UserProfile {
        // Build a sparse payload — PostgREST only updates the keys present
        // in the body, so we can leave untouched fields alone. The Postgres
        // trigger `compute_profile_contact_hashes()` re-hashes phone/email
        // automatically when those columns are part of the update.
        struct Patch: Encodable {
            let name: String?
            let phone: String?
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let patch = Patch(
            // Empty name would blank out the profile — drop it entirely.
            name: (trimmedName?.isEmpty == false) ? trimmedName : nil,
            // Empty phone IS meaningful — the user can clear their number.
            // The trigger nulls the hash when the source is empty, so we
            // pass the empty string through.
            phone: phone?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        // Don't ship an empty patch — saves a no-op round trip.
        if patch.name == nil && patch.phone == nil {
            return try await fetchUser(id: userID)
        }
        try await client
            .from("profiles")
            .update(patch)
            .eq("id", value: userID)
            .execute()
        return try await fetchUser(id: userID)
    }

    func searchUsers(query: String) async throws -> [UserProfile] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let rows: [ProfileRow] = try await client
            .from("profiles")
            .select()
            .ilike("name", pattern: "%\(trimmed)%")
            .limit(20)
            .execute()
            .value

        return rows.map { $0.toModel() }
    }

    // MARK: - Lists

    /// Build `[ownerID: [listName: [placeID]]]` for the given owners.
    private func listsByName(ownerIDs: [String]) async throws -> [String: [String: [String]]] {
        guard !ownerIDs.isEmpty else { return [:] }

        let lists: [ListRow] = try await client
            .from("lists")
            .select()
            .in("owner_id", values: ownerIDs)
            .execute()
            .value

        guard !lists.isEmpty else { return [:] }

        let listIDs = lists.map(\.id)
        let members: [ListPlaceRow] = try await client
            .from("list_places")
            .select()
            .in("list_id", values: listIDs)
            .execute()
            .value

        // place IDs per list, ordered by position
        let placesByList = Dictionary(grouping: members, by: \.list_id)
            .mapValues { $0.sorted { $0.position < $1.position }.map(\.place_id) }

        var result: [String: [String: [String]]] = [:]
        for list in lists {
            result[list.owner_id, default: [:]][list.name] = placesByList[list.id] ?? []
        }
        return result
    }
}
