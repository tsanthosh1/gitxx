import Foundation
import SwiftUI
import AppKit

/// A downloaded job log, split and parsed per step off the main thread. Compared by identity so views
/// don't compare multi-megabyte strings on every update.
public final class ActionsJobLog: Equatable, @unchecked Sendable {
    public let raw: String
    public let steps: [Int: String]
    public let excerpts: [Int: CILogExcerpt]
    public let lowercasedSteps: [Int: String]

    init(raw: String, steps: [ActionsStep]) {
        self.raw = raw
        let split = ActionsStepLog.split(raw: raw, steps: steps)
        self.steps = split
        excerpts = split.mapValues { CILogExcerpt.parse($0, full: true) }
        lowercasedSteps = split.mapValues { $0.lowercased() }
    }

    public static func == (a: ActionsJobLog, b: ActionsJobLog) -> Bool { a === b }
}

public enum ActionsJobLogState: Equatable, Sendable {
    case loading
    case loaded(ActionsJobLog)
    case failed(String)
}

/// Finished job logs never change, so they are kept on disk and reopen instantly.
enum ActionsLogCache {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("GitXX/actions-logs", isDirectory: true)
    }()
    private static let maxBytes = 300 * 1024 * 1024

    private static func url(_ repo: String, _ jobId: Int) -> URL {
        directory.appendingPathComponent("\(repo.replacingOccurrences(of: "/", with: "_"))-\(jobId).log")
    }

    static func read(repo: String, jobId: Int) -> String? {
        let file = url(repo, jobId)
        guard let data = try? Data(contentsOf: file) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ raw: String, repo: String, jobId: Int) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(raw.utf8).write(to: url(repo, jobId), options: .atomic)
        prune()
    }

    /// Drops the least recently opened logs once the cache passes its size limit.
    private static func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let entries = files.compactMap { file -> (URL, Date, Int)? in
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { return nil }
            return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard total > maxBytes else { return }
        for entry in entries.sorted(by: { $0.1 < $1.1 }) where total > maxBytes {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.2
        }
    }
}

/// State for the Actions tab: workflow runs with server-side filters, the selected run's jobs, logs and artifacts.
@MainActor
public final class ActionsStore: ObservableObject {
    weak var state: AppState?

    @Published public private(set) var workflows: [ActionsWorkflow] = []
    @Published public private(set) var runs: [ActionsRun] = []
    @Published public private(set) var totalCount = 0
    @Published public private(set) var isLoadingRuns = false
    @Published public private(set) var isLoadingMore = false
    @Published public private(set) var loadError: String?
    /// Changing the filter shows the run list again.
    @Published public var filter = ActionsRunFilter() {
        didSet {
            guard filter != oldValue else { return }
            if selectedRunId != nil { clearSelection() }
            reloadRuns()
        }
    }
    /// Newest known run per workflow, remembered across filters for the workflow sidebar.
    @Published public private(set) var latestByWorkflow: [Int: ActionsRun] = [:]
    @Published public var searchText = ""

    @Published public private(set) var selectedRunId: Int?
    @Published public private(set) var selectedRun: ActionsRun?
    /// nil shows the run summary (annotations, artifacts, job overview).
    @Published public var selectedJobId: Int?
    @Published public var selectedAttempt: Int?
    @Published public private(set) var jobs: [ActionsJob] = []
    @Published public private(set) var isLoadingJobs = false
    @Published public private(set) var artifacts: [ActionsArtifact] = []
    @Published public private(set) var annotations: [ActionsAnnotation] = []
    @Published public private(set) var jobLogs: [Int: ActionsJobLogState] = [:]
    @Published public private(set) var busy: Set<String> = []
    @Published public var dispatchWorkflow: ActionsWorkflow?
    @Published public var showDispatchPicker = false
    /// Job log shown over the whole window (below the title bar).
    @Published public var fullScreenLog: ActionsFullScreenLog?

    private var repoKey: String?
    private var page = 1
    private var runsGeneration = 0
    private var detailGeneration = 0
    private var pollTask: Task<Void, Never>?
    private var pendingJobSelection: Int?

    init() {}

    // MARK: Context

    private struct Context { let owner: String; let repo: String; let token: String? }

    private var context: Context? {
        guard let state, let ctx = state.prRepoContext(), state.hasConfiguredGitHubToken,
              state.gitHubService.parseRepoOwnerAndName(from: state.currentRepo?.remoteUrl) != nil else { return nil }
        return Context(owner: ctx.owner, repo: ctx.repo, token: ctx.token)
    }

