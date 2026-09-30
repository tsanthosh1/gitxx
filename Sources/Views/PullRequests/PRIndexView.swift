import SwiftUI
import AppKit

public enum PRSortOption: String, CaseIterable, Identifiable {
    case recentlyUpdated = "Recently updated"
    case newest = "Newest"
    case oldest = "Oldest"
    case mostCommented = "Most commented"

    public var id: String { rawValue }
}

public struct PRIndexView: View {
    @ObservedObject var state: AppState
    @AppStorage("gitxx_pr_sort") private var selectedSortRaw: String = PRSortOption.recentlyUpdated.rawValue
    @State private var showAuthorPicker = false
    @FocusState private var searchFocused: Bool

    private var selectedSort: PRSortOption {
        get { PRSortOption(rawValue: selectedSortRaw) ?? .recentlyUpdated }
    }

    private var selectedAuthor: String? {
        state.prAuthorFilter
    }

    // MARK: - Computed Properties & Filtering

    /// Count shown on a quick-filter tab; "–" while an author-scoped count is still loading.
    private func tabCount(_ filter: PRFilter) -> String {
        if let author = state.prAuthorFilter, !author.isEmpty, filter != .myOpen, filter != .myClosed {
            if state.prAuthorTabCountsLogin == author, let count = state.prAuthorTabCounts[filter] { return "\(count)" }
            if state.prFilter == filter, !state.isLoadingPRs { return "\(state.prListTotalCount ?? state.pullRequests.count)" }
            return "–"
        }
        return "\(state.prTabCounts[filter] ?? (state.prFilter == filter ? state.pullRequests.count : 0))"
    }

    private var availableAuthors: [String] {
        Array(Set(state.pullRequests.map { $0.authorName })).sorted()
    }

    private var filteredPRs: [PullRequest] {
        var list = state.pullRequests

        // Local filtering only used as fallback if explicit demo mode is active
        if state.hasExplicitlyLoadedDemoPRs {
            switch state.prFilter {
            case .myOpen:
                list = list.filter { ($0.state == .open || $0.state == .draft) && state.isCurrentUserAuthor(of: $0) }
            case .myClosed:
                list = list.filter { ($0.state == .merged || $0.state == .closed) && state.isCurrentUserAuthor(of: $0) }
            case .open:
                list = list.filter { $0.state == .open || $0.state == .draft }
            case .closed:
                list = list.filter { $0.state == .merged || $0.state == .closed }
            case .reviewNeeded:
                list = list.filter { $0.reviewVerdict == .pending || $0.reviewVerdict == .changesRequested }
            case .all:
                break
            }
        }

        // 2. Filter by Author Dropdown
        if let author = selectedAuthor, !author.isEmpty {
            list = list.filter { $0.authorName.localizedCaseInsensitiveCompare(author) == .orderedSame }
        }

        // 3. Filter by Search Query (tab / author qualifiers are applied server-side)
        let query = PRSearchQuery.freeText(state.prSearchText).lowercased()
        if !query.isEmpty {
            list = list.filter { pr in
                if query.hasPrefix("#") {
                    let numStr = String(query.dropFirst())
                    return "\(pr.number)".contains(numStr)
                }
                if let num = Int(query), pr.number == num {
                    return true
                }
                if query.contains("is:merged") && pr.state != .merged { return false }
                if query.contains("is:draft") && !pr.isDraft { return false }

                let cleanQuery = query
                    .replacingOccurrences(of: "is:merged", with: "")
                    .replacingOccurrences(of: "is:draft", with: "")
                    .trimmingCharacters(in: .whitespaces)

                if cleanQuery.isEmpty { return true }

                return pr.title.lowercased().contains(cleanQuery) ||
                       pr.authorName.lowercased().contains(cleanQuery) ||
                       pr.headBranch.lowercased().contains(cleanQuery) ||
                       pr.baseBranch.lowercased().contains(cleanQuery) ||
                       "\(pr.number)".contains(cleanQuery)
            }
        }

        // 4. Sorting
        switch selectedSort {
        case .recentlyUpdated:
            break // GitHub already returns PRs sorted by last update
        case .newest:
            list.sort { $0.number > $1.number }
        case .oldest:
            list.sort { $0.number < $1.number }
        case .mostCommented:
            list.sort { $0.commentsCount > $1.commentsCount }
        }

        return list
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Controls Bar (Header + Search + Actions)
            topControlsBar
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            // Main Content Area
            if state.isLoadingPRs {
                loadingView
            } else if let error = state.prFetchError {
                errorView(error: error)
            } else if !state.hasConfiguredGitHubToken && !state.hasExplicitlyLoadedDemoPRs {
                tokenNotConfiguredView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Demo banner if active
                        if state.hasExplicitlyLoadedDemoPRs {
                            demoModeBanner
                        }

                        // GitHub-Style Table Container
                        pullRequestsTable
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
        }
        .themedSurface(state.accentTheme, .sidebar)
    }

