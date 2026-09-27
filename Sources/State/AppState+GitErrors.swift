import Foundation
import AppKit

/// A retryable git operation, so a failure dialog can offer "fix, then try again".
public struct GitRetryableOperation {
    public let title: String
    /// Verb used in button labels ("pull", "switch branches").
    public let verb: String
    public let success: String
    public let run: @MainActor () async throws -> Void

    public init(title: String, verb: String, success: String? = nil, run: @escaping @MainActor () async throws -> Void) {
        self.title = title
        self.verb = verb
        self.success = success ?? "\(verb.prefix(1).uppercased() + verb.dropFirst()) succeeded"
        self.run = run
    }
}

extension AppState {
    /// Shows the failure dialog for `operation`, with fixes chosen from the error output.
    func presentGitFailure(_ operation: GitRetryableOperation, error: Error) {
        let output = error.localizedDescription
        let kind = GitErrorKind.classify(output)
        var summary = ""
        var files: [String] = []
        var actions: [GitFixAction] = []

        switch kind {
        case .localChangesOverwritten(let changed):
            files = changed
            summary = "You have uncommitted changes to \(changed.isEmpty ? "some files" : "\(changed.count) file\(changed.count == 1 ? "" : "s")") that this \(operation.verb) would overwrite. Nothing was changed."
            actions.append(GitFixAction("Stash, \(operation.verb), then restore", systemImage: "tray.and.arrow.down", role: .primary) { [weak self] in
                await self?.stashAndRetry(operation, includeUntracked: false)
            })
            actions.append(GitFixAction("Stash & \(operation.verb) (keep changes in the stash)", systemImage: "tray.full") { [weak self] in
                await self?.stashAndRetry(operation, includeUntracked: false, restore: false)
            })
            actions.append(GitFixAction("Commit changes first", systemImage: "checkmark.circle") { [weak self] in
                self?.activeTab = .changes
            })
            if !changed.isEmpty {
                actions.append(GitFixAction("Discard these changes & \(operation.verb)", systemImage: "trash", role: .destructive,
                                            confirmation: "Your changes to \(changed.count) file\(changed.count == 1 ? "" : "s") will be lost. This can't be undone.") { [weak self] in
                    await self?.discardAndRetry(operation, files: changed)
                })
            }
        case .untrackedOverwritten(let untracked):
            files = untracked
            summary = "Untracked files in your working copy would be overwritten by this \(operation.verb). Nothing was changed."
            actions.append(GitFixAction("Stash (incl. untracked), \(operation.verb), then restore", systemImage: "tray.and.arrow.down", role: .primary) { [weak self] in
                await self?.stashAndRetry(operation, includeUntracked: true)
            })
            actions.append(GitFixAction("Stash (incl. untracked) & \(operation.verb), keep changes stashed", systemImage: "tray.full") { [weak self] in
                await self?.stashAndRetry(operation, includeUntracked: true, restore: false)
            })
            if !untracked.isEmpty {
                actions.append(GitFixAction("Delete these files & \(operation.verb)", systemImage: "trash", role: .destructive,
                                            confirmation: "\(untracked.count) untracked file\(untracked.count == 1 ? "" : "s") will be deleted. This can't be undone.") { [weak self] in
                    await self?.runFix(then: operation) { git, repo in
                        try await git.run(["clean", "-f", "--"] + untracked, in: repo)
                    }
                })
            }
        case .indexLocked(let lockPath):
            summary = "Another git process is using this repository (index.lock exists). If nothing else is running git — a terminal command, an IDE, or a crashed process — the lock is stale and can be removed."
            actions.append(GitFixAction("Retry", systemImage: "arrow.clockwise", role: .primary) { [weak self] in
                await self?.retry(operation)
            })
            actions.append(GitFixAction("Remove lock & retry", systemImage: "lock.open", role: .destructive,
                                        confirmation: "Only remove the lock if no other git command is running in this repository.") { [weak self] in
                guard let self, let repo = self.currentRepo else { return }
                let path = lockPath ?? (repo.path as NSString).appendingPathComponent(".git/index.lock")
                try? FileManager.default.removeItem(atPath: path)
                await self.retry(operation)
            })
        case .pushRejected:
            summary = "The remote branch has commits you don't have locally. Pull them first, or overwrite the remote if you rewrote history on purpose."
            actions.append(GitFixAction("Pull, then push", systemImage: "arrow.down.arrow.up", role: .primary) { [weak self] in
                await self?.runFix(then: operation) { git, repo in try await git.pull(at: repo) }
            })
            actions.append(GitFixAction("Force push (with lease)", systemImage: "exclamationmark.arrow.triangle.2.circlepath", role: .destructive,
                                        confirmation: "Remote commits that aren't in your branch will be replaced. --force-with-lease refuses if someone pushed since your last fetch.") { [weak self] in
                self?.forcePushOrigin()
            })
        case .divergentBranches:
            summary = "Your branch and its remote both have new commits. Choose how to combine them."
            actions.append(GitFixAction("Pull with rebase", systemImage: "arrow.triangle.branch", role: .primary) { [weak self] in
                await self?.runFix(then: nil, success: "Pulled with rebase") { git, repo in try await git.run(["pull", "--rebase"], in: repo) }
            })
            actions.append(GitFixAction("Pull with merge", systemImage: "arrow.triangle.merge") { [weak self] in
                await self?.runFix(then: nil, success: "Pulled with a merge commit") { git, repo in try await git.run(["pull", "--no-rebase"], in: repo) }
            })
        case .conflicts:
            summary = "Git stopped because of conflicting changes. Resolve the conflicted files in Changes and commit, or abort to go back."
            actions.append(GitFixAction("Resolve in Changes", systemImage: "exclamationmark.triangle", role: .primary) { [weak self] in
                self?.activeTab = .changes
            })
            actions.append(GitFixAction("Abort", systemImage: "xmark.circle", role: .destructive,
                                        confirmation: "The in-progress merge, rebase or cherry-pick will be abandoned.") { [weak self] in
                await self?.runFix(then: nil, success: "Aborted") { git, repo in
                    for command in [["merge", "--abort"], ["rebase", "--abort"], ["cherry-pick", "--abort"], ["revert", "--abort"]] {
                        if (try? await git.run(command, in: repo)) != nil { return }
                    }
                }
            })
        case .noUpstream:
            summary = "This branch isn't linked to a remote branch yet."
            actions.append(GitFixAction("Push and set upstream", systemImage: "arrow.up.circle", role: .primary) { [weak self] in
                self?.pushOrigin()
            })
        case .unknownRef:
            summary = "Git couldn't find that branch or commit locally. Fetching may bring it in."
            actions.append(GitFixAction("Fetch & retry", systemImage: "arrow.down.circle", role: .primary) { [weak self] in
                await self?.runFix(then: operation) { git, repo in try await git.fetch(at: repo) }
            })
        case .network:
            summary = "Couldn't reach the remote. Check your network or VPN connection."
            actions.append(GitFixAction("Retry", systemImage: "arrow.clockwise", role: .primary) { [weak self] in
                await self?.retry(operation)
            })
        case .authentication:
            summary = "The remote rejected your credentials. Check your SSH key or credential helper — running the command in Terminal shows git's prompt."
        case .other:
            summary = "Git reported an error."
            actions.append(GitFixAction("Retry", systemImage: "arrow.clockwise", role: .primary) { [weak self] in
                await self?.retry(operation)
            })
        }

        actions.append(GitFixAction("Open Terminal", systemImage: "terminal") { [weak self] in
            self?.activeTab = .terminal
        })
        parkedOperationError = nil
        operationError = GitOperationError(title: operation.title, summary: summary, details: output, files: files, actions: actions)
    }

