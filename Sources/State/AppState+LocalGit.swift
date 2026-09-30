import Foundation

/// Local repository operations beyond staging: stashes, cherry-pick, tags and history rewriting.
extension AppState {

    // MARK: - Stashes

    public func loadStashes() async {
        guard let repo = currentRepo else { stashes = []; return }
        stashes = (try? await gitService.listStashes(at: repo.path)) ?? []
    }

    public func createStash(message: String, includeUntracked: Bool, keepIndex: Bool) async -> Bool {
        await runGitOperation("stash", success: "Stashed changes") { git, path in
            try await git.stashPush(at: path, message: message, includeUntracked: includeUntracked, keepIndex: keepIndex)
        }
    }

    public func applyStash(_ stash: GitStash, pop: Bool) async -> Bool {
        await runGitOperation(pop ? "pop" : "apply", success: pop ? "Popped \(stash.ref)" : "Applied \(stash.ref)") { git, path in
            try await git.stashApply(at: path, ref: stash.ref, pop: pop)
        }
    }

    public func dropStash(_ stash: GitStash) async -> Bool {
        await runGitOperation("drop", success: "Dropped \(stash.ref)") { git, path in
            try await git.stashDrop(at: path, ref: stash.ref)
        }
    }

    public func stashDiff(_ stash: GitStash) async -> [FileDiff] {
        guard let repo = currentRepo else { return [] }
        return (try? await gitService.stashDiff(at: repo.path, ref: stash.ref)) ?? []
    }

    // MARK: - Commits

    public func cherryPick(_ commit: GitCommit, noCommit: Bool = false) {
        Task {
            await runGitOperation("cherry-pick", success: noCommit
                ? "Applied \(commit.shortSha) to the working copy"
                : "Cherry-picked \(commit.shortSha) onto \(currentBranch)") { git, path in
                try await git.cherryPick(at: path, sha: commit.sha, noCommit: noCommit)
            }
        }
    }

