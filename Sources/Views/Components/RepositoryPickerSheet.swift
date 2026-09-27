import SwiftUI
import AppKit

public struct RepositoryPickerSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Repository")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // List of repositories
            List {
                Section("Current") {
                    if let current = state.currentRepo {
                        repoRow(current, isCurrent: true)
                    }
                }

                if !state.recentRepos.isEmpty {
                    Section("Recent Repositories") {
                        ForEach(state.recentRepos) { repo in
                            if repo.path != state.currentRepo?.path {
                                repoRow(repo, isCurrent: false)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            // Actions: Open Local Folder
            HStack {
                Button {
                    chooseFolderAndOpen()
                } label: {
                    Label("Open Local Repository...", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 500, height: 420)
    }

    @ViewBuilder
    private func repoRow(_ repo: GitRepository, isCurrent: Bool) -> some View {
        Button {
            state.loadRepo(path: repo.path)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(repo.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)

                        if isCurrent {
                            Text("ACTIVE")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }

                    Text(repo.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }

                Spacer()

                if let remote = repo.remoteUrl {
                    Image(systemName: "globe")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(remote)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chooseFolderAndOpen() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Open Repository"

        if openPanel.runModal() == .OK, let selectedUrl = openPanel.url {
            state.loadRepo(path: selectedUrl.path)
            dismiss()
        }
    }
}