    /// Runs `operation` again; a new failure opens a fresh dialog.
    func retry(_ operation: GitRetryableOperation) async {
        do {
            try await operation.run()
            showToast(operation.success, type: .success)
        } catch {
            presentGitFailure(operation, error: error)
        }
        await refreshRepoAsync(silent: false)
    }

    /// Runs a fix command, then (optionally) the original operation.
    func runFix(then operation: GitRetryableOperation?, success: String? = nil,
                _ fix: @escaping (GitService, String) async throws -> Void) async {
        guard let repo = currentRepo else { return }
        do {
            try await fix(gitService, repo.path)
        } catch {
            presentGitFailure(GitRetryableOperation(title: "Fix failed", verb: "retry") { [gitService] in
                try await fix(gitService, repo.path)
            }, error: error)
            await refreshRepoAsync(silent: false)
            return
        }
        if let operation {
            await retry(operation)
        } else {
            if let success { showToast(success, type: .success) }
            await refreshRepoAsync(silent: false)
        }
    }

    private func stashAndRetry(_ operation: GitRetryableOperation, includeUntracked: Bool, restore: Bool = true) async {
        guard let repo = currentRepo else { return }
        do {
            try await gitService.stashPush(at: repo.path, message: "GitXX: before \(operation.verb)", includeUntracked: includeUntracked, keepIndex: false)
        } catch {
            presentGitFailure(GitRetryableOperation(title: "Stash failed", verb: "stash") { [gitService] in
                try await gitService.stashPush(at: repo.path, message: "GitXX: before \(operation.verb)", includeUntracked: includeUntracked, keepIndex: false)
            }, error: error)
            return
        }
        var operationError: Error?
        do { try await operation.run() } catch { operationError = error }
        if !restore {
            if let operationError {
                presentGitFailure(operation, error: operationError)
            } else {
                showToast("\(operation.verb.capitalized) done. Your changes are in stash@{0} — restore them from the stash drawer.", type: .success)
            }
            await loadStashes()
            await refreshRepoAsync(silent: false)
            return
        }
        do {
            try await gitService.stashApply(at: repo.path, ref: "stash@{0}", pop: true)
        } catch {
            showToast("Your changes are saved in stash@{0} — restoring them hit a conflict. Resolve it in Changes, or use the stash drawer.", type: .error)
        }
        if let operationError {
            presentGitFailure(operation, error: operationError)
        } else {
            showToast("\(operation.verb.capitalized) done; your changes were restored", type: .success)
        }
        await loadStashes()
        await refreshRepoAsync(silent: false)
    }

