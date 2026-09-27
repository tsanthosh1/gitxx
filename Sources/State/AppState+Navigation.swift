import Foundation
import AppKit

/// A github.com location that can be opened inside the app.
public struct GitHubURLTarget: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case repository
        case pullRequests
        case pullRequest(number: Int, tab: PRDetailTab)
        case branch(String)
        case commit(String)
    }

    public let owner: String
    public let repo: String
    public let kind: Kind
    public let url: URL

    public var slug: String { "\(owner)/\(repo)" }

    /// Parses `https://github.com/{owner}/{repo}[/pull/{n}[/files|/checks|/commits]]`, `/pulls`,
    /// `/tree/{branch}` and `/commit/{sha}`. Accepts URLs without a scheme and `#issuecomment` anchors.
    public static func parse(_ raw: String) -> GitHubURLTarget? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(" ") else { return nil }
        if text.hasPrefix("github.com/") || text.hasPrefix("www.github.com/") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let rest = Array(parts.dropFirst(2))

        let kind: Kind
        switch rest.first {
        case nil:
            kind = .repository
        case "pulls":
            kind = .pullRequests
        case "pull":
            guard rest.count >= 2, let number = Int(rest[1]) else { return nil }
            let tab: PRDetailTab
            switch rest.count > 2 ? rest[2] : "" {
            case "files", "changes": tab = .filesChanged
            case "checks": tab = .checks
            case "commits": tab = .commits
            default: tab = .overview
            }
            kind = .pullRequest(number: number, tab: tab)
        case "tree":
            guard rest.count >= 2 else { return nil }
            kind = .branch(rest.dropFirst().joined(separator: "/"))
        case "commit":
            guard rest.count >= 2 else { return nil }
            kind = .commit(rest[1])
        default:
            kind = .repository
        }
        return GitHubURLTarget(owner: owner, repo: repo, kind: kind, url: url)
    }

    public var title: String {
        switch kind {
        case .repository: return "Open \(slug)"
        case .pullRequests: return "Pull requests in \(slug)"
        case .pullRequest(let n, let tab):
            switch tab {
            case .filesChanged: return "Open PR #\(n) · Files changed"
            case .checks: return "Open PR #\(n) · Checks"
            case .commits: return "Open PR #\(n) · Commits"
            case .overview: return "Open PR #\(n)"
            }
        case .branch(let b): return "Check out branch \(b)"
        case .commit(let sha): return "Show commit \(sha.prefix(7))"
        }
    }
}

extension AppState {
    /// Locally opened repository whose `origin` points at `owner/repo`.
    func localRepository(owner: String, repo: String) -> GitRepository? {
        let candidates = (currentRepo.map { [$0] } ?? []) + recentRepos
        return candidates.first { candidate in
            guard let parsed = gitHubService.parseRepoOwnerAndName(from: candidate.remoteUrl) else { return false }
            return parsed.owner.caseInsensitiveCompare(owner) == .orderedSame
                && parsed.name.caseInsensitiveCompare(repo) == .orderedSame
        }
    }

    /// Opens a github.com URL in-app when its repository is available locally; otherwise falls back to the browser.
    public func openGitHubTarget(_ target: GitHubURLTarget) {
        guard let local = localRepository(owner: target.owner, repo: target.repo) else {
            showToast("\(target.slug) isn't open in GitXX — opening in browser", type: .info)
            NSWorkspace.shared.open(target.url)
            return
        }
        Task {
            if currentRepo?.path != local.path {
                loadRepo(path: local.path)
                for _ in 0..<60 where currentRepo?.path != local.path {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                guard currentRepo?.path == local.path else { return }
            }
            await navigate(to: target)
        }
    }

    private func navigate(to target: GitHubURLTarget) async {
        switch target.kind {
        case .repository:
            activeTab = .changes
        case .pullRequests:
            selectedPR = nil
            activeTab = .pullRequests
        case .pullRequest(let number, let tab):
            await openPullRequest(number: number, tab: tab)
        case .branch(let name):
            activeTab = .changes
            checkoutBranch(name)
        case .commit(let sha):
            activeTab = .history
            if let commit = commits.first(where: { $0.sha.hasPrefix(sha) || sha.hasPrefix($0.sha) }) {
                selectCommit(commit)
            } else {
                showToast("Commit \(sha.prefix(7)) isn't in the loaded history", type: .info)
            }
        }
    }

    /// Opens a PR in the current repository, fetching it if it isn't in the loaded list.
    public func openPullRequest(number: Int, tab: PRDetailTab = .overview) async {
        activeTab = .pullRequests
        if let pr = pullRequests.first(where: { $0.number == number }) {
            selectedPR = pr
            selectedPRTab = tab
            loadPRDetails(for: pr)
            return
        }
        guard let ctx = prRepoContext() else { return }
        do {
            guard let pr = try await gitHubService.fetchPullRequest(owner: ctx.owner, repo: ctx.repo, number: number, token: ctx.token) else {
                showToast("Pull request #\(number) not found", type: .error)
                return
            }
            selectedPR = pr
            selectedPRTab = tab
            loadPRDetails(for: pr)
        } catch {
            showToast("Couldn't open #\(number): \(error.localizedDescription)", type: .error)
        }
    }

    /// PRs known for the current repository across every cached list filter (for palette search).
    public var searchablePullRequests: [PullRequest] {
        var byNumber: [Int: PullRequest] = [:]
        if let ctx = prRepoContext() {
            for filter in PRFilter.allCases {
                for pr in PRListCache.shared.get(owner: ctx.owner, repo: ctx.repo, filter: filter)?.pullRequests ?? [] {
                    byNumber[pr.number] = byNumber[pr.number] ?? pr
                }
            }
        }
        for pr in pullRequests { byNumber[pr.number] = pr }
        return byNumber.values.sorted { $0.number > $1.number }
    }
}
