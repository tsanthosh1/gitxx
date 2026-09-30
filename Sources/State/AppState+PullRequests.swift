import Foundation
import AppKit
import SwiftUI

/// Actions posted from the WebKit conversation stream.
public enum PRWebAction: Sendable {
    case toggleChecklist(index: Int)
    case merge(method: GitHubAPIService.MergeMethod, title: String?, message: String?, deleteBranch: Bool)
    case close
    case reopen
    case updateBranch
    case postComment(body: String)
    case replyToThread(commentId: String, body: String)
    case resolveThread(nodeId: String, resolve: Bool)
    case rerunFailedChecks
    case rerunCheck(jobId: String)
    case setDraft(Bool)
    case openFile(path: String)
    case openReviewModal
    case refresh
    case switchTab(PRDetailTab)
    case updateDescription(body: String)
    case aiEditDescription(instruction: String)
    case openDescriptionInChat(instruction: String)
    case openCheckRun(runId: Int, jobId: Int?)
    case showPRActions
    case explainCheck(name: String)
    case resolveConflictsLocally
}

public struct PRRepoContext: Sendable {
    public let owner: String
    public let repo: String
    public let token: String?
}

extension AppState {

    func prRepoContext() -> PRRepoContext? {
        guard let repo = currentRepo else { return nil }
        let ownerRepo = gitHubService.parseRepoOwnerAndName(from: repo.remoteUrl)
        return PRRepoContext(
            owner: ownerRepo?.owner ?? "octocat",
            repo: ownerRepo?.name ?? repo.name,
            token: effectiveGitHubToken
        )
    }

    public func isPRActionRunning(_ key: String) -> Bool {
        prActionsInFlight.contains(key)
    }

    /// Runs a PR mutation with in-flight tracking and a visible error toast; rethrows so callers can react.
    func runPRAction(_ key: String, _ operation: () async throws -> Void) async throws {
        guard !prActionsInFlight.contains(key) else { return }
        prActionsInFlight.insert(key)
        defer { prActionsInFlight.remove(key) }
        do {
            try await operation()
        } catch {
            showToast(error.localizedDescription, type: .error)
            throw error
        }
    }

    // MARK: - Detail metadata

    public func loadPRMeta(for pr: PullRequest) {
        guard let ctx = prRepoContext(), ctx.token != nil else { return }
        runPRDetailTask("meta") { [self] in
            guard let meta = try? await gitHubService.fetchPRDetailMeta(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, token: ctx.token) else { return }
            PRTimelineCache.shared.setMeta(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, meta: meta)
            guard self.selectedPR?.number == pr.number else { return }
            if self.prMeta != meta {
                self.prMeta = meta
            }
            let applied = meta.applyingThreadState(to: self.prTimeline)
            if applied != self.prTimeline {
                self.prTimeline = applied
                PRTimelineCache.shared.set(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, items: applied)
            }
        }
    }

    // MARK: - Inline diff comments & context

    /// Posts a single-line review comment from the Files tab and shows it as a new thread right away.
    public func postInlineReviewComment(path: String, line: Int, side: String, body: String) async throws {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let pr = selectedPR, let ctx = prRepoContext() else { return }
        guard let sha = pr.headSha else {
            showToast("The PR's head commit isn't known yet — try again in a moment", type: .info)
            return
        }
        try await runPRAction("inline-\(path)-\(side)-\(line)") {
            let comment = try await self.gitHubService.createReviewComment(
                owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, commitId: sha,
                path: path, line: line, side: side, body: text, token: ctx.token
            )
            guard self.selectedPR?.number == pr.number else { return }
            let thread = PRReviewThread(id: comment.id, path: path, line: line, diffHunk: comment.diffHunk, comments: [comment])
            self.prTimeline.append(.reviewThread(thread))
            PRTimelineCache.shared.set(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, items: self.prTimeline)
            self.showToast("Comment posted", type: .success)
            // Picks up the new thread's node id so it can be resolved.
            self.loadPRMeta(for: pr)
        }
    }

