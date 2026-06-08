import Foundation

final class MockUserService: UserServiceProtocol, @unchecked Sendable {
    private let allUsers: [UserProfile] = [SampleData.currentUser] + SampleData.friends

    func fetchUser(id: String) async throws -> UserProfile {
        guard let user = allUsers.first(where: { $0.id == id }) else {
            throw AuthError.userNotFound
        }
        return user
    }

    func fetchFriends(for userID: String) async throws -> [UserProfile] {
        try await Task.sleep(for: .milliseconds(300))
        return SampleData.friends
    }

    func addFriend(userID: String, friendID: String) async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    func removeFriend(userID: String, friendID: String) async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    func searchUsers(query: String) async throws -> [UserProfile] {
        try await Task.sleep(for: .milliseconds(300))
        let lowered = query.lowercased()
        return allUsers.filter { $0.name.lowercased().contains(lowered) }
    }

    func updateProfile(
        userID: String,
        name: String?,
        phone: String?
    ) async throws -> UserProfile {
        try await Task.sleep(for: .milliseconds(300))
        // Mock doesn't persist — just echo a synthetic updated profile so
        // the UI optimistic-update path looks alive in previews.
        var updated = try await fetchUser(id: userID)
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            updated.name = trimmed
        }
        // Phone isn't on UserProfile (it's a profiles-table-only field used
        // for contact matching); the mock just ack-and-forgets it.
        _ = phone
        return updated
    }
}
