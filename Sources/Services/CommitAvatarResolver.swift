import Foundation
import SwiftUI

/// Maps commit author emails to GitHub avatar URLs, one lookup per distinct email, persisted across launches.
@MainActor
final class CommitAvatarResolver: ObservableObject {
    static let shared = CommitAvatarResolver()

    private static let storageKey = "gitxx_commit_avatar_urls"

    /// email (lowercased) -> avatar URL; "" means GitHub had no account for that email.
    @Published private(set) var avatarURLs: [String: String]
    private var inFlight: Set<String> = []

    private init() {
        avatarURLs = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }

    func avatarURL(for commit: GitCommit, state: AppState) -> String? {
        let email = commit.authorEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard !email.isEmpty else { return nil }
        if let login = Self.localLogin(email: email, profiles: state.gitProfiles) {
            return "https://github.com/\(login).png?size=64"
        }
        if let cached = avatarURLs[email] {
            return cached.isEmpty ? nil : cached
        }
        resolve(email: email, sha: commit.sha, state: state)
        return nil
    }

    private static func localLogin(email: String, profiles: [GitUserProfile]) -> String? {
        if let profile = profiles.first(where: { $0.email.lowercased() == email && !$0.githubUsername.isEmpty }) {
            return profile.githubUsername
        }
        if email.hasSuffix("@users.noreply.github.com") {
            return email.split(separator: "@").first?.split(separator: "+").last.map(String.init)
        }
        return nil
    }

    private func resolve(email: String, sha: String, state: AppState) {
        guard !inFlight.contains(email),
              let token = state.githubToken, !token.isEmpty,
              let slug = state.gitHubService.parseRepoOwnerAndName(from: state.currentRepo?.remoteUrl) else { return }
        inFlight.insert(email)
        let service = state.gitHubService
        Task {
            defer { inFlight.remove(email) }
            let data: Data
            do {
                data = try await service.sendREST(
                    method: "GET", path: "/repos/\(slug.owner)/\(slug.name)/commits/\(sha)",
                    token: token, actionName: "Resolve commit avatar"
                )
            } catch {
                // Unpushed commits 404/422; retry on a later commit by the same author instead of caching a miss.
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let author = json?["author"] as? [String: Any]
            store(author?["avatar_url"] as? String ?? "", for: email)
        }
    }

    private func store(_ url: String, for email: String) {
        avatarURLs[email] = url
        UserDefaults.standard.set(avatarURLs, forKey: Self.storageKey)
    }
}

struct CommitAuthorAvatar: View {
    @ObservedObject var state: AppState
    @ObservedObject private var resolver = CommitAvatarResolver.shared
    let commit: GitCommit
    var size: CGFloat = 16

    var body: some View {
        PRAvatarView(
            authorName: commit.authorName,
            avatarUrl: resolver.avatarURL(for: commit, state: state),
            size: size
        )
    }
}
