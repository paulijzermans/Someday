import Foundation
import Supabase

/// Persistent implementation of `ListServiceProtocol` backed by the
/// `lists` + `list_places` tables. Round-trips `CustomList` instances
/// so the app can resume a user's custom lists across cold launches.
///
/// Pairing notes for `MapViewModel`:
///   • `customLists` is hydrated from `fetchLists` inside `loadData()`.
///   • `createList` writes through here, then appends locally.
///   • `addPendingPlaces(to:)` writes a `list_places` row per new place.
///   • `cancelAddPendingPlaces` clears local stash only — no DB call.
///
/// imageData is dropped on the floor here — see the protocol note for
/// the rationale (Storage upload is a separate task).
struct SupabaseListService: ListServiceProtocol {
    let client: SupabaseClient

    init() {
        self.client = SupabaseClientProvider.shared
    }

    // MARK: - Fetch

    func fetchLists(for ownerID: String) async throws -> [CustomList] {
        // Two queries, in parallel: the list rows themselves, and every
        // membership row for the user's lists. We assemble the placeIDs
        // arrays client-side to keep the DB query trivial.
        async let listRows: [ListRow] = client
            .from("lists")
            .select()
            .eq("owner_id", value: ownerID)
            .order("created_at", ascending: true)
            .execute()
            .value

        let lists = try await listRows
        guard !lists.isEmpty else { return [] }

        // Pull the membership rows for these list IDs in a single
        // `in_` filter — cheaper than one query per list.
        let listIDs = lists.map(\.id)
        let memberRows: [ListPlaceRow] = try await client
            .from("list_places")
            .select()
            .in("list_id", values: listIDs)
            .order("position", ascending: true)
            .execute()
            .value

        // Bucket memberships by list_id so we can stamp them onto each
        // CustomList in O(N) overall.
        var byList: [String: [String]] = [:]
        for m in memberRows {
            byList[m.list_id, default: []].append(m.place_id)
        }

        return lists.map { row in
            CustomList(
                id: UUID(uuidString: row.id) ?? UUID(),
                name: row.name,
                imageData: nil,
                placeIDs: byList[row.id] ?? []
            )
        }
    }

    // MARK: - Mutate

    func createList(_ list: CustomList, ownerID: String) async throws {
        // Single insert. `id` is client-generated so the local
        // `customLists` array and the DB row share the same UUID.
        let row = ListRow.payload(from: list, ownerID: ownerID)
        try await client
            .from("lists")
            .insert(row)
            .execute()
    }

    func deleteList(listID: String) async throws {
        try await client
            .from("lists")
            .delete()
            .eq("id", value: listID)
            .execute()
        // `list_places` rows go too via the schema's ON DELETE CASCADE.
    }

    func addPlace(placeID: String, toListID listID: String, position: Int) async throws {
        let row = ListPlaceRow(list_id: listID, place_id: placeID, position: position)
        // `upsert` with ignoreDuplicates=true so a re-add against the
        // (list_id, place_id) primary key is silently dropped instead of
        // throwing. Matches the protocol's "idempotent" contract.
        try await client
            .from("list_places")
            .upsert(row, ignoreDuplicates: true)
            .execute()
    }

    func removePlace(placeID: String, fromListID listID: String) async throws {
        try await client
            .from("list_places")
            .delete()
            .eq("list_id", value: listID)
            .eq("place_id", value: placeID)
            .execute()
    }
}
