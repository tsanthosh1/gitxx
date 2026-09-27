import SwiftUI

public struct ChangesSidebarView: View {
    @ObservedObject var state: AppState
    @AppStorage("gitxx_changes_tree") private var treeMode = false
    @AppStorage("gitxx_changes_group_by_stage") private var groupByStage = false
    @State private var collapsedDirs: Set<String> = []
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
                if let parked = state.parkedOperationError {
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
                            .buttonStyle(.plain)
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

                                Text("\(state.workingChanges.count) Changed Files")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            treeMode.toggle()
                        } label: {
                            Image(systemName: treeMode ? "list.bullet.indent" : "list.bullet")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 24)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(treeMode ? "Show as a flat list" : "Group by folder")

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
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Stashes")

                        Menu {
                            Button("Stage All") { state.stageAll() }
                            Button("Unstage All") { state.unstageAll() }
                            Divider()
                            Toggle("Group Staged & Unstaged", isOn: $groupByStage)
                            Divider()
                            Button("Stash All Changes") { state.stashChanges() }
                            Button("Pop Latest Stash") { state.stashPop() }
                            Button("Manage Stashes…") { state.showStashDrawer = true }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 24)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .menuStyle(.borderlessButton)
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
                    .focusable()
                    .focused($listFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    @ViewBuilder
    private func changeRows(_ changes: [WorkingChange]) -> some View {
        if treeMode {
            ForEach(PRFileTree.rows(for: changes, collapsed: collapsedDirs)) { row in
                switch row.kind {
                case .directory(let name, _):
                    directoryRow(id: row.id, name: name)
                        .padding(.leading, CGFloat(row.depth) * 14)
                case .file(let change):
                    fileRow(change, showDirectory: false)
                        .padding(.leading, CGFloat(row.depth) * 14)
                        .tag(change.path)
                }
            }
        } else {
            ForEach(changes) { change in
                fileRow(change, showDirectory: true)
                    .tag(change.path)
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
        .padding(.vertical, 2)
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

        HStack(spacing: 8) {
            // Stage Toggle Checkbox Button (generous 26x26 hit area)
            StageCheckbox(stage: stage, isSelected: isSelected, size: 15,
                          help: stage == .all ? "Click to unstage" : (stage == .partial ? "Partially staged — click to stage the rest" : "Click to stage")) {
                state.toggleStage(for: change.primary)
            }

            // Status Badge (M, A, D, U)
            Text(change.changeKind.badgeLabel)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(change.changeKind.badgeColor)
                .frame(width: 18, height: 18)
                .background(change.changeKind.badgeColor.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            // Filename and directory
            VStack(alignment: .leading, spacing: 2) {
                Text(change.filename)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                if showDirectory && !change.directory.isEmpty {
                    Text(change.directory)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()

            // Discard Changes Button (roomy hit target with hover effect)
            Button {
                state.discardChanges(for: change.primary)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Discard changes in \(change.filename)")
        }
        .padding(.vertical, showDirectory ? 5 : 2)
        .contentShape(Rectangle())
        .modifier(RowHoverHighlight(isSelected: isSelected))
        .onTapGesture {
            listFocused = true
            if !isSelected { state.selectFile(change.primary) }
        }
        .contextMenu {
            Button(stage == .all ? "Unstage File" : "Stage File") {
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
            .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
