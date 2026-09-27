import SwiftUI

public struct CommitLogSidebarView: View {
    @ObservedObject var state: AppState

    var filteredCommits: [GitCommit] {
        if state.historyFilterText.trimmingCharacters(in: .whitespaces).isEmpty {
            return state.commits
        }
        return state.commits.filter {
            $0.summary.localizedCaseInsensitiveContains(state.historyFilterText) ||
            $0.authorName.localizedCaseInsensitiveContains(state.historyFilterText) ||
            $0.sha.localizedCaseInsensitiveContains(state.historyFilterText)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search commits header
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))

                TextField("Search commits (SHA, message, author)...", text: $state.historyFilterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))

                if !state.historyFilterText.isEmpty {
                    Button {
                        state.historyFilterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.02))

            Divider()

            branchBar

            Divider()

            // Commit List
            if state.commits.isEmpty && state.switchingRepoPath != nil {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading history…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredCommits.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clock")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("No commits found")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(filteredCommits, selection: Binding(
                    get: { state.selectedCommit?.id },
                    set: { newId in
                        if let match = state.commits.first(where: { $0.id == newId }) {
                            state.selectCommit(match)
                        }
                    }
                )) { commit in
                    commitRow(commit)
                        .tag(commit.id)
                        .contextMenu { CommitActionsMenu(state: state, commit: commit) }
                }
                .listStyle(.sidebar)
                .id(state.historyRef ?? "HEAD")
            }
        }
    }

    @ViewBuilder
    private func commitRow(_ commit: GitCommit) -> some View {
        let isSelected = state.selectedCommit?.id == commit.id

        VStack(alignment: .leading, spacing: 3) {
            Text(commit.summary)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(2)

            if !commit.refs.isEmpty || state.canCherryPick(commit) {
                refChips(commit, isSelected: isSelected)
            }

            HStack(spacing: 6) {
                // Author Initial Circle
                Circle()
                    .fill(avatarColor(for: commit.authorName))
                    .frame(width: 14, height: 14)
                    .overlay(
                        Text(String(commit.authorName.prefix(1)).uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    )

                Text(commit.authorName)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)

                Spacer()

                Text(commit.relativeDateString)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6))

                Text(commit.shortSha)
                    .font(.system(size: 9, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.12))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var branchBar: some View {
        let local = state.branches.filter { !$0.isRemote && !$0.isCurrent }.map(\.name)
        let remote = state.branches.filter(\.isRemote).map(\.name)
        return HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Menu {
                Button("\(state.currentBranch) (checked out)") { state.setHistoryRef(nil) }
                if !local.isEmpty {
                    Section("Local branches") {
                        ForEach(local, id: \.self) { name in Button(name) { state.setHistoryRef(name) } }
                    }
                }
                if !remote.isEmpty {
                    Section("Remote branches") {
                        ForEach(remote.prefix(60), id: \.self) { name in Button(name) { state.setHistoryRef(name) } }
                    }
                }
            } label: {
                Text(state.historyRef ?? state.currentBranch)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if state.historyRef != nil {
                Text("\(state.historyForeignCommits.count) not on \(state.currentBranch)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button {
                    state.setHistoryRef(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Back to \(state.currentBranch)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func refChips(_ commit: GitCommit, isSelected: Bool) -> some View {
        HStack(spacing: 4) {
            if state.canCherryPick(commit) {
                chip("not on \(state.currentBranch)", icon: "arrow.turn.down.right", color: .orange, isSelected: isSelected)
            }
            ForEach(commit.tagNames.prefix(3), id: \.self) { tag in
                chip(tag, icon: "tag.fill", color: .yellow, isSelected: isSelected)
            }
            ForEach(commit.branchNames.prefix(2), id: \.self) { branch in
                chip(branch, icon: "arrow.triangle.branch", color: .blue, isSelected: isSelected)
            }
        }
        .lineLimit(1)
    }

    private func chip(_ text: String, icon: String, color: Color, isSelected: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 9.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .foregroundStyle(isSelected ? Color.white : color)
        .background((isSelected ? Color.white : color).opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
    }

    private func avatarColor(for name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .indigo, .pink]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }
}

/// Actions available on a commit, shared by the log's context menu and the commit header.
struct CommitActionsMenu: View {
    @ObservedObject var state: AppState
    let commit: GitCommit

    var body: some View {
        if state.canCherryPick(commit) {
            Button("Cherry-pick onto \(state.currentBranch)") { state.cherryPick(commit) }
            Button("Apply changes without committing") { state.cherryPick(commit, noCommit: true) }
            Divider()
        }
        if state.historyRef == nil {
            Button("Revert commit") { state.revertCommit(commit) }
                .disabled(commit.isMerge)
            if state.rebaseRange(from: commit) != nil {
                Button("Interactive rebase from here…") { state.rebaseTargetCommit = commit }
            }
            Divider()
        }
        Button("Create tag…") { state.tagTargetCommit = commit }
        Button("Copy SHA") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commit.sha, forType: .string)
        }
    }
}