    /// Full text of a file at a commit: from the local clone when it has the commit, otherwise the API.
    public func prFileContent(path: String, ref: String) async throws -> String {
        let key = "\(ref):\(path)"
        if let cached = prFileContentCache[key] { return cached }
        var text: String?
        if let repoPath = currentRepo?.path,
           let result = try? await GitService.shared.execute(arguments: ["show", "\(ref):\(path)"], in: repoPath),
           result.isSuccess {
            text = result.stdout
        }
        if text == nil, let ctx = prRepoContext() {
            text = try await gitHubService.fetchFileContent(owner: ctx.owner, repo: ctx.repo, path: path, ref: ref, token: ctx.token)
        }
        guard let text else { throw NSError(domain: "GitXX", code: 404, userInfo: [NSLocalizedDescriptionKey: "File content unavailable"]) }
        if prFileContentCache.count > 200 { prFileContentCache.removeAll() }
        prFileContentCache[key] = text
        return text
    }

    // MARK: - Inline CI job logs

    public func loadJobLog(jobId: String, force: Bool = false) {
        if !force, let existing = prJobLogs[jobId], existing.isLoadedOrLoading { return }
        guard let ctx = prRepoContext() else { return }
        prJobLogs[jobId] = .loading
        Task {
            do {
                let raw = try await gitHubService.fetchJobLog(owner: ctx.owner, repo: ctx.repo, jobId: jobId, token: ctx.token)
                let parsed = await Task.detached(priority: .userInitiated) { (CILogExcerpt.parse(raw), raw) }.value
                prJobLogs[jobId] = .loaded(raw: parsed.1, excerpt: parsed.0)
            } catch {
                prJobLogs[jobId] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Cancellable detail loads

    /// Runs a PR detail load, cancelling the previous load of the same kind (and its network request).
    func runPRDetailTask(_ kind: String, _ work: @escaping @MainActor () async -> Void) {
        prDetailTasks[kind]?.cancel()
        prDetailTasks[kind] = Task { @MainActor in await work() }
    }

    func cancelPRDetailTasks() {
        for task in prDetailTasks.values { task.cancel() }
        prDetailTasks.removeAll()
    }

    // MARK: - Live polling

    func startPRPolling(for pr: PullRequest) {
        prPollTask?.cancel()
        guard pr.state.isActive else { return }
        let number = pr.number
        prPollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                let hasPending = self?.prChecks.contains(where: \.isPending) ?? false
                try? await Task.sleep(nanoseconds: UInt64(hasPending ? 20 : 60) * 1_000_000_000)
                guard !Task.isCancelled, let self,
                      let current = self.selectedPR, current.number == number, current.state.isActive else { return }
                guard self.activeTab == .pullRequests, NSApp.isActive else { continue }
                tick += 1
                self.loadPRChecks(for: current)
                self.loadPRMergeability(for: current)
                if tick % 2 == 0 {
                    self.loadPRTimeline(for: current)
                    self.loadPRMeta(for: current)
                }
            }
        }
    }

    func stopPRPolling() {
        prPollTask?.cancel()
        prPollTask = nil
    }

    public func refreshSelectedPR() {
        guard let pr = selectedPR else { return }
        loadPRDetails(for: pr)
    }

    /// Something outside the app's own actions (the assistant, `gh`, a git command) may have changed the
    /// repository or the open PR: re-read both so the page shows the new state.
    public func refreshAfterExternalChange() {
        refreshRepoSilently()
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }
        Task {
            await GitHubHTTPCache.shared.remove(for: "https://api.github.com/repos/\(ctx.owner)/\(ctx.repo)/pulls/\(pr.number)")
            guard self.selectedPR?.number == pr.number, let current = self.selectedPR else { return }
            self.loadPRDetails(for: current)
        }
    }

    // MARK: - Comments & review threads

    public func postPRComment(_ body: String) async throws {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let pr = selectedPR, let ctx = prRepoContext() else { return }
        try await runPRAction("comment") {
            let comment = try await self.gitHubService.postIssueComment(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, body: text, token: ctx.token)
            guard self.selectedPR?.number == pr.number else { return }
            self.prTimeline.append(.issueComment(comment))
            PRTimelineCache.shared.set(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, items: self.prTimeline)
            self.showToast("Comment posted", type: .success)
        }
    }

