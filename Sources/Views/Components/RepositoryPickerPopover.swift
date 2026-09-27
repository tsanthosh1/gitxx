import SwiftUI
import AppKit

public struct RepositoryPickerPopover: View {
    @ObservedObject var state: AppState
    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool

    var allRepos: [GitRepository] {
        var list: [GitRepository] = []
        if let current = state.currentRepo {
            list.append(current)
        }
        for repo in state.recentRepos {
            if repo.path != state.currentRepo?.path {
                list.append(repo)
            }
        }
        return list
    }

    var filteredRepos: [GitRepository] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return allRepos
        }
        return allRepos.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))

                TextField("Filter repositories...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = filteredRepos.first(where: { $0.path != state.currentRepo?.path }) ?? filteredRepos.first {
                            open(first)
                        }
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Repositories List
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredRepos) { repo in
                        let isCurrent = repo.path == state.currentRepo?.path
                        Button {
                            open(repo)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "book.closed.fill")
                                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                                    .font(.system(size: 14))
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(repo.name)
                                            .font(.system(size: 13, weight: isCurrent ? .bold : .medium))
                                            .foregroundStyle(isCurrent ? Color.primary : Color.primary)
                                            .lineLimit(1)

                                        if isCurrent {
                                            Text("current")
                                                .font(.system(size: 9, weight: .bold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(Color.white.opacity(0.10))
                                                .foregroundStyle(Color.primary)
                                                .clipShape(Capsule())
                                        }
                                    }

                                    Text(repo.path)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                if isCurrent {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Color.primary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(isCurrent ? Color.white.opacity(0.10) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 280)

            Divider()

            // Footer - Add Repository
            HStack {
                Button {
                    chooseFolderAndOpen()
                } label: {
                    Label("Add Local Repository...", systemImage: "folder.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(height: 28)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)

                Spacer()

                Text("\(allRepos.count) repositories")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial.opacity(0.4))
        }
        .frame(width: 440)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.24), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    private func open(_ repo: GitRepository) {
        withAnimation(.easeInOut(duration: 0.12)) {
            state.showRepoPicker = false
        }
        if repo.path != state.currentRepo?.path {
            state.loadRepo(path: repo.path)
        }
    }

    private func chooseFolderAndOpen() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Open Repository"

        if openPanel.runModal() == .OK, let selectedUrl = openPanel.url {
            state.loadRepo(path: selectedUrl.path)
            withAnimation(.easeInOut(duration: 0.12)) {
                state.showRepoPicker = false
            }
        }
    }
}
