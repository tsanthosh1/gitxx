import SwiftUI
import AppKit

public struct CommitDetailView: View {
    @ObservedObject var state: AppState
    @State private var showFullMessage = false

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
                                .lineLimit(showFullMessage ? nil : 2)
                                .textSelection(.enabled)
                                .help(commit.summary)

                            if !commit.body.isEmpty {
                                CommitMessageBody(text: commit.body, expanded: $showFullMessage)
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
                        .iconHover(size: 24)
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
                .themedSurface(state.accentTheme, .header)
                .onChange(of: commit.sha) { _, _ in showFullMessage = false }

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

/// Commit body capped to a few lines so the diff below keeps most of the pane.
private struct CommitMessageBody: View {
    let text: String
    @Binding var expanded: Bool

    private static let collapsedLines = 3
    private var lineCount: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }
    private var isLong: Bool { lineCount > Self.collapsedLines || text.count > 280 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if expanded {
                ScrollView {
                    message.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                message.lineLimit(Self.collapsedLines)
            }
            if isLong {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Text(expanded ? "Show less" : "Show more")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.hoverPlain)
                .pointerCursor()
            }
        }
    }

    private var message: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
