import Foundation

/// Local (git) state of one repository, kept so switching back to it paints immediately.
struct RepoSnapshot {
    var currentBranch: String
    var branches: [GitBranch]
    var commitsAhead: Int
    var commitsBehind: Int
    var files: [GitFileStatus]
    var selectedFile: GitFileStatus?
    var currentDiff: FileDiff?
    var commits: [GitCommit]
    var selectedCommit: GitCommit?
    var commitDiff: FileDiff?
    var stashes: [GitStash]
    var commitSummary: String
    var commitDescription: String
    var lastFetchedDate: Date?
}

extension AppState {
    func saveRepoSnapshot() {
        guard let path = currentRepo?.path else { return }
        repoSnapshots[path] = RepoSnapshot(
            currentBranch: currentBranch, branches: branches,
            commitsAhead: commitsAhead, commitsBehind: commitsBehind,
            files: files, selectedFile: selectedFile, currentDiff: currentDiff,
            commits: commits, selectedCommit: selectedCommit, commitDiff: commitDiff,
            stashes: stashes, commitSummary: commitSummary, commitDescription: commitDescription,
            lastFetchedDate: lastFetchedDate
        )
    }

    /// Replaces every repo-scoped value, from the snapshot if there is one, otherwise with an empty state, so
    /// nothing from the previous repository stays on screen while the new one loads.
    private func applyRepoSnapshot(for path: String, fallbackBranch: String?) {
        let snap = repoSnapshots[path]
        currentBranch = snap?.currentBranch ?? fallbackBranch ?? ""
        branches = snap?.branches ?? []
        commitsAhead = snap?.commitsAhead ?? 0
        commitsBehind = snap?.commitsBehind ?? 0
        files = snap?.files ?? []
        selectedFile = snap?.selectedFile
        currentDiff = snap?.currentDiff
        currentDiffStagedLines = []
        commits = snap?.commits ?? []
        selectedCommit = snap?.selectedCommit
        commitDiff = snap?.commitDiff
        stashes = snap?.stashes ?? []
        commitSummary = snap?.commitSummary ?? ""
        commitDescription = snap?.commitDescription ?? ""
        lastFetchedDate = snap?.lastFetchedDate
        historyRef = nil
        historyForeignCommits = []
        fileFilterText = ""
        historyFilterText = ""
    }

    public func loadRepo(path: String) {
        repoLoadGeneration &+= 1
        let generation = repoLoadGeneration
        let switching = currentRepo?.path != path

        if switching {
            saveRepoSnapshot()
            switchingRepoPath = path
            // Known repositories switch synchronously; git confirms the details in the background.
            if let known = recentRepos.first(where: { $0.path == path }) {
                activateRepo(known, previousPath: currentRepo?.path)
            }
        }

        Task {
            async let isRepoCheck = gitService.isGitRepository(at: path)
            async let nameLookup = gitService.getRepoName(at: path)
            async let remoteLookup = gitService.getRemoteUrl(at: path)
            async let headLookup = headBranchName(at: path)
            let isRepo = await isRepoCheck
            let name = await nameLookup
            let remote = await remoteLookup
            let head = await headLookup
            guard generation == repoLoadGeneration else { return }

            if !isRepo {
                let repo = GitRepository(name: (path as NSString).lastPathComponent, path: path)
                if currentRepo?.path != path { activateRepo(repo, previousPath: currentRepo?.path) } else { currentRepo = repo }
                repoFileWatcher.stopWatching()
                switchingRepoPath = nil
                refreshRepo()
                return
            }

            let repo = GitRepository(name: name, path: path, remoteUrl: remote)
            if currentRepo?.path != path {
                activateRepo(repo, previousPath: currentRepo?.path)
            } else if currentRepo?.name != name || currentRepo?.remoteUrl != remote {
                currentRepo = repo
                hydrateCachedPRList(for: repo)
            }
            // `git status` can take seconds on big repos; HEAD's name is instant.
            if let head, !head.isEmpty, currentBranch != head { currentBranch = head }

            if let idx = recentRepos.firstIndex(where: { $0.path == path }) {
                var existing = recentRepos.remove(at: idx)
                existing.remoteUrl = remote
                recentRepos.insert(existing.name == name ? existing : repo, at: 0)
            } else {
                recentRepos.insert(repo, at: 0)
            }
            saveRecentRepos()
            repoFileWatcher.startWatching(at: repo.path)
            if switching && activeTab == .pullRequests {
                loadPRs()
            }
            await refreshRepoAsync(silent: false)
            if generation == repoLoadGeneration { switchingRepoPath = nil }
        }
    }

    /// Checked-out branch name (or short SHA when detached) without running a full `git status`.
    func headBranchName(at path: String) async -> String? {
        if let r = try? await gitService.execute(arguments: ["symbolic-ref", "--short", "-q", "HEAD"], in: path), r.isSuccess {
            let name = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        guard let r = try? await gitService.execute(arguments: ["rev-parse", "--short", "HEAD"], in: path), r.isSuccess else { return nil }
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    private func activateRepo(_ repo: GitRepository, previousPath: String?) {
        applyRepoSnapshot(for: repo.path, fallbackBranch: repo.currentBranch)
        currentRepo = repo
        if previousPath != repo.path {
            resetRepoScopedPRState()
            hydrateCachedPRList(for: repo)
            recordNavigationStep()
        }
    }

    private func hydrateCachedPRList(for repo: GitRepository) {
        guard let remoteUrl = repo.remoteUrl, let ownerRepo = gitHubService.parseRepoOwnerAndName(from: remoteUrl) else { return }
        if let cached = PRListCache.shared.get(owner: ownerRepo.owner, repo: ownerRepo.name, filter: prFilter) {
            pullRequests = cached.pullRequests
            isLoadingPRs = false
        }
        if let cachedCounts = PRListCache.shared.getTabCounts(owner: ownerRepo.owner, repo: ownerRepo.name) {
            prTabCounts = cachedCounts
        }
    }
}
