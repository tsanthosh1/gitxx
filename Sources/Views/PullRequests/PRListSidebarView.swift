import SwiftUI

public struct PRListSidebarView: View {
    @ObservedObject var state: AppState

    var filteredPRs: [PullRequest] {
        var list = state.pullRequests

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

        let query = PRSearchQuery.freeText(state.prSearchText)
        if !query.isEmpty {
            list = list.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.authorName.localizedCaseInsensitiveContains(query) ||
                "\($0.number)".contains(query)
            }
        }

        return list
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Search & Filter Bar
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))

                    TextField("Search PRs by title, author, or #...", text: $state.prSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))

                    if !state.prSearchText.isEmpty {
                        Button {
                            state.prSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.hoverPlain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Filter tabs
                Picker("", selection: Binding(
                    get: { state.prFilter },
                    set: { newFilter in state.setPRFilter(newFilter) }
                )) {
                    ForEach(PRFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.02))

            // Demo indicator banner if active
            if state.hasExplicitlyLoadedDemoPRs {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10.5))
                        .foregroundStyle(state.accentTheme.primaryColor)
                    Text("Sample PRs (Demo Mode)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary)
                    Spacer()
                    Button("Exit") {
                        state.resetToLivePRs()
                    }
                    .buttonStyle(.hoverPlain)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(state.accentTheme.primaryColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(state.accentTheme.primaryColor.opacity(0.12))
            }

            Divider()

            // Main Content Area
            if state.isLoadingPRs {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Text("Fetching pull requests...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if let error = state.prFetchError {
                tokenErrorSidebarView(error: error)
            } else if !state.hasConfiguredGitHubToken && !state.hasExplicitlyLoadedDemoPRs {
                // Token Not Configured Placeholder
                tokenNotConfiguredSidebarView
            } else if filteredPRs.isEmpty {
                emptyFilteredPRsView
            } else {
                List(filteredPRs, selection: Binding(
                    get: { state.selectedPR?.id },
                    set: { newId in
                        guard let newId = newId, newId != state.selectedPR?.id else { return }
                        DispatchQueue.main.async {
                            if let match = state.pullRequests.first(where: { $0.id == newId }) {
                                state.selectedPR = match
                            }
                        }
                    }
                )) { pr in
                    prRow(pr)
                        .tag(pr.id)
                        .onAppear {
                            if pr.id == state.pullRequests.last?.id { state.loadMorePRs() }
                        }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            Divider()

            // Bottom action bar
            bottomActionBar
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func tokenErrorSidebarView(error: String) -> some View {
        VStack(spacing: 12) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.16))
                    .frame(width: 48, height: 48)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.orange)
            }

            VStack(spacing: 4) {
                Text("Authentication Error")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary)

                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .lineLimit(4)
            }

            VStack(spacing: 8) {
                if state.detectedCLIToken != nil {
                    Button {
                        state.importFromGitHubCLI()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "apple.terminal")
                            Text("Use GitHub CLI Token")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(state.accentTheme.primaryColor)
                    .controlSize(.small)
                    .padding(.horizontal, 16)
                }

                Button {
                    state.initialPreferencesCategory = PreferenceCategory.github.rawValue
                    state.showSettings = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Update in Preferences...")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    state.loadPRs()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .font(.system(size: 10.5))
                }
                .buttonStyle(.hoverPlain)
                .foregroundStyle(Color.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var tokenNotConfiguredSidebarView: some View {
        VStack(spacing: 14) {
            Spacer()

            ZStack {
                Circle()
                    .fill(state.accentTheme.primaryColor.opacity(0.14))
                    .frame(width: 50, height: 50)
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(state.accentTheme.primaryColor)
            }

            VStack(spacing: 4) {
                Text("GitHub Token Required")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary)

                Text("Configure your personal access token to load and review pull requests.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            VStack(spacing: 8) {
                Button {
                    state.initialPreferencesCategory = PreferenceCategory.github.rawValue
                    state.showSettings = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Configure Token")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(state.accentTheme.primaryColor)
                .controlSize(.small)
                .padding(.horizontal, 20)

                Button {
                    state.loadDemoPRs()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text("Load Sample PRs")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.hoverPlain)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var emptyFilteredPRsView: some View {
        VStack(spacing: 10) {
            Spacer()

            if state.pullRequests.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.green.opacity(0.8))
                Text("No Open Pull Requests")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary)
                Text("All clear! No open pull requests found for this repository.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Button {
                    state.showCreatePRSheet = true
                } label: {
                    Label("New Pull Request", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(state.accentTheme.primaryColor)
                .controlSize(.small)
                .padding(.top, 4)
            } else {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text("No matching pull requests")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Try adjusting your search query or filter tab.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var bottomActionBar: some View {
        HStack {
            Button {
                state.showCreatePRSheet = true
            } label: {
                Label("New Pull Request", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.hoverPlain)

            Spacer()

            Button {
                state.loadPRs()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.hoverPlain)
            .help("Refresh pull requests")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .themedSurface(state.accentTheme, .toolbar)
    }

    @ViewBuilder
    private func prRow(_ pr: PullRequest) -> some View {
        let isSelected = state.selectedPR?.id == pr.id

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: pr.state.iconName)
                    .foregroundStyle(pr.state.badgeColor)
                    .font(.system(size: 12, weight: .semibold))

                Text(verbatim: "#\(pr.number)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)

                Spacer()

                Text(pr.reviewVerdict.title)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(pr.reviewVerdict.color.opacity(0.18))
                    .foregroundStyle(pr.reviewVerdict.color)
                    .clipShape(Capsule())
            }

            Text(pr.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(2)
                .help(pr.title)

            HStack(spacing: 6) {
                Text(pr.authorName)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)

                Text("•")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(0.5))

                Text(pr.relativeDateString)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.6))

                Spacer()

                HStack(spacing: 4) {
                    Text("+\(pr.additions)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.green)
                    Text("-\(pr.deletions)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
