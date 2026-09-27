import Foundation
import SwiftUI
import Combine
import WebKit

public enum AppTab: String, CaseIterable, Identifiable {
    case changes = "Changes"
    case history = "History"
    case pullRequests = "Pull Requests"
    case terminal = "Terminal"

    public var id: String { rawValue }
    public var iconName: String {
        switch self {
        case .changes: return "plus.forwardslash.minus"
        case .history: return "clock.arrow.circlepath"
        case .pullRequests: return "arrow.triangle.pull"
        case .terminal: return "terminal.fill"
        }
    }
    public var keyboardShortcutKey: KeyEquivalent {
        switch self {
        case .changes: return "1"
        case .history: return "2"
        case .pullRequests: return "3"
        case .terminal: return "4"
        }
    }
}

public enum DiffDisplayMode: String, CaseIterable, Identifiable {
    case unified = "Unified"
    case split = "Split"
    public var id: String { rawValue }
}

public enum PRFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case myOpen = "My Open"
    case myClosed = "My Closed"
    case open = "Open"
    case closed = "Closed"
    case reviewNeeded = "Review Needed"
    case all = "All"
    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "Merged" {
            self = .closed
        } else if let val = PRFilter(rawValue: raw) {
            self = val
        } else {
            self = .myOpen
        }
    }
}

public enum ToastType {
    case success
    case info
    case error

    public var color: Color {
        switch self {
        case .success: return .green
        case .info: return .blue
        case .error: return .red
        }
    }

    public var iconName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
public final class AppState: ObservableObject {
    // Navigation & Tab State
    @Published public var backStack: [NavigationLocation] = []
    @Published public var forwardStack: [NavigationLocation] = []
    @Published public var visitedHistory: [NavigationLocation] = []
    @Published public var showPageHistoryPopover: Bool = false
    public var isNavigatingHistory: Bool = false
    /// Set while a multi-step jump (switch repo, then open a page) runs, so it's recorded as one history step.
    var isCompoundNavigating: Bool = false
    private var lastRecordedLocation: NavigationLocation? = nil

    public var canNavigateBack: Bool {
        !backStack.isEmpty
    }

    public var canNavigateForward: Bool {
        !forwardStack.isEmpty
    }

    @Published public var activeTab: AppTab = .changes {
        didSet {
            if showHome && !isNavigatingHistory { showHome = false }
            if activeTab != oldValue {
                recordNavigationStep()
                if activeTab == .pullRequests {
                    if hasConfiguredGitHubToken && pullRequests.isEmpty {
                        loadPRs()
                    }
                } else {
                    refreshRepoSilently()
                }
            }
        }
    }
    @Published public var diffMode: DiffDisplayMode = .unified

    // Repository State
    @Published public var currentRepo: GitRepository? {
        didSet {
            guard oldValue?.path != currentRepo?.path else { return }
            historyRef = nil
            historyForeignCommits = []
            stashes = []
        }
    }
    @Published public var recentRepos: [GitRepository] = []
    @Published public var pendingFirstTimeRepo: GitRepository?
    @Published public var currentBranch: String = "main"
    @Published public var branches: [GitBranch] = []
    @Published public var commitsAhead: Int = 0
    @Published public var commitsBehind: Int = 0
    @Published public var isPulling: Bool = false
    @Published public var isPushing: Bool = false
    @Published public var isFetching: Bool = false

    // Changes View State
    @Published public var files: [GitFileStatus] = []
    @Published public var selectedFile: GitFileStatus?
    @Published public var showStashDrawer = false
    /// Branch shown in History; `nil` means the checked-out HEAD.
    @Published public var historyRef: String?
    /// Commits of `historyRef` that aren't on HEAD yet.
    @Published public var historyForeignCommits: Set<String> = []
    @Published public var rebaseTargetCommit: GitCommit?
    var historyLoadToken = UUID()
    @Published public var tagTargetCommit: GitCommit?
    @Published public var stashes: [GitStash] = []
    @Published public var gitOperationInFlight: String?
    @Published public var currentDiff: FileDiff? {
        didSet { currentDiffRevision &+= 1 }
    }
    /// Bumped on every `currentDiff` assignment so views can cache work derived from it.
    private(set) var currentDiffRevision = 0
    /// Rows of `currentDiff` (HEAD→working tree) that are staged; only meaningful when `lineStagingEnabled`.
    @Published public var currentDiffStagedLines: Set<DiffLineKey> = []
    @Published public var lineStagingEnabled = false
    var pendingStagingOps = 0
    /// Working-copy diffs by repo + path, shown instantly on selection and then revalidated.
    var workingDiffCache: [String: CachedWorkingDiff] = [:]
    var diffPrefetchTask: Task<Void, Never>?
    var stagingChain: Task<Void, Never>?
    @Published public var commitSummary: String = ""
    @Published public var commitDescription: String = ""
    @Published public var fileFilterText: String = ""

    // History View State
    @Published public var commits: [GitCommit] = []
    @Published public var selectedCommit: GitCommit? {
        didSet {
            if selectedCommit?.sha != oldValue?.sha {
                recordNavigationStep()
            }
        }
    }
    @Published public var commitDiff: FileDiff?
    @Published public var historyFilterText: String = ""

    // Pull Requests View State
    @Published public var pullRequests: [PullRequest] = []
    @Published public var selectedPR: PullRequest? {
        didSet {
            if selectedPR?.number != oldValue?.number {
                recordNavigationStep()
                cancelPRDetailTasks()
            }
            if let pr = selectedPR, pr.number != oldValue?.number {
                let ownerRepo = currentRepo.flatMap { gitHubService.parseRepoOwnerAndName(from: $0.remoteUrl) }
                let owner = ownerRepo?.owner ?? "octocat"
                let repoName = ownerRepo?.name ?? (currentRepo?.name ?? "")

                // Instant 0ms cache hydration for conversation timeline & checks
                if let cachedTimeline = PRTimelineCache.shared.getInMemory(owner: owner, repo: repoName, prNumber: pr.number) {
                    prTimeline = cachedTimeline
                    isLoadingPRTimeline = false
                } else if let diskTimeline = PRTimelineCache.shared.get(owner: owner, repo: repoName, prNumber: pr.number) {
                    prTimeline = diskTimeline
                    isLoadingPRTimeline = false
                } else {
                    prTimeline = []
                    isLoadingPRTimeline = true
                }

                if let cachedChecks = PRTimelineCache.shared.getChecksInMemory(owner: owner, repo: repoName, prNumber: pr.number) {
                    prChecks = cachedChecks
                    isLoadingPRChecks = false
                } else if let diskChecks = PRTimelineCache.shared.getChecks(owner: owner, repo: repoName, prNumber: pr.number) {
                    prChecks = diskChecks
                    isLoadingPRChecks = false
                } else {
                    prChecks = []
                    isLoadingPRChecks = true
                }

                prMeta = PRTimelineCache.shared.getMeta(owner: owner, repo: repoName, prNumber: pr.number)
                if let meta = prMeta {
                    prTimeline = meta.applyingThreadState(to: prTimeline)
                }
                prCommits = prCommitsCache[pr.number] ?? []
                selectedPRCommitSHA = nil
                let cachedFiles = PRTimelineCache.shared.getFiles(owner: owner, repo: repoName, prNumber: pr.number) ?? []
                prFiles = cachedFiles
                selectedPRFile = cachedFiles.first
                prViewedFiles = PRViewedFilesStore.load(owner: owner, repo: repoName, prNumber: pr.number)

                prTimelineError = nil
                loadPRDetails(for: pr)
            } else if selectedPR == nil {
                stopPRPolling()
            }
        }
    }
    @Published public var prFilter: PRFilter = .myOpen
    @Published public var prTabCounts: [PRFilter: Int] = [:]
    /// Tab counts narrowed to `prAuthorTabCountsLogin`; the "My …" tabs keep using `prTabCounts`.
    @Published public var prAuthorTabCounts: [PRFilter: Int] = [:]
    @Published public var prAuthorTabCountsLogin: String? = nil
    @Published public var prSearchText: String = ""
    @Published public var prFiles: [PRFileChange] = []
    @Published public var selectedPRFile: PRFileChange? = nil
    @Published public var isLoadingPRFiles: Bool = false
    @Published public var prChecks: [PRCheckRun] = []
    @Published public var isLoadingPRChecks: Bool = false
    @Published public var selectedPRTab: PRDetailTab = .overview {
        didSet {
            if selectedPRTab != oldValue {
                recordNavigationStep()
            }
        }
    }
    @Published public var prTimeline: [PRTimelineItem] = []
    @Published public var isLoadingPRTimeline: Bool = false
    @Published public var prTimelineError: String? = nil
    @Published public var prMeta: PRDetailMeta? = nil
    @Published public var repoLabels: [PRLabel] = []
    /// Keys of PR actions currently running (e.g. "merge", "review", "rerun"), used to show spinners and prevent double submits.
    @Published public var prActionsInFlight: Set<String> = []
    @Published public var showMergeSheet: Bool = false
    /// Set to ask the conversation web view to scroll to the merge box; the web view clears it once handled.
    @Published public var prScrollToMergeBoxRequested: Bool = false
    /// Commits on the base branch missing from each PR's head, keyed by PR number.
    @Published public var prBehindCounts: [Int: Int] = [:]
    @Published public var prNavPanelRequested: Bool = false
    @Published public var prThreadFilter: PRConversationView.ResolvedFilter = .all
    /// Author filter on the PR list; `nil` means everyone.
    @Published public var prAuthorFilter: String? = nil
    /// Total matches for the list as currently queried (tab plus author), for the "Showing N of M" label.
    @Published public var prListTotalCount: Int?
    /// Login of the authenticated GitHub user (from `GET /user`), cached across launches.
    @Published public var gitHubViewerLogin: String? = UserDefaults.standard.string(forKey: "gitxx_github_viewer_login")
    /// "filename@patchHash" keys of files marked as viewed for the selected PR.
    @Published public var prViewedFiles: Set<String> = []
    @Published public var prLastRefreshedAt: Date? = nil
    var prPollTask: Task<Void, Never>? = nil
    /// In-flight PR detail loads keyed by kind; a newer load of the same kind, or switching PRs, cancels them.
    var prDetailTasks: [String: Task<Void, Never>] = [:]
    var prListTask: Task<Void, Never>? = nil
    /// File texts at a commit ("sha:path"), used to expand diff context.
    var prFileContentCache: [String: String] = [:]
    /// Inline CI job logs keyed by Actions job id.
    @Published public var prJobLogs: [String: PRJobLogState] = [:]

    // Modal & Sheet Presentation
    @Published public var showCommandPalette: Bool = false {
        didSet {
            if !showCommandPalette && oldValue {
                refreshRepoSilently()
            }
        }
    }
    @Published public var commandPaletteInitialQuery: String = ""
    @Published public var showBranchPicker: Bool = false {
        didSet {
            if showBranchPicker && !oldValue {
                refreshRepoSilently()
            }
        }
    }
    @Published public var showRepoPicker: Bool = false {
        didSet {
            if showRepoPicker && !oldValue {
                refreshRepoSilently()
            }
        }
    }
    @Published public var showSettings: Bool = false {
        didSet {
            if !showSettings && oldValue {
                refreshRepoSilently()
            }
        }
    }
    @Published public var showReviewModal: Bool = false
    @Published public var showCreatePRSheet: Bool = false
    /// Failed git operation shown as a dialog with suggested fixes.
    @Published public var operationError: GitOperationError?
    /// Landing page (recent repositories and the viewer's PRs across repos); shown at launch unless a repo was requested.
    @Published public var showHome: Bool = {
        let args = CommandLine.arguments
        if args.contains("--home") { return true }
        let wantsRepo = args.contains("--open") || args.contains("--history") || args.contains("--prs")
            || args.dropFirst().contains { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        return !wantsRepo
    }() {
        didSet { if showHome != oldValue { recordNavigationStep() } }
    }
    @Published public var homeTab: HomeTab = .repositories
    @Published public var myPullRequests: [CrossRepoPullRequest] = []
    @Published public var myPullRequestsLoading = false
    @Published public var myPullRequestsError: String?
    @Published public var myPullRequestsOpen = true
    @Published public var homeRepoFilter: String?
    @Published public var myPullRequestsEnriching: Set<String> = []
    /// A failure dialog the user set aside to inspect a file; the Changes tab offers a way back to it.
    @Published public var parkedOperationError: GitOperationError?
    @Published public var showTerminalResultSheet: Bool = false
    @Published public var showHelpModal: Bool = false
    @Published public var showCLIInstallSuccessModal: Bool = false

    // Keyboard Shortcuts & Keybindings
    @Published public var shortcuts: [AppShortcutItem] = {
        if let data = UserDefaults.standard.data(forKey: "gitxx_custom_shortcuts"),
           let decoded = try? JSONDecoder().decode([AppShortcutItem].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return AppShortcutItem.defaultShortcuts
    }() {
        didSet {
            saveShortcuts()
        }
    }

    public var isCLIInstalled: Bool {
        let path = NSHomeDirectory() + "/.local/bin/gitxx"
        return FileManager.default.fileExists(atPath: path)
    }

    public func saveShortcuts() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(data, forKey: "gitxx_custom_shortcuts")
        }
    }

    public func updateShortcut(id: String, newKey: String, newModifiers: [String]) {
        if let index = shortcuts.firstIndex(where: { $0.id == id }) {
            shortcuts[index].currentKey = newKey
            shortcuts[index].currentModifiers = newModifiers
            saveShortcuts()
        }
    }

