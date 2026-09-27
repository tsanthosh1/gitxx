import SwiftUI

// MARK: - Create Tag

struct CreateTagSheet: View {
    @ObservedObject var state: AppState
    let commit: GitCommit
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var message = ""
    @State private var push = false
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Mirrors the common `git check-ref-format` rules so obvious mistakes are caught before running git.
    private var nameProblem: String? {
        let n = trimmedName
        if n.isEmpty { return nil }
        if n.contains(where: { $0.isWhitespace }) { return "Tag names can't contain spaces" }
        if n.hasPrefix("-") || n.hasPrefix(".") || n.hasSuffix(".") || n.hasSuffix("/") || n.hasSuffix(".lock") { return "Invalid tag name" }
        if n.contains("..") || n.contains("@{") || n.contains("//") { return "Invalid tag name" }
        if n.rangeOfCharacter(from: CharacterSet(charactersIn: "~^:?*[\\\u{7f}")) != nil { return "Tag names can't contain ~ ^ : ? * [ or \\" }
        if commit.tagNames.contains(n) { return "This commit already has that tag" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "tag").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                Text("Create Tag").font(.system(size: 15, weight: .semibold))
            }
            HStack(spacing: 6) {
                Text(commit.shortSha).font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                Text(commit.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            if !commit.tagNames.isEmpty {
                Text("Existing tags: \(commit.tagNames.joined(separator: ", "))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Name").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                TextField("v1.2.0", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(create)
                if let problem = nameProblem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Message (optional — makes an annotated tag)")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                TextEditor(text: $message)
                    .font(.system(size: 12.5))
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            }
            Toggle("Push tag to origin", isOn: $push)
                .toggleStyle(.checkbox)
                .disabled(state.currentRepo?.remoteUrl == nil)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PRActionButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button(push ? "Create & Push" : "Create Tag", action: create)
                    .buttonStyle(PRActionButtonStyle(.primary(.accentColor)))
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || nameProblem != nil || state.gitOperationInFlight != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { nameFocused = true }
    }

    private func create() {
        guard !trimmedName.isEmpty, nameProblem == nil else { return }
        Task {
            if await state.createTag(name: trimmedName, on: commit, message: message, push: push) { dismiss() }
        }
    }
}

// MARK: - Interactive Rebase

struct InteractiveRebaseSheet: View {
    @ObservedObject var state: AppState
    let target: GitCommit
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable, Equatable {
        var id: String { commit.sha }
        let commit: GitCommit
        var action: GitService.RebaseStep.Action = .pick
        var message: String
    }

    /// Newest first, like the log.
    @State private var items: [Item] = []
    @State private var original: [String] = []
    @State private var pushedTo: [String] = []
    @State private var running = false

    private typealias Action = GitService.RebaseStep.Action

    private var problem: String? {
        guard let oldestKept = items.last(where: { $0.action != .drop }) else { return "At least one commit must be kept" }
        if oldestKept.action == .squash || oldestKept.action == .fixup {
            return "The oldest kept commit can't be squashed — there's nothing below it to squash into"
        }
        if items.contains(where: { $0.action == .reword && $0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Reworded commits need a message"
        }
        return nil
    }

    private var hasChanges: Bool {
        items.map(\.id) != original || items.contains { $0.action != .pick }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.pull").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    Text("Interactive Rebase").font(.system(size: 15, weight: .semibold))
                    Text("\(items.count) commit\(items.count == 1 ? "" : "s") on \(state.currentBranch)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Quick actions") {
                        Button("Squash all into the oldest") {
                            for i in items.indices.dropLast() { items[i].action = .squash }
                        }
                        Button("Fixup all into the oldest") {
                            for i in items.indices.dropLast() { items[i].action = .fixup }
                        }
                        Divider()
                        Button("Reset") { reset() }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Text("Newest commit on top. Drag rows to reorder. Squash and fixup fold a commit into the one below it.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                if !pushedTo.isEmpty {
                    Label("These commits are already on \(pushedTo.prefix(3).joined(separator: ", ")). You'll need to force-push after rewriting.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }
            .padding(18)

            Divider()

            List {
                ForEach($items) { $item in
                    row($item)
                }
                .onMove { from, to in items.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 10) {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle").font(.system(size: 11.5)).foregroundStyle(.red)
                } else {
                    Text("Uncommitted changes are stashed and restored automatically. Conflicts abort the rebase.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .buttonStyle(PRActionButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Rewrite History", action: run)
                    .buttonStyle(PRActionButtonStyle(.primary(.accentColor)))
                    .disabled(problem != nil || !hasChanges || running)
            }
            .padding(14)
        }
        .frame(width: 760, height: 560)
        .onAppear(perform: reset)
        .task {
            if let oldest = items.last?.commit ?? state.rebaseRange(from: target)?.last {
                pushedTo = await state.remoteBranchesContaining(oldest)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: Binding<Item>) -> some View {
        let value = item.wrappedValue
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .padding(.top, 5)
            Picker("", selection: item.action) {
                Text("Pick").tag(Action.pick)
                Text("Reword").tag(Action.reword)
                Text("Squash ↓").tag(Action.squash)
                Text("Fixup ↓").tag(Action.fixup)
                Text("Drop").tag(Action.drop)
            }
            .labelsHidden()
            .frame(width: 104)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(value.commit.shortSha)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if value.action == .reword {
                        TextField("Commit message", text: item.message, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                    } else {
                        Text(value.commit.summary)
                            .font(.system(size: 12.5, weight: .medium))
                            .strikethrough(value.action == .drop)
                            .foregroundStyle(value.action == .drop ? .secondary : .primary)
                            .lineLimit(1)
                    }
                }
                Text(hint(value.action))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Text(value.commit.relativeDateString)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.top, 5)
        }
        .padding(.vertical, 3)
        .opacity(value.action == .drop ? 0.6 : 1)
    }

    private func hint(_ action: Action) -> String {
        switch action {
        case .pick: return "Keep as is"
        case .reword: return "Keep the changes, change the message"
        case .squash: return "Fold into the commit below, combining messages"
        case .fixup: return "Fold into the commit below, discarding this message"
        case .drop: return "Remove this commit and its changes"
        }
    }

    private func reset() {
        let range = state.rebaseRange(from: target) ?? []
        items = range.map { Item(commit: $0, message: $0.body.isEmpty ? $0.summary : $0.summary + "\n\n" + $0.body) }
        original = items.map(\.id)
    }

    private func run() {
        guard problem == nil, let oldest = state.rebaseRange(from: target)?.last else { return }
        let steps = items.reversed().map { item in
            GitService.RebaseStep(sha: item.commit.sha, action: item.action,
                                  message: item.action == .reword ? item.message : nil)
        }
        running = true
        Task {
            let ok = await state.runInteractiveRebase(from: oldest, steps: steps)
            running = false
            if ok { dismiss() }
        }
    }
}
