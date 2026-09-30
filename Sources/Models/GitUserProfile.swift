import Foundation

public enum GitHubAuthMethod: String, Codable, CaseIterable, Sendable {
    case oauth = "OAuth"
    case cli = "GitHub CLI"
    case pat = "Personal Access Token"

    public var icon: String {
        switch self {
        case .oauth: return "globe"
        case .cli: return "apple.terminal"
        case .pat: return "key.fill"
        }
    }
}

public struct GitUserProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var label: String // e.g. "Personal", "Work"
    public var name: String // git user.name
    public var email: String // git user.email
    public var githubUsername: String // for avatar fetching
    public var sshKeyPath: String // e.g. "~/.ssh/bk1" or "~/.ssh/id_ed25519"
    public var customAvatarURL: String?

    public init(
        id: String = UUID().uuidString,
        label: String,
        name: String,
        email: String,
        githubUsername: String = "",
        sshKeyPath: String = "",
        customAvatarURL: String? = nil
    ) {
        self.id = id
        self.label = label
        self.name = name
        self.email = email
        self.githubUsername = githubUsername
        self.sshKeyPath = sshKeyPath
        self.customAvatarURL = customAvatarURL
    }

    public var avatarURL: URL? {
        if let custom = customAvatarURL, !custom.isEmpty, let url = URL(string: custom) {
            return url
        }
        let trimmed = githubUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return URL(string: "\(GitHubHost.web)/\(trimmed).png?size=96")
        }
        return nil
    }

    public var initials: String {
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            let first = parts[0].prefix(1)
            let second = parts[1].prefix(1)
            return "\(first)\(second)".uppercased()
        } else if let first = parts.first {
            return String(first.prefix(2)).uppercased()
        }
        return "GU"
    }

    /// First-launch profile, taken from the global git identity (`git config --global user.name/email`).
    public static let defaultProfiles: [GitUserProfile] = [
        GitUserProfile(
            id: "personal",
            label: "Default",
            name: globalGitConfig("user.name") ?? NSFullUserName(),
            email: globalGitConfig("user.email") ?? ""
        )
    ]

    private static func globalGitConfig(_ key: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["config", "--global", "--get", key]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let value = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
