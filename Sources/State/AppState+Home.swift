import Foundation
import AppKit

public enum HomeTab: String, CaseIterable, Identifiable, Sendable {
    case repositories = "Repositories"
    case pullRequests = "My pull requests"
    case conversations = "AI conversations"
    public var id: String { rawValue }
}

extension AppState {
    public func goHome() {
        showRepoPicker = false
        showBranchPicker = false
        showHome = true
        if myPullRequests.isEmpty { loadMyPullRequests() }
        backfillRecentRepoRemotes()
    }

    public func openRepoFromHome(_ repo: GitRepository) {
        performCompoundNavigation { [weak self] in
            await self?.switchRepository(to: repo.path)
            self?.showHome = false
        }
    }

    public func loadMyPullRequests() {
        guard let token = effectiveGitHubToken, !token.isEmpty else {
            myPullRequestsError = "Sign in to GitHub in Settings to see your pull requests."
            return
        }
        let open = myPullRequestsOpen
        if myPullRequests.isEmpty, let cached = MyPullRequestsCache.load(open: open) {
            myPullRequests = cached
        }
        myPullRequestsLoading = true
        myPullRequestsError = nil
        Task {
            do {
                let fresh = try await gitHubService.fetchMyPullRequests(open: open, token: token)
                guard open == myPullRequestsOpen else { return }
                let previous = Dictionary(myPullRequests.map { ($0.id, $0.pr) }, uniquingKeysWith: { a, _ in a })
                myPullRequests = fresh.map { item in
                    var item = item
                    item.pr = Self.carryOverEnrichment(into: item.pr, from: previous[item.id])
                    return item
                }
                myPullRequestsEnriching = Set(fresh.map(\.id)).subtracting(previous.keys)
                if let filter = homeRepoFilter, !fresh.contains(where: { $0.repository == filter }) { homeRepoFilter = nil }
                myPullRequestsLoading = false
                await enrichMyPullRequests(open: open, token: token)
            } catch {
                myPullRequestsError = error.localizedDescription
                myPullRequestsLoading = false
            }
        }
    }

    /// Diff stats, review decision and CI counts, one batched request per repository, in parallel.
    private func enrichMyPullRequests(open: Bool, token: String) async {
        var byRepo: [String: [Int]] = [:]
        for item in myPullRequests { byRepo[item.repository, default: []].append(item.pr.number) }
        await withTaskGroup(of: (String, [Int: PullRequest]).self) { group in
            for (slug, numbers) in byRepo {
                let parts = slug.split(separator: "/").map(String.init)
                guard parts.count == 2 else { continue }
                for start in stride(from: 0, to: numbers.count, by: 9) {
                    let batch = Array(numbers[start..<min(start + 9, numbers.count)])
                    group.addTask { [gitHubService] in
                        (slug, (try? await gitHubService.fetchPREnrichment(owner: parts[0], repo: parts[1], numbers: batch, token: token)) ?? [:])
                    }
                }
            }
            for await (slug, result) in group {
                guard open == myPullRequestsOpen, !result.isEmpty else { continue }
                myPullRequests = myPullRequests.map { item in
                    guard item.repository == slug, let e = result[item.pr.number] else { return item }
                    var item = item
                    item.pr = Self.carryOverEnrichment(into: item.pr, from: e)
                    return item
                }
                myPullRequestsEnriching.subtract(result.keys.map { "\(slug)#\($0)" })
            }
        }
        guard open == myPullRequestsOpen else { return }
        myPullRequestsEnriching = []
        MyPullRequestsCache.save(myPullRequests, open: open)
    }

    public func setMyPullRequestsOpen(_ open: Bool) {
        guard open != myPullRequestsOpen else { return }
        myPullRequestsOpen = open
        myPullRequests = []
        myPullRequestsEnriching = []
        loadMyPullRequests()
    }

    /// Local clone for a GitHub `owner/repo`, if one is in the recent list.
    public func localRepository(slug: String) -> GitRepository? {
        let parts = slug.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        return localRepository(owner: parts[0], repo: parts[1])
    }

    /// Opens the PR in its local clone (same PR page as the Pull Requests tab); falls back to the browser.
    public func openPullRequestFromHome(_ item: CrossRepoPullRequest, tab: PRDetailTab = .overview) {
        let suffix: String
        switch tab {
        case .filesChanged: suffix = "/files"
        case .checks: suffix = "/checks"
        case .commits: suffix = "/commits"
        case .overview: suffix = ""
        }
        guard let target = GitHubURLTarget.parse(item.pr.url + suffix) else { return }
        guard let local = localRepository(owner: target.owner, repo: target.repo) else {
            openGitHubTarget(target)
            return
        }
        performCompoundNavigation { [weak self] in
            guard let self else { return }
            await self.switchRepository(to: local.path)
            guard self.currentRepo?.path == local.path else { return }
            self.showHome = false
            await self.openPullRequest(number: item.pr.number, tab: tab)
        }
    }

    /// Older recent-repo entries were saved without a remote; fill it in so PRs can be matched to clones.
    func backfillRecentRepoRemotes() {
        let missing = recentRepos.filter { $0.remoteUrl == nil }
        guard !missing.isEmpty else { return }
        Task {
            var changed = false
            for repo in missing {
                guard let remote = await gitService.getRemoteUrl(at: repo.path),
                      let idx = recentRepos.firstIndex(where: { $0.path == repo.path }) else { continue }
                recentRepos[idx].remoteUrl = remote
                changed = true
            }
            if changed { saveRecentRepos() }
        }
    }
}

/// Last "my pull requests" result on disk, so Home shows the list instantly while it refreshes.
enum MyPullRequestsCache {
    private static func url(open: Bool) -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("GitXX", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(open ? "my-prs-open.json" : "my-prs-closed.json")
    }

    static func load(open: Bool) -> [CrossRepoPullRequest]? {
        guard let url = url(open: open), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([CrossRepoPullRequest].self, from: data)
    }

    static func save(_ items: [CrossRepoPullRequest], open: Bool) {
        guard let url = url(open: open), let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