    public func createTag(name: String, on commit: GitCommit, message: String?, push: Bool) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return await runGitOperation("tag", success: push ? "Created and pushed tag \(trimmed)" : "Created tag \(trimmed)") { git, path in
            try await git.createTag(at: path, name: trimmed, sha: commit.sha, message: message)
            if push { try await git.pushTag(at: path, name: trimmed) }
        }
    }

    public func revertCommit(_ commit: GitCommit) {
        Task {
            await runGitOperation("revert", success: "Reverted \(commit.shortSha) on \(currentBranch)") { git, path in
                try await git.revertCommit(at: path, sha: commit.sha)
            }
        }
    }

    // MARK: - Concluding a merge / rebase / cherry-pick / revert

    /// Runs `git <verb> --continue` once nothing is unmerged. A failure (e.g. a hook rejecting the merge commit)
    /// opens the failure dialog with fixes instead of a passing toast. Returns whether it succeeded.
    @discardableResult
    public func continueOperationInProgress() async -> Bool {
        guard let repo = currentRepo else { return false }
        let path = repo.path
        guard let op = await ConflictMerge.inProgress(repo: path), op.verb != nil else { return false }
        let name = op.title.lowercased()
        let success = pendingPRMergePush.map { op == .merge ? "Merge committed. Pushing to update \($0)…" : nil } ?? nil
        let operation = GitRetryableOperation(
            title: "Couldn't finish the \(name)", verb: "commit the \(name)", success: success ?? "\(op.title) complete",
            runSkippingHooks: { [weak self] in
                try await ConflictMerge.continueOperation(repo: path, operation: op, skipHooks: true)
                await self?.pushPendingPRMergeIfConcluded()
            }
        ) { [weak self] in
            try await ConflictMerge.continueOperation(repo: path, operation: op)
            await self?.pushPendingPRMergeIfConcluded()
        }
        do {
            try await operation.run()
            showToast(operation.success, type: .success)
            await refreshRepoAsync(silent: false)
            return true
        } catch {
            await refreshRepoAsync(silent: false)
            if conflictResolverRequest != nil {
                conflictResolverRequest = nil
                try? await Task.sleep(for: .milliseconds(350))
            }
            presentGitFailure(operation, error: error)
            return false
        }
    }

    public func abortOperationInProgress() async {
        guard let repo = currentRepo, let op = await ConflictMerge.inProgress(repo: repo.path) else { return }
        do {
            try await ConflictMerge.abort(repo: repo.path, operation: op)
            pendingPRMergePush = nil
            showToast("\(op.title) aborted", type: .info)
        } catch {
            showToast("Couldn't abort: \(error.localizedDescription)", type: .error)
        }
        await refreshRepoAsync(silent: false)
    }

    // MARK: - History

    /// Shows another branch's log in History (`nil` = HEAD), so its commits can be cherry-picked.
    public func setHistoryRef(_ ref: String?) {
        guard let repo = currentRepo else { return }
        let token = UUID()
        historyLoadToken = token
        Task {
            let commits = (try? await gitService.getLog(at: repo.path, maxCount: 200, ref: ref)) ?? []
            var foreign: Set<String> = []
            if let ref { foreign = await gitService.commitsNotInHead(at: repo.path, ref: ref) }
            guard historyLoadToken == token else { return }
            // Ref and rows change in one update so the list is rebuilt once with the new commits.
            self.historyRef = ref
            self.historyForeignCommits = foreign
            self.commits = commits
            if let first = commits.first {
                selectCommit(first)
            }
        }
    }

    public func canCherryPick(_ commit: GitCommit) -> Bool {
        historyRef != nil && historyForeignCommits.contains(commit.sha)
    }

    /// Commits from `commit` up to HEAD (newest first) when they can be rewritten with an interactive rebase.
    public func rebaseRange(from commit: GitCommit) -> [GitCommit]? {
        guard historyRef == nil, let index = commits.firstIndex(where: { $0.sha == commit.sha }) else { return nil }
        let range = Array(commits[...index])
        guard !range.contains(where: \.isMerge) else { return nil }
        return range
    }

    /// `steps` are oldest first. The base is the parent of the oldest commit (or `--root`).
    public func runInteractiveRebase(from oldest: GitCommit, steps: [GitService.RebaseStep]) async -> Bool {
        let base = oldest.parentShas.first
        let ok = await runGitOperation("rebase", success: "History rewritten on \(currentBranch)") { git, path in
            try await git.interactiveRebase(at: path, onto: base, steps: steps)
        }
        if ok, let first = commits.first { selectCommit(first) }
        return ok
    }

    public func remoteBranchesContaining(_ commit: GitCommit) async -> [String] {
        guard let repo = currentRepo else { return [] }
        return await gitService.remoteBranchesContaining(at: repo.path, sha: commit.sha)
    }

    /// Runs a git operation with a shared busy flag, toast and refresh. Returns whether it succeeded.
    @discardableResult
    func runGitOperation(_ kind: String, success: String, _ body: @escaping (GitService, String) async throws -> Void) async -> Bool {
        guard let repo = currentRepo else { return false }
        guard gitOperationInFlight == nil else {
            showToast("Another git operation is still running", type: .info)
            return false
        }
        gitOperationInFlight = kind
        defer { gitOperationInFlight = nil }
        do {
            try await body(gitService, repo.path)
            showToast(success, type: .success)
            await loadStashes()
            // Non-silent so the commit list and branches reload even when the working tree is unchanged.
            await refreshRepoAsync(silent: false)
            return true
        } catch {
            let repoPath = repo.path
            presentGitFailure(GitRetryableOperation(title: "\(kind.prefix(1).uppercased() + kind.dropFirst()) failed", verb: kind, success: success) { [gitService] in
                try await body(gitService, repoPath)
            }, error: error)
            await refreshRepoAsync(silent: false)
            return false
        }
    }
}

// MARK: - Working diff cache

struct CachedWorkingDiff: Sendable {
    /// The file's status rows when the diff was taken; a different status means the entry is stale.
    let statuses: [GitFileStatus]
    let diff: FileDiff?
    let staged: Set<DiffLineKey>
    let lineStaging: Bool
}

extension AppState {
    func diffCacheKey(_ path: String) -> String {
        (currentRepo?.path ?? "") + "\u{0}" + path
    }

    func applyWorkingDiff(_ entry: CachedWorkingDiff) {
        if currentDiff != entry.diff { currentDiff = entry.diff }
        if currentDiffStagedLines != entry.staged { currentDiffStagedLines = entry.staged }
        if lineStagingEnabled != entry.lineStaging { lineStagingEnabled = entry.lineStaging }
    }

