import Foundation
import AppKit

/// A retryable git operation, so a failure dialog can offer "fix, then try again".
public struct GitRetryableOperation {
    public let title: String
    /// Verb used in button labels ("pull", "switch branches").
    public let verb: String
    public let success: String
    public let run: @MainActor () async throws -> Void
    /// The same operation with git hooks bypassed, offered when a hook rejected it.
    public var runSkippingHooks: (@MainActor () async throws -> Void)?

    public init(title: String, verb: String, success: String? = nil,
                runSkippingHooks: (@MainActor () async throws -> Void)? = nil,
                run: @escaping @MainActor () async throws -> Void) {
        self.title = title
        self.verb = verb
        self.success = success ?? "\(verb.prefix(1).uppercased() + verb.dropFirst()) succeeded"
        self.runSkippingHooks = runSkippingHooks
        self.run = run
    }
}

extension AppState {
    /// Shows the failure dialog for `operation`, with fixes chosen from the error output.
    func presentGitFailure(_ operation: GitRetryableOperation, error: Error) {
        let output = error.localizedDescription
        var kind = GitErrorKind.classify(output)
        if kind == .other, operation.runSkippingHooks != nil, repoHasHooks() { kind = .hookRejected }
        var summary = ""
        var details = output
        var highlights: [String] = []
        var files: [String] = []
        var actions: [GitFixAction] = []

        switch kind {
        case .hookRejected:
            let digest = HookFailure(output: output)
            details = digest.cleanedOutput
            highlights = Array(digest.problems.prefix(8))
            files = hookFiles(digest.paths)
            let who = digest.hook.map { "The \($0) hook" } ?? "A git hook in this repository"
            let what = digest.tasks.isEmpty ? "" : " while running \(digest.tasks.map { "“\($0)”" }.joined(separator: ", "))"
            summary = "\(who) failed\(what), so git didn't \(operation.verb). Nothing was committed; your staged changes and resolved files are untouched. Fix what it reports below and retry, or ask the assistant to work out the fix."
            actions.append(GitFixAction("Ask AI to diagnose & fix", systemImage: "sparkles", role: .primary) { [weak self] in
                self?.askAIAboutHookFailure(verb: operation.verb, digest: digest)
            })
            actions.append(GitFixAction(files.isEmpty ? "Fix in Changes" : "Fix \(files.count == 1 ? (files[0] as NSString).lastPathComponent : "\(files.count) flagged files") in Changes",
                                        systemImage: "pencil.and.list.clipboard") { [weak self] in
                guard let self else { return }
                if let first = files.first, self.files.contains(where: { $0.path == first }) {
                    self.inspectFileFromError(first)
                } else {
                    self.parkedOperationError = self.operationError
                    self.operationError = nil
                    self.activeTab = .changes
                }
            })
            actions.append(GitFixAction("Retry \(operation.verb)", systemImage: "arrow.clockwise") { [weak self] in
                await self?.retry(operation)
            })
            if let skip = operation.runSkippingHooks {
                actions.append(GitFixAction("\(operation.verb.prefix(1).uppercased() + operation.verb.dropFirst()) without running hooks",
                                            systemImage: "exclamationmark.shield", role: .destructive,
                                            confirmation: "Formatters, linters and secret scanners won't run this time. Use it only when the failure isn't about your changes (a broken tool or config, a false positive). A real secret that reaches GitHub has to be rotated, even if you remove it later.") { [weak self] in
                    await self?.retry(GitRetryableOperation(title: operation.title, verb: operation.verb, success: operation.success, run: skip))
                })
            }
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
            actions.append(GitFixAction("Resolve Conflicts…", systemImage: "arrow.triangle.merge", role: .primary) { [weak self] in
                self?.refreshAfterExternalChange()
                self?.openConflictResolver()
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
        let retryAction = GitFixAction("Retry \(operation.verb)", systemImage: "arrow.clockwise", role: .primary) { [weak self] in
            await self?.retry(operation)
        }
        operationError = GitOperationError(title: operation.title, summary: summary, details: details, files: files, actions: actions,
                                           retry: retryAction, showOutput: kind == .hookRejected && highlights.isEmpty,
                                           highlights: highlights)
    }

    /// Repo-relative paths named by a hook, keeping only ones that exist here.
    private func hookFiles(_ paths: [String]) -> [String] {
        guard let repo = currentRepo else { return [] }
        let root = repo.path.hasSuffix("/") ? repo.path : repo.path + "/"
        var result: [String] = []
        for path in paths {
            let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
            guard !relative.hasPrefix("/"), !result.contains(relative),
                  FileManager.default.fileExists(atPath: root + relative) || files.contains(where: { $0.path == relative }) else { continue }
            result.append(relative)
        }
        return result
    }

    /// Hands a rejected commit to the assistant with the digested hook output; it can read the repo's hook
    /// config (husky, lint-staged, pre-commit), edit files and stage them.
    func askAIAboutHookFailure(verb: String, digest: HookFailure) {
        parkedOperationError = operationError
        operationError = nil
        activeTab = .changes
        let chat = AIChatStore.shared
        if !chat.isRunning { chat.newChat() }
        if !chat.isOpen { chat.toggle() }
        var output = digest.cleanedOutput
        if output.count > 6000 { output = String(output.prefix(2500)) + "\n…\n" + String(output.suffix(3000)) }
        var prompt = "A git hook rejected my attempt to \(verb) on branch \(currentBranch)"
        if let hook = digest.hook { prompt += " (\(hook))" }
        if !digest.tasks.isEmpty { prompt += "; failing task: \(digest.tasks.joined(separator: ", "))" }
        prompt += ".\n\nKey lines:\n" + digest.problems.prefix(10).map { "- \($0)" }.joined(separator: "\n")
        prompt += "\n\nFull hook output:\n```\n\(output)\n```\n\n"
        prompt += "Find the root cause (read the hook config such as .husky/, lint-staged and prettier settings, .pre-commit-config.yaml as needed), "
        prompt += "explain it in two lines, apply the smallest safe fix (edit and stage files), then retry: "
        if operationInProgress == .merge || operationInProgress == .cherryPick || operationInProgress == .revert {
            prompt += "a \(operationInProgress!.title.lowercased()) is in progress, so conclude it with `git commit --no-edit` (never `-m`, which drops the merge message). "
        } else if operationInProgress == .rebase {
            prompt += "a rebase is in progress, so continue it with `git -c core.editor=true rebase --continue`. "
        } else if !commitSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "commit again with the message \"\(commitSummary.trimmingCharacters(in: .whitespacesAndNewlines))\". "
        } else {
            prompt += "commit again with a message that describes the staged changes. "
        }
        prompt += "If the retry fails again, read the new output and keep fixing. Don't bypass hooks unless I ask."
        if chat.isRunning { chat.input = prompt } else { chat.send(prompt, state: self) }
    }

    /// Whether commits here run hooks: installed in `.git/hooks`, or managed by husky / pre-commit.
    private func repoHasHooks() -> Bool {
        guard let repo = currentRepo else { return false }
        let fm = FileManager.default
        let root = repo.path as NSString
        if fm.fileExists(atPath: root.appendingPathComponent(".husky"))
            || fm.fileExists(atPath: root.appendingPathComponent(".pre-commit-config.yaml")) { return true }
        let hooks = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(".git/hooks"))) ?? []
        return hooks.contains { !$0.hasSuffix(".sample") && !$0.hasPrefix(".") }
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