    public func resetShortcut(id: String) {
        if let index = shortcuts.firstIndex(where: { $0.id == id }) {
            shortcuts[index].resetToDefault()
            saveShortcuts()
        }
    }

    public func resetAllShortcuts() {
        shortcuts = AppShortcutItem.defaultShortcuts
        saveShortcuts()
        showToast("Reset all shortcuts to defaults", type: .info)
    }

    // Theme & Accent State
    @Published public var accentTheme: AccentTheme = {
        if let saved = UserDefaults.standard.string(forKey: "selectedAccentTheme"),
           let theme = AccentTheme.from(saved) {
            return theme
        }
        return .classicGreen
    }() {
        didSet {
            UserDefaults.standard.set(accentTheme.rawValue, forKey: "selectedAccentTheme")
        }
    }

    // Multiple Git User Profiles
    @Published public var gitProfiles: [GitUserProfile] = {
        var profiles: [GitUserProfile] = []
        if let data = UserDefaults.standard.data(forKey: "gitUserProfiles"),
           let decoded = try? JSONDecoder().decode([GitUserProfile].self, from: data),
           !decoded.isEmpty {
            profiles = decoded
        } else {
            profiles = GitUserProfile.defaultProfiles
        }

        return profiles
    }() {
        didSet {
            saveProfiles()
        }
    }

    @Published public var activeProfileId: String = {
        UserDefaults.standard.string(forKey: "activeGitProfileId") ?? "personal"
    }() {
        didSet {
            UserDefaults.standard.set(activeProfileId, forKey: "activeGitProfileId")
            refreshRepoSilently()
        }
    }

    public var activeProfile: GitUserProfile {
        gitProfiles.first(where: { $0.id == activeProfileId })
            ?? gitProfiles.first
            ?? GitUserProfile.defaultProfiles[0]
    }

    public var currentUserIdentities: Set<String> {
        var set = Set<String>()
        if !activeProfile.githubUsername.isEmpty {
            set.insert(activeProfile.githubUsername.lowercased())
        }
        if !activeProfile.name.isEmpty {
            set.insert(activeProfile.name.lowercased())
        }
        for p in gitProfiles {
            if !p.githubUsername.isEmpty {
                set.insert(p.githubUsername.lowercased())
            }
            if !p.name.isEmpty {
                set.insert(p.name.lowercased())
            }
        }
        if let login = gitHubViewerLogin, !login.isEmpty {
            set.insert(login.lowercased())
        }
        return set
    }

    public func isCurrentUserAuthor(of pr: PullRequest) -> Bool {
        let author = pr.authorName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        if author.isEmpty { return false }
        let ids = currentUserIdentities
        if ids.contains(author) { return true }
        for id in ids {
            if author == id || author.contains(id) || id.contains(author) {
                return true
            }
        }
        if author.contains("santhos") {
            return true
        }
        return false
    }

    @Published public var initialPreferencesCategory: String? = nil

    // Terminal State & Entry History
    @Published public var selectedShell: TerminalShell = {
        if let saved = UserDefaults.standard.string(forKey: "selectedTerminalShell"),
           let shell = TerminalShell(rawValue: saved) {
            return shell
        }
        return .bash
    }() {
        didSet {
            UserDefaults.standard.set(selectedShell.rawValue, forKey: "selectedTerminalShell")
        }
    }
    @Published public var terminalEntries: [TerminalEntry] = []
    @Published public var terminalInput: String = ""
    public var terminalCommandHistory: [String] = []
    public var terminalHistoryIndex: Int = -1

    // Native Git CLI Execution State
    public struct TerminalExecutionResult: Identifiable {
        public let id = UUID()
        public let command: String
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public let date: Date = Date()
        public var isSuccess: Bool { exitCode == 0 }
    }
    @Published public var lastTerminalResult: TerminalExecutionResult?
    @Published public var isExecutingGitCommand: Bool = false

    // AI Commit & GitHub Copilot State
    @Published public var aiProvider: AIProvider = {
        if let saved = UserDefaults.standard.string(forKey: "aiProvider"),
           let p = AIProvider(rawValue: saved) {
            return p
        }
        return .githubCopilot
    }() {
        didSet {
            UserDefaults.standard.set(aiProvider.rawValue, forKey: "aiProvider")
        }
    }

    @Published public var commitStyle: CommitStyle = {
        if let saved = UserDefaults.standard.string(forKey: "commitStyle"),
           let s = CommitStyle(rawValue: saved) {
            return s
        }
        return .conventional
    }() {
        didSet {
            UserDefaults.standard.set(commitStyle.rawValue, forKey: "commitStyle")
        }
    }

    @Published public var copilotModel: CopilotModel = {
        if let saved = UserDefaults.standard.string(forKey: "copilotModel"),
           let m = CopilotModel(rawValue: saved) {
            return m
        }
        return .gpt4o
    }() {
        didSet {
            UserDefaults.standard.set(copilotModel.rawValue, forKey: "copilotModel")
        }
    }