    public var isAvailable: Bool { context != nil }
    public var repoSlug: String? { context.map { "\($0.owner)/\($0.repo)" } }
    public var currentBranch: String? { state.flatMap { $0.currentBranch.isEmpty ? $0.currentRepo?.currentBranch : $0.currentBranch } }
    public var viewerLogin: String? { state?.authenticatedUsername ?? state?.prMeta?.viewerLogin }

    public var selectedWorkflow: ActionsWorkflow? { workflows.first { $0.id == filter.workflowId } }
    public var selectedJob: ActionsJob? { jobs.first { $0.id == selectedJobId } }
    public var hasMore: Bool { runs.count < totalCount }
    public func isBusy(_ key: String) -> Bool { busy.contains(key) }

    public var isCurrentBranchFilter: Bool {
        guard let branch = filter.branch else { return false }
        return branch == currentBranch
    }

    /// Runs after the client-side search (title, branch, sha, actor, workflow, #number).
    public var visibleRuns: [ActionsRun] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return runs }
        let number = q.hasPrefix("#") ? Int(q.dropFirst()) : Int(q)
        return runs.filter { run in
            if let number, run.runNumber == number || run.pullRequestNumbers.contains(number) { return true }
            return [run.displayTitle, run.headBranch, run.workflowName, run.actorLogin, run.event]
                .contains { $0.lowercased().contains(q) } || run.headSha.hasPrefix(q)
        }
    }

    // MARK: Lifecycle

    /// Called when the tab appears or the repository changes; resets when the repo is different.
    public func activate() {
        let key = repoSlug
        if key != repoKey {
            repoKey = key
            reset()
            guard key != nil else { return }
            loadWorkflows()
            reloadRuns()
        } else if runs.isEmpty && !isLoadingRuns {
            reloadRuns()
        }
        startPolling()
    }

    public func deactivate() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func reset() {
        runsGeneration += 1
        detailGeneration += 1
        workflows = []
        latestByWorkflow = [:]
        runs = []
        totalCount = 0
        loadError = nil
        page = 1
        if !filter.isEmpty { filter = ActionsRunFilter() }
        searchText = ""
        clearSelection()
    }

    public func clearSelection() {
        detailGeneration += 1
        selectedRunId = nil
        selectedRun = nil
        selectedJobId = nil
        selectedAttempt = nil
        jobs = []
        artifacts = []
        annotations = []
        jobLogs = [:]
    }

    // MARK: Filters

    public func toggleCurrentBranch() {
        filter.branch = isCurrentBranchFilter ? nil : currentBranch
    }

    public func toggleMine() {
        guard let login = viewerLogin else {
            state?.showToast("Sign in to GitHub to filter by your runs", type: .info)
            return
        }
        filter.actor = filter.actor == login ? nil : login
    }

    public func toggleStatus(_ status: String) {
        filter.status = filter.status == status ? nil : status
    }

    public func show(branch: String?, workflowId: Int? = nil) {
        var f = ActionsRunFilter()
        f.branch = branch
        f.workflowId = workflowId
        filter = f
    }

    // MARK: Loading

    public func loadWorkflows() {
        guard let ctx = context else { return }
        let key = repoKey
        Task {
            guard let list = try? await state?.gitHubService.fetchWorkflows(owner: ctx.owner, repo: ctx.repo, token: ctx.token),
                  key == repoKey else { return }
            workflows = list
        }
    }

    public func reloadRuns() {
        guard let ctx = context else { return }
        runsGeneration += 1
        let generation = runsGeneration
        page = 1
        isLoadingRuns = true
        loadError = nil
        let filter = self.filter
        Task {
            defer { if generation == runsGeneration { isLoadingRuns = false } }
            do {
                guard let service = state?.gitHubService else { return }
                let result = try await service.fetchWorkflowRuns(owner: ctx.owner, repo: ctx.repo, filter: filter, page: 1, token: ctx.token)
                guard generation == runsGeneration else { return }
                runs = result.runs
                totalCount = result.totalCount
                remember(result.runs)
            } catch {
                guard generation == runsGeneration else { return }
                loadError = error.localizedDescription
            }
        }
    }

    public func loadMore() {
        guard let ctx = context, hasMore, !isLoadingMore, !isLoadingRuns else { return }
        let generation = runsGeneration
        let next = page + 1
        isLoadingMore = true
        let filter = self.filter
        Task {
            defer { isLoadingMore = false }
            guard let service = state?.gitHubService,
                  let result = try? await service.fetchWorkflowRuns(owner: ctx.owner, repo: ctx.repo, filter: filter, page: next, token: ctx.token),
                  generation == runsGeneration else { return }
            page = next
            let known = Set(runs.map(\.id))
            runs += result.runs.filter { !known.contains($0.id) }
            totalCount = result.totalCount
            remember(result.runs)
        }
    }

    /// Refreshes page 1 in place, keeping older pages that were already loaded.
    private func refreshFirstPage() async {
        guard let ctx = context, let service = state?.gitHubService, !isLoadingRuns else { return }
        let generation = runsGeneration
        guard let result = try? await service.fetchWorkflowRuns(owner: ctx.owner, repo: ctx.repo, filter: filter, page: 1, token: ctx.token),
              generation == runsGeneration else { return }
        let fresh = Set(result.runs.map(\.id))
        let oldest = result.runs.last?.createdAt ?? .distantPast
        runs = result.runs + runs.filter { !fresh.contains($0.id) && $0.createdAt < oldest }
        totalCount = result.totalCount
        remember(result.runs)
        if let id = selectedRunId, let updated = result.runs.first(where: { $0.id == id }) {
            selectedRun = updated
        }
    }

    private func remember(_ fetched: [ActionsRun]) {
        for run in fetched {
            if let known = latestByWorkflow[run.workflowId], known.id != run.id, known.createdAt >= run.createdAt { continue }
            latestByWorkflow[run.workflowId] = run
        }
    }

    // MARK: Selection

    /// Back from a run's details to the run list.
    public func closeRun() {
        fullScreenLog = nil
        clearSelection()
        state?.recordNavigationStep()
    }

    public func selectRun(_ run: ActionsRun) {
        guard run.id != selectedRunId else { return }
        clearSelection()
        selectedRunId = run.id
        selectedRun = run
        loadRunDetail()
    }

    /// Opens a run by id (from a PR check or a pasted URL), optionally focusing one job.
    public func openRun(id: Int, jobId: Int? = nil) {
        if let run = runs.first(where: { $0.id == id }) {
            if run.id == selectedRunId {
                if let jobId { selectJob(jobId) }
                return
            }
            pendingJobSelection = jobId
            selectRun(run)
            return
        }
        guard let ctx = context else { return }
        clearSelection()
        selectedRunId = id
        pendingJobSelection = jobId
        Task {
            guard let run = try? await state?.gitHubService.fetchWorkflowRun(owner: ctx.owner, repo: ctx.repo, runId: id, token: ctx.token),
                  selectedRunId == id else {
                if selectedRunId == id {
                    selectedRunId = nil
                    state?.showToast("Workflow run \(id) not found", type: .error)
                }
                return
            }
            selectedRun = run
            loadRunDetail()
        }
    }

    public func selectJob(_ id: Int?) {
        selectedJobId = id
        if let id, let job = jobs.first(where: { $0.id == id }), !job.actionsStatus.isActive {
            loadJobLog(job)
        }
    }

    public func selectAttempt(_ attempt: Int) {
        guard let run = selectedRun else { return }
        selectedAttempt = attempt == run.runAttempt ? nil : attempt
        selectedJobId = nil
        jobLogs = [:]
        loadRunDetail()
    }

    public func loadRunDetail(silent: Bool = false) {
        guard let ctx = context, let runId = selectedRunId, let service = state?.gitHubService else { return }
        detailGeneration += 1
        let generation = detailGeneration
        let attempt = selectedAttempt
        if !silent { isLoadingJobs = true }
        Task {
            defer { if generation == detailGeneration { isLoadingJobs = false } }
            async let jobsResult = service.fetchRunJobs(owner: ctx.owner, repo: ctx.repo, runId: runId, attempt: attempt, token: ctx.token)
            async let artifactsResult = service.fetchRunArtifacts(owner: ctx.owner, repo: ctx.repo, runId: runId, token: ctx.token)
            let fetchedJobs = (try? await jobsResult) ?? jobs
            let fetchedArtifacts = (try? await artifactsResult) ?? artifacts
            guard generation == detailGeneration else { return }
            let previous = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            jobs = fetchedJobs
            artifacts = fetchedArtifacts

            if let wanted = pendingJobSelection, fetchedJobs.contains(where: { $0.id == wanted }) {
                pendingJobSelection = nil
                selectJob(wanted)
            } else if !silent, selectedJobId == nil,
                      let failed = fetchedJobs.first(where: { $0.actionsStatus == .failure }) {
                selectJob(failed.id)
            } else if let id = selectedJobId, let job = fetchedJobs.first(where: { $0.id == id }),
                      previous[id]?.actionsStatus.isActive == true, !job.actionsStatus.isActive {
                loadJobLog(job, force: true)
            }
            prefetchLogs(fetchedJobs)

            let finished = fetchedJobs.filter { !$0.actionsStatus.isActive && $0.actionsStatus != .skipped }
            var found: [ActionsAnnotation] = []
            await withTaskGroup(of: [ActionsAnnotation].self) { group in
                for job in finished.prefix(30) {
                    group.addTask { (try? await service.fetchJobAnnotations(owner: ctx.owner, repo: ctx.repo, job: job, token: ctx.token)) ?? [] }
                }
                for await batch in group { found += batch }
            }
            guard generation == detailGeneration else { return }
            let order = ["failure": 0, "warning": 1, "notice": 2]
            annotations = found.sorted { (order[$0.level] ?? 3, $0.jobName) < (order[$1.level] ?? 3, $1.jobName) }
        }
    }

    /// Full job logs only exist once a job has finished (GitHub streams live logs to the browser only).
    public func loadJobLog(_ job: ActionsJob, force: Bool = false) {
        guard let ctx = context, let service = state?.gitHubService, !job.actionsStatus.isActive else { return }
        if !force, let existing = jobLogs[job.id] {
            if case .failed = existing {} else { return }
        }
        jobLogs[job.id] = .loading
        let steps = job.steps, slug = "\(ctx.owner)/\(ctx.repo)", generation = detailGeneration
        Task {
            do {
                let cached = force ? nil : await Task.detached(priority: .userInitiated) { ActionsLogCache.read(repo: slug, jobId: job.id) }.value
                let raw: String
                if let cached {
                    raw = cached
                } else {
                    raw = try await service.fetchJobLog(owner: ctx.owner, repo: ctx.repo, jobId: String(job.id), token: ctx.token)
                    Task.detached(priority: .utility) { ActionsLogCache.write(raw, repo: slug, jobId: job.id) }
                }
                let log = await Task.detached(priority: .userInitiated) { ActionsJobLog(raw: raw, steps: steps) }.value
                guard generation == detailGeneration || jobLogs[job.id] == .loading else { return }
                jobLogs[job.id] = .loaded(log)
            } catch {
                jobLogs[job.id] = .failed(error.localizedDescription)
            }
        }
    }

    /// Starts downloading the logs people open first (failed jobs) as soon as the run's jobs are known.
    private func prefetchLogs(_ jobs: [ActionsJob]) {
        for job in jobs.filter({ $0.actionsStatus == .failure }).prefix(4) where jobLogs[job.id] == nil {
            loadJobLog(job)
        }
    }

    // MARK: Polling

    private var needsPolling: Bool {
        runs.prefix(40).contains { $0.actionsStatus.isActive } || selectedRun?.actionsStatus.isActive == true
            || jobs.contains { $0.actionsStatus.isActive }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var idleTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard NSApp.isActive, self.state?.activeTab == .actions else { continue }
                if self.needsPolling {
                    idleTicks = 0
                } else {
                    // Nothing running: still pick up newly started runs, just less often.
                    idleTicks += 1
                    if idleTicks < 4 { continue }
                    idleTicks = 0
                }
                await self.refreshFirstPage()
                if self.selectedRunId != nil, self.selectedRun?.actionsStatus.isActive == true || self.jobs.contains(where: { $0.actionsStatus.isActive }) {
                    self.loadRunDetail(silent: true)
                }
            }
        }
    }

    // MARK: Actions

    private func perform(_ key: String, success: String, _ work: @escaping (GitHubAPIService, Context) async throws -> Void) {
        guard let ctx = context, let service = state?.gitHubService, !busy.contains(key) else { return }
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            do {
                try await work(service, ctx)
                state?.showToast(success, type: .success)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await refreshFirstPage()
                if selectedRunId != nil { loadRunDetail(silent: true) }
            } catch {
                state?.showToast(error.localizedDescription, type: .error)
            }
        }
    }

    public func rerun(_ run: ActionsRun, failedOnly: Bool, debug: Bool = false) {
        perform("rerun-\(run.id)", success: failedOnly ? "Re-running failed jobs of #\(run.runNumber)" : "Re-running #\(run.runNumber)") { service, ctx in
            if failedOnly {
                try await service.rerunFailedJobs(owner: ctx.owner, repo: ctx.repo, runId: String(run.id), token: ctx.token)
            } else {
                try await service.rerunWorkflowRun(owner: ctx.owner, repo: ctx.repo, runId: run.id, debug: debug, token: ctx.token)
            }
        }
    }

    public func rerunJob(_ job: ActionsJob) {
        perform("rerun-job-\(job.id)", success: "Re-running \(job.name)") { service, ctx in
            try await service.rerunJob(owner: ctx.owner, repo: ctx.repo, jobId: String(job.id), token: ctx.token)
        }
    }

    public func cancel(_ run: ActionsRun, force: Bool = false) {
        perform("cancel-\(run.id)", success: "Cancelling #\(run.runNumber)") { service, ctx in
            try await service.cancelWorkflowRun(owner: ctx.owner, repo: ctx.repo, runId: run.id, force: force, token: ctx.token)
        }
    }

    public func setWorkflow(_ workflow: ActionsWorkflow, enabled: Bool) {
        perform("toggle-\(workflow.id)", success: "\(enabled ? "Enabled" : "Disabled") \(workflow.name)") { service, ctx in
            try await service.setWorkflowEnabled(owner: ctx.owner, repo: ctx.repo, workflowId: workflow.id, enabled: enabled, token: ctx.token)
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            loadWorkflows()
        }
    }

    public func downloadArtifact(_ artifact: ActionsArtifact) {
        guard let ctx = context, let service = state?.gitHubService else { return }
        let key = "artifact-\(artifact.id)"
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            do {
                let url = try await service.downloadArtifact(artifact, token: ctx.token)
                state?.showToast("Downloaded \(url.lastPathComponent)", type: .success)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                state?.showToast("Download failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    public func saveLog(_ job: ActionsJob) {
        guard case .loaded(let log) = jobLogs[job.id] else { return }
        let raw = log.raw
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let safe = job.name.replacingOccurrences(of: "/", with: "-")
        let url = downloads.appendingPathComponent("\(safe)-\(job.id).log")
        do {
            try raw.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            state?.showToast("Couldn't save log: \(error.localizedDescription)", type: .error)
        }
    }

    public func fetchDispatchInputs(_ workflow: ActionsWorkflow, ref: String) async -> Result<[ActionsDispatchInput]?, Error> {
        guard let ctx = context, let service = state?.gitHubService else { return .success(nil) }
        do {
            return .success(try await service.fetchDispatchInputs(owner: ctx.owner, repo: ctx.repo, workflow: workflow, ref: ref, token: ctx.token))
        } catch {
            return .failure(error)
        }
    }

    public func dispatch(_ workflow: ActionsWorkflow, ref: String, inputs: [String: String]) async -> Bool {
        guard let ctx = context, let service = state?.gitHubService else { return false }
        do {
            try await service.dispatchWorkflow(owner: ctx.owner, repo: ctx.repo, workflowId: workflow.id, ref: ref, inputs: inputs, token: ctx.token)
            state?.showToast("Started \(workflow.name) on \(ref)", type: .success)
            Task {
                // The new run shows up in the API a few seconds after dispatch.
                for _ in 0..<3 {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await refreshFirstPage()
                }
            }
            return true
        } catch {
            state?.showToast(error.localizedDescription, type: .error)
            return false
        }
    }

    public func beginDispatch(_ workflow: ActionsWorkflow? = nil) {
        if let workflow = workflow ?? selectedWorkflow {
            dispatchWorkflow = workflow
        } else {
            showDispatchPicker = true
        }
    }

    // MARK: PR links

    /// PRs a run belongs to: GitHub's association first, then open PRs whose head branch matches.
    public func pullRequestNumbers(for run: ActionsRun) -> [Int] {
        if !run.pullRequestNumbers.isEmpty { return run.pullRequestNumbers }
        guard let state, run.event.hasPrefix("pull_request") else { return [] }
        return state.searchablePullRequests
            .filter { $0.headBranch == run.headBranch && $0.state.isActive }
            .map(\.number)
    }

    public func pullRequestTitle(_ number: Int) -> String? {
        state?.searchablePullRequests.first { $0.number == number }?.title
    }
}
