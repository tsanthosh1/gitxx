import SwiftUI
import AppKit

/// Read-only review of a set of local changes (e.g. the files blocking a pull): file list on the left, diff on the right.
struct ChangedFilesDiffSheet: View {
    @ObservedObject var state: AppState
    let title: String
    let paths: [String]
    /// Called with a path to continue on the Changes tab instead.
    var onShowInChanges: ((String) -> Void)?

    @State private var selected: String?
    @State private var diffs: [String: CachedWorkingDiff] = [:]
    /// Files handled from this sheet: path → "Stashed" / "Reverted".
    @State private var resolved: [String: String] = [:]
    @State private var busy: Set<String> = []
    @State private var confirmRevert: [String]?
    @Environment(\.dismiss) private var dismiss

    init(state: AppState, title: String, paths: [String], initial: String? = nil, onShowInChanges: ((String) -> Void)? = nil) {
        self.state = state
        self.title = title
        self.paths = paths
        self.onShowInChanges = onShowInChanges
        _selected = State(initialValue: initial ?? paths.first)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                fileList
                    .frame(minWidth: 220, idealWidth: 290, maxWidth: 460)
                diffPane
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 960, idealWidth: 1180, minHeight: 600, idealHeight: 760)
        .task { await loadAll() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmRevert != nil }, set: { if !$0 { confirmRevert = nil } }),
                            presenting: confirmRevert) { paths in
            Button(paths.count == 1 ? "Revert File" : "Revert \(paths.count) Files", role: .destructive) { revert(paths) }
        } message: { _ in
            Text("Your edits are thrown away (new files are deleted). Stash instead if you might want them back.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(state.accentTheme.primaryColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text("\(paths.count) file\(paths.count == 1 ? "" : "s") · read-only · ↑↓ to switch files")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            let open = pending
            if open.count > 1 {
                Button { stash(open) } label: {
                    Label("Stash all \(open.count)", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                .disabled(!busy.isEmpty)
                .help("Stash every remaining file in this list (one stash entry)")
            }
            if let onShowInChanges, let selected, change(for: selected) != nil {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onShowInChanges(selected) }
                } label: {
                    Label("Open in Changes tab", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                .help("Stage or edit this file on the Changes tab; the fixes stay available from its banner")
            }
            Button("Done") { dismiss() }
                .buttonStyle(PRActionButtonStyle(.primary(state.accentTheme.primaryColor), size: .compact))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var fileList: some View {
        List(selection: $selected) {
            ForEach(paths, id: \.self) { path in
                fileRow(path).tag(path)
            }
        }
        .listStyle(.sidebar)
    }

    private func fileRow(_ path: String) -> some View {
        let change = change(for: path)
        let ns = path as NSString
        let diff = diffs[path]?.diff
        return HStack(spacing: 7) {
            if let change {
                Text(change.changeKind.badgeLabel)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(change.changeKind.badgeColor)
                    .frame(width: 16, height: 16)
                    .background(change.changeKind.badgeColor.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(ns.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if !ns.deletingLastPathComponent.isEmpty {
                    Text(ns.deletingLastPathComponent)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if let done = resolved[path] {
                Text(done)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background((done == "Stashed" ? Color.blue : Color.orange).opacity(0.18), in: Capsule())
                    .foregroundStyle(done == "Stashed" ? Color.blue : Color.orange)
            } else if let diff {
                HStack(spacing: 4) {
                    Text("+\(diff.additions)").foregroundStyle(.green)
                    Text("−\(diff.deletions)").foregroundStyle(.red)
                }
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            }
        }
        .padding(.vertical, 1)
        .opacity(resolved[path] != nil ? 0.6 : 1)
        .help(path)
        .contextMenu {
            if change != nil && resolved[path] == nil {
                Button("Stash This File") { stash([path]) }
                Button("Revert This File…", role: .destructive) { confirmRevert = [path] }
            }
        }
    }

    private var pending: [String] {
        paths.filter { change(for: $0) != nil && resolved[$0] == nil }
    }

    private var confirmTitle: String {
        guard let paths = confirmRevert else { return "" }
        return paths.count == 1 ? "Revert \((paths[0] as NSString).lastPathComponent)?" : "Revert \(paths.count) files?"
    }

    private func fileActions(_ path: String) -> some View {
        let isBusy = busy.contains(path)
        return HStack(spacing: 8) {
            Image(systemName: "lightbulb").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Stash to keep these edits for later, or revert to throw them away.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isBusy { ProgressView().controlSize(.small) }
            Button { stash([path]) } label: {
                Label("Stash file", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
            .help("Move this file's changes into a new stash; restore it later from Stashes")
            Button { confirmRevert = [path] } label: {
                Label("Revert file", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
            .foregroundStyle(.red)
            .help("Discard this file's changes")
        }
        .disabled(isBusy)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .themedSurface(state.accentTheme, .header)
    }

    private func stash(_ targets: [String]) {
        run(targets, label: "Stashed") { await state.stashFiles(targets) }
    }

    private func revert(_ targets: [String]) {
        run(targets, label: "Reverted") { await state.revertFiles(targets) }
    }

    private func run(_ targets: [String], label: String, _ action: @escaping () async -> Bool) {
        busy.formUnion(targets)
        Task {
            let ok = await action()
            busy.subtract(targets)
            guard ok else { return }
            for path in targets { resolved[path] = label }
            if let current = selected, targets.contains(current), let next = pending.first {
                selected = next
            }
        }
    }

    @ViewBuilder
    private var diffPane: some View {
        if let selected {
            if let done = resolved[selected] {
                placeholder(done == "Stashed" ? "Stashed — restore it later from Changes › Stashes" : "Reverted — this file no longer has local changes",
                            icon: done == "Stashed" ? "tray.and.arrow.down" : "arrow.uturn.backward")
            } else if change(for: selected) == nil {
                placeholder("No local changes for this file", icon: "checkmark.circle")
            } else if let entry = diffs[selected] {
                VStack(spacing: 0) {
                    fileActions(selected)
                    Divider()
                    if let diff = entry.diff {
                        DiffViewer(state: state, diff: diff, title: selected)
                            .id(selected)
                    } else {
                        placeholder("Couldn't read the diff for this file", icon: "exclamationmark.triangle")
                    }
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading diff…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            placeholder("Select a file", icon: "doc.text")
        }
    }

    private func placeholder(_ text: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.secondary.opacity(0.6))
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func change(for path: String) -> WorkingChange? {
        state.workingChanges.first { $0.path == path }
    }

    /// Selected file first, then the rest (so the +/- counts fill in).
    private func loadAll() async {
        guard let repoPath = state.currentRepo?.path else { return }
        let ordered = (selected.map { [$0] } ?? []) + paths.filter { $0 != selected }
        for path in ordered where diffs[path] == nil {
            guard let change = change(for: path) else { continue }
            let statuses = state.files.filter { $0.path == path }
            if let cached = state.workingDiffCache[state.diffCacheKey(path)], cached.statuses == statuses {
                diffs[path] = cached
                continue
            }
            let entry = await state.fetchWorkingDiff(change.primary, change: change, repoPath: repoPath)
            if Task.isCancelled { return }
            diffs[path] = entry
        }
    }
}
