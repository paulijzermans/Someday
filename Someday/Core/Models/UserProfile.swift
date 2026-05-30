import Foundation

struct UserProfile: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var email: String
    var avatarURL: URL?
    var friendIDs: [String]
    var lists: [String: [String]]
    var createdAt: Date

    var initials: String {
        let parts = name.split(separator: " ")
        let first = parts.first.map { String($0.prefix(1)) } ?? ""
        let last = parts.dropFirst().first.map { String($0.prefix(1)) } ?? ""
        return (first + last).uppercased()
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        email: String,
        avatarURL: URL? = nil,
        friendIDs: [String] = [],
        lists: [String: [String]] = [:],
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.avatarURL = avatarURL
        self.friendIDs = friendIDs
        self.lists = lists
        self.createdAt = createdAt
    }
}
