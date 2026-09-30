import SwiftUI

public struct ChangesSidebarView: View {
    @ObservedObject var state: AppState
    @AppStorage("gitxx_changes_tree") private var treeMode = false
    @AppStorage("gitxx_changes_group_by_stage") private var groupByStage = false
    @State private var collapsedDirs: Set<String> = []
    @State private var hoveredPath: String?
    @State private var confirmDiscardAll = false
    @State private var refreshSpin = 0.0
    @State private var finishingOperation = false
    @State private var confirmAbortInProgress = false
    @FocusState private var listFocused: Bool

    var filteredChanges: [WorkingChange] {
        let changes = state.workingChanges
        let query = state.fileFilterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return changes }
        return changes.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    var allStaged: Bool {
        !state.files.isEmpty && state.files.allSatisfy { $0.isStaged }
    }

    public var body: some View {
        GeometryReader { geo in
            let maxAllowedHeight = max(185, geo.size.height - 120)
            let currentPaneHeight = min(max(state.commitPaneHeight, 130), maxAllowedHeight)

            VStack(spacing: 0) {
                if !state.conflictedPaths.isEmpty {
                    if let parked = state.parkedOperationError { parkedErrorBanner(parked) }
                    conflictsBanner(state.conflictedPaths.count)
                } else if let op = state.operationInProgress {
                    resolvedOperationBanner(op, rejection: state.parkedOperationError)
                } else if let parked = state.parkedOperationError {
                    parkedErrorBanner(parked)
                }
                // Header: Filter & Select All
                VStack(spacing: 8) {
                    // Filter search bar
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))

                        TextField("Filter files...", text: $state.fileFilterText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))

                        if !state.fileFilterText.isEmpty {
                            Button {
                                state.fileFilterText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 12))
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.hoverPlain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )

