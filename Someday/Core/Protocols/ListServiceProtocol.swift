import Foundation

/// CRUD on the user's custom lists + the place-membership join table.
/// Mirrors the `lists` + `list_places` tables from the Supabase schema.
///
/// Implementations:
///   • `SupabaseListService` — writes through to Postgres (real path).
///   • `MockListService`     — in-memory only (demo / preview).
///
/// `CustomList.imageData` is **not** persisted by this protocol — list
/// cover photos need Supabase Storage uploads, which is a separate layer.
/// For now imageData lives in-memory and is dropped on cold launch.
protocol ListServiceProtocol: Sendable {
    /// Fetch the user's own custom lists, each with `placeIDs` hydrated
    /// from `list_places`. Returns an empty array if the user has no lists.
    func fetchLists(for ownerID: String) async throws -> [CustomList]

    /// Insert a fresh list row. The client-generated `list.id` is used so
    /// the in-memory model and the DB row share the same UUID.
    func createList(_ list: CustomList, ownerID: String) async throws

    /// Delete a list and all its membership rows (cascade in schema).
    func deleteList(listID: String) async throws

    /// Append a place to a list. Idempotent — duplicates are ignored
    /// at the join-table primary-key level.
    func addPlace(placeID: String, toListID listID: String, position: Int) async throws

    /// Remove a place from a list. No-op if the membership doesn't exist.
    func removePlace(placeID: String, fromListID listID: String) async throws
}