    public func replyToReviewThread(rootCommentId: String, body: String) async throws {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let pr = selectedPR, let ctx = prRepoContext() else { return }
        try await runPRAction("reply-\(rootCommentId)") {
            let reply = try await self.gitHubService.replyToReviewComment(
                owner: ctx.owner, repo: ctx.repo, prNumber: pr.number,
                commentId: rootCommentId, body: text, token: ctx.token
            )
            guard self.selectedPR?.number == pr.number else { return }
            self.prTimeline = self.prTimeline.map { item in
                guard case .reviewThread(var thread) = item, thread.comments.first?.id == rootCommentId else { return item }
                thread.comments.append(reply)
                return .reviewThread(thread)
            }
            PRTimelineCache.shared.set(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, items: self.prTimeline)
            self.showToast("Reply posted", type: .success)
        }
    }

    public func setReviewThreadResolved(nodeId: String, resolved: Bool) async throws {
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }
        try await runPRAction("resolve-\(nodeId)") {
            try await self.gitHubService.setReviewThreadResolved(threadNodeId: nodeId, resolved: resolved, token: ctx.token)
            guard self.selectedPR?.number == pr.number else { return }
            let viewer = self.prMeta?.viewerLogin
            self.prTimeline = self.prTimeline.map { item in
                guard case .reviewThread(var thread) = item, thread.nodeId == nodeId else { return item }
                thread.isResolved = resolved
                thread.resolvedByName = resolved ? viewer : nil
                return .reviewThread(thread)
            }
            if var meta = self.prMeta {
                meta.threads = meta.threads.map {
                    guard $0.nodeId == nodeId else { return $0 }
                    return PRThreadMeta(nodeId: $0.nodeId, isResolved: resolved, isOutdated: $0.isOutdated,
                                        resolvedBy: resolved ? viewer : nil, firstCommentDatabaseId: $0.firstCommentDatabaseId)
                }
                self.prMeta = meta
                PRTimelineCache.shared.setMeta(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, meta: meta)
            }
            PRTimelineCache.shared.set(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, items: self.prTimeline)
            self.showToast(resolved ? "Conversation resolved" : "Conversation unresolved", type: .success)
            self.loadPRMergeability(for: pr)
        }
    }

    // MARK: - Labels

    public func loadRepoLabels() {
        guard let ctx = prRepoContext() else { return }
        if repoLabels.isEmpty, let cached = PRTimelineCache.shared.getRepoLabels(owner: ctx.owner, repo: ctx.repo) {
            repoLabels = cached
        }
        Task {
            guard let labels = try? await gitHubService.fetchRepoLabels(owner: ctx.owner, repo: ctx.repo, token: ctx.token),
                  !labels.isEmpty else { return }
            PRTimelineCache.shared.setRepoLabels(owner: ctx.owner, repo: ctx.repo, labels: labels)
            if self.repoLabels != labels {
                self.repoLabels = labels
            }
        }
    }

    public func updatePRLabels(_ names: [String]) async throws {
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }
        let previous = prMeta
        if var meta = prMeta {
            meta.labels = names.map { name in
                repoLabels.first(where: { $0.name == name }) ?? meta.labels.first(where: { $0.name == name }) ?? PRLabel(name: name, color: "8b949e")
            }
            prMeta = meta
        }
        do {
            try await runPRAction("labels") {
                let applied = try await self.gitHubService.setPRLabels(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, labels: names, token: ctx.token)
                guard self.selectedPR?.number == pr.number, var meta = self.prMeta else { return }
                meta.labels = applied
                self.prMeta = meta
                PRTimelineCache.shared.setMeta(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, meta: meta)
                self.showToast("Labels updated", type: .success)
            }
        } catch {
            if self.selectedPR?.number == pr.number { self.prMeta = previous }
            throw error
        }
    }

    // MARK: - CI re-runs

    public func rerunFailedChecks() async throws {
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }
        let runIds = Array(Set(prChecks.filter { $0.isFailure || ($0.conclusion?.lowercased() == "cancelled") }.compactMap(\.actionsRunId)))
        guard !runIds.isEmpty else {
            showToast("No failed GitHub Actions runs to re-run", type: .info)
            return
        }
        try await runPRAction("rerun") {
            for runId in runIds {
                try await self.gitHubService.rerunFailedJobs(owner: ctx.owner, repo: ctx.repo, runId: runId, token: ctx.token)
            }
            self.showToast("Re-running failed jobs in \(runIds.count) workflow run\(runIds.count == 1 ? "" : "s")", type: .success)
            await self.reloadChecksAfterRerun(pr: pr, ctx: ctx)
        }
    }

    public func rerunCheck(jobId: String) async throws {
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }
        try await runPRAction("rerun-\(jobId)") {
            try await self.gitHubService.rerunJob(owner: ctx.owner, repo: ctx.repo, jobId: jobId, token: ctx.token)
            self.showToast("Job re-run requested", type: .success)
            await self.reloadChecksAfterRerun(pr: pr, ctx: ctx)
        }
    }

    private func reloadChecksAfterRerun(pr: PullRequest, ctx: PRRepoContext) async {
        if let sha = pr.headSha {
            await gitHubService.invalidateChecksCache(owner: ctx.owner, repo: ctx.repo, headSha: sha)
        }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let current = selectedPR, current.number == pr.number else { return }
        loadPRChecks(for: current)
        startPRPolling(for: current)
    }

    // MARK: - Draft state

    /// Creates a revert PR for the selected merged PR and opens it.
    public func revertSelectedPR(draft: Bool) async throws {
        guard let pr = selectedPR, pr.state == .merged, let ctx = prRepoContext() else { return }
        guard let nodeId = prMeta?.nodeId, prMeta?.prNumber == pr.number else {
            showToast("PR details are still loading — try again in a moment", type: .info)
            return
        }
        try await runPRAction("revert") {
            let created = try await self.gitHubService.revertPullRequest(
                prNodeId: nodeId,
                title: "Revert \"\(pr.title)\"",
                body: "Reverts #\(pr.number)",
                draft: draft,
                token: ctx.token
            )
            self.showToast("Opened revert pull request #\(created.number)", type: .success)
            self.loadPRs()
            await self.openPullRequest(number: created.number)
        }
    }

    public func setSelectedPRDraft(_ draft: Bool) async throws {
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }
        guard let nodeId = prMeta?.nodeId, prMeta?.prNumber == pr.number else {
            showToast("PR details are still loading — try again in a moment", type: .info)
            return
        }
        try await runPRAction("draft") {
            try await self.gitHubService.setPRDraft(prNodeId: nodeId, draft: draft, token: ctx.token)
            if var current = self.selectedPR, current.number == pr.number {
                current.isDraft = draft
                current.state = draft ? .draft : .open
                self.selectedPR = current
            }
            if let idx = self.pullRequests.firstIndex(where: { $0.number == pr.number }) {
                self.pullRequests[idx].isDraft = draft
                self.pullRequests[idx].state = draft ? .draft : .open
            }
            if !draft {
                self.prTimeline.append(.readyForReview(authorName: self.prMeta?.viewerLogin ?? "you", at: Date()))
            }
            await GitHubHTTPCache.shared.remove(for: "https://api.github.com/repos/\(ctx.owner)/\(ctx.repo)/pulls/\(pr.number)")
            self.showToast(draft ? "Converted to draft" : "Marked ready for review", type: .success)
            self.loadPRMergeability(for: pr)
            self.loadPRs()
        }
    }

    // MARK: - Viewed files

    public func isPRFileViewed(_ file: PRFileChange) -> Bool {
        prViewedFiles.contains(PRViewedFilesStore.key(for: file))
    }

    public func togglePRFileViewed(_ file: PRFileChange) {
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }
        let key = PRViewedFilesStore.key(for: file)
        if prViewedFiles.contains(key) {
            prViewedFiles.remove(key)
        } else {
            prViewedFiles.insert(key)
        }
        PRViewedFilesStore.save(prViewedFiles, owner: ctx.owner, repo: ctx.repo, prNumber: pr.number)
    }

    public func openPRFile(path: String) {
        selectedPRTab = .filesChanged
        if let match = prFiles.first(where: { $0.filename == path }) {
            selectedPRFile = match
        }
    }

    // MARK: - Web view bridge

    /// Handles an action from the conversation web view. Returns `true` on success.
    public func handlePRWebAction(_ action: PRWebAction) async -> Bool {
        do {
            switch action {
            case .toggleChecklist(let index):
                try await togglePRChecklistItem(at: index)
            case .merge(let method, let title, let message, let deleteBranch):
                try await mergeSelectedPR(method: method, commitTitle: title, commitMessage: message, deleteBranch: deleteBranch)
            case .close:
                try await closeSelectedPR()
            case .reopen:
                try await reopenSelectedPR()
            case .updateBranch:
                try await updateSelectedPRBranch()
            case .postComment(let body):
                try await postPRComment(body)
            case .replyToThread(let commentId, let body):
                try await replyToReviewThread(rootCommentId: commentId, body: body)
            case .resolveThread(let nodeId, let resolve):
                try await setReviewThreadResolved(nodeId: nodeId, resolved: resolve)
            case .rerunFailedChecks:
                try await rerunFailedChecks()
            case .rerunCheck(let jobId):
                try await rerunCheck(jobId: jobId)
            case .setDraft(let draft):
                try await setSelectedPRDraft(draft)
            case .openFile(let path):
                openPRFile(path: path)
            case .openReviewModal:
                showReviewModal = true
            case .refresh:
                refreshSelectedPR()
            case .switchTab(let tab):
                selectedPRTab = tab
            case .updateDescription(let body):
                do {
                    try await updateSelectedPRDescription(newBody: body)
                } catch {
                    showToast("Couldn't update the description: \(error.localizedDescription)", type: .error)
                    throw error
                }
            case .aiEditDescription(let instruction):
                try await rewriteSelectedPRDescriptionWithAI(instruction: instruction)
            case .openDescriptionInChat(let instruction):
                openPRDescriptionInChat(instruction: instruction)
            case .openCheckRun(let runId, let jobId):
                openActionsRun(runId: runId, jobId: jobId)
            case .showPRActions:
                showActions(branch: selectedPR?.headBranch)
                recordNavigationStep()
            case .explainCheck(let name):
                explainFailedCheck(name)
            case .resolveConflictsLocally:
                try await updateSelectedPRBranchLocally()
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - AI description edits

    /// Rewrites the PR body with a single model call and saves it.
    func rewriteSelectedPRDescriptionWithAI(instruction: String) async throws {
        guard let pr = selectedPR else { return }
        let ask = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty else { return }
        let system = """
        You edit GitHub pull request descriptions. Apply the user's instruction to the current description and \
        return ONLY the complete new description in GitHub-flavored Markdown: no preamble, no explanation, no code fence \
        around the whole answer. Keep the existing template structure (headings, checklists, links) unless the \
        instruction says otherwise. Never invent facts that the commits or files don't support.
        """
        var context = """
        PR #\(pr.number): \(pr.title)
        Base: \(pr.baseBranch) ← Head: \(pr.headBranch)
        """
        let commits = prCommits.prefix(40).map { "- \($0.message.split(separator: "\n").first.map(String.init) ?? "")" }
        if !commits.isEmpty { context += "\n\nCommits:\n" + commits.joined(separator: "\n") }
        let files = prFiles.prefix(80).map { "- \($0.filename) (+\($0.additions) -\($0.deletions))" }
        if !files.isEmpty { context += "\n\nChanged files:\n" + files.joined(separator: "\n") }
        let user = """
        \(context)

        Current description:
        <<<
        \(pr.body)
        >>>

        Instruction: \(ask)
        """
        let reply: AIChatReply
        do {
            reply = try await AIChatService.complete(provider: aiProvider, model: copilotModel.rawValue, githubToken: effectiveGitHubToken,
                                                     messages: [.system(system), .user(user)], tools: [])
        } catch {
            showToast("AI edit failed: \(error.localizedDescription)", type: .error)
            throw error
        }
        let body = Self.stripOuterFence(reply.content ?? "")
        guard !body.isEmpty else {
            showToast("The AI returned an empty description; nothing was changed.", type: .info)
            throw NSError(domain: "GitXX", code: 422)
        }
        do {
            try await updateSelectedPRDescription(newBody: body)
        } catch {
            showToast("Couldn't update the description: \(error.localizedDescription)", type: .error)
            throw error
        }
    }

    /// Whether the selected PR's head branch is checked out here, so its base can be merged in locally.
    public var selectedPRIsCheckedOut: Bool {
        guard let pr = selectedPR, currentRepo != nil else { return false }
        return pr.headBranch == currentBranch
    }

    /// Merges the PR's base into its checked-out head branch. A clean merge is pushed right away;
    /// conflicts open the resolver, which pushes once the merge is concluded.
    func updateSelectedPRBranchLocally() async throws {
        guard let pr = selectedPR, let repo = currentRepo, let ctx = prRepoContext() else { return }
        struct Failure: Error {}
        guard selectedPRIsCheckedOut else {
            showToast("Check out \(pr.headBranch) first to resolve its conflicts locally", type: .info)
            throw Failure()
        }
        guard gitOperationInFlight == nil else {
            showToast("Another git operation is still running", type: .info)
            throw Failure()
        }
        let path = repo.path
        let status = try await gitService.execute(arguments: ["status", "--porcelain=v1", "-uno"], in: path)
        guard status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("Commit or stash your local changes before updating \(pr.headBranch)", type: .error)
            throw Failure()
        }

        gitOperationInFlight = "merge"
        defer { gitOperationInFlight = nil }
        let remote = await baseRemote(in: path, owner: ctx.owner, repo: ctx.repo)
        let fetch = try await gitService.execute(arguments: ["fetch", remote, pr.baseBranch], in: path)
        guard fetch.isSuccess else {
            showToast("Couldn't fetch \(remote)/\(pr.baseBranch): \(Self.firstLine(fetch.stderr))", type: .error)
            throw Failure()
        }
        let merge = try await gitService.execute(
            arguments: ["merge", "--no-edit", "-m", "Merge \(remote)/\(pr.baseBranch) into \(pr.headBranch)", "FETCH_HEAD"],
            in: path)
        await refreshRepoAsync(silent: false)
        if merge.isSuccess {
            if merge.stdout.contains("Already up to date") {
                showToast("\(pr.headBranch) already contains \(pr.baseBranch). Push it if GitHub still shows conflicts.", type: .info)
            } else {
                showToast("Merged \(pr.baseBranch) cleanly. Pushing to update #\(pr.number)…", type: .success)
                pushOrigin()
            }
            return
        }
        guard !conflictedPaths.isEmpty else {
            showToast("Merge failed: \(Self.firstLine(merge.stderr.isEmpty ? merge.stdout : merge.stderr))", type: .error)
            throw Failure()
        }
        pendingPRMergePush = "#\(pr.number)"
        openConflictResolver()
    }

    /// The remote pointing at the PR's GitHub repository, falling back to `origin`.
    private func baseRemote(in path: String, owner: String, repo: String) async -> String {
        let remotes = (try? await gitService.execute(arguments: ["remote", "-v"], in: path))?.stdout ?? ""
        for line in remotes.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let parsed = gitHubService.parseRepoOwnerAndName(from: String(parts[1])),
                  parsed.owner.lowercased() == owner.lowercased(), parsed.name.lowercased() == repo.lowercased() else { continue }
            return String(parts[0])
        }
        return "origin"
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "unknown error"
    }

    /// Hands a failing check to the assistant, which reads its logs with the CI tools.
    func explainFailedCheck(_ name: String) {
        guard let pr = selectedPR else { return }
        let chat = AIChatStore.shared
        if !chat.isRunning { chat.newChat() }
        if !chat.isOpen { chat.toggle() }
        let prompt = "Why did the check “\(name)” fail on PR #\(pr.number)? Read its logs, then give the root cause and the fix."
        if chat.isRunning { chat.input = prompt } else { chat.send(prompt, state: self) }
    }

    func openPRDescriptionInChat(instruction: String) {
        guard let pr = selectedPR else { return }
        let chat = AIChatStore.shared
        let ask = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chat.isRunning { chat.newChat() }
        if !chat.isOpen { chat.toggle() }
        let prompt = "Update the description of PR #\(pr.number) (\(pr.title))"
        if ask.isEmpty || chat.isRunning {
            chat.input = prompt + (ask.isEmpty ? ": " : ": \(ask)")
        } else {
            chat.send(prompt + ": \(ask)", state: self)
        }
    }

    private static func stripOuterFence(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```"), t.hasSuffix("```"), t.count > 6 else { return t }
        if let firstNewline = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: firstNewline)...].dropLast(3))
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Viewed Files Persistence

