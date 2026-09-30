import SwiftUI
import AppKit

public struct RepositoryPickerPopover: View {
    @ObservedObject var state: AppState
    @State private var searchText: String = ""
    @State private var highlighted = 0

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

                PaletteSearchField(
                    text: $searchText,
                    placeholder: "Filter repositories...",
                    onSubmit: {
                        let list = filteredRepos
                        if list.indices.contains(highlighted) { open(list[highlighted]) }
                    },
                    onDownArrow: { move(1) },
                    onUpArrow: { move(-1) },
                    onEscape: {
                        if searchText.isEmpty { state.showRepoPicker = false } else { searchText = "" }
                    },
                    fontSize: 13
                )
                .frame(height: 20)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.hoverPlain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Repositories List
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(filteredRepos.enumerated()), id: \.element.id) { index, repo in
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
                                } else {
                                    Color.clear.frame(width: 24, height: 24)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverPlain)
                        .overlay(alignment: .trailing) {
                            if !isCurrent && index == highlighted {
                                Button { remove(repo) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10.5, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.icon(size: 24))
                                .help("Remove \(repo.name) from this list (the folder isn't touched)")
                                .padding(.trailing, 8)
                            }
                        }
                        .background(index == highlighted ? Color.primary.opacity(0.18) : (isCurrent ? Color.white.opacity(0.10) : Color.clear))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onHover { if $0 { highlighted = index } }
                        .contextMenu {
                            Button("Open") { open(repo) }
                            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.path) }
                            if !isCurrent {
                                Divider()
                                Button("Remove from List") { remove(repo) }
                            }
                        }
                        .id(repo.id)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 280)
            .onChange(of: highlighted) { _, index in
                let list = filteredRepos
                guard list.indices.contains(index) else { return }
                proxy.scrollTo(list[index].id, anchor: nil)
            }
            }
            .onChange(of: searchText) { _, _ in resetHighlight() }
            .onAppear { resetHighlight() }

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
            .background(Color.primary.opacity(0.04))
        }
        .frame(width: 440)
        .themedSurface(state.accentTheme, .elevated)
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
    }

    private func move(_ delta: Int) {
        let count = filteredRepos.count
        guard count > 0 else { return }
        highlighted = min(max(highlighted + delta, 0), count - 1)
    }

    /// Starts on the first repository other than the open one, so Return switches to it.
    private func resetHighlight() {
        highlighted = filteredRepos.firstIndex(where: { $0.path != state.currentRepo?.path }) ?? 0
    }

    private func remove(_ repo: GitRepository) {
        withAnimation(.easeOut(duration: 0.15)) {
            state.recentRepos.removeAll { $0.path == repo.path }
        }
        state.saveRecentRepos()
        highlighted = min(highlighted, max(filteredRepos.count - 1, 0))
        state.showToast("Removed \(repo.name) from the list", type: .info)
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
