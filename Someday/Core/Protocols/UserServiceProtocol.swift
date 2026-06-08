import Foundation

protocol UserServiceProtocol: Sendable {
    func fetchUser(id: String) async throws -> UserProfile
    func fetchFriends(for userID: String) async throws -> [UserProfile]
    func addFriend(userID: String, friendID: String) async throws
    func removeFriend(userID: String, friendID: String) async throws
    func searchUsers(query: String) async throws -> [UserProfile]

    /// Partial update of the signed-in user's profile row. Passing `nil`
    /// leaves the field unchanged. Used by Account Settings to edit the
    /// display name + phone number. Phone is what unlocks the phone-half
    /// of contact-discovery — the DB trigger hashes the new value on
    /// write so it becomes searchable immediately.
    func updateProfile(
        userID: String,
        name: String?,
        phone: String?
    ) async throws -> UserProfile
}
