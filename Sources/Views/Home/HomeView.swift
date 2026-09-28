import SwiftUI
import AppKit

/// Landing page: recent repositories, and the viewer's pull requests across repositories.
struct HomeView: View {
    @ObservedObject var state: AppState
    /// The PR tab is expensive to build (tooltips and avatars on every row), so it is built once in the
    /// background and then only hidden, which makes ⌘2 / clicking the tab instant.
    @State private var pullRequestsBuilt = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                HomeRepositoriesView(state: state)
                    .opacity(state.homeTab == .repositories ? 1 : 0)
                    .allowsHitTesting(state.homeTab == .repositories)
                    .accessibilityHidden(state.homeTab != .repositories)
                if pullRequestsBuilt || state.homeTab == .pullRequests {
                    HomePullRequestsView(state: state)
                        .opacity(state.homeTab == .pullRequests ? 1 : 0)
                        .allowsHitTesting(state.homeTab == .pullRequests)
                        .accessibilityHidden(state.homeTab != .pullRequests)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            state.backfillRecentRepoRemotes()
            if state.myPullRequests.isEmpty && !state.myPullRequestsLoading { state.loadMyPullRequests() }
            try? await Task.sleep(for: .milliseconds(400))
            pullRequestsBuilt = true
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "house.fill")
                    .foregroundStyle(state.accentTheme.primaryColor)
                Text("Home")
                    .font(.system(size: 15, weight: .semibold))
            }
            .frame(width: 200, alignment: .leading)

            Spacer()

            HStack(spacing: 2) {
                ForEach(HomeTab.allCases) { tab in
                    let selected = state.homeTab == tab
                    Button {
                        state.homeTab = tab
                    } label: {
                        HStack(spacing: 6) {
                            if tab == .pullRequests {
                                PullRequestGlyph(size: 12, color: selected ? .primary : .secondary)
                            } else {
                                Image(systemName: "book.closed")
                                    .font(.system(size: 11.5))
                            }
                            Text(tab.rawValue)
                                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                            Text(tab == .repositories ? "⌘1" : "⌘2")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            if tab == .pullRequests, state.myPullRequestsOpen, !state.myPullRequests.isEmpty {
                                Text("\(state.myPullRequests.count)")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                        }
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(selected ? Color.primary.opacity(0.1) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 9))

            Spacer()

            Group {
                if let repo = state.currentRepo {
                    Button {
                        state.showHome = false
                    } label: {
                        Label("Back to \(repo.name)", systemImage: "arrow.right")
                            .lineLimit(1)
                    }
                    .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                    .help("Return to \(repo.path)")
                }
            }
            .frame(width: 200, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Repositories

private struct HomeRepositoriesView: View {
    @ObservedObject var state: AppState
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// `/tmp/x` and `/private/tmp/x` are the same checkout; list it once.
    private var uniqueRepos: [GitRepository] {
        var seen = Set<String>()
        return state.recentRepos.filter { seen.insert(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path).inserted }
    }

    private var repos: [GitRepository] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return uniqueRepos }
        return uniqueRepos.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q) }
    }

    private func openPRCount(_ repo: GitRepository) -> Int {
        guard state.myPullRequestsOpen, let parsed = state.gitHubService.parseRepoOwnerAndName(from: repo.remoteUrl) else { return 0 }
        let slug = "\(parsed.owner)/\(parsed.name)".lowercased()
        return state.myPullRequests.filter { $0.repository.lowercased() == slug }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Filter repositories", text: $query)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                            .onSubmit { if let first = repos.first { state.openRepoFromHome(first) } }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))

                    Button {
                        chooseFolderAndOpen()
                    } label: {
                        Label("Open repository…", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(PRActionButtonStyle(.primary(state.accentTheme.primaryColor)))
                }

                Text("Recent repositories")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                if repos.isEmpty {
                    Text(state.recentRepos.isEmpty ? "No repositories yet. Open one to get started." : "No repositories match “\(query)”.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(repos.enumerated()), id: \.element.path) { index, repo in
                            HomeRepositoryRow(state: state, repo: repo, openPRs: openPRCount(repo))
                            if index < repos.count - 1 { Divider().padding(.leading, 54) }
                        }
                    }
                    .background(Color.primary.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                }
            }
            .frame(maxWidth: 860)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            searchFocused = true
        }
    }

    private func chooseFolderAndOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Repository"
        if panel.runModal() == .OK, let url = panel.url {
            state.requestOpenRepo(path: url.path)
        }
    }
}

private struct HomeRepositoryRow: View {
    @ObservedObject var state: AppState
    let repo: GitRepository
    let openPRs: Int
    @State private var hovered = false

