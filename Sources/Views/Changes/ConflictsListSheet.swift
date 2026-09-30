import SwiftUI

public struct ConflictResolverRequest: Identifiable {
    public let id = UUID()
    /// Opens straight into this file's merge window.
    public let path: String?
}

/// IntelliJ's "Conflicts" dialog: every unmerged file with Accept Yours / Accept Theirs / Merge…, then continue or abort.
struct ConflictsListSheet: View {
    @ObservedObject var state: AppState
    let request: ConflictResolverRequest
    @Environment(\.dismiss) private var dismiss

    struct Entry: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let code: String

        var description: String {
            switch code {
            case "UU": return "Both modified"
            case "AA": return "Both added"
            case "DU": return "Deleted by yours"
            case "UD": return "Deleted by theirs"
            case "AU": return "Added by yours"
            case "UA": return "Added by theirs"
            case "DD": return "Both deleted"
            default: return "Conflict"
            }
        }
        var canMerge: Bool { code == "UU" || code == "AA" }
    }

    @State private var entries: [Entry] = []
    @State private var sides: ConflictSides?
    @State private var loading = true
    @State private var selection: String?
    @State private var merging: String?
    @State private var busy = false
    @State private var confirmAbort = false
    @State private var openedInitial = false

    private var repo: String? { state.currentRepo?.path }
    private var accent: Color { state.accentTheme.primaryColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 900, height: 480)
        .task { await reload() }
        .onChange(of: merging) { _, path in
            guard let path, let repo, let sides else { return }
            merging = nil
            ConflictResolverWindow.show(state: state, repo: repo, path: path, sides: sides) { changed in
                if changed { Task { await reload() } }
            }
        }
        .alert("Abort the \(sides?.operation.title.lowercased() ?? "merge")?", isPresented: $confirmAbort) {
            Button("Abort", role: .destructive) { Task { await abort() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything goes back to how it was before it started. Resolutions made so far are discarded.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(entries.isEmpty && !loading ? Color.green : Color.orange, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(entries.isEmpty && !loading ? "All conflicts resolved" : "Resolve conflicts")
                    .font(.system(size: 15, weight: .semibold))
                if let sides {
                    Text("\(sides.operation.title) in progress · \(sides.oursTitle): \(sides.oursDetail) · \(sides.theirsTitle): \(sides.theirsDetail)")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.icon(size: 26)).help("Reload")
        }
        .padding(16)
    }

    @ViewBuilder
    private var list: some View {
        if loading && entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 30)).foregroundStyle(.green)
                Text(sides?.operation.verb != nil
                     ? "Nothing left to resolve. Continue the \(sides?.operation.title.lowercased() ?? "merge") to finish."
                     : "Nothing left to resolve.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    HStack {
                        Text("FILE").frame(maxWidth: .infinity, alignment: .leading)
                        Text("STATUS").frame(width: 130, alignment: .leading)
                        Color.clear.frame(width: 430)
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
                    ForEach(entries) { entry in row(entry) }
                }
                .padding(10)
            }
        }
    }

    private func row(_ entry: Entry) -> some View {
        let selected = selection == entry.path
        return HStack(spacing: 8) {
            Image(systemName: "doc.text").font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text((entry.path as NSString).lastPathComponent).font(.system(size: 12.5, weight: .medium))
                let dir = (entry.path as NSString).deletingLastPathComponent
                if !dir.isEmpty {
                    Text(dir).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.description)
                .font(.system(size: 11.5))
                .foregroundStyle(.orange)
                .frame(width: 130, alignment: .leading)
            HStack(spacing: 6) {
                Button("Accept \(sides?.oursTitle ?? "Yours")") { Task { await accept(entry, ours: true) } }
                    .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                    .fixedSize()
                Button("Accept \(sides?.theirsTitle ?? "Theirs")") { Task { await accept(entry, ours: false) } }
                    .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                    .fixedSize()
                Button { merging = entry.path } label: {
                    Label("Open in Merge Tool", systemImage: "rectangle.split.3x1")
                }
                .buttonStyle(PRActionButtonStyle(.primary(accent), size: .compact))
                .fixedSize()
                .disabled(!entry.canMerge)
                .help(entry.canMerge ? "Resolve this file in the three-pane merge window" : "One side deleted this file; accept a side instead")
            }
            .frame(width: 430, alignment: .trailing)
            .disabled(busy)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? accent.opacity(0.14) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if entry.canMerge { merging = entry.path } }
        .onTapGesture { selection = entry.path }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if sides != nil {
                Button("Abort \(sides?.operation.title ?? "Merge")", role: .destructive) { confirmAbort = true }
                    .buttonStyle(PRActionButtonStyle(.secondary))
                    .disabled(busy)
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(PRActionButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
            if entries.isEmpty, let op = sides?.operation, op.verb != nil {
                Button {
                    Task { await continueOperation() }
                } label: {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small) }
                        Text("Continue \(op.title)")
                        KeyCap("⌘"); KeyCap("↩")
                    }
                }
                .buttonStyle(PRActionButtonStyle(.primary(accent)))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(busy || loading)
            } else if let first = entries.first(where: \.canMerge) {
                Button {
                    merging = selection.flatMap { s in entries.first { $0.path == s && $0.canMerge }?.path } ?? first.path
                } label: {
                    HStack(spacing: 6) { Text("Open in Merge Tool"); KeyCap("⌘"); KeyCap("↩") }
                }
                .buttonStyle(PRActionButtonStyle(.primary(accent)))
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
    }

    // MARK: Actions

    private func reload() async {
        guard let repo else { return }
        loading = true
        async let status = GitService.shared.execute(arguments: ["status", "--porcelain=v1", "-uno"], in: repo)
        async let loadedSides = ConflictMerge.sides(repo: repo)
        let unmerged: Set<String> = ["UU", "AA", "DU", "UD", "AU", "UA", "DD"]
        entries = ((try? await status)?.stdout ?? "")
            .components(separatedBy: "\n")
            .filter { $0.count > 3 && unmerged.contains(String($0.prefix(2))) }
            .map { Entry(path: Self.unquote(String($0.dropFirst(3))), code: String($0.prefix(2))) }
        sides = await loadedSides
        loading = false
        if !openedInitial {
            openedInitial = true
            if let path = request.path, entries.contains(where: { $0.path == path }) { merging = path }
        }
        state.refreshAfterExternalChange()
    }

    private static func unquote(_ path: String) -> String {
        guard path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 else { return path }
        return String(path.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func accept(_ entry: Entry, ours: Bool) async {
        guard let repo else { return }
        busy = true
        defer { busy = false }
        do {
            try await ConflictMerge.accept(repo: repo, path: entry.path, ours: ours)
            await reload()
        } catch {
            state.showToast("Couldn't resolve \(entry.path): \(error.localizedDescription)", type: .error)
        }
    }

    private func abort() async {
        guard let repo, let op = sides?.operation else { return }
        busy = true
        defer { busy = false }
        do {
            try await ConflictMerge.abort(repo: repo, operation: op)
            state.pendingPRMergePush = nil
            state.showToast("\(op.title) aborted", type: .info)
            state.refreshAfterExternalChange()
            dismiss()
        } catch {
            state.showToast("Couldn't abort: \(error.localizedDescription)", type: .error)
        }
    }

    private func continueOperation() async {
        guard let repo else { return }
        busy = true
        defer { busy = false }
        guard await state.continueOperationInProgress() else { return }
        let next = await ConflictMerge.inProgress(repo: repo)
        await reload()
        if entries.isEmpty {
            dismiss()
        } else if let next {
            state.showToast("\(next.title) stopped at the next conflict", type: .info)
        }
    }
}
