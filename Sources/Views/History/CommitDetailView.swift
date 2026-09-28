import SwiftUI
import AppKit

public struct CommitDetailView: View {
    @ObservedObject var state: AppState

    public var body: some View {
        VStack(spacing: 0) {
            if let commit = state.selectedCommit {
                // Commit Header
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(commit.summary)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.primary)

                            if !commit.body.isEmpty {
                                Text(commit.body)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)
                            }
                        }

                        Spacer()

                        if state.canCherryPick(commit) {
                            Button {
                                state.cherryPick(commit)
                            } label: {
                                Label("Cherry-pick", systemImage: "arrow.turn.down.right")
                            }
                            .buttonStyle(PRActionButtonStyle(.primary(.accentColor), size: .compact))
                            .disabled(state.gitOperationInFlight != nil)
                            .help("Apply this commit on top of \(state.currentBranch)")
                        }

                        Button {
                            state.tagTargetCommit = commit
                        } label: {
                            Label("Tag", systemImage: "tag")
                        }
                        .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                        .help("Create a tag on this commit")

                        Menu {
                            CommitActionsMenu(state: state, commit: commit)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More commit actions")

                        // Copy SHA Button
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.sha, forType: .string)
                            state.showToast("Copied commit SHA to clipboard", type: .success)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text(commit.shortSha)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Copy full SHA: \(commit.sha)")
                    }

                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            CommitAuthorAvatar(state: state, commit: commit, size: 20)
                            Text(commit.authorName)
                                .font(.system(size: 12, weight: .medium))
                            if !commit.authorEmail.isEmpty {
                                Text("<\(commit.authorEmail)>")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("•")
                            .foregroundStyle(.tertiary)

                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(commit.authorDate, style: .date)
                                .font(.system(size: 11))
                            Text(commit.authorDate, style: .time)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                }
                .padding(14)
                .background(.ultraThinMaterial)

                Divider()

                // Diff Viewer for Commit
                DiffViewer(state: state, diff: state.commitDiff, title: "Changes in \(commit.shortSha)")
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clock")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("Select a commit from the log to view changes")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
