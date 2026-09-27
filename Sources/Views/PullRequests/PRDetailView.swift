import SwiftUI
import AppKit

public struct PRDetailView: View {
    @ObservedObject var state: AppState
    @State private var quickTokenInput: String = ""
    @State private var fileSearchText: String = ""
    @AppStorage(PRFileTree.treeModeDefaultsKey) private var fileTreeMode = true
    @State private var collapsedDirs: Set<String> = []

    public var body: some View {
        VStack(spacing: 0) {
            if let pr = state.selectedPR {
                // Conversation and files own the app toolbar + header so they can scroll away with the content.
                switch state.selectedPRTab {
                case .overview:
                    PRChromeContainer(state: state, pr: pr) { inset, visible, onChromeHidden in
                        PRConversationView(state: state, pr: pr, topInset: inset, visibleChromeHeight: visible, onChromeHidden: onChromeHidden)
                    }
                case .filesChanged:
                    PRChromeContainer(state: state, pr: pr) { inset, visible, onChromeHidden in
                        prDiffTab(pr, topInset: inset, visibleChromeHeight: visible, onChromeHidden: onChromeHidden)
                    }
                case .commits:
                    PRDetailHeaderView(state: state, pr: pr)
                    Divider()
                    PRCommitsView(state: state, pr: pr)
                case .checks:
                    PRDetailHeaderView(state: state, pr: pr)
                    Divider()
                    PRChecksView(state: state, pr: pr)
                }

            } else if let error = state.prFetchError {
                tokenErrorDetailView(error: error)
            } else if !state.hasConfiguredGitHubToken && !state.hasExplicitlyLoadedDemoPRs {
                gitHubTokenPlaceholderView
            } else {
                noSelectionPlaceholderView
            }
        }
        .onExitCommand {
            withAnimation(.easeInOut(duration: 0.15)) {
                state.selectedPR = nil
            }
        }
        .sheet(isPresented: $state.showMergeSheet) {
            PRMergeSheet(state: state)
        }
    }

    // MARK: - Overview & Conversation

    @ViewBuilder
    private func prOverviewTab(_ pr: PullRequest) -> some View {
        PRConversationView(state: state, pr: pr)
    }

    // MARK: - Files Changed Diff

