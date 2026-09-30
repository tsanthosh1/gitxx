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
        case actions(workflowFile: String?)
        case actionsRun(runId: Int, jobId: Int?)
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
        if !text.contains("://"), let first = text.split(separator: "/").first, GitHubHost.isWebHost(String(first)) {
            text = "https://" + text
        }
        guard let url = URL(string: text), let host = url.host?.lowercased(), GitHubHost.isWebHost(host) else { return nil }
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
        case "actions":
            // /actions, /actions/workflows/{file}, /actions/runs/{id}[/job/{id}|/attempts/{n}]
            if rest.count >= 3, rest[1] == "runs", let runId = Int(rest[2]) {
                let jobId = rest.count >= 5 && rest[3] == "job" ? Int(rest[4]) : nil
                kind = .actionsRun(runId: runId, jobId: jobId)
            } else {
                kind = .actions(workflowFile: rest.count >= 3 && rest[1] == "workflows" ? rest[2] : nil)
            }
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
        case .actions(let file): return file.map { "Actions · \($0)" } ?? "Actions in \(slug)"
        case .actionsRun(let runId, let jobId): return jobId == nil ? "Open workflow run \(runId)" : "Open workflow run \(runId) · job \(jobId!)"
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
            LinkRouter.openInBrowser([target.url])
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
        case .actions(let file):
            activeTab = .actions
            actions.activate()
            if let file {
                for _ in 0..<40 where actions.workflows.isEmpty { try? await Task.sleep(nanoseconds: 50_000_000) }
                actions.filter.workflowId = actions.workflows.first { $0.fileName == file }?.id
            }
        case .actionsRun(let runId, let jobId):
            openActionsRun(runId: runId, jobId: jobId)
        }
    }

    /// Switches to the Actions tab and opens a run (used by PR checks, links and the palette).
    public func openActionsRun(runId: Int, jobId: Int? = nil) {
        activeTab = .actions
        actions.activate()
        actions.openRun(id: runId, jobId: jobId)
        recordNavigationStep()
    }

    /// Opens the newest run for a branch, loading the branch's runs first.
    public func openLatestActionsRun(branch: String?) {
        showActions(branch: branch)
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if !actions.isLoadingRuns, let run = actions.runs.first(where: { branch == nil || $0.headBranch == branch }) {
                    actions.selectRun(run)
                    recordNavigationStep()
                    return
                }
            }
        }
    }

    /// Actions tab filtered to a branch, e.g. a PR's head branch.
    public func showActions(branch: String?, workflowId: Int? = nil) {
        activeTab = .actions
        actions.activate()
        actions.show(branch: branch, workflowId: workflowId)
    }

    /// Opens a PR in the current repository, fetching it if it isn't in the loaded list.
    /// Any cached list (every filter) or an earlier one-off fetch paints the PR at once; loadPRDetails refreshes it.
    public func openPullRequest(number: Int, tab: PRDetailTab = .overview) async {
        activeTab = .pullRequests
        guard let ctx = prRepoContext() else { return }
        let key = "\(ctx.owner)/\(ctx.repo)#\(number)".lowercased()
        if let pr = pullRequests.first(where: { $0.number == number })
            ?? searchablePullRequests.first(where: { $0.number == number })
            ?? fetchedPullRequests[key] {
            show(pr, tab: tab)
            return
        }
        openingPRNumber = number
        defer { if openingPRNumber == number { openingPRNumber = nil } }
        do {
            guard let pr = try await gitHubService.fetchPullRequest(owner: ctx.owner, repo: ctx.repo, number: number, token: ctx.token) else {
                showToast("Pull request #\(number) not found", type: .error)
                return
            }
            fetchedPullRequests[key] = pr
            // Dropped if the user backed out of the loading page or moved to another repository meanwhile.
            guard openingPRNumber == number, let now = prRepoContext(), now.owner == ctx.owner, now.repo == ctx.repo else { return }
            show(pr, tab: tab)
        } catch {
            showToast("Couldn't open #\(number): \(error.localizedDescription)", type: .error)
        }
    }

    private func show(_ pr: PullRequest, tab: PRDetailTab) {
        selectedPRTab = tab
        selectedPR = pr
        loadPRDetails(for: pr)
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
