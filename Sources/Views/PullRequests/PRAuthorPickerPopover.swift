import SwiftUI

/// Searchable author filter for the PR list, with "Me" pinned at the top.
struct PRAuthorPickerPopover: View {
    @ObservedObject var state: AppState
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var remote: [GitHubUserSuggestion] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    private struct Author: Identifiable {
        var id: String { login.lowercased() }
        let login: String
        let avatarUrl: String?
        let count: Int
    }

    private var authors: [Author] {
        var byLogin: [String: Author] = [:]
        for pr in state.pullRequests {
            let key = pr.authorName.lowercased()
            let existing = byLogin[key]
            byLogin[key] = Author(login: pr.authorName, avatarUrl: existing?.avatarUrl ?? pr.authorAvatarUrl, count: (existing?.count ?? 0) + 1)
        }
        let me = state.gitHubViewerLogin?.lowercased()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return byLogin.values
            .filter { $0.id != me }
            .filter { trimmed.isEmpty || $0.login.localizedCaseInsensitiveContains(trimmed) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending }
    }

    /// Repo members matching the query that aren't already listed from the loaded PRs.
    private var remoteMatches: [GitHubUserSuggestion] {
        let listed = Set(authors.map(\.id))
        let me = state.gitHubViewerLogin?.lowercased()
        return remote.filter { !listed.contains($0.id) && $0.id != me }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter authors", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        if let first = authors.first?.login ?? remoteMatches.first?.login { choose(first) }
                    }
                if searching {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty {
                        row(title: "Any author", subtitle: nil, avatar: nil, login: nil, icon: "person.2")
                        if let me = state.gitHubViewerLogin {
                            row(title: "Me", subtitle: me, avatar: state.pullRequests.first(where: { $0.authorName.caseInsensitiveCompare(me) == .orderedSame })?.authorAvatarUrl, login: me, icon: nil)
                        }
                        Divider().padding(.vertical, 4)
                    }
                    ForEach(authors) { author in
                        row(title: author.login, subtitle: "\(author.count) PR\(author.count == 1 ? "" : "s")", avatar: author.avatarUrl, login: author.login, icon: nil)
                    }
                    if !remoteMatches.isEmpty {
                        if !authors.isEmpty { Divider().padding(.vertical, 4) }
                        Text("People in this repository")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 2)
                        ForEach(remoteMatches) { user in
                            row(title: user.login, subtitle: user.name, avatar: user.avatarUrl, login: user.login, icon: nil)
                        }
                    }
                    if authors.isEmpty && remoteMatches.isEmpty && !query.isEmpty && !searching {
                        Text("No one matches “\(query)”")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
            // A fixed height keeps the popover from resizing (and clipping rows) as remote results arrive.
            .frame(height: 340)
        }
        .frame(width: 300)
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            focused = true
        }
        .task(id: query) { await searchRemote() }
    }

    private func row(title: String, subtitle: String?, avatar: String?, login: String?, icon: String?) -> some View {
        let isSelected = login.map { state.prAuthorFilter?.caseInsensitiveCompare($0) == .orderedSame } ?? (state.prAuthorFilter == nil)
        return Button {
            choose(login)
        } label: {
            HStack(spacing: 9) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Circle())
                } else {
                    PRAvatarView(authorName: login ?? title, avatarUrl: avatar, size: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(isSelected ? Color.primary.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
    }

    private func searchRemote() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let ctx = state.prRepoContext() else {
            remote = []
            searching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        let results = try? await state.gitHubService.searchMentionableUsers(owner: ctx.owner, repo: ctx.repo, query: trimmed, token: ctx.token)
        guard !Task.isCancelled else { return }
        remote = results ?? []
        searching = false
    }

    private func choose(_ login: String?) {
        if let login, let avatar = (authors.first { $0.id == login.lowercased() }?.avatarUrl
                                    ?? remote.first { $0.id == login.lowercased() }?.avatarUrl) {
            PRAuthorAvatars.remember(login: login, url: avatar)
        }
        isPresented = false
        state.setPRAuthorFilter(login)
    }
}

/// Avatar URLs of authors picked in the filter, so the filter button can show them before their PRs load.
enum PRAuthorAvatars {
    @MainActor private static var urls: [String: String] = [:]

    @MainActor static func remember(login: String, url: String) { urls[login.lowercased()] = url }

    @MainActor static func url(for login: String) -> String {
        urls[login.lowercased()] ?? "https://github.com/\(login).png?size=64"
    }
}
