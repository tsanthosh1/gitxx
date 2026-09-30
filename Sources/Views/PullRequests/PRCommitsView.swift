import SwiftUI
import AppKit

/// Commits tab: the PR's commits grouped by day on the left, the selected commit's message and diff on the right.
struct PRCommitsView: View {
    @ObservedObject var state: AppState
    let pr: PullRequest

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private var selectedCommit: PRCommit? {
        state.prCommits.first { $0.sha == state.selectedPRCommitSHA } ?? state.prCommits.last
    }

    private var groupedByDay: [(day: Date, commits: [PRCommit])] {
        let calendar = Calendar.current
        var groups: [(day: Date, commits: [PRCommit])] = []
        for commit in state.prCommits {
            let day = calendar.startOfDay(for: commit.date)
            if let last = groups.last, last.day == day {
                groups[groups.count - 1].commits.append(commit)
            } else {
                groups.append((day, [commit]))
            }
        }
        return groups
    }

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 240, idealWidth: 360, maxWidth: 520)
            detailPane
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if state.prCommits.isEmpty && !state.isLoadingPRCommits { state.loadPRCommits(for: pr) }
        }
    }

    // MARK: - List

    @ViewBuilder
    private var listPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(state.prCommits.isEmpty ? "Commits" : "\(state.prCommits.count) commit\(state.prCommits.count == 1 ? "" : "s")")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(pr.headBranch) → \(pr.baseBranch)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    state.loadPRCommits(for: pr)
                } label: {
                    PRActionLabel("", systemImage: "arrow.clockwise", isRunning: state.isLoadingPRCommits)
                }
                .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                .help("Reload commits")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            Divider()

            if state.prCommits.isEmpty {
                VStack(spacing: 8) {
                    if state.isLoadingPRCommits {
                        ProgressView().controlSize(.small)
                        Text("Loading commits…").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text(state.hasConfiguredGitHubToken ? "No commits found" : "Connect GitHub to list commits")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { selectedCommit?.sha }, set: { state.selectedPRCommitSHA = $0 })) {
                    ForEach(groupedByDay, id: \.day) { group in
                        Section("Commits on \(Self.dayFormatter.string(from: group.day))") {
                            ForEach(group.commits) { commit in
                                CommitListRow(commit: commit)
                                    .tag(commit.sha)
                                    .contextMenu { commitMenu(commit) }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .themedSurface(state.accentTheme, .sidebar)
    }

    @ViewBuilder
    private func commitMenu(_ commit: PRCommit) -> some View {
        Button("Copy SHA") { copy(commit.sha, label: "SHA") }
        Button("Copy Message") { copy(commit.message, label: "message") }
        if let url = commit.htmlUrl.flatMap(URL.init(string:)) {
            Divider()
            Button("Open on GitHub") { LinkRouter.open(url) }
        }
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.showToast("Copied \(label)", type: .success)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let commit = selectedCommit {
            VStack(spacing: 0) {
                commitHeader(commit)
                Divider()
                commitFiles(commit)
            }
            .task(id: commit.sha) { await state.loadCommitFiles(sha: commit.sha) }
        } else {
            Text(state.isLoadingPRCommits ? "" : "Select a commit")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func commitHeader(_ commit: PRCommit) -> some View {
        let files = state.prCommitFiles[commit.sha]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(commit.summary)
                    .font(.system(size: 15, weight: .semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    copy(commit.sha, label: "SHA")
                } label: {
                    Label(commit.shortSha, systemImage: "doc.on.doc")
                        .font(.system(size: 11.5, design: .monospaced))
                }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                .help("Copy full SHA")
                if let url = commit.htmlUrl.flatMap(URL.init(string:)) {
                    Button {
                        LinkRouter.open(url)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                    .help("Open commit on GitHub")
                }
            }
            if !commit.body.isEmpty {
                ScrollView {
                    Text(commit.body)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                PRAvatarView(authorName: commit.authorLogin ?? commit.authorName, avatarUrl: commit.authorAvatarUrl, size: 18)
                Text(commit.authorLogin ?? commit.authorName)
                    .font(.system(size: 12, weight: .semibold))
                Text("committed \(CommitListRow.relative.localizedString(for: commit.date, relativeTo: Date()))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if let files {
                    let adds = files.reduce(0) { $0 + $1.additions }
                    let dels = files.reduce(0) { $0 + $1.deletions }
                    Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Text("+\(adds)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.green)
                    Text("−\(dels)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.red)
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func commitFiles(_ commit: PRCommit) -> some View {
        if let files = state.prCommitFiles[commit.sha] {
            if files.isEmpty {
                Text("This commit has no file changes")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PRFilesWebView(
                    files: files,
                    mode: state.diffMode,
                    viewedPaths: [],
                    threadsPayload: "{}",
                    filter: "",
                    selectedPath: nil,
                    canOpenLocally: state.currentRepo?.path != nil,
                    prURL: pr.url,
                    allowComments: false,
                    onOpenInEditor: { path in
                        guard let repoPath = state.currentRepo?.path else { return }
                        LinkRouter.open(URL(fileURLWithPath: (repoPath as NSString).appendingPathComponent(path)))
                    },
                    onFileContent: { path in
                        try await state.prFileContent(path: path, ref: commit.sha)
                    }
                )
                .id(commit.sha)
            }
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading changes…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CommitListRow: View {
    let commit: PRCommit

    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PRAvatarView(authorName: commit.authorLogin ?? commit.authorName, avatarUrl: commit.authorAvatarUrl, size: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.summary)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(commit.authorLogin ?? commit.authorName).fontWeight(.medium)
                    Text("· \(Self.relative.localizedString(for: commit.date, relativeTo: Date()))")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(commit.shortSha)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(.vertical, 3)
        .help(commit.message)
    }
}
