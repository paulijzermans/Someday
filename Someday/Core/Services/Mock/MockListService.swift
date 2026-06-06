import Foundation

/// In-memory implementation of `ListServiceProtocol` for demo / preview
/// mode. Nothing persists across launches — used when `SupabaseConfig`
/// isn't configured (no `Secrets.plist` filled in) so the UI still works
/// offline.
actor MockListService: ListServiceProtocol {
    private var lists: [CustomList] = []

    func fetchLists(for ownerID: String) async throws -> [CustomList] {
        // Tiny sleep so the call feels async like the real one.
        try await Task.sleep(for: .milliseconds(120))
        return lists
    }

    func createList(_ list: CustomList, ownerID: String) async throws {
        // No dedup against existing names — the schema's `(owner_id,name)`
        // unique constraint enforces that, and the live service path
        // surfaces the error. Mock mode keeps the simpler path.
        lists.append(list)
    }

    func deleteList(listID: String) async throws {
        lists.removeAll { $0.id.uuidString == listID }
    }

    func addPlace(placeID: String, toListID listID: String, position: Int) async throws {
        guard let i = lists.firstIndex(where: { $0.id.uuidString == listID }) else { return }
        guard !lists[i].placeIDs.contains(placeID) else { return }
        lists[i].placeIDs.append(placeID)
    }

    func removePlace(placeID: String, fromListID listID: String) async throws {
        guard let i = lists.firstIndex(where: { $0.id.uuidString == listID }) else { return }
        lists[i].placeIDs.removeAll { $0 == placeID }
    }
}