    private func discardAndRetry(_ operation: GitRetryableOperation, files: [String]) async {
        await runFix(then: operation) { git, repo in
            try await git.run(["checkout", "HEAD", "--"] + files, in: repo)
        }
    }

    // MARK: - Common operations

    func pullOperation() -> GitRetryableOperation? {
        guard let repo = currentRepo else { return nil }
        return GitRetryableOperation(title: "Pull failed", verb: "pull") { [gitService] in
            try await gitService.pull(at: repo.path)
        }
    }

    func pushOperation(branch: String) -> GitRetryableOperation? {
        guard let repo = currentRepo else { return nil }
        return GitRetryableOperation(title: "Push failed", verb: "push") { [gitService] in
            try await gitService.push(at: repo.path, setUpstream: true, branch: branch)
        }
    }

    func checkoutOperation(_ branch: String) -> GitRetryableOperation? {
        guard let repo = currentRepo else { return nil }
        return GitRetryableOperation(title: "Couldn't switch to \(branch)", verb: "switch branches", success: "Switched to \(branch)") { [gitService] in
            try await gitService.checkout(at: repo.path, branch: branch)
        }
    }

    /// Sets the failure dialog aside and shows the file's diff on the Changes tab.
    public func inspectFileFromError(_ path: String) {
        guard let error = operationError, let file = files.first(where: { $0.path == path }) else { return }
        parkedOperationError = error
        operationError = nil
        activeTab = .changes
        selectFile(file)
    }

    public func reopenParkedError() {
        guard let error = parkedOperationError else { return }
        parkedOperationError = nil
        operationError = error
    }
}