    private var slug: String? {
        guard let remote = repo.remoteUrl, remote.contains("github.com") else { return nil }
        return state.gitHubService.parseRepoOwnerAndName(from: remote).map { "\($0.owner)/\($0.name)" }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(repo.name)
                        .font(.system(size: 13.5, weight: .semibold))
                    if let slug {
                        Text(slug)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    if state.currentRepo?.path == repo.path {
                        Text("Current")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                Text((repo.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if openPRs > 0, let slug {
                Button {
                    state.homeRepoFilter = slug
                    state.homeTab = .pullRequests
                } label: {
                    HStack(spacing: 4) {
                        PullRequestGlyph(size: 11, color: .green)
                        Text("\(openPRs) open")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Show your open pull requests in \(slug)")
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary.opacity(hovered ? 1 : 0.4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(hovered ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .pointerCursor()
        .onTapGesture { state.openRepoFromHome(repo) }
        .contextMenu {
            Button("Open") { state.openRepoFromHome(repo) }
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repo.path) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(repo.path, forType: .string)
            }
            Divider()
            Button("Remove from Recent") {
                state.recentRepos.removeAll { $0.path == repo.path }
                state.saveRecentRepos()
            }
        }
    }
}

// MARK: - My pull requests

private struct HomePullRequestsView: View {
    @ObservedObject var state: AppState

    private var repoCounts: [(slug: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for item in state.myPullRequests {
            if counts[item.repository] == nil { order.append(item.repository) }
            counts[item.repository, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    private var visible: [CrossRepoPullRequest] {
        guard let filter = state.homeRepoFilter else { return state.myPullRequests }
        return state.myPullRequests.filter { $0.repository == filter }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
                .background(.regularMaterial)
            Divider()
            list
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: Binding(get: { state.myPullRequestsOpen }, set: { state.setMyPullRequestsOpen($0) })) {
                Text("Open").tag(true)
                Text("Closed").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    repoRow(slug: nil, label: "All repositories", count: state.myPullRequests.count)
                    if !repoCounts.isEmpty {
                        Text("Repositories")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                    }
                    ForEach(repoCounts, id: \.slug) { entry in
                        repoRow(slug: entry.slug, label: entry.slug, count: entry.count)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
    }

    private func repoRow(slug: String?, label: String, count: Int) -> some View {
        let selected = state.homeRepoFilter == slug
        let local = slug.map { state.localRepository(slug: $0) != nil } ?? true
        return Button {
            state.homeRepoFilter = slug
        } label: {
            HStack(spacing: 8) {
                Image(systemName: slug == nil ? "tray.full" : "book.closed")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(slug.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? label)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    if let slug {
                        Text(local ? slug : "\(slug) · not cloned")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? Color.primary.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(local ? label : "\(label) isn't cloned locally — its PRs open in the browser")
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(state.homeRepoFilter ?? "All repositories")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(visible.count) \(state.myPullRequestsOpen ? "open" : "closed")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if state.myPullRequestsLoading && !state.myPullRequests.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button {
                    state.loadMyPullRequests()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                .disabled(state.myPullRequestsLoading)
            }
            .padding(.horizontal, 18)
            .frame(height: 46)
            Divider()

            if let error = state.myPullRequestsError, state.myPullRequests.isEmpty {
                placeholder(icon: "exclamationmark.triangle", text: error)
            } else if state.myPullRequestsLoading && state.myPullRequests.isEmpty {
                VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity)
            } else if visible.isEmpty {
                placeholder(icon: "checkmark.circle", text: state.myPullRequestsOpen ? "You have no open pull requests." : "No closed pull requests.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        if state.homeRepoFilter == nil {
                            ForEach(repoCounts, id: \.slug) { entry in
                                Section {
                                    rows(state.myPullRequests.filter { $0.repository == entry.slug })
                                } header: {
                                    sectionHeader(entry.slug, count: entry.count)
                                }
                            }
                        } else {
                            rows(visible)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rows(_ items: [CrossRepoPullRequest]) -> some View {
        ForEach(items) { item in
            PRIndexRowView(pr: item.pr, accentColor: state.accentTheme.primaryColor,
                           isEnriching: state.myPullRequestsEnriching.contains(item.id)) { tab in
                state.openPullRequestFromHome(item, tab: tab)
            }
            .equatable()
            Divider().opacity(0.5)
        }
    }

    private func sectionHeader(_ slug: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "book.closed")
                .font(.system(size: 11))
            Text(slug)
                .font(.system(size: 12, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if state.localRepository(slug: slug) == nil {
                Text("not cloned · opens in browser")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 30)
        .background(.bar)
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
    }
}