enum PRViewedFilesStore {
    /// Keyed by filename plus a stable hash of the patch so a file re-appears as unviewed when it changes.
    static func key(for file: PRFileChange) -> String {
        var hash: UInt64 = 5381
        for byte in (file.patch ?? "\(file.additions)-\(file.deletions)").utf8 {
            hash = (hash &<< 5) &+ hash &+ UInt64(byte)
        }
        return "\(file.filename)@\(String(hash, radix: 36))"
    }

    private static func defaultsKey(owner: String, repo: String, prNumber: Int) -> String {
        "gitxx_viewed_files_\(owner)_\(repo)_\(prNumber)"
    }

    static func load(owner: String, repo: String, prNumber: Int) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey(owner: owner, repo: repo, prNumber: prNumber)) ?? [])
    }

    static func save(_ keys: Set<String>, owner: String, repo: String, prNumber: Int) {
        let k = defaultsKey(owner: owner, repo: repo, prNumber: prNumber)
        if keys.isEmpty {
            UserDefaults.standard.removeObject(forKey: k)
        } else {
            UserDefaults.standard.set(Array(keys), forKey: k)
        }
    }
}

extension AppState {
    // MARK: - Commits tab

    public func loadPRCommits(for pr: PullRequest) {
        guard let ctx = prRepoContext() else { return }
        if prCommits.isEmpty { isLoadingPRCommits = true }
        runPRDetailTask("commits") { [self] in
            do {
                let commits = try await gitHubService.fetchPRCommits(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, token: ctx.token)
                prCommitsCache[pr.number] = commits
                guard selectedPR?.number == pr.number else { return }
                isLoadingPRCommits = false
                if prCommits != commits { prCommits = commits }
            } catch {
                if !GitHubHTTP.isCancellation(error), selectedPR?.number == pr.number { isLoadingPRCommits = false }
            }
        }
    }

    /// Files of one commit, from the local repo when the commit exists there (instant), otherwise the API.
    public func loadCommitFiles(sha: String) async {
        guard prCommitFiles[sha] == nil, let ctx = prRepoContext() else { return }
        if let repo = currentRepo,
           let res = try? await gitService.execute(arguments: ["show", "--format=", "--no-color", "-U3", "--diff-merges=first-parent", sha], in: repo.path),
           res.isSuccess {
            let files = PRFileChange.fromUnifiedDiff(res.stdout)
            if !files.isEmpty || res.stdout.isEmpty {
                prCommitFiles[sha] = files
                return
            }
        }
        do {
            prCommitFiles[sha] = try await gitHubService.fetchCommitFiles(owner: ctx.owner, repo: ctx.repo, sha: sha, token: ctx.token)
        } catch {
            if !GitHubHTTP.isCancellation(error) { showToast("Couldn't load commit \(sha.prefix(7)): \(error.localizedDescription)", type: .error) }
        }
    }
}