    // MARK: - Top Controls Bar

    private var topControlsBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Row 1: title, repository and primary actions
            HStack(alignment: .center, spacing: 10) {
                PullRequestGlyph(size: 18, color: Color.primary)

                Text("Pull requests")
                    .font(.system(size: 19, weight: .bold))
                    .fixedSize()

                if let repo = state.currentRepo {
                    let slug = state.gitHubService.parseRepoOwnerAndName(from: repo.remoteUrl).map { "\($0.owner)/\($0.name)" } ?? repo.name
                    Text(slug)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(slug)
                }

                Spacer(minLength: 12)

                Button {
                    state.loadPRs()
                } label: {
                    PRActionLabel("Refresh", systemImage: "arrow.clockwise", isRunning: state.isLoadingPRs)
                }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .large))
                .help("Fetch the latest pull requests from GitHub (⌘R)")

                Button {
                    state.showCreatePRSheet = true
                } label: {
                    Label("New pull request", systemImage: "plus")
                }
                .buttonStyle(PRActionButtonStyle(.primary(Color(red: 35/255, green: 134/255, blue: 54/255)), size: .large))
                .help("Create a new pull request")
            }

            // Row 2: search + author + sort
            HStack(spacing: 8) {
                searchField
                authorFilterButton
                labelFilterMenu
                sortMenu
            }
        }
        .onAppear {
            state.ensureGitHubViewerLogin()
            syncSearchWithScope()
        }
        .onChange(of: state.prFilter) { _, _ in syncSearchWithScope() }
        .onChange(of: state.prAuthorFilter) { _, _ in syncSearchWithScope() }
    }

    /// Keeps the qualifier prefix of the search text in step with the selected tab and author.
    private func syncSearchWithScope() {
        let composed = PRSearchQuery.compose(filter: state.prFilter, author: state.prAuthorFilter,
                                             freeText: PRSearchQuery.freeText(state.prSearchText))
        if composed != state.prSearchText { state.prSearchText = composed }
    }

    /// Return applies typed qualifiers (e.g. `is:closed`, `author:octocat`) to the tab and author controls.
    private func applySearchScope() {
        let scope = PRSearchQuery.scope(of: state.prSearchText)
        if scope.filter != state.prFilter { state.setPRFilter(scope.filter) }
        let isMyTab = scope.filter == .myOpen || scope.filter == .myClosed
        if !isMyTab, scope.author?.lowercased() != state.prAuthorFilter?.lowercased() {
            state.setPRAuthorFilter(scope.author)
        }
        syncSearchWithScope()
    }

    private var hasFreeSearchText: Bool {
        !PRSearchQuery.freeText(state.prSearchText).isEmpty
    }

    private func clearFreeSearchText() {
        state.prSearchText = PRSearchQuery.compose(filter: state.prFilter, author: state.prAuthorFilter, freeText: "")
    }

    private static let filterControlHeight: CGFloat = 36

    private func filterControlBackground(active: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(active ? 0.12 : 0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(active ? 0.28 : 0.12), lineWidth: 1)
            )
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            TextField("Search title, #number, branch or author   ·   is:draft  is:open  is:merged", text: $state.prSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit { applySearchScope() }
                .onExitCommand { clearFreeSearchText(); searchFocused = false }

            if hasFreeSearchText {
                Button {
                    clearFreeSearchText()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.hoverPlain)
                .help("Clear search")
            } else {
                Text("⌘F")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.filterControlHeight)
        .frame(maxWidth: .infinity)
        .background(filterControlBackground(active: searchFocused))
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = true }
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        )
    }

    private var authorFilterButton: some View {
        let author = selectedAuthor
        let isMe = author != nil && author?.caseInsensitiveCompare(state.gitHubViewerLogin ?? "") == .orderedSame
        let avatar = author.map { a in
            state.pullRequests.first(where: { $0.authorName.caseInsensitiveCompare(a) == .orderedSame })?.authorAvatarUrl
                ?? PRAuthorAvatars.url(for: a)
        }
        return Button {
            showAuthorPicker.toggle()
        } label: {
            HStack(spacing: 7) {
                if let author {
                    PRAvatarView(authorName: author, avatarUrl: avatar, size: 18)
                    Text(isMe ? "Me" : author)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Image(systemName: "person.2")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Any author")
                        .font(.system(size: 12.5, weight: .medium))
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .frame(width: 190, height: Self.filterControlHeight)
            .background(filterControlBackground(active: author != nil))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .help(author.map { "Showing pull requests by \($0)" } ?? "Filter by author")
        .popover(isPresented: $showAuthorPicker, arrowEdge: .bottom) {
            PRAuthorPickerPopover(state: state, isPresented: $showAuthorPicker)
        }
    }

    /// Repository labels, plus any seen on loaded PRs before the label list arrives.
    private var knownLabels: [PRLabel] {
        var byName: [String: PRLabel] = [:]
        for pr in state.pullRequests { for l in pr.labels ?? [] { byName[l.name] = l } }
        for l in state.repoLabels { byName[l.name] = l }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var labelFilterMenu: some View {
        let selected = state.prLabelFilter
        let selectedLabel = selected.flatMap { name in knownLabels.first { $0.name == name } ?? PRLabel(name: name, color: "8b949e") }
        return Menu {
            Button("Any label") { state.setPRLabelFilter(nil) }
            Divider()
            ForEach(knownLabels, id: \.name) { label in
                Button {
                    state.setPRLabelFilter(label.name)
                } label: {
                    if label.name == selected { Label(label.name, systemImage: "checkmark") } else { Text(label.name) }
                }
            }
        } label: {
            HStack(spacing: 7) {
                if let selectedLabel {
                    Circle().fill(selectedLabel.swiftUIColor).frame(width: 8, height: 8)
                    Text(selectedLabel.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Image(systemName: "tag")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Text("Any label")
                        .font(.system(size: 12.5, weight: .medium))
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .frame(width: 170, height: Self.filterControlHeight)
            .background(filterControlBackground(active: selected != nil))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(selected.map { "Showing pull requests labelled \($0)" } ?? "Filter by label")
        .onAppear { state.loadRepoLabels() }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $selectedSortRaw) {
                ForEach(PRSortOption.allCases) { option in
                    Text(option.rawValue).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
            .onChange(of: selectedSortRaw) { _, _ in state.loadPRs() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text(selectedSort.rawValue)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .frame(width: 190, height: Self.filterControlHeight)
            .background(filterControlBackground())
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.hoverPlain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort pull requests")
    }

    // MARK: - GitHub-Style Pull Requests Table

    private var pullRequestsTable: some View {
        VStack(spacing: 0) {
            // Table Header Bar
            tableHeaderBar

            Divider()

            // Rows or Empty Filter Result
            if filteredPRs.isEmpty {
                emptyFilteredView
            } else {
                LazyVStack(spacing: 0) {
                    let rows = filteredPRs
                    ForEach(rows) { pr in
                        PRIndexRowView(
                            pr: pr,
                            accentColor: state.accentTheme.primaryColor,
                            isEnriching: state.prsAwaitingEnrichment.contains(pr.number),
                            onOpen: { tab in
                                openPR(pr, tab: tab)
                            }
                        )
                        .equatable()
                        .onAppear {
                            if pr.id == rows.last?.id { state.loadMorePRs() }
                        }
                        Divider()
                            .opacity(0.5)
                    }
                    if state.prListHasMore {
                        HStack(spacing: 8) {
                            if state.isLoadingMorePRs {
                                ProgressView().controlSize(.small)
                                Text("Loading more pull requests…")
                            } else {
                                Button("Load more") { state.loadMorePRs() }
                                    .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .onAppear { state.loadMorePRs() }
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Table Header Bar (Tabs)

    private func filterTab(_ filter: PRFilter, label: String, systemImage: String?) -> some View {
        let selected = state.prFilter == filter
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                state.setPRFilter(filter)
            }
        } label: {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                } else {
                    PullRequestGlyph(size: 13, color: selected ? Color.primary : Color.secondary)
                }
                Text(label)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                Capsule().fill(selected ? Color.primary.opacity(0.10) : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(selected ? Color.primary.opacity(0.16) : Color.clear, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverPlain)
        .pointerCursor()
    }

    private var tableHeaderBar: some View {
        HStack(spacing: 6) {
            filterTab(.myOpen, label: "\(tabCount(.myOpen)) My Open", systemImage: "person.fill")
            filterTab(.myClosed, label: "\(tabCount(.myClosed)) My Closed", systemImage: "person.fill.checkmark")
            filterTab(.open, label: "\(tabCount(.open)) Open", systemImage: nil)
            filterTab(.closed, label: "\(tabCount(.closed)) Closed", systemImage: "checkmark")
            filterTab(.reviewNeeded, label: "\(tabCount(.reviewNeeded)) Review needed", systemImage: "person.crop.circle.badge.exclamationmark")
            filterTab(.all, label: "All (\(tabCount(.all)))", systemImage: "tray.2")

            Spacer()

            let totalForTab = state.prListTotalCount ?? state.prTabCounts[state.prFilter] ?? state.pullRequests.count
            if totalForTab > filteredPRs.count {
                Text("Showing \(filteredPRs.count) of \(totalForTab)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(filteredPRs.count) pull requests")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
    }

    private func openPR(_ pr: PullRequest, tab: PRDetailTab) {
        withAnimation(.easeInOut(duration: 0.15)) {
            state.selectedPR = pr
            state.selectedPRTab = tab
        }
    }


    // MARK: - State Banners & Empty Views

    private var demoModeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(state.accentTheme.primaryColor)

            Text("Demo Mode Active")
                .font(.system(size: 12, weight: .bold))

            Text("Displaying simulated pull requests for testing and review.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            Spacer()

            Button("Exit Demo") {
                state.resetToLivePRs()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(state.accentTheme.primaryColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(state.accentTheme.primaryColor.opacity(0.20), lineWidth: 1)
        )
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text("Fetching pull requests from GitHub...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(error: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("Failed to Load Pull Requests")
                .font(.system(size: 15, weight: .bold))

            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 10) {
                Button("Retry") {
                    state.loadPRs()
                }
                .buttonStyle(.borderedProminent)
                .tint(state.accentTheme.primaryColor)

                Button("Open Settings") {
                    state.showSettings = true
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var tokenNotConfiguredView: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                Circle()
                    .fill(state.accentTheme.primaryColor.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(state.accentTheme.primaryColor)
            }

            VStack(spacing: 6) {
                Text("Connect GitHub to View Pull Requests")
                    .font(.system(size: 16, weight: .bold))

                Text("Authenticate with your GitHub account to browse open PRs, review code, track CI checks, and merge branches.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            VStack(spacing: 10) {
                Button {
                    state.startGitHubOAuthFlow()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "safari.fill")
                        Text("Sign in with GitHub (Recommended)")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(state.accentTheme.primaryColor)
                .controlSize(.regular)

                HStack(spacing: 12) {
                    if state.detectedCLIToken != nil {
                        Button("Connect with gh CLI") {
                            state.importFromGitHubCLI()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button("Configure Token Manually") {
                        state.showSettings = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Load Sample PRs") {
                        state.loadDemoPRs()
                    }
                    .buttonStyle(.hoverPlain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(state.accentTheme.primaryColor)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyFilteredView: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.4))
                .padding(.top, 36)

            Text("No pull requests match the current filters")
                .font(.system(size: 13, weight: .semibold))

            Text("Try clearing search keywords or switching between the Open and Closed tabs.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button("Clear Filters") {
                state.setPRAuthorFilter(nil)
                state.setPRFilter(.open)
                clearFreeSearchText()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Direct Navigation Quick Action Button

private struct PRQuickActionButton: View {
    let icon: String
    var iconColor: Color? = nil
    let label: String
    let tooltip: String
    var width: CGFloat? = nil
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(iconColor ?? (isHovered ? Color.primary : Color.secondary))

                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(width: width)
            .padding(.horizontal, width != nil ? 0 : 8)
            .padding(.vertical, 5)
            .background(isHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isHovered ? Color.primary.opacity(0.20) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.hoverPlain)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .help(tooltip)
    }
}

// MARK: - File-Level Helper Functions

fileprivate func ciStatusIconName(_ status: String?) -> String {
    switch status {
    case "SUCCESS": return "checkmark.circle.fill"
    case "FAILURE": return "xmark.circle.fill"
    case "PENDING": return "circle.dotted"
    default: return "checkmark.seal"
    }
}

fileprivate func ciStatusColor(_ status: String?) -> Color {
    switch status {
    case "SUCCESS": return .green.opacity(0.9)
    case "FAILURE": return .red.opacity(0.9)
    case "PENDING": return .yellow.opacity(0.9)
    default: return .secondary.opacity(0.7)
    }
}

fileprivate func reviewVerdictColor(_ verdict: ReviewVerdict) -> Color {
    switch verdict {
    case .approved: return .green.opacity(0.85)
    case .changesRequested: return .red.opacity(0.85)
    case .commented: return .blue.opacity(0.85)
    case .pending: return .orange.opacity(0.85)
    }
}

fileprivate func reviewVerdictTextColor(_ verdict: ReviewVerdict) -> Color {
    switch verdict {
    case .approved: return .green.opacity(0.85)
    case .changesRequested: return .red.opacity(0.85)
    case .commented: return .secondary.opacity(0.75)
    case .pending: return .orange.opacity(0.85)
    }
}

// MARK: - Isolated PR Index Row View

public struct PRIndexRowView: View, Equatable {
    public let pr: PullRequest
    public let accentColor: Color
    /// Stats and CI are still loading; show placeholders instead of zeros.
    public var isEnriching: Bool = false
    public let onOpen: (PRDetailTab) -> Void

    @State private var isHovered: Bool = false
    @State private var copiedBranch: Bool = false

    public nonisolated static func == (lhs: PRIndexRowView, rhs: PRIndexRowView) -> Bool {
        return lhs.pr.id == rhs.pr.id &&
               lhs.pr.state == rhs.pr.state &&
               lhs.pr.title == rhs.pr.title &&
               lhs.pr.isDraft == rhs.pr.isDraft &&
               lhs.pr.reviewVerdict == rhs.pr.reviewVerdict &&
               lhs.pr.ciStatus == rhs.pr.ciStatus &&
               lhs.pr.totalChecksCount == rhs.pr.totalChecksCount &&
               lhs.pr.passedChecksCount == rhs.pr.passedChecksCount &&
               lhs.pr.commentsCount == rhs.pr.commentsCount &&
               lhs.pr.changedFilesCount == rhs.pr.changedFilesCount &&
               lhs.pr.additions == rhs.pr.additions &&
               lhs.pr.deletions == rhs.pr.deletions &&
               lhs.pr.labels == rhs.pr.labels &&
               lhs.pr.reviewers == rhs.pr.reviewers &&
               lhs.isEnriching == rhs.isEnriching &&
               lhs.accentColor == rhs.accentColor
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // 1. Status Icon Pill (Using Custom PR Vector Glyph)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(pr.state.badgeColor.opacity(0.12))
                    .frame(width: 28, height: 28)

                PullRequestGlyph(size: 15, color: pr.state.badgeColor)
            }
            .padding(.top, 2)

            // 2. Title (Line 1) & 3 Quick Action Buttons + Metadata (Line 2)
            VStack(alignment: .leading, spacing: 7) {
                // Line 1: PR Title + Draft Badge
                HStack(alignment: .center, spacing: 8) {
                    Text(pr.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .underline(isHovered, color: Color.primary.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(pr.title)

                    if pr.isDraft {
                        Text("Draft")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundStyle(.secondary)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    if let labels = pr.labels, !labels.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(labels.prefix(3), id: \.name) { PRLabelPill(label: $0) }
                            if labels.count > 3 {
                                Text("+\(labels.count - 3)")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .help(labels.dropFirst(3).map(\.name).joined(separator: ", "))
                            }
                        }
                        .fixedSize()
                    }

                    Spacer(minLength: 8)

                    if let reviewers = pr.reviewers, !reviewers.isEmpty {
                        PRRowReviewers(reviewers: reviewers)
                    }
                }

                // Line 2: 3 Quick Action Buttons on the Left, Followed by Strictly Aligned Metadata Columns
                HStack(alignment: .center, spacing: 12) {
                    // --- 3 Quick Action Buttons (Concise Icon + Number, No Labels/Parentheses) ---
                    HStack(spacing: 5) {
                        // Button 1: Conversation (Message Bubble + Count)
                        PRQuickActionButton(
                            icon: "bubble.left.and.bubble.right",
                            label: "\(pr.commentsCount)",
                            tooltip: pr.commentsCount == 1 ? "1 conversation comment" : "\(pr.commentsCount) conversation comments",
                            width: 46
                        ) {
                            onOpen(.overview)
                        }

                        // Button 2: Checks (CI Icon + n/m)
                        PRQuickActionButton(
                            icon: ciStatusIconName(pr.ciStatus),
                            iconColor: ciStatusColor(pr.ciStatus),
                            label: pr.totalChecksCount > 0 ? "\(pr.passedChecksCount)/\(pr.totalChecksCount)" : "-",
                            tooltip: pr.totalChecksCount > 0 ? "\(pr.passedChecksCount) passed out of \(pr.totalChecksCount) checks" : "Open CI/CD Checks",
                            width: 68
                        ) {
                            onOpen(.checks)
                        }
                        .redacted(reason: isEnriching ? .placeholder : [])

                        // Button 3: Files Changed (File Icon + Count)
                        PRQuickActionButton(
                            icon: "doc.badge.ellipsis",
                            label: "\(pr.changedFilesCount)",
                            tooltip: pr.changedFilesCount == 1 ? "1 file changed" : "\(pr.changedFilesCount) files changed",
                            width: 46
                        ) {
                            onOpen(.filesChanged)
                        }
                        .redacted(reason: isEnriching ? .placeholder : [])
                    }

                    Text("•")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.secondary.opacity(0.35))

                    // Col 1: PR Number + Avatar + Username + Timestamp (Strictly Aligned)
                    HStack(spacing: 6) {
                        Text(verbatim: "#\(pr.number)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.70))
                            .lineLimit(1)
                            .fixedSize()
                            .frame(minWidth: 44, alignment: .leading)
                            .help("PR #\(pr.number)")

                        PRAvatarView(authorName: pr.authorName, avatarUrl: pr.authorAvatarUrl, size: 16)

                        Text(pr.authorName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.secondary.opacity(0.90))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 105, alignment: .leading)
                            .help(pr.authorName)

                        Text("opened \(pr.relativeDateString)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.secondary.opacity(0.65))
                            .lineLimit(1)
                            .frame(width: 90, alignment: .leading)
                    }
                    .frame(width: 275, alignment: .leading)

                    Text("•")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.secondary.opacity(0.35))

                    // Col 2: Review Verdict Status (Approved / Review Required / Changes Requested)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(reviewVerdictColor(pr.reviewVerdict))
                            .frame(width: 6, height: 6)
                        Text(pr.reviewVerdict.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(reviewVerdictTextColor(pr.reviewVerdict))
                            .lineLimit(1)
                    }
                    .frame(width: 130, alignment: .leading)
                    .redacted(reason: isEnriching ? .placeholder : [])
                    .help("Review Status: \(pr.reviewVerdict.title)")

                    Text("•")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.secondary.opacity(0.35))

                    // Col 3: Current Head Branch (with Copy Icon)
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary.opacity(0.55))

                        Text(pr.headBranch)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 145, alignment: .leading)
                            .help(pr.headBranch)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pr.headBranch, forType: .string)
                            copiedBranch = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copiedBranch = false
                            }
                        } label: {
                            Image(systemName: copiedBranch ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(copiedBranch ? Color.green : Color.secondary.opacity(0.60))
                        }
                        .buttonStyle(.hoverPlain)
                        .help("Copy branch name")
                    }
                    .frame(width: 180, alignment: .leading)

                    Text("•")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.secondary.opacity(0.35))

                    // Col 4: Size + Line Additions & Deletions
                    HStack(spacing: 4) {
                        Text(pr.size.rawValue)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(pr.size.color)
                            .frame(width: 22, height: 16)
                            .background(pr.size.color.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .opacity(pr.additions + pr.deletions > 0 ? 1 : 0)
                            .help("Size \(pr.size.rawValue): \(pr.size.rangeText)")
                        Text("+\(pr.additions.formatted())")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.green.opacity(0.80))
                            .lineLimit(1)

                        Text("-\(pr.deletions.formatted())")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.red.opacity(0.80))
                            .lineLimit(1)
                            .help("+\(pr.additions) additions, -\(pr.deletions) deletions")
                    }
                    .frame(width: 125, alignment: .leading)
                    .redacted(reason: isEnriching ? .placeholder : [])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(isHovered ? Color.white.opacity(0.035) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .pointerCursor()
        .onTapGesture {
            onOpen(.overview)
        }
    }
}


/// Reviewer avatars on a list row, ringed by their latest review state (dashed while a review is requested).
private struct PRRowReviewers: View {
    let reviewers: [PRListReviewer]

    private static func color(_ status: PRListReviewer.Status) -> Color {
        switch status {
        case .approved: return .green
        case .changesRequested: return .red
        case .commented: return .secondary
        case .requested: return .orange
        }
    }

    private static func label(_ status: PRListReviewer.Status) -> String {
        switch status {
        case .approved: return "approved"
        case .changesRequested: return "requested changes"
        case .commented: return "commented"
        case .requested: return "review requested"
        }
    }

    var body: some View {
        HStack(spacing: -4) {
            ForEach(reviewers.prefix(5), id: \.login) { reviewer in
                PRAvatarView(authorName: reviewer.login, avatarUrl: reviewer.avatarUrl, size: 18)
                    .padding(2)
                    .overlay(
                        Circle().strokeBorder(Self.color(reviewer.status),
                                              style: StrokeStyle(lineWidth: 1.5, dash: reviewer.status == .requested ? [2.5, 2] : []))
                    )
                    .help("\(reviewer.login): \(Self.label(reviewer.status))")
            }
            if reviewers.count > 5 {
                Text("+\(reviewers.count - 5)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .help(reviewers.dropFirst(5).map { "\($0.login): \(Self.label($0.status))" }.joined(separator: "\n"))
            }
        }
        .fixedSize()
    }
}