    private var filteredPRFiles: [PRFileChange] {
        let trimmed = fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return state.prFiles
        }
        return state.prFiles.filter {
            $0.filename.localizedCaseInsensitiveContains(trimmed)
        }
    }

    @ViewBuilder
    private func prDiffTab(_ pr: PullRequest, topInset: CGFloat, visibleChromeHeight: CGFloat, onChromeHidden: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 0) {
            // Left sidebar: Changed files list
            VStack(spacing: 0) {
                // Header & Search
                VStack(spacing: 8) {
                    HStack {
                        Label("Files Changed", systemImage: "doc.badge.ellipsis")
                            .font(.system(size: 12, weight: .bold))

                        Spacer()

                        Button {
                            fileTreeMode.toggle()
                        } label: {
                            Image(systemName: fileTreeMode ? "list.bullet" : "folder")
                        }
                        .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                        .help(fileTreeMode ? "Show as a flat list" : "Group by folder")

                        if state.isLoadingPRFiles && state.prFiles.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            let viewed = state.prFiles.filter { state.isPRFileViewed($0) }.count
                            Text("\(viewed) / \(state.prFiles.count) viewed")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .foregroundStyle(viewed == state.prFiles.count && viewed > 0 ? Color.green : Color.secondary)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                                .help("Mark files as viewed to track review progress. Files re-appear unviewed when they change.")
                        }
                    }

                    // Search field
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        TextField("Filter files...", text: $fileSearchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))

                        if !fileSearchText.isEmpty {
                            Button {
                                fileSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear file filter")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                    Picker("", selection: $state.diffMode) {
                        ForEach(DiffDisplayMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Unified or side-by-side diff")
                }
                .padding(10)
                .background(.ultraThinMaterial)

                Divider()

                // Files list
                if state.isLoadingPRFiles && state.prFiles.isEmpty {
                    VStack(spacing: 10) {
                        Spacer()
                        ProgressView()
                            .controlSize(.regular)
                        Text("Loading changed files...")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else if filteredPRFiles.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 24))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text(state.prFiles.isEmpty ? "No files changed" : "No matching files")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        if state.prFiles.isEmpty {
                            Button("Reload Files") {
                                state.loadPRFiles(for: pr)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollViewReader { proxy in
                    List(selection: Binding(
                        get: { state.selectedPRFile?.filename },
                        set: { newFilename in
                            guard let newFilename = newFilename, newFilename != state.selectedPRFile?.filename else { return }
                            DispatchQueue.main.async {
                                if let match = state.prFiles.first(where: { $0.filename == newFilename }) {
                                    state.selectedPRFile = match
                                }
                            }
                        }
                    )) {
                        let openThreads = threadCountsByPath
                        if fileTreeMode {
                            ForEach(PRFileTree.rows(for: filteredPRFiles, collapsed: collapsedDirs)) { row in
                                switch row.kind {
                                case .directory(let name, let count):
                                    directoryRow(id: row.id, name: name, count: count)
                                        .padding(.leading, CGFloat(row.depth) * 14)
                                        .id(row.id)
                                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                                case .file(let file):
                                    prFileRow(file: file, openThreads: openThreads[file.filename] ?? 0, showDirectory: false)
                                        .padding(.leading, CGFloat(row.depth) * 14)
                                        .tag(file.filename)
                                        .id(file.filename)
                                        .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                                }
                            }
                        } else {
                            ForEach(filteredPRFiles) { file in
                                prFileRow(file: file, openThreads: openThreads[file.filename] ?? 0)
                                    .tag(file.filename)
                                    .id(file.filename)
                                    .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: state.selectedPRFile?.filename) { _, name in
                        // Follows the diff's scroll position; a no-op when the row is already visible.
                        guard let name else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(name) }
                    }
                    }
                }
            }
            .frame(width: 320)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
            .padding(.top, visibleChromeHeight)

            Divider()
                .padding(.top, visibleChromeHeight)

            // Right pane: every file's diff in one continuous scroll
            Group {
                if state.prFiles.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        if state.isLoadingPRFiles {
                            ProgressView().controlSize(.regular)
                        } else {
                            Image(systemName: "doc.text")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary.opacity(0.5))
                            Text("No file changes to show")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.top, topInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PRFilesWebView(
                        files: fileTreeMode ? PRFileTree.orderedFiles(state.prFiles) : state.prFiles,
                        mode: state.diffMode,
                        viewedPaths: Set(state.prFiles.filter { state.isPRFileViewed($0) }.map(\.filename)),
                        threadsPayload: threadsPayload,
                        filter: fileSearchText.trimmingCharacters(in: .whitespacesAndNewlines),
                        selectedPath: state.selectedPRFile?.filename,
                        canOpenLocally: state.currentRepo?.path != nil,
                        prURL: pr.url,
                        topInset: topInset,
                        onChromeHidden: { onChromeHidden($0) },
                        onCurrentFile: { path in
                            guard path != state.selectedPRFile?.filename,
                                  let match = state.prFiles.first(where: { $0.filename == path }) else { return }
                            state.selectedPRFile = match
                        },
                        onToggleViewed: { path in
                            if let file = state.prFiles.first(where: { $0.filename == path }) {
                                state.togglePRFileViewed(file)
                            }
                        },
                        onOpenInEditor: { path in
                            guard let repoPath = state.currentRepo?.path else { return }
                            NSWorkspace.shared.open(URL(fileURLWithPath: (repoPath as NSString).appendingPathComponent(path)))
                        },
                        onSwitchTab: { tab in state.selectedPRTab = tab },
                        onAction: { action in await state.handlePRWebAction(action) },
                        onNewComment: { path, line, side, body in
                            do {
                                try await state.postInlineReviewComment(path: path, line: line, side: side, body: body)
                                return true
                            } catch {
                                return false
                            }
                        },
                        onFileContent: { path in
                            guard let file = state.prFiles.first(where: { $0.filename == path }),
                                  let ref = state.selectedPR?.headSha else {
                                throw NSError(domain: "GitXX", code: 404, userInfo: [NSLocalizedDescriptionKey: "head commit unknown"])
                            }
                            return try await state.prFileContent(path: file.filename, ref: ref)
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 13/255, green: 17/255, blue: 23/255))
        .onAppear {
            if state.prFiles.isEmpty && !state.isLoadingPRFiles {
                state.loadPRFiles(for: pr)
            }
        }
    }

    /// Review threads grouped by file for the Files tab, as the JSON the page's `gitxxSetThreads` expects.
    private var threadsPayload: String {
        var map: [String: [[String: Any]]] = [:]
        for item in state.prTimeline {
            guard case .reviewThread(let t) = item else { continue }
            let comments: [[String: Any]] = t.comments.map { c in
                [
                    "id": c.id, "author": c.authorName, "avatar": c.authorAvatarUrl ?? "",
                    "body": c.body, "ts": Int(c.createdAt.timeIntervalSince1970)
                ]
            }
            var entry: [String: Any] = [
                "id": t.id, "side": t.comments.first?.side ?? "RIGHT", "resolved": t.isResolved,
                "outdated": t.isOutdated ?? false, "comments": comments
            ]
            if let line = t.line { entry["line"] = line }
            if let nodeId = t.nodeId { entry["nodeId"] = nodeId }
            if let by = t.resolvedByName { entry["resolvedBy"] = by }
            map[t.path, default: []].append(entry)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private var threadCountsByPath: [String: Int] {
        var counts: [String: Int] = [:]
        for item in state.prTimeline {
            if case .reviewThread(let t) = item, !t.isResolved { counts[t.path, default: 0] += 1 }
        }
        return counts
    }

    private func directoryRow(id: String, name: String, count: Int) -> some View {
        let collapsed = collapsedDirs.contains(id)
        return Button {
            withAnimation(.easeOut(duration: 0.12)) {
                if collapsed { collapsedDirs.remove(id) } else { collapsedDirs.insert(id) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12)
                Image(systemName: collapsed ? "folder" : "folder.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.secondary)
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if collapsed {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Expand folder" : "Collapse folder")
    }

    @ViewBuilder
    private func prFileRow(file: PRFileChange, openThreads: Int, showDirectory: Bool = true) -> some View {
        let isViewed = state.isPRFileViewed(file)
        HStack(spacing: 8) {
            Button {
                state.togglePRFileViewed(file)
            } label: {
                Image(systemName: isViewed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(isViewed ? Color.green : Color.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isViewed ? "Mark as not viewed" : "Mark as viewed")

            Text(file.statusLetter)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(file.statusBadgeColor)
                .frame(width: 18, height: 18)
                .background(file.statusBadgeColor.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileDisplayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .strikethrough(false)
                    .foregroundStyle(isViewed ? Color.secondary : Color.primary)

                if showDirectory && !file.directoryPath.isEmpty {
                    Text(file.directoryPath)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .help(file.filename)

            Spacer(minLength: 4)

            if openThreads > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "bubble.left.fill")
                    Text("\(openThreads)")
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.orange)
                .help("\(openThreads) unresolved conversation\(openThreads == 1 ? "" : "s") on this file")
            }

            VStack(alignment: .trailing, spacing: 1) {
                if file.additions > 0 {
                    Text("+\(file.additions)")
                        .foregroundStyle(.green)
                }
                if file.deletions > 0 {
                    Text("-\(file.deletions)")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // MARK: - GitHub Token Placeholder & Empty States

    @ViewBuilder
    private func tokenErrorDetailView(error: String) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 24) {
                Spacer().frame(height: 20)

                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.18))
                        .frame(width: 86, height: 86)

                    Circle()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: 64, height: 64)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1.5)
                        )

                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.orange)
                }

                VStack(spacing: 6) {
                    Text("GitHub Authentication Failed")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.primary)

                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 500)
                }

                if state.detectedCLIToken != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: "apple.terminal")
                                .font(.system(size: 20))
                                .foregroundStyle(state.accentTheme.primaryColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Active GitHub CLI Session Available")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.primary)

                                Text("GitXX detected an authenticated GitHub CLI ('gh') session. Click below to connect automatically.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                state.importFromGitHubCLI()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.down.circle.fill")
                                    Text("Use GitHub CLI Token")
                                }
                                .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(state.accentTheme.primaryColor)
                        }
                    }
                    .padding(16)
                    .background(state.accentTheme.primaryColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(state.accentTheme.primaryColor.opacity(0.24), lineWidth: 1)
                    )
                    .frame(maxWidth: 560)
                }

                quickConnectBox

                actionButtonsRow

                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var gitHubTokenPlaceholderView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 22) {
                Spacer().frame(height: 16)

                tokenHeroHeader

                featuresGrid

                quickConnectBox

                actionButtonsRow

                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var tokenHeroHeader: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [state.accentTheme.primaryColor.opacity(0.30), state.accentTheme.primaryColor.opacity(0.02)],
                            center: .center,
                            startRadius: 10,
                            endRadius: 55
                        )
                    )
                    .frame(width: 86, height: 86)

                Circle()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Circle()
                            .strokeBorder(state.accentTheme.primaryColor.opacity(0.35), lineWidth: 1.5)
                    )

                Image(systemName: "key.horizontal.badge.ellipsis")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(state.accentTheme.primaryColor)
            }

            VStack(spacing: 6) {
                Text("GitHub Token Required")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.primary)

                let repoName = state.currentRepo?.name ?? "this repository"
                Text("Pull requests for ")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.secondary)
                + Text(repoName)
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(state.accentTheme.primaryColor)
                + Text(" are fetched live from GitHub's GraphQL API. Configure your Personal Access Token to view and review them.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 540)
        }
    }

    @ViewBuilder
    private var featuresGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            featurePreviewCard(
                icon: "arrow.triangle.pull",
                title: "Pull Request Browser",
                description: "Filter by open, needs review, or merged. Search by author or PR number."
            )
            featurePreviewCard(
                icon: "bubble.left.and.bubble.right.fill",
                title: "Code Reviews & Comments",
                description: "Read threaded discussions, review inline code comments, and submit verdicts."
            )
            featurePreviewCard(
                icon: "arrow.triangle.branch",
                title: "One-Click Checkout",
                description: "Switch to any PR branch locally to test changes directly on your machine."
            )
            featurePreviewCard(
                icon: "checkmark.shield.fill",
                title: "CI / CD Status Checks",
                description: "Inspect GitHub Actions test runs, check runs, and build matrix statuses."
            )
        }
        .frame(maxWidth: 560)
    }

    private func featurePreviewCard(icon: String, title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(state.accentTheme.primaryColor)
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.primary)
            }
            Text(description)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.24))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var quickConnectBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Quick Connect Token", systemImage: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(state.accentTheme.primaryColor)

                Spacer()

                Link(destination: URL(string: "https://github.com/settings/tokens/new?description=GitXX&scopes=repo,read:org")!) {
                    HStack(spacing: 4) {
                        Text("Create Token on GitHub")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(state.accentTheme.primaryColor)
                }
            }

            HStack(spacing: 8) {
                SecureField("Paste Personal Access Token (ghp_...)", text: $quickTokenInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .onSubmit {
                        let trimmed = quickTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            state.saveGitHubToken(trimmed)
                        }
                    }

                Button {
                    let trimmed = quickTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    state.saveGitHubToken(trimmed)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text("Save & Connect")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(state.accentTheme.primaryColor)
                .controlSize(.small)
                .disabled(quickTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Stored securely in macOS Keychain. Required scopes: 'repo' (or read-only for public repos).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: 560)
    }

    @ViewBuilder
    private var actionButtonsRow: some View {
        HStack(spacing: 12) {
            Button {
                state.initialPreferencesCategory = PreferenceCategory.github.rawValue
                state.showSettings = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Configure in Preferences...")
                }
                .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button {
                state.loadDemoPRs()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("Preview with Sample PRs")
                }
                .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    @ViewBuilder
    private var noSelectionPlaceholderView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 40))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("Select a pull request to review")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Choose an item from the sidebar to inspect diffs, comments, and CI checks.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