    /// Line-stageable HEAD→working-tree diff when possible, otherwise the plain index or worktree diff.
    func fetchWorkingDiff(_ file: GitFileStatus, change: WorkingChange?, repoPath: String) async -> CachedWorkingDiff {
        let statuses = files.filter { $0.path == file.path }
        if let change, ![.unmerged, .renamed, .copied].contains(change.changeKind),
           change.index?.changeKind != .unmerged, change.worktree?.changeKind != .unmerged {
            let untracked = change.index == nil && change.worktree?.changeKind == .untracked
            if let result = try? await gitService.workingDiff(at: repoPath, path: file.path, untracked: untracked) {
                let enabled = !result.diff.isBinary && !result.diff.patchHeader.isEmpty
                return CachedWorkingDiff(statuses: statuses, diff: result.diff, staged: result.staged, lineStaging: enabled)
            }
        }
        let diff = try? await gitService.getDiff(at: repoPath, for: file.path, staged: file.isStaged)
        return CachedWorkingDiff(statuses: statuses, diff: diff, staged: [], lineStaging: false)
    }

    /// Loads diffs of the other changed files in the background so clicking one shows it immediately.
    /// Files over 1 MB are skipped; they load on demand.
    func prefetchWorkingDiffs() {
        guard let repo = currentRepo, pendingStagingOps == 0 else { return }
        diffPrefetchTask?.cancel()
        if workingDiffCache.count > 400 { workingDiffCache.removeAll() }
        let repoPath = repo.path
        let pending = workingChanges.filter { change in
            guard change.path != selectedFile?.path else { return false }
            let statuses = files.filter { $0.path == change.path }
            guard workingDiffCache[diffCacheKey(change.path)]?.statuses != statuses else { return false }
            let url = URL(fileURLWithPath: repoPath).appendingPathComponent(change.path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size <= 1_000_000
        }.prefix(80)
        guard !pending.isEmpty else { return }
        diffPrefetchTask = Task { [weak self] in
            for change in pending {
                guard let self, !Task.isCancelled, self.currentRepo?.path == repoPath else { return }
                let entry = await self.fetchWorkingDiff(change.primary, change: change, repoPath: repoPath)
                guard self.currentRepo?.path == repoPath, self.pendingStagingOps == 0 else { continue }
                self.workingDiffCache[self.diffCacheKey(change.path)] = entry
            }
        }
    }
}

extension AppState {
    /// Reverts every changed file (staged and unstaged) and deletes the untracked ones in the list.
    public func discardAllChanges() {
        guard let repo = currentRepo else { return }
        let paths = Array(Set(files.map(\.path)))
        guard !paths.isEmpty else { return }
        Task {
            do {
                try await gitService.discardChanges(at: repo.path, files: paths)
                showToast("Discarded changes in \(paths.count) file\(paths.count == 1 ? "" : "s")", type: .info)
            } catch {
                showToast("Discard failed: \(error.localizedDescription)", type: .error)
            }
            await refreshRepoAsync()
        }
    }
}

extension AppState {
    /// Stashes just these files (tracked and untracked) under a descriptive message. Returns `true` on success.
    @discardableResult
    public func stashFiles(_ paths: [String]) async -> Bool {
        guard let repo = currentRepo, !paths.isEmpty else { return false }
        let label = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) files"
        do {
            try await gitService.stashPush(at: repo.path, message: "GitXX: \(label)", includeUntracked: true, keepIndex: false, paths: paths)
            showToast("Stashed \(label)", type: .info)
            await loadStashes()
            await refreshRepoAsync()
            return true
        } catch {
            showToast("Stash failed: \(error.localizedDescription)", type: .error)
            return false
        }
    }

    /// Reverts just these files (and deletes them if untracked). Returns `true` on success.
    @discardableResult
    public func revertFiles(_ paths: [String]) async -> Bool {
        guard let repo = currentRepo, !paths.isEmpty else { return false }
        let label = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) files"
        do {
            try await gitService.discardChanges(at: repo.path, files: paths)
            showToast("Reverted \(label)", type: .info)
            await refreshRepoAsync()
            return true
        } catch {
            showToast("Revert failed: \(error.localizedDescription)", type: .error)
            return false
        }
    }
}