    @Published public var isGeneratingCommitAI: Bool = false
    private var currentAITask: Task<Void, Never>? = nil
    @Published public var isCopilotConnected: Bool = false
    @Published public var copilotUsername: String? = nil
    @Published public var activeDeviceCode: DeviceCodeResponse? = nil
    @Published public var isDeviceFlowPolling: Bool = false
    @Published public var showAIAuthPopover: Bool = false
    @Published public var copilotQuota: CopilotQuotaInfo? = nil
    @Published public var appAIConsumedCount: Int = {
        UserDefaults.standard.integer(forKey: "gitxxCopilotRequestsUsed")
    }()
    @Published public var isRefreshingQuota: Bool = false
    @Published public var repoButtonWidth: CGFloat = 230
    /// Window is about half a laptop screen; side panels that don't fit are hidden.
    @Published public var isNarrowWidth = false
    @Published public var isReducedWidth: Bool = false
    @Published public var commitPaneHeight: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "gitxxCommitPaneHeight")
        return saved >= 125 ? CGFloat(saved) : 185
    }() {
        didSet {
            UserDefaults.standard.set(Double(commitPaneHeight), forKey: "gitxxCommitPaneHeight")
        }
    }

    // App Status & Rate Limit
    @Published public var isLoading: Bool = false
    @Published public var toastMessage: String?
    @Published public var toastType: ToastType = .info
    @Published public var githubToken: String?
    @Published public var authMethod: GitHubAuthMethod = .pat
    @Published public var isAuthenticatingGitHubOAuth: Bool = false
    @Published public var githubOAuthUserCode: String? = nil
    @Published public var githubOAuthVerificationUri: String? = nil
    @Published public var githubOAuthError: String? = nil
    @Published public var isPollingOAuth: Bool = false
    @Published public var showOAuthModal: Bool = false
    @Published public var authenticatedUsername: String? = nil
    @Published public var rateLimit: GitHubRateLimitInfo = GitHubRateLimitInfo()
    @Published public var hasExplicitlyLoadedDemoPRs: Bool = false
    @Published public var isLoadingPRs: Bool = false
    @Published public var prCommits: [PRCommit] = []
    @Published public var isLoadingPRCommits = false
    @Published public var selectedPRCommitSHA: String?
    @Published public var prCommitFiles: [String: [PRFileChange]] = [:]
    var prCommitsCache: [Int: [PRCommit]] = [:]
    @Published public var isLoadingMorePRs = false
    @Published public var prListHasMore = false
    /// Rows still waiting for diff stats / CI; the list shows placeholders for them.
    @Published public var prsAwaitingEnrichment: Set<Int> = []
    var prListCursor: String?
    @Published public var prFetchError: String? = nil
    @Published public var apiRequestLogs: [APIRequestLogEntry] = []
    @Published public var apiLogStats: APILogStats = APILogStats()
    @Published public var detectedCLIToken: String? = nil

    public var effectiveGitHubToken: String? {
        if let token = githubToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        if let cli = detectedCLIToken, !cli.isEmpty {
            return cli
        }
        return GitHubAPIService.getGitHubCLIToken()
    }

    public var hasConfiguredGitHubToken: Bool {
        return effectiveGitHubToken != nil
    }

    let gitService = GitService.shared
    let gitHubService = GitHubAPIService.shared

    public init() {
        self.githubToken = KeychainHelper.getGitHubToken()
        if let savedMethod = UserDefaults.standard.string(forKey: "gitxx_github_auth_method"),
           let method = GitHubAuthMethod(rawValue: savedMethod) {
            self.authMethod = method
        } else if self.githubToken?.hasPrefix("gho_") == true {
            self.authMethod = .oauth
        } else if self.githubToken != nil {
            self.authMethod = .pat
        }

        if let token = self.githubToken, !token.isEmpty {
            Task { [weak self] in
                guard let self = self else { return }
                let (isValid, username, _) = await self.gitHubService.validateToken(token)
                if isValid, let username = username {
                    await MainActor.run {
                        self.authenticatedUsername = username
                    }
                }
            }
        }

        self.recentRepos = Self.loadSavedRecentRepos()

        // Check if custom path was given as command-line argument
        let customPath = CommandLine.arguments.dropFirst().first(where: {
            !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0)
        })

        // Custom path, then the most recently used repo, then currentDirectory
        let initialPath: String
        if let custom = customPath {
            initialPath = custom
        } else if let recent = recentRepos.first {
            initialPath = recent.path
        } else {
            initialPath = FileManager.default.currentDirectoryPath
        }

        loadRepo(path: initialPath)

        if CommandLine.arguments.contains("--history") {
            self.activeTab = .history
        } else if CommandLine.arguments.contains("--prs") {
            self.activeTab = .pullRequests
        }

        checkCopilotStatus()
        checkGitHubCLIToken()
        setupAutoRefreshHooks()

        refreshAPILogs()
        NotificationCenter.default.addObserver(forName: GitHubAPILogger.logUpdatedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAPILogs()
            }
        }

        // Navigation History Observer Hooks
        NotificationCenter.default.addObserver(forName: NSNotification.Name("NavigateBackAction"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.navigateBack()
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("NavigateForwardAction"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.navigateForward()
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("TogglePageHistoryAction"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showPageHistoryPopover.toggle()
            }
        }

        setupNavigationShortcutMonitor()
        recordNavigationStep()

        // Handle repository open request from terminal CLI
        NotificationCenter.default.addObserver(forName: NSNotification.Name("OpenRepoPathFromCLI"), object: nil, queue: .main) { [weak self] note in
            if let path = note.object as? String {
                Task { @MainActor [weak self] in
                    self?.requestOpenRepo(path: path)
                }
            }
        }
    }

    func saveRecentRepos() {
        if let encoded = try? JSONEncoder().encode(recentRepos) {
            UserDefaults.standard.set(encoded, forKey: "gitxxRecentRepos")
        }
    }

    private static func loadSavedRecentRepos() -> [GitRepository] {
        if let data = UserDefaults.standard.data(forKey: "gitxxRecentRepos"),
           let repos = try? JSONDecoder().decode([GitRepository].self, from: data) {
            return repos.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        return []
    }

    // MARK: - Auto-Refresh, Periodic Polling & Focus Hooks

    private var periodicRefreshTimer: Timer?
    private var periodicFetchTimer: Timer?
    let repoFileWatcher = RepoFileWatcher()
    private var isRefreshing: Bool = false
    private var pendingRefresh: Bool = false
    /// Identifies the refresh that owns `isRefreshing`; a refresh of a repo we've since left must not clear it.
    private var refreshToken: UUID?
    private var refreshingRepoPath: String?
    /// Last-known local state per repository, restored instantly when switching back to it.
    var repoSnapshots: [String: RepoSnapshot] = [:]
    var repoLoadGeneration = 0
    /// Repository being opened / branch being checked out, for progress in the toolbar.
    @Published public var switchingRepoPath: String?
    @Published public var switchingBranchTo: String?
    private var lastStatusDuration: TimeInterval = 0
    private var lastStatusFinishedAt = Date.distantPast
    private var throttledRefreshScheduled = false

    private func setupAutoRefreshHooks() {
        // 1. Native FSEvents File System Watcher Callback
        repoFileWatcher.onRepoChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshRepoSilently()
            }
        }

        // 2. Periodic Polling Timer (Every 3.5 seconds)
        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollRefresh()
            }
        }

        // 3. Periodic Background Remote Fetch Timer (Every 60 seconds)
        periodicFetchTimer?.invalidate()
        periodicFetchTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.backgroundFetchOrigin()
            }
        }

        // 4. App & Window Focus Lifecycle Observers
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRepoSilently()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRepoSilently()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRepoSilently()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SwitchPRSubTab"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let tabName = note.object as? String
            Task { @MainActor [weak self] in
                if tabName == "filesChanged" {
                    self?.selectedPRTab = .filesChanged
                } else if tabName == "checks" {
                    self?.selectedPRTab = .checks
                } else if tabName == "commits" {
                    self?.selectedPRTab = .commits
                } else {
                    self?.selectedPRTab = .overview
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("SelectPRNumber"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let num = note.object as? Int {
                DispatchQueue.main.async { [weak self] in
                    if let match = self?.pullRequests.first(where: { $0.number == num }) {
                        self?.selectedPR = match
                    }
                }
            }
        }
    }

    // MARK: - Toast Banner

    public func showToast(_ message: String, type: ToastType = .info) {
        self.toastMessage = message
        self.toastType = type
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if self?.toastMessage == message {
                self?.toastMessage = nil
            }
        }
    }

    // MARK: - Repository Operations

    /// "My open" / "My closed" imply author = me; leaving them clears an author filter that was set that way.
    /// Author applied server-side; "My open"/"My closed" already carry `author:@me`.
    var prListAuthorQualifier: String? {
        guard let author = prAuthorFilter, !author.isEmpty, prFilter != .myOpen, prFilter != .myClosed else { return nil }
        return author
    }

    /// Picks an author, moving between "My …" and the general tabs so the list query stays consistent.
    public func setPRAuthorFilter(_ login: String?) {
        let me = gitHubViewerLogin
        let isMe = login != nil && me != nil && login!.caseInsensitiveCompare(me!) == .orderedSame
        var target = prFilter
        if isMe {
            if target == .open { target = .myOpen } else if target == .closed { target = .myClosed }
        } else if target == .myOpen {
            target = .open
        } else if target == .myClosed {
            target = .closed
        }
        prAuthorFilter = login
        if prAuthorTabCountsLogin != login {
            prAuthorTabCounts = [:]
            prAuthorTabCountsLogin = login
        }
        if target != prFilter {
            setPRFilter(target)
            prAuthorFilter = login
        } else {
            reloadPRListFromScratch()
        }
    }

    private func reloadPRListFromScratch() {
        pullRequests = []
        isLoadingPRs = true
        prListCursor = nil
        prListHasMore = false
        prListTotalCount = nil
        prListTask?.cancel()
        prListTask = Task { await loadPRsAsync() }
    }

    private func syncAuthorFilter(for filter: PRFilter) {
        let me = gitHubViewerLogin
        if filter == .myOpen || filter == .myClosed {
            if let me { prAuthorFilter = me } else { ensureGitHubViewerLogin() }
        } else if let me, prAuthorFilter?.caseInsensitiveCompare(me) == .orderedSame {
            prAuthorFilter = nil
        }
    }

    public func ensureGitHubViewerLogin() {
        guard gitHubViewerLogin == nil, let token = effectiveGitHubToken, !token.isEmpty else { return }
        Task {
            let result = await gitHubService.validateToken(token)
            guard let login = result.username else { return }
            self.gitHubViewerLogin = login
            UserDefaults.standard.set(login, forKey: "gitxx_github_viewer_login")
            if self.prFilter == .myOpen || self.prFilter == .myClosed { self.prAuthorFilter = login }
        }
    }

    /// Drops the previous repository's PR list and open PR so the PR tab shows the new repo's list.
    func resetRepoScopedPRState() {
        stopPRPolling()
        selectedPR = nil
        pullRequests = []
        prTabCounts = [:]
        prTimeline = []
        prChecks = []
        prFiles = []
        selectedPRFile = nil
        prMeta = nil
        repoLabels = []
        prFetchError = nil
        prThreadFilter = .all
        prAuthorFilter = (prFilter == .myOpen || prFilter == .myClosed) ? gitHubViewerLogin : nil
        selectedPRTab = .overview
    }

    // MARK: - CLI & External Open Requests

    public func requestOpenRepo(path: String) {
        let standardPath = URL(fileURLWithPath: path).standardized.resolvingSymlinksInPath().path
        showHome = false

        Task { @MainActor in
            let isRepo = await gitService.isGitRepository(at: standardPath)
            guard isRepo else {
                showToast("Not a git repository: \((standardPath as NSString).lastPathComponent)", type: .error)
                return
            }

            // Find top-level root of repository
            let repoRoot: String
            if let result = try? await gitService.execute(arguments: ["rev-parse", "--show-toplevel"], in: standardPath), result.isSuccess {
                let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                repoRoot = trimmed.isEmpty ? standardPath : trimmed
            } else {
                repoRoot = standardPath
            }

            // 1. If currently opened active repository
            if let current = currentRepo, current.path == repoRoot {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                showToast("Repository '\(current.name)' is already open", type: .info)
                return
            }

            // 2. If already opened previously (in recent repositories)
            if recentRepos.contains(where: { $0.path == repoRoot }) {
                loadRepo(path: repoRoot)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                showToast("Opened repository '\((repoRoot as NSString).lastPathComponent)'", type: .info)
                return
            }

            // 3. Opening for the first time -> Ask for confirmation
            let name = await gitService.getRepoName(at: repoRoot)
            let branches = (try? await gitService.getBranches(at: repoRoot)) ?? []
            let branch = branches.first(where: { $0.isCurrent })?.name ?? "main"
            let remote = await gitService.getRemoteUrl(at: repoRoot)
            let candidate = GitRepository(name: name, path: repoRoot, currentBranch: branch, remoteUrl: remote)

            self.pendingFirstTimeRepo = candidate
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    public func confirmOpenFirstTimeRepo() {
        guard let repo = pendingFirstTimeRepo else { return }
        pendingFirstTimeRepo = nil
        loadRepo(path: repo.path)
        showToast("Opened repository '\(repo.name)'", type: .info)
    }

    public func cancelOpenFirstTimeRepo() {
        pendingFirstTimeRepo = nil
    }

    public func installCLIInPath() {
        let bundleResourcePath = Bundle.main.resourcePath ?? ""
        let bundledCLI = bundleResourcePath + "/bin/gitxx"
        let fallbackDevCLI = NSHomeDirectory() + "/work/gitxx/bin/gitxx"
        let sourcePath = FileManager.default.fileExists(atPath: bundledCLI) ? bundledCLI : fallbackDevCLI

        guard FileManager.default.fileExists(atPath: sourcePath) else {
            showToast("Could not locate gitxx CLI executable", type: .error)
            return
        }

        let targetDir = NSHomeDirectory() + "/.local/bin"
        let targetPath = targetDir + "/gitxx"

        do {
            try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: targetPath) {
                try FileManager.default.removeItem(atPath: targetPath)
            }
            try FileManager.default.createSymbolicLink(atPath: targetPath, withDestinationPath: sourcePath)
            self.showCLIInstallSuccessModal = true
        } catch {
            showToast("Failed to install CLI: \(error.localizedDescription)", type: .error)
        }
    }

    public func refreshRepo() {
        Task {
            await self.refreshRepoAsync(silent: false)
        }
    }

    public func refreshRepoSilently() {
        // Big repos can take seconds per `git status`; space background refreshes out relative to that cost.
        let minGap = max(1.0, lastStatusDuration * 3)
        let wait = minGap - Date().timeIntervalSince(lastStatusFinishedAt)
        if wait > 0 {
            guard !throttledRefreshScheduled else { return }
            throttledRefreshScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.throttledRefreshScheduled = false
                Task { await self.refreshRepoAsync(silent: true) }
            }
            return
        }
        Task {
            await self.refreshRepoAsync(silent: true)
        }
    }

    /// Timer fallback for changes FSEvents misses; the watcher handles the common case.
    private func pollRefresh() {
        guard Date().timeIntervalSince(lastStatusFinishedAt) > max(15, lastStatusDuration * 6) else { return }
        refreshRepoSilently()
    }

    /// `includeHistory: false` skips reloading branches and the commit log unless HEAD's branch or sync state moved
    /// (staging can't change either, and they're slow on large repos).
    func refreshRepoAsync(silent: Bool = false, includeHistory: Bool = true) async {
        guard let repo = currentRepo else { return }

        if isRefreshing, refreshingRepoPath == repo.path {
            pendingRefresh = true
            return
        }
        let token = UUID()
        refreshToken = token
        refreshingRepoPath = repo.path
        isRefreshing = true
        if !silent {
            self.isLoading = true
        }

        defer {
            if refreshToken == token {
                if !silent {
                    self.isLoading = false
                }
                isRefreshing = false
                refreshingRepoPath = nil
                if pendingRefresh {
                    pendingRefresh = false
                    refreshRepoSilently()
                }
            }
        }
        /// Results for a repository the user has already left must not land in the new one's state.
        func stillCurrent() -> Bool { currentRepo?.path == repo.path && refreshToken == token }

        // The branch list and log don't depend on status; start them now instead of after status + diff.
        let eagerHistory = self.commits.isEmpty || (!silent && includeHistory)
        let historyRefAtStart = historyRef
        let historyTask: Task<([GitBranch], [GitCommit]), Error>? = eagerHistory ? Task { [gitService] in
            async let branchList = gitService.getBranches(at: repo.path)
            async let commitList = gitService.getLog(at: repo.path, maxCount: 200, ref: historyRefAtStart)
            return (try await branchList, try await commitList)
        } : nil

        do {
            let statusStart = Date()
            let status = try await gitService.getStatus(at: repo.path)
            guard stillCurrent() else { historyTask?.cancel(); return }
            lastStatusDuration = Date().timeIntervalSince(statusStart)
            lastStatusFinishedAt = Date()

            let branchChanged = self.currentBranch != status.branch
            let syncCountChanged = (self.commitsAhead != status.commitsAhead) || (self.commitsBehind != status.commitsBehind)
            let filesChanged = self.files != status.files
            let statusChanged = branchChanged || syncCountChanged || filesChanged

            self.currentBranch = status.branch
            self.commitsAhead = status.commitsAhead
            self.commitsBehind = status.commitsBehind
            self.files = status.files

            // Auto-select first meaningful file if nothing selected, or if selected file was deleted
            if self.selectedFile == nil || !self.files.contains(where: { $0.id == self.selectedFile?.id }) {
                let samePath = self.files.first { $0.path == self.selectedFile?.path }
                let candidate = samePath ?? self.files.first(where: { !$0.filename.hasSuffix(".DS_Store") }) ?? self.files.first
                self.selectedFile = candidate
            } else if let selected = self.selectedFile, let fresh = self.files.first(where: { $0.id == selected.id }), fresh != selected {
                self.selectedFile = fresh
            }
            if let selected = self.selectedFile {
                await loadDiffForSelectedFile(selected)
                guard stillCurrent() else { historyTask?.cancel(); return }
            } else {
                self.currentDiff = nil
            }
            if filesChanged { prefetchWorkingDiffs() }

            // Load Branches & Commits in parallel if status changed, not silent, or empty
            let historyMayHaveChanged = includeHistory || branchChanged || syncCountChanged
            if self.commits.isEmpty || (historyMayHaveChanged && (!silent || statusChanged)) {
                let loaded: ([GitBranch], [GitCommit])
                if let historyTask, historyRefAtStart == historyRef, !branchChanged {
                    loaded = try await historyTask.value
                } else {
                    historyTask?.cancel()
                    async let branchList = gitService.getBranches(at: repo.path)
                    async let commitList = gitService.getLog(at: repo.path, maxCount: 200, ref: historyRef)
                    loaded = (try await branchList, try await commitList)
                }
                if let ref = historyRef {
                    let foreign = await gitService.commitsNotInHead(at: repo.path, ref: ref)
                    guard stillCurrent() else { return }
                    self.historyForeignCommits = foreign
                }
                guard stillCurrent() else { return }

                if self.branches != loaded.0 { self.branches = loaded.0 }
                if self.commits != loaded.1 { self.commits = loaded.1 }

                if let firstCommit = self.commits.first,
                   self.selectedCommit == nil || !self.commits.contains(where: { $0.sha == self.selectedCommit?.sha }) {
                    self.selectedCommit = firstCommit
                    await loadDiffForSelectedCommit(firstCommit)
                }
            }

            historyTask?.cancel()
            saveRepoSnapshot()

            // Load PRs only if on PRs tab or explicit user refresh
            if self.activeTab == .pullRequests && (!silent || statusChanged) {
                await loadPRsAsync()
            }

        } catch {
            if !silent {
                showToast("Git status failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    public func backgroundFetchOrigin() {
        guard let repo = currentRepo, repo.remoteUrl != nil else { return }
        Task {
            do {
                try await gitService.fetch(at: repo.path)
                await MainActor.run {
                    self.lastFetchedDate = Date()
                }
                await refreshRepoAsync(silent: true)
            } catch {
                // Background fetch fails silently (e.g. offline)
            }
        }
    }

    // MARK: - Browser & Web Link Operations

    public var currentBrowserURLString: String? {
        guard let repo = currentRepo else { return nil }

        let ownerRepo = gitHubService.parseRepoOwnerAndName(from: repo.remoteUrl)
        let owner = ownerRepo?.owner
        let repoName = ownerRepo?.name ?? repo.name

        let baseURL: String
        if let o = owner {
            baseURL = "https://github.com/\(o)/\(repoName)"
        } else if let remote = repo.remoteUrl, remote.hasPrefix("http") {
            baseURL = remote.replacingOccurrences(of: ".git", with: "")
        } else {
            baseURL = "https://github.com/local/\(repoName)"
        }

        switch activeTab {
        case .changes:
            if let file = selectedFile {
                return "\(baseURL)/blob/\(currentBranch)/\(file.path)"
            } else {
                return "\(baseURL)/tree/\(currentBranch)"
            }
        case .history:
            if let commit = selectedCommit {
                return "\(baseURL)/commit/\(commit.sha)"
            } else {
                return "\(baseURL)/commits/\(currentBranch)"
            }
        case .pullRequests:
            if let pr = selectedPR, !pr.url.isEmpty {
                return pr.url
            } else if let pr = selectedPR {
                return "\(baseURL)/pull/\(pr.number)"
            } else {
                return "\(baseURL)/pulls"
            }
        case .terminal:
            return baseURL
        }
    }

    public var currentBrowserURL: URL? {
        guard let urlStr = currentBrowserURLString, let url = URL(string: urlStr) else { return nil }
        return url
    }

    public func copyCurrentBrowserLink() {
        guard let link = currentBrowserURLString else {
            showToast("No repository web link available", type: .info)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        showToast("Copied browser link to clipboard", type: .success)
    }

    public func openCurrentInBrowser() {
        guard let url = currentBrowserURL else {
            showToast("No browser URL available for this page", type: .info)
            return
        }
        NSWorkspace.shared.open(url)
        showToast("Opened in browser: \(url.lastPathComponent)", type: .info)
    }

    // MARK: - Browser-Style Back & Forward History Navigation

    public var currentNavigationLocation: NavigationLocation {
        if showHome {
            return NavigationLocation(page: .home, repoPath: nil, repoName: "Home", title: "Home")
        }
        let page: NavigationLocation.PageType
        let title: String

        switch activeTab {
        case .changes:
            page = .changes
            title = "Changes"
        case .history:
            page = .history(commitSha: selectedCommit?.sha)
            if let sha = selectedCommit?.sha {
                title = "Commit \(sha.prefix(7))"
            } else {
                title = "History"
            }
        case .pullRequests:
            if let pr = selectedPR {
                page = .pullRequestDetail(prNumber: pr.number, subTab: selectedPRTab)
                title = "PR #\(pr.number): \(pr.title)"
            } else {
                page = .pullRequestsIndex(filter: prFilter)
                title = "Pull Requests"
            }
        case .terminal:
            page = .terminal
            title = "Terminal"
        }

        return NavigationLocation(
            page: page,
            repoPath: currentRepo?.path,
            repoName: currentRepo?.name,
            title: title
        )
    }

    public func recordNavigationStep() {
        guard !isNavigatingHistory, !isCompoundNavigating else { return }

        let current = currentNavigationLocation
        recordVisitedLocation(current)

        if let last = lastRecordedLocation, last == current {
            return
        }

        if let last = lastRecordedLocation, last.repoPath != nil || last.page == .home {
            backStack.append(last)
            if backStack.count > 60 {
                backStack.removeFirst()
            }
            forwardStack.removeAll()
        }

        lastRecordedLocation = current
    }

    public func recordVisitedLocation(_ loc: NavigationLocation) {
        var updated = loc
        updated.timestamp = Date()
        visitedHistory.removeAll(where: { $0 == loc })
        visitedHistory.insert(updated, at: 0)
        if visitedHistory.count > 60 {
            visitedHistory.removeLast()
        }
    }

    public func navigateToHistoryItem(_ loc: NavigationLocation) {
        showPageHistoryPopover = false
        guard loc != currentNavigationLocation else { return }
        let current = currentNavigationLocation
        backStack.append(current)
        if backStack.count > 60 {
            backStack.removeFirst()
        }
        forwardStack.removeAll(where: { $0 == loc })
        isNavigatingHistory = true
        applyLocation(loc)
        lastRecordedLocation = loc
        isNavigatingHistory = false
        recordVisitedLocation(loc)
        showToast("Jumped to \(loc.title)", type: .info)
    }

    public func clearVisitedHistory() {
        visitedHistory.removeAll()
        let current = currentNavigationLocation
        visitedHistory.append(current)
        showToast("Cleared page history", type: .info)
    }

    public func navigateBack() {
        guard canNavigateBack, let previous = backStack.popLast() else { return }
        let current = currentNavigationLocation
        forwardStack.append(current)
        if forwardStack.count > 60 {
            forwardStack.removeFirst()
        }
        isNavigatingHistory = true
        applyLocation(previous)
        lastRecordedLocation = previous
        isNavigatingHistory = false
        recordVisitedLocation(previous)
        showToast("← \(previous.title)", type: .info)
    }

    public func navigateForward() {
        guard canNavigateForward, let next = forwardStack.popLast() else { return }
        let current = currentNavigationLocation
        backStack.append(current)
        if backStack.count > 60 {
            backStack.removeFirst()
        }
        isNavigatingHistory = true
        applyLocation(next)
        lastRecordedLocation = next
        isNavigatingHistory = false
        recordVisitedLocation(next)
        showToast("→ \(next.title)", type: .info)
    }

    public func applyLocation(_ loc: NavigationLocation) {
        if loc.page != .home, let path = loc.repoPath, path != currentRepo?.path {
            isCompoundNavigating = true
            Task {
                await switchRepository(to: path)
                isNavigatingHistory = true
                applyPage(loc)
                isNavigatingHistory = false
                isCompoundNavigating = false
                lastRecordedLocation = loc
            }
            return
        }
        applyPage(loc)
    }

    /// Loads `path` (if it isn't already open) and waits until it's the current repository.
    func switchRepository(to path: String) async {
        guard currentRepo?.path != path else { return }
        loadRepo(path: path)
        for _ in 0..<80 where currentRepo?.path != path {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Runs a multi-step navigation (e.g. switch repo, then open a PR) and records only where it ends up.
    func performCompoundNavigation(_ steps: @escaping () async -> Void) {
        isCompoundNavigating = true
        Task {
            await steps()
            isCompoundNavigating = false
            recordNavigationStep()
        }
    }

    private func applyPage(_ loc: NavigationLocation) {
        if loc.page == .home {
            showHome = true
            return
        }
        showHome = false
        withAnimation(.easeInOut(duration: 0.15)) {
            switch loc.page {
            case .changes:
                self.activeTab = .changes
            case .history(let commitSha):
                self.activeTab = .history
                if let sha = commitSha {
                    self.selectedCommit = self.commits.first(where: { $0.sha == sha })
                } else {
                    self.selectedCommit = nil
                }
            case .pullRequestsIndex(let filter):
                self.activeTab = .pullRequests
                self.selectedPR = nil
                self.prFilter = filter
            case .pullRequestDetail(let prNumber, let subTab):
                self.activeTab = .pullRequests
                if let match = self.pullRequests.first(where: { $0.number == prNumber }) {
                    self.selectedPR = match
                } else {
                    self.selectedPR = PullRequest(number: prNumber, title: "PR #\(prNumber)", authorName: "GitHub", headBranch: "main")
                }
                self.selectedPRTab = subTab
            case .terminal:
                self.activeTab = .terminal
            case .home:
                break
            }
        }
    }

    public func setupNavigationShortcutMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let flags = event.modifierFlags
            let hasCommand = flags.contains(.command)
            let hasShift = flags.contains(.shift)
            let hasControl = flags.contains(.control)
            let hasOption = flags.contains(.option)

            if !hasCommand && !hasControl && !hasOption, self.handlePRDetailLetterKey(event) {
                return nil
            }

            // Only proceed if Command is held, and no other modifiers (Shift, Control, Option)
            guard hasCommand && !hasShift && !hasControl && !hasOption else { return event }

            // If user is actively typing in an editable NSTextView / NSTextField, allow Command-Left/Right line navigation
            if let responder = event.window?.firstResponder as? NSTextView, responder.isEditable {
                return event
            }

            if event.keyCode == 123 { // Left Arrow (⌘←)
                if self.canNavigateBack {
                    self.navigateBack()
                }
                return nil
            } else if event.keyCode == 124 { // Right Arrow (⌘→)
                if self.canNavigateForward {
                    self.navigateForward()
                }
                return nil
            } else if event.keyCode == 14 { // 'E' key (⌘E) -> Toggle Page History Popover
                self.showPageHistoryPopover.toggle()
                return nil
            }
            return event
        }
    }

    /// Single-letter PR detail shortcuts: c Conversation, f Files, s Checks, g Jump-to panel.
    /// Ignored while typing, in sheets/overlays, and when the conversation web view has focus (its JS handles them).
    private func handlePRDetailLetterKey(_ event: NSEvent) -> Bool {
        guard activeTab == .pullRequests, selectedPR != nil,
              !showCommandPalette, !showRepoPicker, !showBranchPicker, !showReviewModal, !showSettings, !showHelpModal, !showCreatePRSheet,
              let window = event.window, window.attachedSheet == nil, !window.isSheet,
              let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else { return false }
        if let responder = window.firstResponder as? NSView {
            if let text = responder as? NSTextView, text.isEditable { return false }
            var view: NSView? = responder
            while let v = view {
                if v is WKWebView { return false }
                view = v.superview
            }
        }
        switch key {
        case "c": selectedPRTab = .overview
        case "f": selectedPRTab = .filesChanged
        case "s": selectedPRTab = .checks
        case "o": selectedPRTab = .commits
        case "g":
            selectedPRTab = .overview
            prNavPanelRequested = true
        case "[", "]":
            guard selectedPRTab == .filesChanged, !prFiles.isEmpty,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            let files = PRFileTree.isTreeMode ? PRFileTree.orderedFiles(prFiles) : prFiles
            let index = files.firstIndex { $0.filename == selectedPRFile?.filename } ?? -1
            let next = min(files.count - 1, max(0, index + (key == "]" ? 1 : -1)))
            selectedPRFile = files[next]
        default: return false
        }
        return true
    }

    // MARK: - Changes & Diff Loading

    public func selectFile(_ file: GitFileStatus) {
        self.selectedFile = file
        if let cached = workingDiffCache[diffCacheKey(file.path)], cached.statuses == files.filter({ $0.path == file.path }) {
            applyWorkingDiff(cached)
        }
        Task {
            await loadDiffForSelectedFile(file)
        }
    }

    /// Sorted by path so staging a file (which moves it within `git status` output) doesn't reorder the list.
    public var workingChanges: [WorkingChange] {
        WorkingChange.group(files).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func loadDiffForSelectedFile(_ file: GitFileStatus) async {
        guard let repo = currentRepo else { return }
        let change = workingChanges.first { $0.path == file.path }
        let result = await fetchWorkingDiff(file, change: change, repoPath: repo.path)
        guard currentRepo?.path == repo.path, pendingStagingOps == 0 else { return }
        workingDiffCache[diffCacheKey(file.path)] = result
        guard selectedFile?.path == file.path else { return }
        applyWorkingDiff(result)
    }

    /// GitHub Desktop-style line toggling: the index entry is rewritten right away, optimistically.
    public func setLinesStaged(_ keys: Set<DiffLineKey>, staged: Bool) {
        guard lineStagingEnabled, let repo = currentRepo, let file = selectedFile, let diff = currentDiff, !keys.isEmpty else { return }
        var desired = currentDiffStagedLines
        if staged { desired.formUnion(keys) } else { desired.subtract(keys) }
        guard desired != currentDiffStagedLines else { return }
        currentDiffStagedLines = desired
        let included = desired
        enqueueStaging { [gitService] in
            try await gitService.setStagedLines(at: repo.path, path: file.path, diff: diff, included: included)
        }
    }

    /// Reverts rows of the working-copy diff (and drops them from the index if they were staged).
    public func discardLines(_ keys: Set<DiffLineKey>) {
        guard lineStagingEnabled, let repo = currentRepo, let file = selectedFile, let diff = currentDiff, !keys.isEmpty else { return }
        let staged = currentDiffStagedLines
        let desired = staged.subtracting(keys)
        currentDiffStagedLines = desired
        enqueueStaging { [gitService] in
            if desired != staged {
                try await gitService.setStagedLines(at: repo.path, path: file.path, diff: diff, included: desired)
            }
            try await gitService.discardLines(at: repo.path, diff: diff, lines: keys)
        }
        showToast("Discarded \(keys.count) line\(keys.count == 1 ? "" : "s") in \(file.filename)", type: .info)
    }

    private func enqueueStaging(_ operation: @escaping @Sendable () async throws -> Void) {
        pendingStagingOps += 1
        let previous = stagingChain
        stagingChain = Task { [weak self] in
            await previous?.value
            do {
                try await operation()
            } catch {
                self?.showToast("Couldn't update staging: \(error.localizedDescription)", type: .error)
            }
            guard let self else { return }
            pendingStagingOps -= 1
            if pendingStagingOps == 0 { await refreshRepoAsync(silent: true, includeHistory: false) }
        }
    }

    /// Checkbox toggles update the list immediately; git runs in the staging queue and a status-only refresh follows.
    public func toggleStage(for file: GitFileStatus) {
        setFilesStaged([file.path], staged: !file.isStaged)
    }

    /// Stages or unstages whole files (file and folder checkboxes in the Changes list).
    public func setFilesStaged(_ paths: [String], staged: Bool) {
        guard let repo = currentRepo, !paths.isEmpty else { return }
        applyOptimisticStaging(Set(paths), staged: staged)
        enqueueStaging { [gitService] in
            if staged {
                try await gitService.run(["add", "-A", "--"] + paths, in: repo.path)
            } else {
                try await gitService.unstage(at: repo.path, files: paths)
            }
        }
    }

    public func stageAll() {
        guard let repo = currentRepo else { return }
        applyOptimisticStaging(Set(files.map(\.path)), staged: true)
        enqueueStaging { [gitService] in try await gitService.stageAll(at: repo.path) }
    }

    public func unstageAll() {
        guard let repo = currentRepo else { return }
        applyOptimisticStaging(Set(files.map(\.path)), staged: false)
        enqueueStaging { [gitService] in try await gitService.unstageAll(at: repo.path) }
    }

    /// Collapses each file's index/worktree entries into one entry on the requested side.
    private func applyOptimisticStaging(_ paths: Set<String>, staged: Bool) {
        var byPath: [String: [GitFileStatus]] = [:]
        for file in files where paths.contains(file.path) { byPath[file.path, default: []].append(file) }
        var emitted = Set<String>()
        var result: [GitFileStatus] = []
        for file in files {
            guard let entries = byPath[file.path] else { result.append(file); continue }
            guard emitted.insert(file.path).inserted else { continue }
            let index = entries.first { $0.isStaged }
            var entry = entries.first { !$0.isStaged } ?? entries[0]
            if staged {
                if entry.changeKind == .untracked { entry.changeKind = .added }
                if let index, index.changeKind == .added || index.changeKind == .renamed { entry.changeKind = index.changeKind }
            } else if index?.changeKind == .added {
                entry.changeKind = .untracked
            }
            entry.isStaged = staged
            result.append(entry)
        }
        files = result
        if let selected = selectedFile, paths.contains(selected.path) {
            if let fresh = result.first(where: { $0.path == selected.path }) { selectedFile = fresh }
            if lineStagingEnabled, let diff = currentDiff {
                currentDiffStagedLines = staged ? PartialPatch.changedLines(in: diff) : []
            }
        }
    }

    public func discardChanges(for file: GitFileStatus) {
        guard let repo = currentRepo else { return }
        Task {
            do {
                try await gitService.discardChanges(at: repo.path, files: [file.path])
                showToast("Discarded changes in \(file.filename)", type: .info)
                await refreshRepoAsync()
            } catch {
                showToast("Discard failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    public func commitStaged() {
        guard let repo = currentRepo else { return }
        let summary = commitSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            showToast("Please provide a commit summary", type: .error)
            return
        }

        let stagedCount = files.filter { $0.isStaged }.count
        if stagedCount == 0 {
            showToast("No files staged to commit. Staging all modified files...", type: .info)
            Task {
                try? await gitService.stageAll(at: repo.path)
                try? await gitService.commit(at: repo.path, summary: summary, description: self.commitDescription)
                self.commitSummary = ""
                self.commitDescription = ""
                self.showToast("Committed to \(self.currentBranch)", type: .success)
                await self.refreshRepoAsync()
            }
            return
        }

        Task {
            do {
                try await gitService.commit(at: repo.path, summary: summary, description: self.commitDescription)
                self.commitSummary = ""
                self.commitDescription = ""
                self.showToast("Committed to \(self.currentBranch)", type: .success)
                await self.refreshRepoAsync()
            } catch {
                let description = self.commitDescription
                presentGitFailure(GitRetryableOperation(title: "Commit failed", verb: "commit", success: "Committed to \(self.currentBranch)") { [weak self, gitService] in
                    try await gitService.commit(at: repo.path, summary: summary, description: description)
                    self?.commitSummary = ""
                    self?.commitDescription = ""
                }, error: error)
            }
        }
    }

    // MARK: - History Operations

    public func selectCommit(_ commit: GitCommit) {
        self.selectedCommit = commit
        Task {
            await loadDiffForSelectedCommit(commit)
        }
    }

    func loadDiffForSelectedCommit(_ commit: GitCommit) async {
        guard let repo = currentRepo else { return }
        do {
            let diff = try await gitService.getCommitDiff(at: repo.path, sha: commit.sha)
            self.commitDiff = diff
        } catch {
            self.commitDiff = nil
        }
    }

    // MARK: - Branch Operations

    public func checkoutBranch(_ branchName: String) {
        guard let repo = currentRepo, switchingBranchTo == nil else { return }
        switchingBranchTo = branchName
        Task {
            do {
                try await gitService.checkout(at: repo.path, branch: branchName)
                // Show the new branch as soon as HEAD moves; status, files and history follow.
                if let head = await headBranchName(at: repo.path), currentRepo?.path == repo.path {
                    currentBranch = head
                }
                switchingBranchTo = nil
                showToast("Switched to \(currentBranch)", type: .success)
                await refreshRepoAsync()
            } catch {
                switchingBranchTo = nil
                if let op = checkoutOperation(branchName) { presentGitFailure(op, error: error) }
                await refreshRepoAsync()
            }
        }
    }

    public func createBranch(name: String) {
        guard let repo = currentRepo else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switchingBranchTo = trimmed
        Task {
            defer { if switchingBranchTo == trimmed { switchingBranchTo = nil } }
            do {
                try await gitService.createBranch(at: repo.path, name: trimmed, checkout: true)
                if currentRepo?.path == repo.path { currentBranch = trimmed }
                switchingBranchTo = nil
                showToast("Created and checked out \(trimmed)", type: .success)
                await refreshRepoAsync()
            } catch {
                presentGitFailure(GitRetryableOperation(title: "Couldn't create \(trimmed)", verb: "create the branch", success: "Created and checked out \(trimmed)") { [gitService] in
                    try await gitService.createBranch(at: repo.path, name: trimmed, checkout: true)
                }, error: error)
            }
        }
    }

    // MARK: - Remote Synchronization

    @Published public var lastFetchedDate: Date? = nil

    public var lastFetchedText: String {
        guard let date = lastFetchedDate else { return "Never fetched" }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "Last fetched just now"
        } else if interval < 3600 {
            let mins = max(1, Int(interval / 60))
            return "Last fetched \(mins)m ago"
        } else {
            let hours = Int(interval / 3600)
            return "Last fetched \(hours)h ago"
        }
    }

    public func fetchOrigin() {
        guard let repo = currentRepo else { return }
        self.isFetching = true
        Task {
            do {
                try await gitService.fetch(at: repo.path)
                await MainActor.run {
                    self.lastFetchedDate = Date()
                    self.isFetching = false
                }
                await refreshRepoAsync()
            } catch {
                await MainActor.run {
                    self.isFetching = false
                }
                presentGitFailure(GitRetryableOperation(title: "Fetch failed", verb: "fetch") { [gitService] in
                    try await gitService.fetch(at: repo.path)
                }, error: error)
            }
        }
    }

    public func pullOrigin() {
        guard let repo = currentRepo else { return }
        self.isPulling = true
        Task {
            do {
                try await gitService.pull(at: repo.path)
                await MainActor.run {
                    self.lastFetchedDate = Date()
                    self.isPulling = false
                }
                await refreshRepoAsync()
            } catch {
                await MainActor.run {
                    self.isPulling = false
                }
                if let op = pullOperation() { presentGitFailure(op, error: error) }
            }
        }
    }

    public func pushOrigin() {
        guard let repo = currentRepo else { return }
        self.isPushing = true
        Task {
            do {
                try await gitService.push(at: repo.path, setUpstream: true, branch: self.currentBranch)
                await MainActor.run {
                    self.lastFetchedDate = Date()
                    self.isPushing = false
                }
                await refreshRepoAsync()
            } catch {
                await MainActor.run {
                    self.isPushing = false
                }
                if let op = pushOperation(branch: self.currentBranch) { presentGitFailure(op, error: error) }
            }
        }
    }

    public func forcePushOrigin() {
        guard let repo = currentRepo else { return }
        self.isPushing = true
        Task {
            do {
                try await gitService.run(["push", "--force-with-lease", "origin", self.currentBranch], in: repo.path)
                await MainActor.run {
                    self.lastFetchedDate = Date()
                    self.isPushing = false
                }
                await refreshRepoAsync()
            } catch {
                await MainActor.run {
                    self.isPushing = false
                }
                let branch = self.currentBranch
                presentGitFailure(GitRetryableOperation(title: "Force push failed", verb: "force push") { [gitService] in
                    try await gitService.run(["push", "--force-with-lease", "origin", branch], in: repo.path)
                }, error: error)
            }
        }
    }

    public func stashChanges() {
        guard let repo = currentRepo else { return }
        Task {
            do {
                try await gitService.stashPush(at: repo.path, message: "Stashed by GitXX at \(Date().formatted(date: .abbreviated, time: .shortened))", includeUntracked: true, keepIndex: false)
                await loadStashes()
                showToast("Stashed changes", type: .info)
                await refreshRepoAsync()
            } catch {
                showToast("Stash failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    public func stashPop() {
        guard let repo = currentRepo else { return }
        Task {
            do {
                try await gitService.stashPop(at: repo.path)
                showToast("Applied stashed changes", type: .success)
                await loadStashes()
                await refreshRepoAsync()
            } catch {
                presentGitFailure(GitRetryableOperation(title: "Stash pop failed", verb: "pop the stash") { [gitService] in
                    try await gitService.stashPop(at: repo.path)
                }, error: error)
                await refreshRepoAsync()
            }
        }
    }

    // MARK: - Pull Requests Operations

    public func setPRFilter(_ newFilter: PRFilter) {
        guard prFilter != newFilter else { return }
        prFilter = newFilter
        recordNavigationStep()
        syncAuthorFilter(for: newFilter)

        guard let repo = currentRepo else { return }
        let ownerRepo = gitHubService.parseRepoOwnerAndName(from: repo.remoteUrl)
        let owner = ownerRepo?.owner ?? "octocat"
        let repoName = ownerRepo?.name ?? repo.name

        // 1. If cached, show cached data IMMEDIATELY (0ms)
        prListTotalCount = nil
        if prListAuthorQualifier == nil, let cached = PRListCache.shared.get(owner: owner, repo: repoName, filter: newFilter) {
            self.pullRequests = cached.pullRequests
            self.isLoadingPRs = false
        } else {
            self.pullRequests = []
            self.isLoadingPRs = true
        }

        prListCursor = nil
        prListHasMore = false

        // 2. Fetch fresh from server for newFilter
        // Switching filters or repos quickly cancels the superseded list request.
        prListTask?.cancel()
        prListTask = Task { await loadPRsAsync() }
    }

    public func loadPRs() {
        guard let repo = currentRepo else { return }
        let ownerRepo = gitHubService.parseRepoOwnerAndName(from: repo.remoteUrl)
        let owner = ownerRepo?.owner ?? "octocat"
        let repoName = ownerRepo?.name ?? repo.name

        // Check cache first: if present, display immediately
        if prListAuthorQualifier == nil, let cached = PRListCache.shared.get(owner: owner, repo: repoName, filter: self.prFilter) {
            self.pullRequests = cached.pullRequests
            self.isLoadingPRs = false
        } else if self.pullRequests.isEmpty {
            self.isLoadingPRs = true
        }

        if let cachedCounts = PRListCache.shared.getTabCounts(owner: owner, repo: repoName) {
            self.prTabCounts = cachedCounts
        }

        Task {
            await loadPRsAsync()
        }
    }

    private func loadPRsAsync() async {
        guard let repo = currentRepo else { return }
        guard hasConfiguredGitHubToken else {
            if !hasExplicitlyLoadedDemoPRs {
                self.pullRequests = []
                self.selectedPR = nil
            }
            return
        }

        let targetFilter = self.prFilter
        let targetAuthor = self.prListAuthorQualifier
        let targetRepoPath = repo.path
        let ownerRepo = gitHubService.parseRepoOwnerAndName(from: repo.remoteUrl)
        let owner = ownerRepo?.owner ?? "octocat"
        let repoName = ownerRepo?.name ?? repo.name

        if self.pullRequests.isEmpty {
            self.isLoadingPRs = true
        }
        self.prFetchError = nil

        let token = self.effectiveGitHubToken
        let sort = UserDefaults.standard.string(forKey: "gitxx_pr_sort")
        let countsAuthor = self.prAuthorFilter.flatMap { $0.isEmpty ? nil : $0 }
        let countsTask = Task { [gitHubService] in
            try? await gitHubService.fetchPRTabCounts(owner: owner, repo: repoName, author: countsAuthor, token: token)
        }

        do {
            let page = try await gitHubService.fetchPRListPage(
                owner: owner, repo: repoName, filter: targetFilter, sort: sort, after: nil, author: targetAuthor, token: token
            )
            guard self.currentRepo?.path == targetRepoPath, self.prFilter == targetFilter,
                  self.prListAuthorQualifier == targetAuthor, !Task.isCancelled else { return }

            let known = Dictionary(self.pullRequests.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
            self.pullRequests = page.prs.map { Self.carryOverEnrichment(into: $0, from: known[$0.number]) }
            self.prsAwaitingEnrichment = Set(page.prs.filter { known[$0.number] == nil }.map(\.number))
            self.prListCursor = page.endCursor
            self.prListHasMore = page.hasNextPage
            self.isLoadingPRs = false
            self.prListTotalCount = page.totalCount
            if targetAuthor == nil {
                self.prTabCounts[targetFilter] = page.totalCount
            } else if self.prAuthorTabCountsLogin == targetAuthor {
                self.prAuthorTabCounts[targetFilter] = page.totalCount
            }

            await enrichPRs(page.prs.map(\.number), owner: owner, repo: repoName, filter: targetFilter, repoPath: targetRepoPath)
            guard self.currentRepo?.path == targetRepoPath, self.prFilter == targetFilter else { return }

            if let counts = await countsTask.value {
                if let countsAuthor {
                    for (f, count) in counts where f == .myOpen || f == .myClosed { self.prTabCounts[f] = count }
                    if self.prAuthorFilter == countsAuthor {
                        self.prAuthorTabCountsLogin = countsAuthor
                        self.prAuthorTabCounts = counts.filter { $0.key != .myOpen && $0.key != .myClosed }
                    }
                } else {
                    for (f, count) in counts { self.prTabCounts[f] = count }
                }
            }
            if targetAuthor == nil {
                PRListCache.shared.set(owner: owner, repo: repoName, filter: targetFilter,
                                       prs: Array(self.pullRequests.prefix(page.prs.count)), tabCounts: self.prTabCounts)
            }
            self.rateLimit = await gitHubService.getRateLimit()
            if let current = self.selectedPR, let refreshed = self.pullRequests.first(where: { $0.id == current.id }),
               refreshed.headSha != current.headSha || refreshed.ciStatus != current.ciStatus || refreshed.title != current.title {
                self.selectedPR = refreshed
                loadPRDetails(for: refreshed)
            }
        } catch {
            countsTask.cancel()
            if GitHubHTTP.isCancellation(error) || Task.isCancelled { return }
            await loadPRsLegacy(owner: owner, repo: repoName, filter: targetFilter, repoPath: targetRepoPath)
        }
    }

    /// Keeps stats from a previous load while fresh ones are fetched, so rows don't flash "+0 −0".
    static func carryOverEnrichment(into pr: PullRequest, from old: PullRequest?) -> PullRequest {
        guard let old else { return pr }
        var pr = pr
        pr.additions = old.additions
        pr.deletions = old.deletions
        pr.changedFilesCount = old.changedFilesCount
        pr.reviewVerdict = old.reviewVerdict
        pr.ciStatus = old.ciStatus
        pr.totalChecksCount = old.totalChecksCount
        pr.passedChecksCount = old.passedChecksCount
        return pr
    }

    /// Fills in diff stats, review decision and CI for listed PRs in small parallel batches.
    private func enrichPRs(_ numbers: [Int], owner: String, repo: String, filter: PRFilter, repoPath: String) async {
        let token = self.effectiveGitHubToken
        let batches = stride(from: 0, to: numbers.count, by: 9).map { Array(numbers[$0..<min($0 + 9, numbers.count)]) }
        await withTaskGroup(of: [Int: PullRequest].self) { group in
            for batch in batches {
                group.addTask { [gitHubService] in
                    (try? await gitHubService.fetchPREnrichment(owner: owner, repo: repo, numbers: batch, token: token)) ?? [:]
                }
            }
            for await result in group {
                guard self.currentRepo?.path == repoPath, self.prFilter == filter, !result.isEmpty else { continue }
                self.pullRequests = self.pullRequests.map { pr in
                    guard let e = result[pr.number] else { return pr }
                    return Self.carryOverEnrichment(into: pr, from: e)
                }
                self.prsAwaitingEnrichment.subtract(result.keys)
            }
        }
        self.prsAwaitingEnrichment.subtract(numbers)
    }

    /// Next page of the current list, triggered when the last row scrolls into view.
    public func loadMorePRs() {
        guard prListHasMore, !isLoadingMorePRs, let cursor = prListCursor, let repo = currentRepo else { return }
        let ownerRepo = gitHubService.parseRepoOwnerAndName(from: repo.remoteUrl)
        let owner = ownerRepo?.owner ?? "octocat"
        let repoName = ownerRepo?.name ?? repo.name
        let filter = prFilter, repoPath = repo.path
        let author = prListAuthorQualifier
        let token = effectiveGitHubToken
        let sort = UserDefaults.standard.string(forKey: "gitxx_pr_sort")
        isLoadingMorePRs = true
        Task {
            defer { self.isLoadingMorePRs = false }
            guard let page = try? await gitHubService.fetchPRListPage(
                owner: owner, repo: repoName, filter: filter, sort: sort, after: cursor, author: author, token: token
            ), self.currentRepo?.path == repoPath, self.prFilter == filter, self.prListAuthorQualifier == author,
               self.prListCursor == cursor else { return }
            let existing = Set(self.pullRequests.map(\.number))
            let fresh = page.prs.filter { !existing.contains($0.number) }
            self.pullRequests.append(contentsOf: fresh)
            self.prsAwaitingEnrichment.formUnion(fresh.map(\.number))
            self.prListCursor = page.endCursor
            self.prListHasMore = page.hasNextPage
            await enrichPRs(fresh.map(\.number), owner: owner, repo: repoName, filter: filter, repoPath: repoPath)
        }
    }

    /// Previous single-request path (GraphQL with REST fallback), used when the paged query fails.
    private func loadPRsLegacy(owner: String, repo repoName: String, filter targetFilter: PRFilter, repoPath targetRepoPath: String) async {
        do {
            let result = try await gitHubService.fetchPullRequestsServerFiltered(
                owner: owner,
                repo: repoName,
                filter: targetFilter,
                token: self.effectiveGitHubToken
            )
            PRListCache.shared.set(owner: owner, repo: repoName, filter: targetFilter, prs: result.prs, tabCounts: result.counts)
            guard self.currentRepo?.path == targetRepoPath else { return }
            if self.prFilter == targetFilter {
                self.pullRequests = result.prs
                self.prListHasMore = false
                self.prListCursor = nil
                self.isLoadingPRs = false
            }
            for (f, count) in result.counts {
                self.prTabCounts[f] = count
            }
        } catch {
            if GitHubHTTP.isCancellation(error) || Task.isCancelled { return }
            if self.prFilter == targetFilter {
                self.isLoadingPRs = false
                self.prFetchError = error.localizedDescription
                if self.pullRequests.isEmpty {
                    showToast("Failed to fetch PRs: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    public func loadPRDetails(for pr: PullRequest) {
        loadPRFiles(for: pr)
        loadPRCommits(for: pr)
        loadPRChecks(for: pr)
        loadPRTimeline(for: pr)
        loadPRMergeability(for: pr)
        loadPRMeta(for: pr)
        startPRPolling(for: pr)
    }

    public func loadPRTimeline(for pr: PullRequest) {
        guard let ctx = prRepoContext() else {
            self.prTimelineError = "No repository selected."
            self.isLoadingPRTimeline = false
            return
        }
        let (owner, repoName, tokenToUse) = (ctx.owner, ctx.repo, ctx.token)

        // 1. Fast cache hydrate if not already loaded from in-memory cache
        if self.prTimeline.isEmpty {
            if let cached = PRTimelineCache.shared.get(owner: owner, repo: repoName, prNumber: pr.number) {
                self.prTimeline = cached
                self.isLoadingPRTimeline = false
            } else {
                self.isLoadingPRTimeline = true
            }
        }
        self.prTimelineError = nil

        // 2. Silent background revalidation from GitHub API
        runPRDetailTask("timeline") { [self] in
            do {
                var items = try await gitHubService.fetchPRTimeline(
                    owner: owner,
                    repo: repoName,
                    prNumber: pr.number,
                    token: tokenToUse
                )
                guard self.selectedPR?.number == pr.number else { return }
                if let meta = self.prMeta, meta.prNumber == pr.number {
                    items = meta.applyingThreadState(to: items)
                }
                PRTimelineCache.shared.set(owner: owner, repo: repoName, prNumber: pr.number, items: items)
                if self.prTimeline != items {
                    self.prTimeline = items
                }
                self.isLoadingPRTimeline = false
                self.prTimelineError = nil
                self.prLastRefreshedAt = Date()
            } catch {
                guard !GitHubHTTP.isCancellation(error), !Task.isCancelled, self.selectedPR?.number == pr.number else { return }
                self.isLoadingPRTimeline = false
                if self.prTimeline.isEmpty {
                    self.prTimelineError = error.localizedDescription
                    self.showToast("Timeline: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    public func loadPRFiles(for pr: PullRequest) {
        guard let ctx = prRepoContext() else { return }
        if self.prFiles.isEmpty {
            self.isLoadingPRFiles = true
        }

        runPRDetailTask("files") { [self] in
            do {
                let files = try await gitHubService.fetchPRFiles(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, expectedCount: pr.changedFilesCount, token: ctx.token)
                PRTimelineCache.shared.setFiles(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, files: files)
                guard self.selectedPR?.number == pr.number else { return }
                self.isLoadingPRFiles = false
                if self.prFiles != files {
                    let previous = self.selectedPRFile?.filename
                    self.prFiles = files
                    self.selectedPRFile = files.first(where: { $0.filename == previous }) ?? files.first
                }
                guard !files.isEmpty else { return }

                let totalAdditions = files.reduce(0) { $0 + $1.additions }
                let totalDeletions = files.reduce(0) { $0 + $1.deletions }
                func withStats(_ item: PullRequest) -> PullRequest {
                    var copy = item
                    if totalAdditions > 0 { copy.additions = totalAdditions }
                    if totalDeletions > 0 { copy.deletions = totalDeletions }
                    copy.changedFilesCount = files.count
                    return copy
                }
                if let cur = self.selectedPR, cur.number == pr.number {
                    let updated = withStats(cur)
                    if updated != cur { self.selectedPR = updated }
                }
                if let idx = self.pullRequests.firstIndex(where: { $0.number == pr.number }) {
                    let updated = withStats(self.pullRequests[idx])
                    if updated != self.pullRequests[idx] { self.pullRequests[idx] = updated }
                }
            } catch {
                if !GitHubHTTP.isCancellation(error), !Task.isCancelled, self.selectedPR?.number == pr.number {
                    self.isLoadingPRFiles = false
                }
            }
        }
    }

    public func loadPRChecks(for pr: PullRequest) {
        guard let ctx = prRepoContext() else { return }
        let (owner, repoName, tokenToUse) = (ctx.owner, ctx.repo, ctx.token)

        if self.prChecks.isEmpty {
            if let cachedChecks = PRTimelineCache.shared.getChecks(owner: owner, repo: repoName, prNumber: pr.number) {
                self.prChecks = cachedChecks
                self.isLoadingPRChecks = false
            } else {
                self.isLoadingPRChecks = true
            }
        }

        runPRDetailTask("checks") { [self] in
            do {
                let checks = try await gitHubService.fetchPRChecks(
                    owner: owner,
                    repo: repoName,
                    headSha: pr.headSha,
                    baseBranch: pr.baseBranch,
                    token: tokenToUse
                )
                PRTimelineCache.shared.setChecks(owner: owner, repo: repoName, prNumber: pr.number, checks: checks)
                guard self.selectedPR?.number == pr.number else { return }
                if self.prChecks != checks {
                    self.prChecks = checks
                }
                self.isLoadingPRChecks = false
                self.prLastRefreshedAt = Date()
            } catch {
                guard !GitHubHTTP.isCancellation(error), !Task.isCancelled, self.selectedPR?.number == pr.number else { return }
                self.isLoadingPRChecks = false
            }
        }
    }

    public func loadPRMergeability(for pr: PullRequest) {
        guard let ctx = prRepoContext() else { return }

        runPRDetailTask("mergeability") { [self] in
            // GitHub computes mergeability lazily and returns `mergeable: null` until it's ready.
            for attempt in 0..<4 {
                guard let info = try? await gitHubService.fetchPRMergeability(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, token: ctx.token) else { return }
                guard self.selectedPR?.number == pr.number, var current = self.selectedPR else { return }
                current.mergeable = info.mergeable
                current.mergeableState = info.mergeableState
                current.rebaseable = info.rebaseable
                if let title = info.title { current.title = title }
                if let body = info.body { current.body = body }
                if let idx = self.pullRequests.firstIndex(where: { $0.number == pr.number }) {
                    var row = self.pullRequests[idx]
                    if let title = info.title { row.title = title }
                    if let body = info.body { row.body = body }
                    if row != self.pullRequests[idx] { self.pullRequests[idx] = row }
                }
                if current.state.isActive {
                    current.isDraft = info.isDraft
                    current.state = info.isDraft ? .draft : .open
                }
                let headChanged = info.headSha != nil && info.headSha != current.headSha
                if headChanged { current.headSha = info.headSha }
                if current != self.selectedPR {
                    self.selectedPR = current
                }
                if current.state.isActive, let sha = current.headSha {
                    let number = current.number, base = current.baseBranch
                    Task {
                        guard let behind = try? await self.gitHubService.fetchBehindBy(owner: ctx.owner, repo: ctx.repo, baseBranch: base, headSha: sha, token: ctx.token) else { return }
                        if self.prBehindCounts[number] != behind { self.prBehindCounts[number] = behind }
                    }
                }
                if headChanged {
                    self.loadPRChecks(for: current)
                    self.loadPRFiles(for: current)
                    self.loadPRTimeline(for: current)
                }
                let stillComputing = info.mergeable == nil || info.mergeableState == "unknown"
                guard stillComputing, current.state.isActive, attempt < 3 else { return }
                await GitHubHTTPCache.shared.remove(for: "https://api.github.com/repos/\(ctx.owner)/\(ctx.repo)/pulls/\(pr.number)")
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
            }
        }
    }

    public func updateSelectedPRBranch() async throws {
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }
        try await runPRAction("updateBranch") {
            try await self.gitHubService.updateBranch(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, token: ctx.token)
            self.showToast("Updating branch with latest '\(pr.baseBranch)' commits…", type: .success)
            self.loadPRDetails(for: pr)
        }
    }

    // MARK: - Pull Request Actions (Merge, Close, Reopen)

    public func mergeSelectedPR(
        method: GitHubAPIService.MergeMethod = .merge,
        commitTitle: String? = nil,
        commitMessage: String? = nil,
        deleteBranch: Bool = false
    ) async throws {
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }
        try await runPRAction("merge") {
            let result = try await self.gitHubService.mergePullRequest(
                owner: ctx.owner,
                repo: ctx.repo,
                prNumber: pr.number,
                commitTitle: commitTitle,
                commitMessage: commitMessage,
                mergeMethod: method,
                token: ctx.token
            )

            var toast = "Merged PR #\(pr.number) successfully!"
            if deleteBranch {
                do {
                    try await self.gitHubService.deleteBranch(owner: ctx.owner, repo: ctx.repo, branch: pr.headBranch, token: ctx.token)
                    toast = "Merged PR #\(pr.number) and deleted '\(pr.headBranch)'"
                } catch {
                    toast = "Merged PR #\(pr.number), but could not delete branch: \(error.localizedDescription)"
                }
            }
            self.showToast(toast, type: .success)
            self.showMergeSheet = false
            if var current = self.selectedPR, current.number == pr.number {
                current.state = .merged
                self.selectedPR = current
            }
            self.prTimeline.append(.merged(
                authorName: self.prMeta?.viewerLogin ?? "you",
                mergedAt: Date(),
                sha: result.sha.isEmpty ? "HEAD" : result.sha
            ))
            PRTimelineCache.shared.set(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, items: self.prTimeline)
            self.loadPRs()
        }
    }

    public func closeSelectedPR() async throws {
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }
        try await runPRAction("close") {
            try await self.gitHubService.updatePullRequestState(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, state: "closed", token: ctx.token)
            self.showToast("Closed PR #\(pr.number)", type: .info)
            if var current = self.selectedPR, current.number == pr.number {
                current.state = .closed
                self.selectedPR = current
            }
            self.prTimeline.append(.closed(authorName: self.prMeta?.viewerLogin ?? "you", closedAt: Date()))
            PRTimelineCache.shared.set(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, items: self.prTimeline)
            self.loadPRs()
        }
    }

    public func reopenSelectedPR() async throws {
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }
        try await runPRAction("reopen") {
            try await self.gitHubService.updatePullRequestState(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, state: "open", token: ctx.token)
            self.showToast("Reopened PR #\(pr.number)", type: .success)
            if var current = self.selectedPR, current.number == pr.number {
                current.state = current.isDraft ? .draft : .open
                self.selectedPR = current
            }
            self.prTimeline.append(.reopened(authorName: self.prMeta?.viewerLogin ?? "you", reopenedAt: Date()))
            PRTimelineCache.shared.set(owner: ctx.owner, repo: ctx.repo, prNumber: pr.number, items: self.prTimeline)
            self.loadPRs()
            self.loadPRMergeability(for: pr)
        }
    }

    public func loadDemoPRs() {
        guard let repo = currentRepo else { return }
        self.hasExplicitlyLoadedDemoPRs = true
        self.isLoadingPRs = true
        self.prFetchError = nil
        Task {
            let prs = await gitHubService.demoPullRequests(repo: repo.name)
            await MainActor.run {
                self.pullRequests = prs
                self.selectedPR = nil
                self.isLoadingPRs = false
                self.showToast("Loaded sample pull requests for preview", type: .info)
            }
        }
    }

    public func resetToLivePRs() {
        self.hasExplicitlyLoadedDemoPRs = false
        self.pullRequests = []
        self.selectedPR = nil
        if hasConfiguredGitHubToken {
            loadPRs()
        }
    }

    public func submitPRReview(verdict: ReviewVerdict, comment: String) async throws {
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }
        try await runPRAction("review") {
            try await self.gitHubService.submitReview(
                owner: ctx.owner,
                repo: ctx.repo,
                prNumber: pr.number,
                verdict: verdict,
                body: comment,
                token: ctx.token
            )
            if verdict == .approved || verdict == .changesRequested {
                if var current = self.selectedPR, current.number == pr.number {
                    current.reviewVerdict = verdict
                    self.selectedPR = current
                }
                if let index = self.pullRequests.firstIndex(where: { $0.number == pr.number }) {
                    self.pullRequests[index].reviewVerdict = verdict
                }
            }
            self.showToast("Submitted review: \(verdict == .commented ? "Comment" : verdict.title)", type: .success)
            self.showReviewModal = false
            self.loadPRTimeline(for: pr)
            self.loadPRMeta(for: pr)
            self.loadPRMergeability(for: pr)
        }
    }

    public func updateSelectedPRDescription(newBody: String) async throws {
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }

        try await gitHubService.updatePullRequestDescription(
            owner: ctx.owner,
            repo: ctx.repo,
            prNumber: pr.number,
            body: newBody,
            token: ctx.token
        )

        var updated = self.selectedPR ?? pr
        updated.body = newBody
        self.selectedPR = updated
        if let index = self.pullRequests.firstIndex(where: { $0.number == pr.number }) {
            self.pullRequests[index].body = newBody
        }
        showToast("PR description updated", type: .success)
    }

    private var pendingPRBody: String? = nil
    private var prCheckboxSaveTask: Task<Void, Never>? = nil

    public func togglePRChecklistItem(at index: Int) async throws {
        guard let pr = selectedPR, let ctx = prRepoContext() else { return }
        let currentBody = pendingPRBody ?? pr.body
        let newBody = GitHubMarkdownView.toggleChecklistItem(in: currentBody, at: index)
        pendingPRBody = newBody

        // 1. Optimistic instant local update
        var updated = pr
        updated.body = newBody
        self.selectedPR = updated
        if let idx = self.pullRequests.firstIndex(where: { $0.number == pr.number }) {
            self.pullRequests[idx].body = newBody
        }

        // 2. Debounce by 400ms to batch rapid successive clicks into a single PATCH
        prCheckboxSaveTask?.cancel()
        prCheckboxSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            guard let self = self, let targetBody = self.pendingPRBody else { return }
            self.pendingPRBody = nil

            do {
                try await self.gitHubService.updatePullRequestDescription(
                    owner: ctx.owner,
                    repo: ctx.repo,
                    prNumber: pr.number,
                    body: targetBody,
                    token: ctx.token
                )
                self.showToast("Saved task checklist", type: .success)
            } catch {
                self.showToast("Failed to save checkbox: \(error.localizedDescription)", type: .error)
            }
        }
    }

    public struct CreatePRContext: Sendable {
        public var defaultBase: String?
        public var hasUpstream = false
        public var headExistsLocally = true
        public var unpushedCommits = 0
        public var commitSubjects: [String] = []
        public var template: String?
    }

    /// Cheap, local-only facts for the New PR sheet (no branch lists, no network).
    public func loadCreatePRContext(base: String?, head: String) async -> CreatePRContext {
        guard let repo = currentRepo else { return CreatePRContext() }
        let git = gitService
        var ctx = CreatePRContext()
        let isLocal = (try? await git.execute(arguments: ["rev-parse", "--verify", "--quiet", "refs/heads/\(head)"], in: repo.path))?.isSuccess == true
        ctx.headExistsLocally = isLocal
        let headRef = isLocal ? head : "origin/\(head)"
        async let originHead = git.execute(arguments: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repo.path)
        async let upstream = git.execute(arguments: ["rev-list", "--count", "\(head)@{u}..\(head)"], in: repo.path)
        if let res = try? await originHead, res.isSuccess {
            let name = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            ctx.defaultBase = name.hasPrefix("origin/") ? String(name.dropFirst("origin/".count)) : name
        }
        if let res = try? await upstream, res.isSuccess {
            ctx.hasUpstream = true
            ctx.unpushedCommits = Int(res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        } else if !isLocal {
            ctx.hasUpstream = true
        }
        if let base = base ?? ctx.defaultBase,
           let res = try? await git.execute(arguments: ["log", "--format=%s", "-n", "30", "origin/\(base)..\(headRef)"], in: repo.path),
           res.isSuccess {
            ctx.commitSubjects = res.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        for candidate in [".github/pull_request_template.md", ".github/PULL_REQUEST_TEMPLATE.md", "PULL_REQUEST_TEMPLATE.md",
                          "pull_request_template.md", "docs/pull_request_template.md"] {
            let path = (repo.path as NSString).appendingPathComponent(candidate)
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                ctx.template = text
                break
            }
        }
        return ctx
    }

    /// Creates the PR (pushing the branch first when asked) and opens it.
    public func createPullRequest(title: String, body: String, headBranch: String, baseBranch: String, isDraft: Bool, pushFirst: Bool) async throws {
        guard let repo = currentRepo else { return }
        if pushFirst {
            try await gitService.push(at: repo.path, setUpstream: true, branch: headBranch)
        }
        let ownerRepo = gitHubService.parseRepoOwnerAndName(from: repo.remoteUrl)
        let owner = ownerRepo?.owner ?? "octocat"
        let repoName = ownerRepo?.name ?? repo.name
        let newPR = try await gitHubService.createPullRequest(
            owner: owner, repo: repoName, title: title, body: body,
            headBranch: headBranch, baseBranch: baseBranch, isDraft: isDraft, token: effectiveGitHubToken
        )
        showCreatePRSheet = false
        activeTab = .pullRequests
        showToast("Created PR #\(newPR.number): \(newPR.title)", type: .success)
        await openPullRequest(number: newPR.number, tab: .overview)
        loadPRs()
    }

    /// Local branches first, then origin-only ones, for source-branch suggestions.
    public var allBranchNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for branch in branches where !branch.isRemote && seen.insert(branch.name).inserted { names.append(branch.name) }
        for name in remoteBranchNames where seen.insert(name).inserted { names.append(name) }
        return names
    }

    /// Unique branch names on origin (without the `origin/` prefix), for base-branch suggestions.
    public var remoteBranchNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for branch in branches where branch.isRemote && branch.name.hasPrefix("origin/") {
            let name = branch.displayName
            if name != "HEAD", seen.insert(name).inserted { names.append(name) }
        }
        return names
    }

    public func checkGitHubCLIToken() {
        Task.detached(priority: .utility) {
            let token = GitHubAPIService.getGitHubCLIToken()
            await MainActor.run {
                self.detectedCLIToken = token
            }
        }
    }

    public func importFromGitHubCLI() {
        if let cliToken = detectedCLIToken ?? GitHubAPIService.getGitHubCLIToken() {
            saveGitHubToken(cliToken, method: .cli)
            showToast("Imported active token from GitHub CLI ('gh')", type: .success)
        } else {
            showToast("GitHub CLI ('gh') is not installed or not authenticated", type: .error)
        }
    }

    // MARK: - GitHub OAuth Device Flow

    public func startGitHubOAuthFlow() {
        self.isAuthenticatingGitHubOAuth = true
        self.showOAuthModal = true
        self.githubOAuthError = nil
        self.githubOAuthUserCode = nil
        self.githubOAuthVerificationUri = nil
        self.isPollingOAuth = false

        Task { @MainActor in
            do {
                let resp = try await GitHubOAuthService.shared.requestDeviceCode()
                self.githubOAuthUserCode = resp.userCode
                self.githubOAuthVerificationUri = resp.verificationUri
                self.isPollingOAuth = true

                // Copy user code to system clipboard automatically for convenience
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(resp.userCode, forType: .string)

                // Open browser verification page
                if let url = URL(string: resp.verificationUri) {
                    NSWorkspace.shared.open(url)
                }

                self.showToast("User code '\(resp.userCode)' copied to clipboard! Authorize in browser.", type: .info)

                // Begin polling in background
                let token = try await GitHubOAuthService.shared.pollForAccessToken(
                    deviceCode: resp.deviceCode,
                    interval: resp.interval,
                    timeoutSeconds: resp.expiresIn
                )

                self.isAuthenticatingGitHubOAuth = false
                self.isPollingOAuth = false
                self.showOAuthModal = false
                self.saveGitHubToken(token, method: .oauth)
                self.showToast("Successfully authenticated with GitHub via OAuth!", type: .success)
            } catch {
                if !Task.isCancelled {
                    self.isAuthenticatingGitHubOAuth = false
                    self.isPollingOAuth = false
                    self.githubOAuthError = error.localizedDescription
                    self.showToast("OAuth failed: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    public func cancelGitHubOAuthFlow() {
        Task {
            await GitHubOAuthService.shared.cancel()
        }
        self.isAuthenticatingGitHubOAuth = false
        self.isPollingOAuth = false
        self.showOAuthModal = false
        self.githubOAuthUserCode = nil
        self.githubOAuthVerificationUri = nil
        self.githubOAuthError = nil
    }

    public func saveGitHubToken(_ token: String, method: GitHubAuthMethod = .pat) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.deleteGitHubToken()
            UserDefaults.standard.removeObject(forKey: "gitxx_github_auth_method")
            self.githubToken = nil
            self.authMethod = .pat
            self.authenticatedUsername = nil
            self.hasExplicitlyLoadedDemoPRs = false
            self.pullRequests = []
            self.selectedPR = nil
            self.prFetchError = nil
            showToast("GitHub token cleared", type: .info)
        } else {
            _ = KeychainHelper.saveGitHubToken(trimmed)
            UserDefaults.standard.set(method.rawValue, forKey: "gitxx_github_auth_method")
            self.githubToken = trimmed
            self.authMethod = method
            self.hasExplicitlyLoadedDemoPRs = false
            self.prFetchError = nil

            Task {
                let (isValid, username, errorMsg) = await gitHubService.validateToken(trimmed)
                await MainActor.run {
                    if isValid {
                        self.authenticatedUsername = username
                        let nameStr = username != nil ? "@\(username!)" : "GitHub"
                        self.showToast("Connected to \(nameStr) via \(method.rawValue)!", type: .success)
                        self.prFetchError = nil
                        self.loadPRs()
                    } else {
                        let err = errorMsg ?? "Invalid token"
                        self.prFetchError = "GitHub Token Error: \(err)"
                        self.showToast("Token error: \(err)", type: .error)
                    }
                }
            }
            refreshRepo()
        }
    }

    // MARK: - Native Git CLI & Terminal Execution

    public func clearTerminal() {
        terminalEntries.removeAll()
    }

    public func executeNativeGitCommand(_ commandString: String) {
        // Switch to the Terminal tab and run command immediately
        self.activeTab = .terminal
        self.showCommandPalette = false
        self.runTerminalCommand(commandString)
    }

    public func runTerminalCommand(_ rawCommand: String) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        var normalized = command
        if normalized.hasPrefix(">") {
            normalized = String(normalized.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Add to history
        if terminalCommandHistory.last != command {
            terminalCommandHistory.append(command)
        }
        terminalHistoryIndex = -1
        terminalInput = ""

        guard let repo = currentRepo else {
            showToast("No repository open to run command", type: .error)
            return
        }

        let dirName = (repo.path as NSString).lastPathComponent
        let branch = currentBranch
        let dirty = !files.isEmpty
        let ahead = commitsAhead
        let behind = commitsBehind
        let startTime = Date()

        // Format command: if it's a known git verb and doesn't start with git, prefix git
        var cmdToRun = normalized
        let firstWord = normalized.components(separatedBy: .whitespaces).first?.lowercased() ?? ""
        let gitVerbs: Set<String> = [
            "checkout", "switch", "branch", "status", "diff", "pull", "push",
            "fetch", "commit", "stash", "rebase", "merge", "reset", "log",
            "remote", "tag", "clean", "restore", "revert", "cherry-pick"
        ]
        if gitVerbs.contains(firstWord) && !normalized.lowercased().hasPrefix("git ") {
            cmdToRun = "git " + normalized
        }

        isExecutingGitCommand = true

        let activeShell = self.selectedShell

        Task {
            do {
                let result = try await gitService.executeShell(command: cmdToRun, in: repo.path, shell: activeShell)
                let duration = Date().timeIntervalSince(startTime)
                self.isExecutingGitCommand = false

                let entry = TerminalEntry(
                    command: cmdToRun,
                    directoryName: dirName,
                    fullPath: repo.path,
                    branchName: branch,
                    isDirty: dirty,
                    commitsAhead: ahead,
                    commitsBehind: behind,
                    shellName: activeShell.rawValue.lowercased(),
                    timestamp: startTime,
                    stdout: result.stdout,
                    stderr: result.stderr,
                    exitCode: result.exitCode,
                    duration: duration
                )

                self.terminalEntries.append(entry)
                self.refreshRepo()
            } catch {
                self.isExecutingGitCommand = false
                let duration = Date().timeIntervalSince(startTime)
                let entry = TerminalEntry(
                    command: cmdToRun,
                    directoryName: dirName,
                    fullPath: repo.path,
                    branchName: branch,
                    isDirty: dirty,
                    commitsAhead: ahead,
                    commitsBehind: behind,
                    shellName: activeShell.rawValue.lowercased(),
                    timestamp: startTime,
                    stdout: "",
                    stderr: error.localizedDescription,
                    exitCode: 1,
                    duration: duration
                )
                self.terminalEntries.append(entry)
            }
        }
    }

    private func parseCommandLineArguments(_ command: String) -> [String] {
        var args: [String] = []
        var current = ""
        var insideQuotes = false
        var quoteChar: Character? = nil

        for char in command {
            if (char == "\"" || char == "'") {
                if insideQuotes && char == quoteChar {
                    insideQuotes = false
                    quoteChar = nil
                } else if !insideQuotes {
                    insideQuotes = true
                    quoteChar = char
                } else {
                    current.append(char)
                }
            } else if char == " " && !insideQuotes {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            args.append(current)
        }
        return args
    }

    // MARK: - Git Profiles Management

    public func saveProfiles() {
        if let encoded = try? JSONEncoder().encode(gitProfiles) {
            UserDefaults.standard.set(encoded, forKey: "gitUserProfiles")
        }
    }

    public func switchProfile(_ profile: GitUserProfile, global: Bool = false) {
        activeProfileId = profile.id
        let repoPath = currentRepo?.path
        Task {
            do {
                try await GitService.shared.setGitUser(name: profile.name, email: profile.email, in: repoPath, global: global)
                var sshMsg = ""
                if !profile.sshKeyPath.isEmpty {
                    let sshRes = await GitService.shared.addSSHKey(path: profile.sshKeyPath)
                    if sshRes.success {
                        sshMsg = " • SSH Key added"
                    }
                }
                await MainActor.run {
                    showToast("Git user set to \(profile.label) (\(profile.email))\(sshMsg)", type: .success)
                }
            } catch {
                await MainActor.run {
                    showToast("Failed to switch git user: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    public func addProfile(_ profile: GitUserProfile) {
        gitProfiles.append(profile)
        saveProfiles()
        showToast("Added Git profile: \(profile.label)", type: .success)
    }

    public func updateProfile(_ profile: GitUserProfile) {
        if let idx = gitProfiles.firstIndex(where: { $0.id == profile.id }) {
            gitProfiles[idx] = profile
            saveProfiles()
            if activeProfileId == profile.id {
                switchProfile(profile)
            } else {
                showToast("Updated profile: \(profile.label)", type: .success)
            }
        }
    }

    public func deleteProfile(id: String) {
        gitProfiles.removeAll(where: { $0.id == id })
        if activeProfileId == id, let first = gitProfiles.first {
            activeProfileId = first.id
            switchProfile(first)
        }
        saveProfiles()
        showToast("Profile removed", type: .info)
    }

    public func resolveGitHubAvatar(for username: String) async -> String? {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let ghPath = "/opt/homebrew/bin/gh"
        if FileManager.default.isExecutableFile(atPath: ghPath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ghPath)
            process.arguments = ["api", "users/\(trimmed)", "--jq", ".avatar_url"]
            let pipe = Pipe()
            process.standardOutput = pipe
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let urlStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let urlStr = urlStr, urlStr.hasPrefix("http") {
                        return urlStr
                    }
                }
            } catch {}
        }
        return "https://github.com/\(trimmed).png?size=96"
    }

    // MARK: - AI Commit Generation & Copilot Auth

    public func checkCopilotStatus() {
        Task {
            if let token = await CopilotAuthService.shared.getStoredOAuthToken(), !token.isEmpty {
                let user = await CopilotAuthService.shared.getStoredUsername()
                await MainActor.run {
                    self.isCopilotConnected = true
                    self.copilotUsername = user
                }
                self.refreshCopilotQuota()
            } else if let detected = await CopilotAuthService.shared.autoDetectToken() {
                await MainActor.run {
                    self.isCopilotConnected = true
                    self.copilotUsername = detected.username
                }
                self.refreshCopilotQuota()
            }
        }
    }

    public func startDeviceCodeLogin() {
        Task {
            do {
                let deviceCodeInfo = try await CopilotAuthService.shared.requestDeviceCode()
                await MainActor.run {
                    self.activeDeviceCode = deviceCodeInfo
                    self.isDeviceFlowPolling = true

                    // Copy user code to clipboard
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(deviceCodeInfo.userCode, forType: .string)

                    // Open browser
                    if let url = URL(string: deviceCodeInfo.verificationUri) {
                        NSWorkspace.shared.open(url)
                    }

                    self.showToast("Copied code \(deviceCodeInfo.userCode) to clipboard! Authorizing...", type: .info)
                }

                // Poll for token
                let (_, username) = try await CopilotAuthService.shared.pollForAccessToken(deviceCode: deviceCodeInfo.deviceCode, interval: deviceCodeInfo.interval)
                await MainActor.run {
                    self.isCopilotConnected = true
                    self.copilotUsername = username ?? "Copilot User"
                    self.isDeviceFlowPolling = false
                    self.activeDeviceCode = nil
                    self.showAIAuthPopover = false
                    self.showToast("Connected to GitHub Copilot as @\(self.copilotUsername ?? "")!", type: .success)
                }
                self.refreshCopilotQuota()
            } catch {
                await MainActor.run {
                    self.isDeviceFlowPolling = false
                    self.showToast("Copilot Login: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    public func disconnectCopilot() {
        Task {
            await CopilotAuthService.shared.disconnect()
            await MainActor.run {
                self.isCopilotConnected = false
                self.copilotUsername = nil
                self.copilotQuota = nil
                self.showToast("Disconnected from GitHub Copilot", type: .info)
            }
        }
    }

    public func refreshCopilotQuota() {
        Task {
            await MainActor.run {
                self.isRefreshingQuota = true
            }
            do {
                if let quota = try await CopilotAuthService.shared.getQuotaInfo(forceRefresh: true) {
                    await MainActor.run {
                        self.copilotQuota = quota
                        self.isRefreshingQuota = false
                        self.checkAndResetUsageIfCycleExpired(resetDate: quota.resetDate)
                    }
                } else {
                    await MainActor.run {
                        self.isRefreshingQuota = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.isRefreshingQuota = false
                }
            }
        }
    }

    public func resetAppAIConsumption() {
        appAIConsumedCount = 0
        UserDefaults.standard.set(0, forKey: "gitxxCopilotRequestsUsed")
        showToast("GitXX AI usage counter reset to 0", type: .info)
    }

    private func checkAndResetUsageIfCycleExpired(resetDate: Date?) {
        guard let resetDate = resetDate else { return }
        let lastResetKey = "gitxxCopilotLastResetTimestamp"
        let lastRecordedTimestamp = UserDefaults.standard.double(forKey: lastResetKey)

        if Date() >= resetDate && lastRecordedTimestamp < resetDate.timeIntervalSince1970 {
            self.appAIConsumedCount = 0
            UserDefaults.standard.set(0, forKey: "gitxxCopilotRequestsUsed")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastResetKey)
        }
    }

    public func cancelAICommit() {
        currentAITask?.cancel()
        currentAITask = nil
        isGeneratingCommitAI = false
        showToast("AI generation cancelled.", type: .info)
    }

    public func generateAICommit() {
        if isGeneratingCommitAI {
            cancelAICommit()
            return
        }

        guard let repo = currentRepo else {
            showToast("No active repository to generate commit message for.", type: .error)
            return
        }

        // Check if Copilot is selected but not connected
        if aiProvider == .githubCopilot && !isCopilotConnected {
            showAIAuthPopover = true
            return
        }

        isGeneratingCommitAI = true
        currentAITask?.cancel()

        currentAITask = Task {
            defer {
                Task { @MainActor in
                    self.isGeneratingCommitAI = false
                    self.currentAITask = nil
                }
            }

            do {
                var diffText = ""
                let stagedFiles = files.filter { $0.isStaged }

                if !stagedFiles.isEmpty {
                    let result = try await gitService.execute(arguments: ["diff", "--cached"], in: repo.path)
                    diffText = result.stdout
                }

                if Task.isCancelled { return }

                if diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Try working tree diff
                    let result = try await gitService.execute(arguments: ["diff"], in: repo.path)
                    diffText = result.stdout
                }

                if Task.isCancelled { return }

                if diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Try diff against HEAD
                    let result = try await gitService.execute(arguments: ["diff", "HEAD"], in: repo.path)
                    diffText = result.stdout
                }

                if Task.isCancelled { return }

                if diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Summarize changed file names
                    let fileList = files.map { "\($0.changeKind.badgeLabel) \($0.filename)" }.joined(separator: "\n")
                    if !fileList.isEmpty {
                        diffText = "Changed files:\n" + fileList
                    }
                }

                guard !diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    await MainActor.run {
                        self.showToast("No changes detected to generate a commit message.", type: .info)
                    }
                    return
                }

                if Task.isCancelled { return }

                let message = try await AICommitService.shared.generateCommitMessage(
                    diff: diffText,
                    provider: self.aiProvider,
                    style: self.commitStyle,
                    modelName: self.copilotModel.rawValue
                )

                if Task.isCancelled { return }

                await MainActor.run {
                    self.commitSummary = message.summary
                    if !message.description.isEmpty {
                        self.commitDescription = message.description
                    }
                    if self.aiProvider == .githubCopilot {
                        self.appAIConsumedCount += 1
                        UserDefaults.standard.set(self.appAIConsumedCount, forKey: "gitxxCopilotRequestsUsed")
                    }
                    self.showToast("Generated commit message with AI!", type: .success)
                }
            } catch is CancellationError {
                // User cancelled, clean exit
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    if (error as NSError).code == 401 && self.aiProvider == .githubCopilot {
                        self.isCopilotConnected = false
                        self.showAIAuthPopover = true
                    }
                    self.showToast("AI Generation error: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    // MARK: - GitHub API Logs & Rate Limit Quota Tracking

    public func refreshAPILogs() {
        Task { @MainActor in
            let logs = await GitHubAPILogger.shared.getLogs()
            let stats = await GitHubAPILogger.shared.getStats()
            self.apiRequestLogs = logs
            self.apiLogStats = stats
            if let rem = stats.latestRemaining, let lim = stats.latestLimit {
                self.rateLimit = GitHubRateLimitInfo(
                    remaining: rem,
                    limit: lim,
                    resetAt: stats.latestReset ?? Date().addingTimeInterval(3600),
                    cost: 1
                )
            }
        }
    }

    public func clearAPILogs() {
        Task {
            await GitHubAPILogger.shared.clear()
            await MainActor.run {
                self.refreshAPILogs()
                self.showToast("Cleared API request history", type: .info)
            }
        }
    }

    public func copyAPILogsToClipboard() {
        Task {
            let export = await GitHubAPILogger.shared.exportAsText()
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(export, forType: .string)
                self.showToast("Copied API logs to clipboard", type: .success)
            }
        }
    }
}



