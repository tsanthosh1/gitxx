import SwiftUI
import AppKit

struct ActionsRunDetailView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ActionsStore
    let run: ActionsRun

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { store.closeRun() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text(store.selectedWorkflow.map { "\($0.name) runs" } ?? "All runs").lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                .keyboardShortcut(store.fullScreenLog == nil ? .cancelAction : nil)
                .help("Back to the run list (Esc)")
                Text("/").foregroundStyle(.tertiary)
                Text("\(run.workflowName) #\(String(run.runNumber))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ActionsRunHeader(state: state, store: store, run: run)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            HSplitView {
                ActionsJobsColumn(store: store, run: run)
                    .frame(minWidth: 200, idealWidth: 300, maxWidth: 560)
                Group {
                    if let job = store.selectedJob {
                        ActionsJobView(state: state, store: store, job: job)
                            .id(job.id)
                    } else {
                        ActionsRunSummaryView(state: state, store: store, run: run)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Header

private struct ActionsRunHeader: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ActionsStore
    let run: ActionsRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ActionsStatusIcon(status: run.actionsStatus, size: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.displayTitle.isEmpty ? run.workflowName : run.displayTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text("\(run.workflowName) #\(String(run.runNumber))")
                            .fontWeight(.medium)
                        Text("·")
                        Text(run.eventLabel)
                        if !run.actorLogin.isEmpty {
                            Text("·")
                            PRAvatarView(authorName: run.actorLogin, avatarUrl: run.actorAvatarUrl, size: 14)
                            Button(run.actorLogin) { store.filter.actor = run.actorLogin }
                                .buttonStyle(.hoverPlain)
                                .help("Show runs by \(run.actorLogin)")
                        }
                        Text("·")
                        Text(ActionsFormat.relativeDate(run.createdAt))
                            .help(run.createdAt.formatted(date: .abbreviated, time: .standard))
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                actionButtons
            }
            HStack(spacing: 6) {
                ActionsBranchChip(branch: run.headBranch, isCurrent: run.headBranch == store.currentBranch) {
                    store.filter.branch = run.headBranch
                }
                Button {
                    if let commit = state.commits.first(where: { $0.sha == run.headSha }) {
                        state.activeTab = .history
                        state.selectCommit(commit)
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(run.headSha, forType: .string)
                        state.showToast("Copied \(run.shortSha)", type: .success)
                    }
                } label: {
                    Text(run.shortSha)
                        .font(.system(size: 10.5, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.hoverPlain)
                .pointerCursor()
                .help(state.commits.contains { $0.sha == run.headSha } ? "Show commit in History" : "Copy commit SHA")
                ForEach(store.pullRequestNumbers(for: run), id: \.self) { number in
                    ActionsPRChip(number: number, title: store.pullRequestTitle(number)) {
                        Task { await state.openPullRequest(number: number, tab: .checks) }
                    }
                }
                if run.runAttempt > 1 {
                    Menu {
                        ForEach((1...run.runAttempt).reversed(), id: \.self) { attempt in
                            Button {
                                store.selectAttempt(attempt)
                            } label: {
                                let current = (store.selectedAttempt ?? run.runAttempt) == attempt
                                if current { Label("Attempt \(attempt)", systemImage: "checkmark") } else { Text("Attempt \(attempt)") }
                            }
                        }
                    } label: {
                        Text("Attempt \(store.selectedAttempt ?? run.runAttempt) of \(run.runAttempt)")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Show jobs from an earlier attempt")
                }
                Spacer(minLength: 0)
                stat("Status", run.actionsStatus.label, color: run.actionsStatus.color)
                stat(run.actionsStatus.isActive ? "Running for" : "Duration", ActionsFormat.duration(run.duration))
                if !store.artifacts.isEmpty { stat("Artifacts", "\(store.artifacts.count)") }
            }
        }
    }

    private func stat(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(color)
        }
        .padding(.leading, 10)
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            if run.actionsStatus.isActive {
                Button {
                    store.cancel(run)
                } label: {
                    PRActionLabel("Cancel run", systemImage: "stop.circle", isRunning: store.isBusy("cancel-\(run.id)"))
                }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                .disabled(store.isBusy("cancel-\(run.id)"))
            } else {
                let failed = run.actionsStatus == .failure || run.actionsStatus == .cancelled
                Menu {
                    Button("Re-run all jobs") { store.rerun(run, failedOnly: false) }
                    if failed { Button("Re-run failed jobs") { store.rerun(run, failedOnly: true) } }
                    Divider()
                    Button("Re-run all jobs with debug logging") { store.rerun(run, failedOnly: false, debug: true) }
                } label: {
                    PRActionLabel(failed ? "Re-run failed" : "Re-run", systemImage: "arrow.counterclockwise", isRunning: store.isBusy("rerun-\(run.id)"))
                } primaryAction: {
                    store.rerun(run, failedOnly: failed)
                }
                .menuStyle(.button)
                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                .fixedSize()
                .disabled(store.isBusy("rerun-\(run.id)"))
            }
            Button {
                if let url = URL(string: run.htmlUrl) { LinkRouter.open(url) }
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
            .help("Open this run on GitHub")
            Menu {
                ActionsRunMenu(state: state, store: store, run: run)
                if !run.workflowPath.isEmpty, let slug = store.repoSlug {
                    Divider()
                    Button("View workflow file") {
                        if let url = URL(string: "https://github.com/\(slug)/blob/\(run.headSha)/\(run.workflowPath)") { LinkRouter.open(url) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .iconHover(size: 24)
        }
    }
}

// MARK: - Jobs column

private struct ActionsJobsColumn: View {
    @ObservedObject var store: ActionsStore
    let run: ActionsRun
    @State private var collapsed: Set<String> = []

    private struct Row: Identifiable {
        let node: ActionsJobNode
        let depth: Int
        var id: String { node.id }
    }

    var body: some View {
        let tree = ActionsJobNode.tree(store.jobs)
        let rows = flatten(tree, depth: 0)
        let groupIds = allGroupIds(tree)
        List(selection: Binding(get: { store.selectedJobId ?? -1 }, set: { id in if let id { store.selectJob(id == -1 ? nil : id) } })) {
            Label {
                Text("Summary").font(.system(size: 12.5, weight: .medium))
            } icon: {
                Image(systemName: "house")
            }
            .tag(-1)

            Section {
                if store.isLoadingJobs && store.jobs.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Loading jobs…").foregroundStyle(.secondary) }
                        .font(.system(size: 11.5))
                } else {
                    ForEach(rows) { row in
                        if let job = row.node.job {
                            rowContent(row)
                                .tag(job.id)
                                .help("\(job.name) · \(job.actionsStatus.label)")
                        } else {
                            rowContent(row)
                                .contentShape(Rectangle())
                                .onTapGesture { toggle(row.node.id) }
                                .help("\(row.node.title) · \(row.node.leaves.count) jobs · \(row.node.status.label)")
                        }
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Jobs")
                    Text(String(store.jobs.count)).foregroundStyle(.secondary)
                    Spacer()
                    let failed = store.jobs.filter { $0.actionsStatus == .failure }.count
                    if failed > 0 { Text("\(failed) failed").foregroundStyle(.red) }
                    if !groupIds.isEmpty {
                        Button {
                            collapsed = collapsed.isEmpty ? groupIds : []
                        } label: {
                            Image(systemName: collapsed.isEmpty ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        }
                        .buttonStyle(.hoverPlain)
                        .help(collapsed.isEmpty ? "Collapse all groups" : "Expand all groups")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.35))
    }

    private func rowContent(_ row: Row) -> some View {
        let node = row.node
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if node.isGroup {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(collapsed.contains(node.id) ? 0 : 90))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 10)
            ActionsStatusIcon(status: node.status, size: 12)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if node.id.contains("/matrix:") {
                        Image(systemName: "square.grid.2x2").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Text(node.title)
                        .font(.system(size: 12, weight: node.isGroup ? .semibold : (node.status == .failure ? .medium : .regular)))
                        .foregroundStyle(node.status == .skipped ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                if node.isGroup {
                    let leaves = node.leaves
                    let failed = leaves.filter { $0.actionsStatus == .failure }.count
                    Text("\(leaves.count) jobs\(failed > 0 ? " · \(failed) failed" : "")")
                        .font(.system(size: 10))
                        .foregroundStyle(failed > 0 ? Color.red.opacity(0.85) : Color.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(ActionsFormat.duration(node.duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .padding(.vertical, 2)
    }

    private func flatten(_ nodes: [ActionsJobNode], depth: Int) -> [Row] {
        nodes.flatMap { node -> [Row] in
            var rows = [Row(node: node, depth: depth)]
            if node.isGroup, !collapsed.contains(node.id) { rows += flatten(node.children, depth: depth + 1) }
            return rows
        }
    }

    private func allGroupIds(_ nodes: [ActionsJobNode]) -> Set<String> {
        Set(nodes.flatMap { $0.isGroup ? [$0.id] + Array(allGroupIds($0.children)) : [] })
    }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }
}

// MARK: - Summary

private struct ActionsRunSummaryView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ActionsStore
    let run: ActionsRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                triggerCard
                if !store.annotations.isEmpty { annotationsSection }
                jobsSection
                artifactsSection
            }
            .padding(16)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var triggerCard: some View {
        HStack(spacing: 18) {
            summaryStat("Triggered via", run.eventLabel)
            summaryStat("Status", run.actionsStatus.label, color: run.actionsStatus.color)
            summaryStat("Total duration", ActionsFormat.duration(run.duration))
            summaryStat("Jobs", "\(store.jobs.filter { $0.actionsStatus == .success }.count)/\(store.jobs.count) passed")
            summaryStat("Artifacts", "\(store.artifacts.count)")
            Spacer()
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }

    private func summaryStat(_ title: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
        }
    }

    private func sectionTitle(_ title: String, _ count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let count { Text("\(count)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.secondary) }
        }
    }

    private var annotationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Annotations", store.annotations.count)
            VStack(spacing: 0) {
                ForEach(Array(store.annotations.prefix(50).enumerated()), id: \.element.id) { index, note in
                    Button {
                        store.selectJob(note.jobId)
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: note.iconName).foregroundStyle(note.color).font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.jobName + (note.title.map { " · \($0)" } ?? ""))
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text(note.message)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                    .multilineTextAlignment(.leading)
                                if !note.path.isEmpty && note.path != ".github" {
                                    Text("\(note.path)\(note.startLine > 0 ? ":\(note.startLine)" : "")")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverPlain)
                    if index < min(store.annotations.count, 50) - 1 { Divider() }
                }
            }
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
        }
    }

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Jobs", store.jobs.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 8) {
                ForEach(store.jobs) { job in
                    Button {
                        store.selectJob(job.id)
                    } label: {
                        HStack(spacing: 8) {
                            ActionsStatusIcon(status: job.actionsStatus, size: 13)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(job.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                Text("\(job.actionsStatus.label) · \(ActionsFormat.duration(job.duration))")
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(9)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(job.actionsStatus == .failure ? Color.red.opacity(0.35) : Color.primary.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverPlain)
                }
            }
        }
    }

    private var artifactsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Artifacts", store.artifacts.count)
            if store.artifacts.isEmpty {
                Text("This run produced no artifacts.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.artifacts.enumerated()), id: \.element.id) { index, artifact in
                        HStack(spacing: 10) {
                            Image(systemName: "shippingbox").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(artifact.name).font(.system(size: 12.5, weight: .medium))
                                Text(artifact.expired ? "Expired" : "\(ActionsFormat.bytes(artifact.sizeInBytes))\(artifact.expiresAt.map { " · expires \(ActionsFormat.relativeDate($0))" } ?? "")")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !artifact.expired {
                                Button {
                                    store.downloadArtifact(artifact)
                                } label: {
                                    PRActionLabel("Download", systemImage: "arrow.down.circle", isRunning: store.isBusy("artifact-\(artifact.id)"))
                                }
                                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                                .disabled(store.isBusy("artifact-\(artifact.id)"))
                            }
                        }
                        .padding(10)
                        if index < store.artifacts.count - 1 { Divider() }
                    }
                }
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
            }
        }
    }
}

// MARK: - Job (steps + logs)

private struct ActionsJobView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ActionsStore
    let job: ActionsJob
    let isFullScreen: Bool

    @State private var expanded: Set<Int>
    @State private var query: String
    @State private var didAutoExpand: Bool
    @State private var hoveredStep: Int?

    init(state: AppState, store: ActionsStore, job: ActionsJob, fullScreen: ActionsFullScreenLog? = nil) {
        self.state = state
        self.store = store
        self.job = job
        isFullScreen = fullScreen != nil
        _expanded = State(initialValue: fullScreen?.expanded ?? [])
        _query = State(initialValue: fullScreen?.query ?? "")
        _didAutoExpand = State(initialValue: fullScreen != nil)
    }

    private var logState: ActionsJobLogState? { store.jobLogs[job.id] }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if case .failed(let message) = logState {
                        Text(message.contains("404") || message.contains("410")
                             ? "The log isn't available (it may have expired, or the job hasn't produced one yet)."
                             : message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                    if job.actionsStatus.isActive {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("This job is running. Step logs load here when it finishes.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            if let url = job.htmlUrl.flatMap(URL.init(string:)) {
                                Button("Watch live on GitHub") { LinkRouter.open(url) }
                                    .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                            }
                        }
                        .padding(10)
                    }
                    ForEach(job.steps) { step in
                        stepRow(step)
                    }
                }
                .padding(10)
            }
            .background(Color(red: 13/255, green: 17/255, blue: 23/255))
        }
        .onAppear { autoExpand() }
        .onChange(of: logState) { _, _ in autoExpand() }
        .onChange(of: query) { _, q in
            guard !q.isEmpty, case .loaded(let log) = logState else { return }
            let lower = q.lowercased()
            expanded.formUnion(log.lowercasedSteps.filter { $0.value.contains(lower) }.map(\.key))
        }
    }

    private func autoExpand() {
        guard !didAutoExpand, case .loaded = logState else { return }
        didAutoExpand = true
        expanded = Set(job.steps.filter { $0.actionsStatus == .failure }.map(\.number))
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ActionsStatusIcon(status: job.actionsStatus, size: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text([job.actionsStatus.label, ActionsFormat.duration(job.duration), job.runnerName ?? job.labels.first]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                if !job.actionsStatus.isActive {
                    Button { store.rerunJob(job) } label: {
                        PRActionLabel("Re-run job", systemImage: "arrow.counterclockwise", isRunning: store.isBusy("rerun-job-\(job.id)"))
                    }
                    .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                    .fixedSize()
                    .disabled(store.isBusy("rerun-job-\(job.id)"))
                }
                if let url = job.htmlUrl.flatMap(URL.init(string:)) {
                    Button { LinkRouter.open(url) } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                        .help("Open this job on GitHub")
                }
            }
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    TextField("Search this job's log", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !query.isEmpty {
                        Text("\(matchCount) line\(matchCount == 1 ? "" : "s")")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.hoverPlain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .frame(maxWidth: 360)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .disabled(logState == nil || logState == .loading)
                Spacer(minLength: 4)
                Button {
                    expanded = Set(job.steps.map(\.number))
                    if case .none = logState, !job.actionsStatus.isActive { store.loadJobLog(job) }
                } label: {
                    Label("Expand all", systemImage: "rectangle.expand.vertical")
                }
                .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                .disabled(expanded.count == job.steps.count)
                .help("Expand every step")
                Button {
                    expanded = []
                } label: {
                    Label("Collapse all", systemImage: "rectangle.compress.vertical")
                }
                .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                .disabled(expanded.isEmpty)
                .help("Collapse every step")
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 2)
                if case .loaded(let log) = logState {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.raw, forType: .string)
                        state.showToast("Copied job log", type: .success)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                        .help("Copy the raw log")
                    Button { store.saveLog(job) } label: { Image(systemName: "square.and.arrow.down") }
                        .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                        .help("Save the raw log to Downloads")
                }
                if !job.actionsStatus.isActive {
                    Button { store.loadJobLog(job, force: true) } label: {
                        PRActionLabel("", systemImage: "arrow.clockwise", isRunning: logState == .loading)
                    }
                    .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                    .help("Reload log")
                }
                if isFullScreen {
                    Button {
                        store.fullScreenLog = nil
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                    .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                    .keyboardShortcut(.cancelAction)
                    .help("Exit full screen (Esc)")
                } else {
                    Button {
                        store.fullScreenLog = ActionsFullScreenLog(jobId: job.id, expanded: expanded, query: query)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                    .help("Show the log full screen")
                }
            }
        }
    }

    private var matchCount: Int {
        guard case .loaded(let log) = logState, !query.isEmpty else { return 0 }
        let q = query.lowercased()
        return log.lowercasedSteps.values.reduce(0) { total, text in
            total + text.split(separator: "\n").reduce(0) { $0 + ($1.contains(q) ? 1 : 0) }
        }
    }

    @ViewBuilder
    private func stepRow(_ step: ActionsStep) -> some View {
        let isOpen = expanded.contains(step.number)
        let log: ActionsJobLog? = {
            if case .loaded(let log) = logState { return log }
            return nil
        }()
        let matches = query.isEmpty ? 0 : (log?.lowercasedSteps[step.number]?.components(separatedBy: query.lowercased()).count ?? 1) - 1

        VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { expanded.remove(step.number) } else { expanded.insert(step.number) }
                if case .none = logState, !job.actionsStatus.isActive { store.loadJobLog(job) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(hoveredStep == step.number ? Color.primary : Color.secondary)
                        .frame(width: 10)
                    ActionsStatusIcon(status: step.actionsStatus, size: 12)
                    Text(step.name)
                        .font(.system(size: 12.5, weight: step.actionsStatus == .failure ? .semibold : .regular))
                        .foregroundStyle(Color(white: 0.9))
                        .lineLimit(1)
                    if matches > 0 {
                        Text("\(matches) match\(matches == 1 ? "" : "es")")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .background(Color.yellow.opacity(0.2), in: Capsule())
                            .foregroundStyle(.yellow)
                    }
                    Spacer()
                    Text(ActionsFormat.duration(step.duration))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(hoveredStep == step.number ? Color.white.opacity(0.1) : (isOpen ? Color.white.opacity(0.06) : Color.clear),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(hoveredStep == step.number ? 0.12 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .pointerCursor()
            .onHover { inside in
                if inside { hoveredStep = step.number } else if hoveredStep == step.number { hoveredStep = nil }
            }

            if isOpen {
                stepLog(step, excerpt: log?.excerpts[step.number])
                    .padding(.leading, 26)
                    .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private func stepLog(_ step: ActionsStep, excerpt full: CILogExcerpt?) -> some View {
        switch logState {
        case .none where job.actionsStatus.isActive:
            Text(step.actionsStatus.isActive
                 ? "Running… GitHub publishes the log when the job finishes."
                 : "GitHub publishes step logs when the whole job finishes.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(8)
        case .none, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading log…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(8)
        case .failed:
            EmptyView()
        case .loaded:
            if let full, !full.lines.isEmpty {
                let excerpt = filtered(full)
                if excerpt.lines.isEmpty {
                    Text("No lines match “\(query)”").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(8)
                } else {
                    LogTextView(excerpt: excerpt, scrollToFirstError: step.actionsStatus == .failure)
                        .frame(height: min(isFullScreen ? 1400 : 520, max(40, CGFloat(excerpt.lines.count) * 15.5 + 18)))
                        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Text(step.actionsStatus == .skipped ? "This step was skipped." : "No output for this step.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    private func filtered(_ excerpt: CILogExcerpt) -> CILogExcerpt {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return excerpt }
        let lines = excerpt.lines.filter { $0.text.lowercased().contains(q) }
        return CILogExcerpt(lines: lines, totalLines: excerpt.totalLines, errorCount: excerpt.errorCount, isExcerpt: true)
    }
}

/// Covers the window below the title bar with the selected job's log.
struct ActionsFullScreenLogHost: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ActionsStore

    var body: some View {
        ZStack {
            if state.activeTab == .actions, let full = store.fullScreenLog, let job = store.jobs.first(where: { $0.id == full.jobId }) {
                ActionsJobView(state: state, store: store, job: job, fullScreen: full)
                    .id("fullscreen-\(job.id)")
                    .background(Color(NSColor.windowBackgroundColor))
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.fullScreenLog?.jobId)
    }
}
