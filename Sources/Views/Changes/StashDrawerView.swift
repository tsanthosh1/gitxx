import SwiftUI

/// Lists stashes with their diffs, and creates / applies / pops / drops them.
struct StashDrawerView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var includeUntracked = true
    @State private var keepIndex = false
    @State private var selectedRef: String?
    @State private var files: [FileDiff] = []
    @State private var selectedFilePath: String?
    @State private var loadingDiff = false
    @State private var confirmDrop: GitStash?

    private var selectedStash: GitStash? { state.stashes.first { $0.ref == selectedRef } }
    private var busy: Bool { state.gitOperationInFlight != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            newStashBar
            Divider()
            HStack(spacing: 0) {
                stashList.frame(width: 280)
                Divider()
                if selectedStash != nil {
                    fileList.frame(width: 230)
                    Divider()
                    DiffViewer(state: state, diff: files.first { $0.path == selectedFilePath }, title: selectedFilePath)
                } else {
                    placeholder
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 1040, idealWidth: 1180, minHeight: 620, idealHeight: 720)
        .task { await state.loadStashes(); selectFirstIfNeeded() }
        .onChange(of: state.stashes) { _, _ in
            selectFirstIfNeeded()
            Task { await loadDiff() }
        }
        .onChange(of: selectedRef) { _, _ in Task { await loadDiff() } }
        .confirmationDialog("Drop \(confirmDrop?.ref ?? "stash")?", isPresented: Binding(
            get: { confirmDrop != nil }, set: { if !$0 { confirmDrop = nil } }
        ), presenting: confirmDrop) { stash in
            Button("Drop Stash", role: .destructive) {
                Task { if await state.dropStash(stash) { selectedRef = nil } }
            }
        } message: { stash in
            Text("\u{201C}\(stash.message)\u{201D} will be deleted. This can't be undone from GitXX.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Stashes")
                .font(.system(size: 15, weight: .semibold))
            Text("\(state.stashes.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Done") { dismiss() }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var newStashBar: some View {
        HStack(spacing: 12) {
            TextField("Stash message (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createStash)
            Toggle("Include untracked", isOn: $includeUntracked)
                .toggleStyle(.checkbox)
            Toggle("Keep staged changes", isOn: $keepIndex)
                .toggleStyle(.checkbox)
                .help("Stash everything but leave the staged changes in place (--keep-index)")
            Button {
                createStash()
            } label: {
                Label("Stash Changes", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(PRActionButtonStyle(.primary(.accentColor), size: .compact))
            .disabled(busy || state.files.isEmpty)
            .help(state.files.isEmpty ? "No local changes to stash" : "git stash push")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.02))
    }

    private var stashList: some View {
        Group {
            if state.stashes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("No stashes").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Text("Stashed work shows up here.").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.stashes, selection: $selectedRef) { stash in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stash.message.isEmpty ? stash.subject : stash.message)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(stash.ref)
                                .font(.system(size: 10.5, design: .monospaced))
                            if let branch = stash.branch {
                                Label(branch, systemImage: "arrow.triangle.branch")
                                    .labelStyle(.titleAndIcon)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(PRDateFormatterHelper.shared.formatRelative(date: stash.date))
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(stash.ref)
                    .contextMenu {
                        Button("Apply") { Task { await state.applyStash(stash, pop: false) } }
                        Button("Pop") { Task { await state.applyStash(stash, pop: true) } }
                        Divider()
                        Button("Drop…", role: .destructive) { confirmDrop = stash }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var fileList: some View {
        Group {
            if loadingDiff && files.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(files, id: \.path, selection: $selectedFilePath) { file in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text((file.path as NSString).lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            let dir = (file.path as NSString).deletingLastPathComponent
                            if !dir.isEmpty {
                                Text(dir).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                        Spacer(minLength: 4)
                        Text("+\(file.additions)").foregroundStyle(.green)
                        Text("-\(file.deletions)").foregroundStyle(.red)
                    }
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tag(file.path)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var placeholder: some View {
        Text(state.stashes.isEmpty ? "" : "Select a stash to see its changes")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let stash = selectedStash {
                Text("\(files.count) file\(files.count == 1 ? "" : "s") · +\(files.reduce(0) { $0 + $1.additions }) −\(files.reduce(0) { $0 + $1.deletions })")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Drop…", role: .destructive) { confirmDrop = stash }
                    .buttonStyle(PRActionButtonStyle(.destructive, size: .compact))
                Button("Apply") { Task { await state.applyStash(stash, pop: false) } }
                    .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                    .help("Apply and keep the stash (git stash apply)")
                Button("Pop") { Task { if await state.applyStash(stash, pop: true) { selectedRef = nil } } }
                    .buttonStyle(PRActionButtonStyle(.primary(.accentColor), size: .compact))
                    .help("Apply and remove the stash (git stash pop)")
            } else {
                Spacer()
            }
        }
        .disabled(busy)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func createStash() {
        guard !busy, !state.files.isEmpty else { return }
        Task {
            if await state.createStash(message: message, includeUntracked: includeUntracked, keepIndex: keepIndex) {
                message = ""
                selectedRef = state.stashes.first?.ref
            }
        }
    }

    private func selectFirstIfNeeded() {
        if selectedStash == nil { selectedRef = state.stashes.first?.ref }
    }

    private func loadDiff() async {
        guard let stash = selectedStash else { files = []; return }
        loadingDiff = true
        let diffs = await state.stashDiff(stash)
        guard stash.ref == selectedRef else { return }
        files = diffs
        loadingDiff = false
        if !diffs.contains(where: { $0.path == selectedFilePath }) { selectedFilePath = diffs.first?.path }
    }
}
