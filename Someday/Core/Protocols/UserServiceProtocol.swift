import Foundation

protocol UserServiceProtocol: Sendable {
    func fetchUser(id: String) async throws -> UserProfile
    func fetchFriends(for userID: String) async throws -> [UserProfile]
    func addFriend(userID: String, friendID: String) async throws
    func removeFriend(userID: String, friendID: String) async throws
    func searchUsers(query: String) async throws -> [UserProfile]
}
