import SwiftUI
import AppKit

/// Actions tab: workflow definitions on the left; on the right the (filtered) run list, or the opened run's
/// jobs, step logs and artifacts.
struct ActionsContainerView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ActionsStore

    var body: some View {
        Group {
            if !state.hasConfiguredGitHubToken {
                unavailable(icon: "person.badge.key", title: "Connect GitHub to see Actions",
                            message: "Sign in or add a token in Settings to browse workflow runs, logs and artifacts.",
                            button: ("Open Settings", { state.showSettings = true }))
            } else if !store.isAvailable {
                unavailable(icon: "play.slash", title: "No GitHub remote",
                            message: "This repository's origin isn't on GitHub, so there are no Actions runs to show.",
                            button: nil)
            } else {
                HSplitView {
                    ActionsWorkflowSidebar(state: state, store: store)
                        .frame(minWidth: 210, idealWidth: 260, maxWidth: 400)
                    detail
                        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { store.activate() }
        .sheet(item: $store.dispatchWorkflow) { workflow in
            ActionsDispatchSheet(state: state, store: store, workflow: workflow)
        }
        .sheet(isPresented: $store.showDispatchPicker) {
            ActionsWorkflowPickerSheet(store: store)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let run = store.selectedRun {
            ActionsRunDetailView(state: state, store: store, run: run)
                .id(run.id)
        } else if store.selectedRunId != nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ActionsRunListPane(state: state, store: store)
        }
    }

    private func unavailable(icon: String, title: String, message: String, button: (String, () -> Void)?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let button {
                Button(button.0, action: button.1)
                    .buttonStyle(PRActionButtonStyle(.secondary, size: .regular))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Run list

struct ActionsRunListPane: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ActionsStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            quickFilters
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            list
        }
        .themedSurface(state.accentTheme, .sidebar)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(store.selectedWorkflow?.name ?? "All workflows")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        if let workflow = store.selectedWorkflow, !workflow.isActive {
                            Text("Disabled")
                                .font(.system(size: 9.5, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(store.selectedWorkflow?.path ?? "Runs of every workflow in \(store.repoSlug ?? "this repository")")
                        .font(.system(size: 11, design: store.selectedWorkflow == nil ? .default : .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button {
                    store.beginDispatch()
                } label: {
                    Label("Run workflow", systemImage: "play.fill")
                }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                .disabled(store.selectedWorkflow?.isActive == false)
                .help(store.selectedWorkflow == nil ? "Choose a workflow to start" : "Start this workflow (workflow_dispatch)")
                Button {
                    store.reloadRuns()
                    store.loadWorkflows()
                } label: {
                    PRActionLabel("", systemImage: "arrow.clockwise", isRunning: store.isLoadingRuns)
                }
                .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                .help("Refresh runs (auto-refreshes while runs are in progress)")
                if let workflow = store.selectedWorkflow {
                    Menu {
                        Button(workflow.isActive ? "Disable workflow" : "Enable workflow") {
                            store.setWorkflow(workflow, enabled: !workflow.isActive)
                        }
                        if let url = workflow.htmlUrl.flatMap(URL.init(string:)) {
                            Button("Open workflow file on GitHub") { LinkRouter.open(url) }
                        }
                        Button("Copy path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(workflow.path, forType: .string)
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
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filter by title, branch, #run, #PR, actor or SHA", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searchFocused)
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.hoverPlain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08)))
        }
    }

    // MARK: Quick filters

    private var quickFilters: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                chip(title: store.currentBranch.map { "Current branch · \($0)" } ?? "Current branch",
                     icon: "arrow.triangle.branch", on: store.isCurrentBranchFilter) { store.toggleCurrentBranch() }
                    .help("Only runs for the checked-out branch")
                chip(title: "Mine", icon: "person", on: store.filter.actor != nil && store.filter.actor == store.viewerLogin) { store.toggleMine() }
                chip(title: "Failed", icon: "xmark.circle", on: store.filter.status == "failure") { store.toggleStatus("failure") }
                chip(title: "Running", icon: "circle.dotted.circle", on: store.filter.status == "in_progress") { store.toggleStatus("in_progress") }
                moreFilters
                Spacer(minLength: 0)
            }
            let tokens = activeTokens
            if !tokens.isEmpty || !store.runs.isEmpty {
                HStack(spacing: 6) {
                    Text(countText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(tokens, id: \.label) { token in
                        Button(action: token.clear) {
                            HStack(spacing: 3) {
                                Text(token.label).lineLimit(1)
                                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.hoverPlain)
                        .help("Remove filter")
                    }
                    if tokens.count > 1 {
                        Button("Clear all") { store.filter = ActionsRunFilter() }
                            .buttonStyle(.hoverPlain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var countText: String {
        let shown = store.visibleRuns.count
        if !store.searchText.isEmpty { return "\(shown) of \(store.runs.count) loaded" }
        return "\(store.totalCount) run\(store.totalCount == 1 ? "" : "s")"
    }

    private struct Token { let label: String; let clear: () -> Void }

    private var activeTokens: [Token] {
        var tokens: [Token] = []
        if let branch = store.filter.branch { tokens.append(Token(label: "branch: \(branch)") { store.filter.branch = nil }) }
        if let actor = store.filter.actor { tokens.append(Token(label: "actor: \(actor)") { store.filter.actor = nil }) }
        if let event = store.filter.event { tokens.append(Token(label: "event: \(event)") { store.filter.event = nil }) }
        if let status = store.filter.status { tokens.append(Token(label: "status: \(status)") { store.filter.status = nil }) }
        return tokens
    }

    private var moreFilters: some View {
        Menu {
            Menu("Branch") {
                if let current = store.currentBranch {
                    Button("\(current) (current)") { store.filter.branch = current }
                    Divider()
                }
                let names = Array(Set(state.branches.map(\.displayName) + store.runs.map(\.headBranch)))
                    .filter { !$0.isEmpty && $0 != store.currentBranch && !$0.hasPrefix("origin/HEAD") }
                    .sorted()
                ForEach(names.prefix(60), id: \.self) { name in
                    Button(name) { store.filter.branch = name.hasPrefix("origin/") ? String(name.dropFirst(7)) : name }
                }
            }
            Menu("Event") {
                ForEach([("push", "Push"), ("pull_request", "Pull request"), ("workflow_dispatch", "Manual"), ("schedule", "Schedule"), ("merge_group", "Merge queue"), ("release", "Release")], id: \.0) { value, title in
                    Button { store.filter.event = store.filter.event == value ? nil : value } label: {
                        if store.filter.event == value { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
            Menu("Status") {
                ForEach([("success", "Success"), ("failure", "Failure"), ("in_progress", "In progress"), ("queued", "Queued"), ("waiting", "Waiting"), ("action_required", "Action required"), ("cancelled", "Cancelled"), ("skipped", "Skipped"), ("timed_out", "Timed out")], id: \.0) { value, title in
                    Button { store.toggleStatus(value) } label: {
                        if store.filter.status == value { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
            Menu("Actor") {
                let actors = Array(Set(store.runs.map(\.actorLogin))).filter { !$0.isEmpty }.sorted()
                ForEach(actors, id: \.self) { login in
                    Button { store.filter.actor = store.filter.actor == login ? nil : login } label: {
                        if store.filter.actor == login { Label(login, systemImage: "checkmark") } else { Text(login) }
                    }
                }
            }
            if !store.filter.isEmpty {
                Divider()
                Button("Clear filters") { store.filter = ActionsRunFilter() }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .iconHover(size: 24)
        .help("More filters: branch, event, status, actor")
    }

    private func chip(title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .frame(maxWidth: 220)
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .background(on ? Color.primary.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().stroke(on ? Color.primary.opacity(0.25) : Color.primary.opacity(0.08)))
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.hoverPlain)
        .pointerCursor()
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        let runs = store.visibleRuns
        if store.isLoadingRuns && store.runs.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading workflow runs…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.loadError, store.runs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(.orange)
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") { store.reloadRuns() }.buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if runs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "play.circle").font(.system(size: 28)).foregroundStyle(.secondary.opacity(0.5))
                Text(store.filter.isEmpty && store.searchText.isEmpty ? "No workflow runs yet" : "No runs match these filters")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                if !store.filter.isEmpty {
                    Button("Clear filters") { store.filter = ActionsRunFilter() }
                        .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(runs) { run in
                    ActionsRunRow(state: state, store: store, run: run) {
                        store.selectRun(run)
                        state.recordNavigationStep()
                    }
                    .listRowSeparator(.visible)
                    .contextMenu { ActionsRunMenu(state: state, store: store, run: run) }
                    .onAppear { if run.id == runs.last?.id { store.loadMore() } }
                }
                if store.hasMore && store.searchText.isEmpty {
                    HStack {
                        Spacer()
                        if store.isLoadingMore {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Load more") { store.loadMore() }.buttonStyle(.hoverPlain).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .font(.system(size: 11.5))
                    .padding(.vertical, 6)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

struct ActionsStatusIcon: View {
    let status: ActionsStatus
    var size: CGFloat = 14

    var body: some View {
        if status == .running {
            ProgressView()
                .controlSize(.mini)
                .tint(.yellow)
                .frame(width: size, height: size)
        } else {
            Image(systemName: status.iconName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(status.color)
                .frame(width: size, height: size)
        }
    }
}

struct ActionsRunRow: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ActionsStore
    let run: ActionsRun
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ActionsStatusIcon(status: run.actionsStatus, size: 15)
                .help(run.actionsStatus.label)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.displayTitle.isEmpty ? run.workflowName : run.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text("\(run.workflowName) #\(String(run.runNumber))\(run.runAttempt > 1 ? " · attempt \(run.runAttempt)" : "") · \(run.eventLabel)")
                    if !run.actorLogin.isEmpty {
                        Text("·")
                        PRAvatarView(authorName: run.actorLogin, avatarUrl: run.actorAvatarUrl, size: 13)
                        Text(run.actorLogin)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                ForEach(store.pullRequestNumbers(for: run).prefix(2), id: \.self) { number in
                    ActionsPRChip(number: number) { Task { await state.openPullRequest(number: number, tab: .checks) } }
                }
                ActionsBranchChip(branch: run.headBranch, isCurrent: run.headBranch == store.currentBranch) {
                    store.filter.branch = run.headBranch
                }
            }
            VStack(alignment: .trailing, spacing: 3) {
                Label(ActionsFormat.relativeDate(run.createdAt), systemImage: "calendar")
                    .help(run.createdAt.formatted(date: .abbreviated, time: .standard))
                Label(ActionsFormat.duration(run.duration), systemImage: "stopwatch")
                    .font(.system(size: 10.5, design: .monospaced))
            }
            .labelStyle(TrailingIconLabelStyle())
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .frame(width: 92, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0.35)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .pointerCursor()
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title.lineLimit(1)
            configuration.icon.font(.system(size: 9)).frame(width: 11)
        }
    }
}

struct ActionsBranchChip: View {
    let branch: String
    var isCurrent = false
    var action: (() -> Void)? = nil

    var body: some View {
        let label = HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 8.5, weight: .semibold))
            Text(branch).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
        .background(Color.primary.opacity(isCurrent ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 4))
        .frame(maxWidth: 190, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)

        if let action {
            Button(action: action) { label }
                .buttonStyle(.hoverPlain)
                .pointerCursor()
                .help("Show runs for \(branch)")
        } else {
            label.help(isCurrent ? "\(branch) (checked out)" : branch)
        }
    }
}

struct ActionsPRChip: View {
    let number: Int
    var title: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                PullRequestGlyph(size: 9, color: .green)
                Text("#\(String(number))")
                if let title { Text(title).lineLimit(1).foregroundStyle(.secondary) }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.hoverPlain)
        .pointerCursor()
        .help("Open pull request #\(String(number))")
    }
}

struct ActionsRunMenu: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ActionsStore
    let run: ActionsRun

    var body: some View {
        if run.actionsStatus.isActive {
            Button("Cancel run") { store.cancel(run) }
        } else {
            Button("Re-run all jobs") { store.rerun(run, failedOnly: false) }
            if run.actionsStatus == .failure || run.actionsStatus == .cancelled {
                Button("Re-run failed jobs") { store.rerun(run, failedOnly: true) }
            }
        }
        Divider()
        ForEach(store.pullRequestNumbers(for: run), id: \.self) { number in
            Button("Open pull request #\(String(number))") { Task { await state.openPullRequest(number: number, tab: .checks) } }
        }
        Button("Show runs for \(run.headBranch)") { store.filter.branch = run.headBranch }
        Button("Show \(run.workflowName) runs") { store.filter.workflowId = run.workflowId }
        if !run.actorLogin.isEmpty {
            Button("Show runs by \(run.actorLogin)") { store.filter.actor = run.actorLogin }
        }
        Divider()
        Button("Open on GitHub") { if let url = URL(string: run.htmlUrl) { LinkRouter.open(url) } }
        Button("Copy run link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(run.htmlUrl, forType: .string)
        }
        Button("Copy commit SHA") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(run.headSha, forType: .string)
        }
    }
}