                    // Select All / Unselect All row
                    HStack(spacing: 8) {
                        Button {
                            if allStaged {
                                state.unstageAll()
                            } else {
                                state.stageAll()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: allStaged ? "checkmark.square.fill" : (state.files.contains(where: { $0.isStaged }) ? "minus.square.fill" : "square"))
                                    .font(.system(size: 15))
                                    .foregroundStyle(state.files.contains(where: { $0.isStaged }) ? Color.primary : Color.secondary.opacity(0.8))
                                    .frame(width: 20, height: 20)

                                ViewThatFits(in: .horizontal) {
                                    Text("\(state.workingChanges.count) Changed Files")
                                    Text("\(state.workingChanges.count) Files")
                                    Text("\(state.workingChanges.count)")
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverPlain)

                        Spacer()

                        HStack(spacing: 3) {
                            headerIcon("arrow.clockwise", help: "Refresh status (⌘R)", spin: refreshSpin) {
                                withAnimation(.easeInOut(duration: 0.5)) { refreshSpin += 360 }
                                state.refreshRepo()
                            }
                            headerIcon(treeMode ? "list.bullet.indent" : "list.bullet",
                                       help: treeMode ? "Show as a flat list" : "Group by folder") { treeMode.toggle() }
                            if treeMode {
                                headerIcon(collapsedDirs.isEmpty ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                           help: collapsedDirs.isEmpty ? "Collapse all folders" : "Expand all folders") {
                                    toggleAllFolders()
                                }
                            }
                            headerIcon("square.split.1x2", help: groupByStage ? "Stop grouping by staged state" : "Group staged & unstaged",
                                       active: groupByStage) { groupByStage.toggle() }
                        }

                        Button {
                            state.showStashDrawer = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "tray.full")
                                    .font(.system(size: 12, weight: .semibold))
                                if !state.stashes.isEmpty {
                                    Text("\(state.stashes.count)")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                }
                            }
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 28, minHeight: 24)
                            .padding(.horizontal, state.stashes.isEmpty ? 0 : 4)
                        }
                        .buttonStyle(.icon(size: 24, resting: 0.06))
                        .help("Stashes")

                        moreMenu
                    }
                    .padding(.horizontal, 2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.02))

                Divider()

                // File List
                if state.files.isEmpty && state.switchingRepoPath != nil {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading changes…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredChanges.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 38))
                            .foregroundStyle(.secondary.opacity(0.6))
                        Text(state.files.isEmpty ? "No local changes" : "No matching files")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        if state.files.isEmpty {
                            Text("Working directory is clean")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Selection is drawn by the rows (neutral grey) instead of List's accent-coloured highlight.
                    ScrollViewReader { proxy in
                    List {
                        if groupByStage {
                            let staged = filteredChanges.filter { $0.stageState != .none }
                            let unstaged = filteredChanges.filter { $0.stageState == .none }
                            if !staged.isEmpty {
                                Section { changeRows(staged) } header: { sectionHeader("Staged", count: staged.count) }
                            }
                            if !unstaged.isEmpty {
                                Section { changeRows(unstaged) } header: { sectionHeader("Unstaged", count: unstaged.count) }
                            }
                        } else {
                            changeRows(filteredChanges)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 20)
                    .focusable()
                    .focused($listFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.space) { toggleSelectedStage(); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                    .onChange(of: state.selectedFile?.path) { _, path in
                        guard let path else { return }
                        DispatchQueue.main.async { proxy.scrollTo(path) }
                    }
                    .onAppear {
                        if let path = state.selectedFile?.path { DispatchQueue.main.async { proxy.scrollTo(path) } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                // Vertical Resizer Handle between File List and Commit Box
                CommitPaneResizeDivider(state: state, maxAllowedHeight: maxAllowedHeight)

                // Bottom Commit Box (Resizable Height)
                CommitBoxView(state: state)
                    .frame(height: currentPaneHeight)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: state.currentRepo?.path) { await state.loadStashes() }
    }

    /// No vertical list padding: rows carry their own, so highlights of neighbouring rows meet without a gap.
    private static let rowInsets = EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)

    @ViewBuilder
    private func changeRows(_ changes: [WorkingChange]) -> some View {
        if treeMode {
            ForEach(PRFileTree.rows(for: changes, collapsed: collapsedDirs)) { row in
                switch row.kind {
                case .directory(let name, _):
                    directoryRow(id: row.id, name: name)
                        .padding(.leading, CGFloat(row.depth) * 14)
                        .listRowInsets(Self.rowInsets)
                case .file(let change):
                    fileRow(change, showDirectory: false)
                        .padding(.leading, CGFloat(row.depth) * 14)
                        .listRowInsets(Self.rowInsets)
                        .tag(change.path)
                        .id(change.path)
                }
            }
        } else {
            ForEach(changes) { change in
                fileRow(change, showDirectory: true)
                    .listRowInsets(Self.rowInsets)
                    .tag(change.path)
                    .id(change.path)
            }
        }
    }

    /// Files in the order they appear on screen (grouping, tree and collapsed folders applied).
    private var displayedChanges: [WorkingChange] {
        let groups = groupByStage
            ? [filteredChanges.filter { $0.stageState != .none }, filteredChanges.filter { $0.stageState == .none }]
            : [filteredChanges]
        return groups.flatMap { group -> [WorkingChange] in
            guard treeMode else { return group }
            return PRFileTree.rows(for: group, collapsed: collapsedDirs).compactMap { row in
                if case .file(let change) = row.kind { return change }
                return nil
            }
        }
    }

    private func headerIcon(_ symbol: String, help: String, active: Bool = false, spin: Double = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(active ? state.accentTheme.primaryColor : Color.secondary)
                .rotationEffect(.degrees(spin))
                .frame(width: 26, height: 24)
                .background(active ? state.accentTheme.primaryColor.opacity(0.16) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.icon(size: 24, resting: active ? 0 : 0.06))
        .help(help)
    }

    private func toggleAllFolders() {
        if collapsedDirs.isEmpty {
            let dirs = Set(state.workingChanges.flatMap { change -> [String] in
                let parts = change.path.split(separator: "/").dropLast()
                return parts.indices.map { "dir:" + parts[...$0].joined(separator: "/") }
            })
            collapsedDirs = dirs
        } else {
            collapsedDirs = []
        }
    }

    /// Space stages (or unstages) the selected file and keeps it selected; with nothing selected it picks the first file.
    private func toggleSelectedStage() {
        let changes = displayedChanges
        guard !changes.isEmpty else { return }
        guard let path = state.selectedFile?.path, let change = changes.first(where: { $0.path == path }) else {
            state.selectFile(changes[0].primary)
            return
        }
        state.setFilesStaged([change.path], staged: change.stageState != .all)
        if let updated = state.workingChanges.first(where: { $0.path == change.path }) {
            state.selectFile(updated.primary)
        }
    }

    private var moreMenu: some View {
        let changes = state.workingChanges
        let unstaged = changes.filter { $0.stageState != .all }.count
        let staged = changes.filter { $0.stageState != .none }.count
        return Menu {
            Section("Staging") {
                Button { state.stageAll() } label: {
                    Label(unstaged > 0 ? "Stage All (\(unstaged))" : "Stage All", systemImage: "checkmark.square")
                }
                .disabled(unstaged == 0)
                Button { state.unstageAll() } label: {
                    Label(staged > 0 ? "Unstage All (\(staged))" : "Unstage All", systemImage: "square")
                }
                .disabled(staged == 0)
                Button(role: .destructive) { confirmDiscardAll = true } label: {
                    Label("Discard All Changes…", systemImage: "trash")
                }
                .disabled(changes.isEmpty)
            }
            Section("View") {
                Picker(selection: $treeMode) {
                    Label("Flat List", systemImage: "list.bullet").tag(false)
                    Label("Folder Tree", systemImage: "list.bullet.indent").tag(true)
                } label: { Text("Layout") }
                .pickerStyle(.inline)
                Toggle(isOn: $groupByStage) {
                    Label("Group Staged & Unstaged", systemImage: "square.split.1x2")
                }
            }
            Section("Stash") {
                Button { state.stashChanges() } label: {
                    Label("Stash All Changes", systemImage: "tray.and.arrow.down")
                }
                .disabled(changes.isEmpty)
                Button { state.stashPop() } label: {
                    Label(state.stashes.first.map { "Pop “\($0.subject.count > 40 ? String($0.subject.prefix(40)) + "…" : $0.subject)”" } ?? "Pop Latest Stash",
                          systemImage: "tray.and.arrow.up")
                }
                .disabled(state.stashes.isEmpty)
                Button { state.showStashDrawer = true } label: {
                    Label(state.stashes.isEmpty ? "Manage Stashes…" : "Manage Stashes (\(state.stashes.count))…", systemImage: "tray.full")
                }
            }
            Section {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(filteredChanges.map(\.path).joined(separator: "\n"), forType: .string)
                    state.showToast("Copied \(filteredChanges.count) path\(filteredChanges.count == 1 ? "" : "s")", type: .success)
                } label: {
                    Label("Copy Changed Paths", systemImage: "doc.on.doc")
                }
                .disabled(filteredChanges.isEmpty)
                if let path = state.currentRepo?.path {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                        Label("Reveal Repository in Finder", systemImage: "folder")
                    }
                }
                Button { state.refreshRepo() } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .iconHover(size: 24)
        .help("Staging, view, stash and file actions")
        .confirmationDialog("Discard all \(changes.count) changed files?", isPresented: $confirmDiscardAll) {
            Button("Discard All Changes", role: .destructive) { state.discardAllChanges() }
        } message: {
            Text("Staged and unstaged edits are reverted and new untracked files are deleted. This can't be undone. Stash the changes instead if you might want them back.")
        }
    }

    private func moveSelection(by delta: Int) {
        let changes = displayedChanges
        guard !changes.isEmpty else { return }
        let current = changes.firstIndex { $0.path == state.selectedFile?.path }
        let next = current.map { min(max($0 + delta, 0), changes.count - 1) } ?? (delta > 0 ? 0 : changes.count - 1)
        guard next != current else { return }
        state.selectFile(changes[next].primary)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func changes(under directoryID: String) -> [WorkingChange] {
        let prefix = String(directoryID.dropFirst("dir:".count)) + "/"
        return filteredChanges.filter { $0.path.hasPrefix(prefix) }
    }

    private func directoryRow(id: String, name: String) -> some View {
        let children = changes(under: id)
        let stagedCount = children.filter { $0.stageState == .all }.count
        let folderState: WorkingChange.StageState = stagedCount == children.count
            ? .all : (children.contains { $0.stageState != .none } ? .partial : .none)
        let collapsed = collapsedDirs.contains(id)
        return HStack(spacing: 6) {
            StageCheckbox(stage: folderState, isSelected: false, size: 14,
                          help: folderState == .all ? "Unstage everything in this folder" : "Stage everything in this folder") {
                state.setFilesStaged(children.map(\.path), staged: folderState != .all)
            }

            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(children.count)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .modifier(RowHoverHighlight(isSelected: false))
        .onTapGesture {
            if collapsed { collapsedDirs.remove(id) } else { collapsedDirs.insert(id) }
        }
    }

    @ViewBuilder
    private func fileRow(_ change: WorkingChange, showDirectory: Bool) -> some View {
        let isSelected = state.selectedFile?.path == change.path
        let stage = change.stageState

        HStack(spacing: 7) {
            StageCheckbox(stage: stage, isSelected: isSelected, size: 14,
                          help: stage == .all ? "Click to unstage" : (stage == .partial ? "Partially staged — click to stage the rest" : "Click to stage")) {
                state.toggleStage(for: change.primary)
            }

            // Status Badge (M, A, D, U)
            Text(change.changeKind.badgeLabel)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(change.changeKind.badgeColor)
                .frame(width: 16, height: 16)
                .background(change.changeKind.badgeColor.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            // Filename and directory
            VStack(alignment: .leading, spacing: 0) {
                Text(change.filename)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                if showDirectory && !change.directory.isEmpty {
                    Text(change.directory)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 4)

            if change.changeKind == .unmerged {
                Button {
                    state.openConflictResolver(path: change.path)
                } label: {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 22, height: 22)
                        .background(Color.orange.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .help("Open \(change.filename) in the merge tool")
            }

            Button {
                state.discardChanges(for: change.primary)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .opacity(hoveredPath == change.path || isSelected ? 1 : 0)
            .help("Discard changes in \(change.filename)")
        }
        .padding(.vertical, showDirectory ? 3 : 4)
        .contentShape(Rectangle())
        .modifier(RowHoverHighlight(isSelected: isSelected))
        .onHover { inside in
            if inside { hoveredPath = change.path } else if hoveredPath == change.path { hoveredPath = nil }
        }
        .onTapGesture(count: 2) {
            if change.changeKind == .unmerged { state.openConflictResolver(path: change.path) }
        }
        .onTapGesture {
            listFocused = true
            if !isSelected { state.selectFile(change.primary) }
        }
        .contextMenu {
            if change.changeKind == .unmerged {
                Button("Resolve Conflict…") { state.openConflictResolver(path: change.path) }
                Divider()
            }
            Button(stage == .all ? "Unstage File (Space)" : "Stage File (Space)") {
                state.toggleStage(for: change.primary)
            }
            if stage == .partial, let index = change.index {
                Button("Unstage File") { state.toggleStage(for: index) }
            }
            Button("Discard Changes...", role: .destructive) {
                state.discardChanges(for: change.primary)
            }
        }
    }

    private func conflictsBanner(_ count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count) conflicted file\(count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .semibold))
                Text("Use the merge button on a file, or Resolve… for all")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Resolve…") { state.openConflictResolver() }
                .buttonStyle(PRActionButtonStyle(.primary(state.accentTheme.primaryColor), size: .compact))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    /// Every conflict is resolved but the merge/rebase hasn't been committed yet. When the last attempt was
    /// rejected (e.g. by a hook), the same banner says why and links back to the fixes, instead of a second banner.
    private func resolvedOperationBanner(_ op: ConflictOperation, rejection: GitOperationError?) -> some View {
        let name = op.title.lowercased()
        let tint: Color = rejection == nil ? .green : .orange
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: rejection == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rejection == nil ? "\(op.title) in progress" : "\(op.title) in progress · last commit was rejected")
                        .font(.system(size: 12, weight: .semibold))
                    Text(rejection.map(Self.rejectionReason) ?? "Conflicts are resolved. Commit to finish the \(name), or abort it.")
                        .font(.system(size: 10.5, design: rejection?.highlights.isEmpty == false ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if rejection != nil {
                    Button {
                        state.parkedOperationError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(.secondary)
                    .help("Hide the rejection details")
                }
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if rejection != nil {
                    Button("Details & fixes") { state.reopenParkedError() }
                        .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                        .fixedSize()
                }
                Button("Abort") { confirmAbortInProgress = true }
                    .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                    .fixedSize()
                Button {
                    Task {
                        finishingOperation = true
                        state.parkedOperationError = nil
                        await state.continueOperationInProgress()
                        finishingOperation = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        if finishingOperation { ProgressView().controlSize(.mini) }
                        Text(op == .rebase ? "Continue Rebase" : rejection == nil ? "Commit \(op.title)" : "Retry Commit")
                    }
                }
                .buttonStyle(PRActionButtonStyle(.primary(state.accentTheme.primaryColor), size: .compact))
                .fixedSize()
                .disabled(finishingOperation)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10))
        .alert("Abort the \(name)?", isPresented: $confirmAbortInProgress) {
            Button("Abort", role: .destructive) { Task { await state.abortOperationInProgress() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything goes back to how it was before the \(name) started. Your conflict resolutions are discarded.")
        }
    }

    /// The most telling highlight: an actual error line rather than "✖ task:" or "hook exited with code 1".
    private static func rejectionReason(_ error: GitOperationError) -> String {
        let lines = error.highlights
        return lines.first { $0.lowercased().contains("error") && !$0.contains("exited with code") }
            ?? lines.first { !$0.hasPrefix("✖") && !$0.contains("exited with code") }
            ?? lines.first ?? error.title
    }

    private func parkedErrorBanner(_ error: GitOperationError) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error.title)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 4)
            Button("Back to fixes") { state.reopenParkedError() }
                .buttonStyle(PRActionButtonStyle(.primary(state.accentTheme.primaryColor), size: .compact))
            Button {
                state.parkedOperationError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
    }
}

/// Stage checkbox; hovering only brightens it to white.
private struct StageCheckbox: View {
    let stage: WorkingChange.StageState
    let isSelected: Bool
    let size: CGFloat
    let help: String
    let action: () -> Void
    @State private var hovering = false

    private var symbol: String {
        switch stage {
        case .none: return "square"
        case .partial: return "minus.square.fill"
        case .all: return "checkmark.square.fill"
        }
    }

    private var color: Color {
        if hovering { return .white }
        return stage == .none ? Color.secondary.opacity(0.8) : Color.primary.opacity(0.85)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .pointerCursor()
        .help(help)
    }
}

/// Neutral row background: a stronger grey for the selected file, a faint one under the pointer.
private struct RowHoverHighlight: ViewModifier {
    let isSelected: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.14 : (hovering ? 0.06 : 0)))
                    .padding(.horizontal, -6)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
