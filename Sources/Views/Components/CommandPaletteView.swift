import SwiftUI
import AppKit

public struct PaletteCommand: Identifiable {
    public let id = UUID()
    public let title: String
    public let subtitle: String
    public let iconName: String
    public let shortcut: String?
    public var section: String = ""
    public var score: Int = 0
    public let action: () -> Void

    public init(title: String, subtitle: String, iconName: String, shortcut: String?, section: String = "", score: Int = 0, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
        self.shortcut = shortcut
        self.section = section
        self.score = score
        self.action = action
    }
}

/// Palette search modes, selected by a query prefix (like VS Code / Raycast).
public enum PaletteMode: String, CaseIterable, Identifiable {
    case all, commands, repositories, branches, pullRequests, git

    public var id: String { rawValue }

    public var prefix: String {
        switch self {
        case .all: return ""
        case .commands: return ":"
        case .repositories: return "@"
        case .branches: return "/"
        case .pullRequests: return "#"
        case .git: return ">"
        }
    }

    public var title: String {
        switch self {
        case .all: return "All"
        case .commands: return "Commands"
        case .repositories: return "Repos"
        case .branches: return "Branches"
        case .pullRequests: return "PRs"
        case .git: return "Git"
        }
    }

    public var placeholder: String {
        switch self {
        case .all: return "Search commands, PRs, branches, repos — or paste a GitHub URL"
        case .commands: return "Run an app command…"
        case .repositories: return "Switch to a repository…"
        case .branches: return "Check out or create a branch…"
        case .pullRequests: return "Find a pull request by title, #number, author or branch…"
        case .git: return "Type a git command, e.g. status -s"
        }
    }

    static func detect(_ query: String) -> (PaletteMode, String) {
        for mode in [PaletteMode.commands, .repositories, .branches, .pullRequests] where query.hasPrefix(mode.prefix) {
            return (mode, String(query.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        return (.all, query.trimmingCharacters(in: .whitespaces))
    }
}

/// Lightweight fuzzy ranking: exact > prefix > word-prefix > substring > in-order subsequence.
enum PaletteFuzzy {
    static func score(_ query: String, _ text: String) -> Int? {
        let q = query.lowercased(), t = text.lowercased()
        guard !q.isEmpty else { return 1 }
        if t == q { return 1000 }
        if t.hasPrefix(q) { return 800 - min(t.count, 200) }
        let separators = CharacterSet(charactersIn: " /-_.#:")
        if t.components(separatedBy: separators).contains(where: { $0.hasPrefix(q) }) { return 600 - min(t.count, 200) }
        if t.contains(q) { return 400 - min(t.count, 200) }
        var idx = t.startIndex
        for ch in q {
            guard let found = t[idx...].firstIndex(of: ch) else { return nil }
            idx = t.index(after: found)
        }
        return 100 - min(t.count, 90)
    }

    static func best(_ query: String, _ fields: [String]) -> Int? {
        fields.compactMap { score(query, $0) }.max()
    }
}

public struct PaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onDownArrow: () -> Void
    var onUpArrow: () -> Void
    var onEscape: () -> Void
    var onTab: (Bool) -> Void = { _ in }
    var fontSize: CGFloat = 15
    /// The palette keeps typing focus on its field; popovers with other inputs turn this off.
    var keepsFocus = true

    public init(
        text: Binding<String>,
        placeholder: String,
        onSubmit: @escaping () -> Void,
        onDownArrow: @escaping () -> Void,
        onUpArrow: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onTab: @escaping (Bool) -> Void = { _ in },
        fontSize: CGFloat = 15,
        keepsFocus: Bool = true
    ) {
        self.fontSize = fontSize
        self.keepsFocus = keepsFocus
        self._text = text
        self.placeholder = placeholder
        self.onSubmit = onSubmit
        self.onDownArrow = onDownArrow
        self.onUpArrow = onUpArrow
        self.onEscape = onEscape
        self.onTab = onTab
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.placeholderString = placeholder
        textField.stringValue = text
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = NSFont.systemFont(ofSize: fontSize)
        textField.delegate = context.coordinator
        context.coordinator.textField = textField
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true

        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
        }
        return textField
    }

    public func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        if nsView.stringValue != text {
            nsView.stringValue = text
            nsView.currentEditor()?.selectedRange = NSRange(location: text.utf16.count, length: 0)
        }
        guard keepsFocus else { return }
        DispatchQueue.main.async {
            if let window = nsView.window, window.firstResponder != nsView.currentEditor() && window.firstResponder != nsView {
                window.makeFirstResponder(nsView)
            }
        }
    }

    public class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteSearchField
        weak var textField: NSTextField?

        init(_ parent: PaletteSearchField) {
            self.parent = parent
        }

        public func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
            }
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onDownArrow()
                return true
            } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onUpArrow()
                return true
            } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            } else if commandSelector == #selector(NSResponder.insertTab(_:)) {
                parent.onTab(false)
                return true
            } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                parent.onTab(true)
                return true
            }
            return false
        }
    }
}

public struct CommandPaletteView: View {
    @ObservedObject var state: AppState
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    /// Only keyboard moves scroll the list; hover changes selection without fighting a trackpad scroll.
    @State private var scrollToSelection = false
    @State private var lastPointer: CGPoint?
    @State private var keyMonitor: Any?

    // MARK: - Native Git & Shell Command Detection

    private let commonGitAliases: Set<String> = [
        "gs", "gst", "ga", "gaa", "gc", "gcm", "gca", "gco", "gcb", "gd", "gdc", "gds",
        "gl", "glo", "glog", "gp", "gpf", "gpu", "gpl", "gb", "gba", "gr", "grh", "grb",
        "gtag"
    ]

    var isNativeGitCommand: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.lowercased().hasPrefix("git ") || trimmed.lowercased() == "git" {
            return true
        }
        if trimmed.hasPrefix(">") || trimmed.hasPrefix("$") {
            return true
        }
        let firstWord = trimmed.components(separatedBy: .whitespaces).first?.lowercased() ?? ""
        if commonGitAliases.contains(firstWord) {
            return true
        }
        let gitVerbs: Set<String> = [
            "checkout", "switch", "branch", "status", "diff", "pull", "push",
            "fetch", "commit", "stash", "rebase", "merge", "reset", "log",
            "remote", "tag", "clean", "restore", "revert", "cherry-pick"
        ]
        return gitVerbs.contains(firstWord)
    }

    var cleanGitCommandString: String {
        var str = query.trimmingCharacters(in: .whitespaces)
        if str.hasPrefix(">") || str.hasPrefix("$") {
            return String(str.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let firstWord = str.components(separatedBy: .whitespaces).first?.lowercased() ?? ""
        if commonGitAliases.contains(firstWord) {
            return str
        }
        if !str.lowercased().hasPrefix("git ") && str.lowercased() != "git" {
            str = "git " + str
        }
        return str
    }

    // MARK: - Commands

    var baseCommands: [PaletteCommand] {
        let list: [PaletteCommand] = [
            PaletteCommand(title: "Ask AI Assistant", subtitle: "Chat that can run git, gh and GitHub API calls with this page as context", iconName: "sparkles", shortcut: "⌘I") {
                if !AIChatStore.shared.isOpen { AIChatStore.shared.toggle() }
            },
            PaletteCommand(title: "Go Home", subtitle: "Recent repositories and your pull requests across repos (dashboard)", iconName: "house", shortcut: "⇧⌘H") {
                state.homeTab = .repositories
                state.goHome()
            },
            PaletteCommand(title: "My Pull Requests (All Repositories)", subtitle: "Home · your open pull requests across every repository", iconName: "gitxx.pr.OPEN", shortcut: nil) {
                state.homeTab = .pullRequests
                state.goHome()
            },
            PaletteCommand(title: "Switch to Changes", subtitle: "View uncommitted local changes and diffs", iconName: "plus.forwardslash.minus", shortcut: "⌘1") {
                state.activeTab = .changes
            },
            PaletteCommand(title: "Switch to History", subtitle: "Browse commit logs and past revisions", iconName: "clock.arrow.circlepath", shortcut: "⌘2") {
                state.activeTab = .history
            },
            PaletteCommand(title: "Switch to Pull Requests", subtitle: "Review and approve GitHub Pull Requests", iconName: "gitxx.pr.OPEN", shortcut: "⌘3") {
                state.activeTab = .pullRequests
            },
            PaletteCommand(title: "Switch to Actions", subtitle: "GitHub Actions workflow runs, jobs, logs and artifacts", iconName: "play.circle", shortcut: "⌘4") {
                state.activeTab = .actions
            },
            PaletteCommand(title: "Actions: Runs on Current Branch", subtitle: "Workflow runs for \(state.currentRepo?.currentBranch ?? "the checked-out branch")", iconName: "arrow.triangle.branch", shortcut: nil) {
                state.showActions(branch: state.currentRepo?.currentBranch)
            },
            PaletteCommand(title: "Actions: Latest Run on Current Branch", subtitle: "Open the newest workflow run for \(state.currentRepo?.currentBranch ?? "this branch")", iconName: "play.circle.fill", shortcut: nil) {
                state.openLatestActionsRun(branch: state.currentRepo?.currentBranch)
            },
            PaletteCommand(title: "Actions: Failed Runs", subtitle: "Workflow runs that failed", iconName: "xmark.circle", shortcut: nil) {
                state.showActions(branch: nil)
                state.actions.filter.status = "failure"
            },
            PaletteCommand(title: "Actions: Runs in Progress", subtitle: "Queued and running workflow runs", iconName: "circle.dotted.circle", shortcut: nil) {
                state.showActions(branch: nil)
                state.actions.filter.status = "in_progress"
            },
            PaletteCommand(title: "Actions: My Runs", subtitle: "Workflow runs you triggered", iconName: "person", shortcut: nil) {
                state.showActions(branch: nil)
                state.actions.toggleMine()
            },
            PaletteCommand(title: "Actions: Run Workflow…", subtitle: "Start a workflow_dispatch run with inputs", iconName: "play.fill", shortcut: nil) {
                state.activeTab = .actions
                state.actions.activate()
                state.actions.beginDispatch()
            },
            PaletteCommand(title: "New Branch…", subtitle: "Create a branch from the current or any other branch", iconName: "arrow.triangle.branch", shortcut: "⇧⌘N") {
                state.beginNewBranch()
            },
            PaletteCommand(title: "Resolve Conflicts…", subtitle: state.conflictedPaths.isEmpty ? "Three-pane merge for conflicted files (none right now)" : "\(state.conflictedPaths.count) conflicted file\(state.conflictedPaths.count == 1 ? "" : "s"): accept yours / theirs or merge", iconName: "arrow.triangle.merge", shortcut: nil) {
                state.openConflictResolver()
            },
            PaletteCommand(title: "Fetch Origin", subtitle: "Fetch new commits and branches from remote", iconName: "arrow.clockwise", shortcut: "⌘T") {
                state.fetchOrigin()
            },
            PaletteCommand(title: "Pull from Origin", subtitle: "Incorporate remote changes into current branch", iconName: "arrow.down.circle", shortcut: "⇧⌘P") {
                state.pullOrigin()
            },
            PaletteCommand(title: "Push to Origin", subtitle: "Publish local commits to remote branch", iconName: "arrow.up.circle", shortcut: "⌘P") {
                state.pushOrigin()
            },
            PaletteCommand(title: "Stage All Changes", subtitle: "Add all modified and untracked files to staging", iconName: "plus.square.on.square", shortcut: nil) {
                state.stageAll()
            },
            PaletteCommand(title: "Unstage All Changes", subtitle: "Reset staging index", iconName: "minus.square", shortcut: nil) {
                state.unstageAll()
            },
            PaletteCommand(title: "Commit Changes", subtitle: "Commit staged modifications to repository", iconName: "checkmark.circle", shortcut: "⌘Enter") {
                state.commitStaged()
            },
            PaletteCommand(title: "Stash Working Changes", subtitle: "Save uncommitted changes to stash", iconName: "archivebox", shortcut: nil) {
                state.stashChanges()
            },
            PaletteCommand(title: "Pop Stashed Changes", subtitle: "Apply latest stash to working directory", iconName: "archivebox.fill", shortcut: nil) {
                state.stashPop()
            },
            PaletteCommand(title: "Switch / Create Branch...", subtitle: "Quickly checkout or create git branches", iconName: "arrow.triangle.branch", shortcut: "⌘B") {
                state.showBranchPicker = true
            },
            PaletteCommand(title: "Open Local Repository...", subtitle: "Browse folder to open another repository", iconName: "folder.badge.plus", shortcut: "⌘O") {
                state.showRepoPicker = true
            },
            PaletteCommand(title: "Install 'gitxx' in PATH", subtitle: "Enable 'gitxx' command in Terminal to open repositories", iconName: "terminal", shortcut: nil) {
                state.installCLIInPath()
            },
            PaletteCommand(title: "GitHub API & Rate Limit Settings", subtitle: "Configure Personal Access Token and view quota", iconName: "gearshape", shortcut: "⌘,") {
                state.showSettings = true
            }
        ]

        return list
    }

    // MARK: - Modes

    private var modeAndTerm: (PaletteMode, String) {
        if isNativeGitCommand { return (.git, cleanGitCommandString) }
        return PaletteMode.detect(query)
    }

    private var activeMode: PaletteMode { modeAndTerm.0 }
    private var searchTerm: String { modeAndTerm.1 }

    private var pastedURLTarget: GitHubURLTarget? {
        activeMode == .all ? GitHubURLTarget.parse(query) : nil
    }

    private func switchMode(to mode: PaletteMode) {
        let term = activeMode == .git ? "" : searchTerm
        query = mode == .git ? ">" : mode.prefix + term
        selectedIndex = 0
    }

    private func cycleMode(backwards: Bool) {
        let modes = PaletteMode.allCases
        let current = modes.firstIndex(of: activeMode) ?? 0
        let next = (current + (backwards ? modes.count - 1 : 1)) % modes.count
        switchMode(to: modes[next])
    }

    // MARK: - Result Sources

    private func ranked(_ items: [PaletteCommand], limit: Int? = nil) -> [PaletteCommand] {
        let sorted = items.enumerated().sorted { lhs, rhs in
            lhs.element.score != rhs.element.score ? lhs.element.score > rhs.element.score : lhs.offset < rhs.offset
        }.map(\.element)
        guard let limit else { return sorted }
        return Array(sorted.prefix(limit))
    }

    private func commandResults(_ term: String) -> [PaletteCommand] {
        baseCommands.compactMap { cmd -> PaletteCommand? in
            guard let score = PaletteFuzzy.best(term, [cmd.title, cmd.subtitle]) else { return nil }
            var c = cmd
            c.section = "Commands"
            c.score = score
            return c
        }
    }

    private func repositoryResults(_ term: String) -> [PaletteCommand] {
        var seen = Set<String>()
        let repos = ((state.currentRepo.map { [$0] } ?? []) + state.recentRepos).filter { seen.insert($0.path).inserted }
        var items: [PaletteCommand] = repos.compactMap { repo -> PaletteCommand? in
            let slug = state.gitHubService.parseRepoOwnerAndName(from: repo.remoteUrl).map { "\($0.owner)/\($0.name)" }
            guard let score = PaletteFuzzy.best(term, [repo.name, slug ?? "", repo.path]) else { return nil }
            let isCurrent = repo.path == state.currentRepo?.path
            return PaletteCommand(
                title: slug ?? repo.name,
                subtitle: (isCurrent ? "Current · " : "") + (repo.path as NSString).abbreviatingWithTildeInPath,
                iconName: isCurrent ? "checkmark.circle.fill" : "folder",
                shortcut: nil,
                section: "Repositories",
                score: score + (isCurrent ? -50 : 0)
            ) {
                if !isCurrent { state.loadRepo(path: repo.path) }
            }
        }
        if activeMode == .repositories {
            items.append(PaletteCommand(title: "Open another repository…", subtitle: "Browse for a local folder", iconName: "folder.badge.plus", shortcut: "⌘O", section: "Repositories", score: -1000) {
                state.showRepoPicker = true
            })
        }
        return items
    }

    private func branchResults(_ term: String) -> [PaletteCommand] {
        var items: [PaletteCommand] = state.branches.compactMap { branch -> PaletteCommand? in
            guard let score = PaletteFuzzy.score(term, branch.displayName) else { return nil }
            let name = branch.displayName
            return PaletteCommand(
                title: name,
                subtitle: branch.isCurrent ? "Current branch" : (branch.isRemote ? "Remote branch · check out" : "Local branch · check out"),
                iconName: branch.isCurrent ? "checkmark.circle.fill" : (branch.isRemote ? "cloud" : "arrow.triangle.branch"),
                shortcut: nil,
                section: "Branches",
                score: score + (branch.isRemote ? 0 : 20) + (branch.isCurrent ? -60 : 0)
            ) {
                if !branch.isCurrent { state.checkoutBranch(branch.name) }
            }
        }
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || PaletteFuzzy.score(term, "new branch create") != nil {
            items.append(PaletteCommand(title: "New Branch…", subtitle: "Create a branch and choose its base", iconName: "plus.circle",
                                        shortcut: "⇧⌘N", section: "Branches", score: trimmed.isEmpty ? 100_000 : 500) {
                state.beginNewBranch()
            })
        }
        if activeMode == .branches, !trimmed.isEmpty, !trimmed.contains(" "),
           !state.branches.contains(where: { $0.displayName == trimmed }) {
            items.append(PaletteCommand(title: "Create branch “\(trimmed)”", subtitle: "From \(state.currentRepo?.currentBranch ?? "current HEAD")", iconName: "plus.circle", shortcut: nil, section: "Branches", score: -1000) {
                state.createBranch(name: trimmed)
            })
            items.append(PaletteCommand(title: "Create branch “\(trimmed)” from…", subtitle: "Choose the base branch first", iconName: "arrow.triangle.branch", shortcut: "⇧⌘N", section: "Branches", score: -1001) {
                state.beginNewBranch(name: trimmed)
            })
        }
        return items
    }

    /// Workflows (filter the Actions tab) and loaded runs (open them), plus PR/run cross-links for the current page.
    private func actionsResults(_ term: String) -> [PaletteCommand] {
        let store = state.actions
        var items: [PaletteCommand] = []
        if let pr = state.selectedPR, state.activeTab == .pullRequests,
           let score = PaletteFuzzy.best(term, ["actions runs for this pull request", "#\(pr.number) runs", pr.headBranch]) {
            items.append(PaletteCommand(title: "Actions: Runs for PR #\(pr.number)", subtitle: "Workflow runs on \(pr.headBranch)", iconName: "play.circle", shortcut: nil, section: "Actions", score: score + 50) {
                state.showActions(branch: pr.headBranch)
            })
        }
        if let run = store.selectedRun, state.activeTab == .actions {
            for number in store.pullRequestNumbers(for: run) {
                if let score = PaletteFuzzy.best(term, ["open pull request #\(number)", "pr \(number)"]) {
                    items.append(PaletteCommand(title: "Open PR #\(number) for this run", subtitle: store.pullRequestTitle(number) ?? run.headBranch, iconName: "gitxx.pr.OPEN", shortcut: nil, section: "Actions", score: score + 50) {
                        Task { await state.openPullRequest(number: number, tab: .checks) }
                    })
                }
            }
        }
        for workflow in store.workflows {
            guard let score = PaletteFuzzy.best(term, [workflow.name, workflow.fileName]) else { continue }
            items.append(PaletteCommand(title: "Workflow: \(workflow.name)", subtitle: "Show runs · \(workflow.path)", iconName: "square.stack.3d.up", shortcut: nil, section: "Actions", score: score) {
                state.showActions(branch: nil, workflowId: workflow.id)
            })
        }
        for run in store.runs.prefix(80) {
            let fields = [run.displayTitle, "\(run.workflowName) #\(run.runNumber)", run.headBranch]
            guard let score = PaletteFuzzy.best(term, fields) else { continue }
            items.append(PaletteCommand(title: run.displayTitle.isEmpty ? run.workflowName : run.displayTitle, subtitle: "\(run.workflowName) #\(run.runNumber) · \(run.actionsStatus.label) · \(run.headBranch)", iconName: run.actionsStatus.iconName, shortcut: nil, section: "Workflow runs", score: score - 20) {
                state.openActionsRun(runId: run.id)
            })
        }
        return items
    }

    private func pullRequestResults(_ term: String) -> [PaletteCommand] {
        let digits = term.hasPrefix("#") ? String(term.dropFirst()) : term
        let number = Int(digits)
        let prs = state.searchablePullRequests
        var items: [PaletteCommand] = prs.compactMap { pr -> PaletteCommand? in
            let score: Int?
            if let number {
                score = pr.number == number ? 2000 : (String(pr.number).hasPrefix(digits) ? 900 : nil)
            } else {
                score = PaletteFuzzy.best(term, [pr.title, pr.authorName, pr.headBranch])
            }
            guard let score else { return nil }
            let stateLabel: String
            switch pr.state {
            case .open: stateLabel = pr.isDraft ? "Draft" : "Open"
            case .draft: stateLabel = "Draft"
            case .merged: stateLabel = "Merged"
            case .closed: stateLabel = "Closed"
            }
            return PaletteCommand(
                title: pr.title,
                subtitle: "#\(pr.number) · \(stateLabel) · \(pr.authorName) · \(pr.headBranch)",
                iconName: "gitxx.pr.\(pr.state.rawValue)",
                shortcut: nil,
                section: "Pull requests",
                score: score + (pr.state.isActive ? 10 : 0)
            ) {
                Task { await state.openPullRequest(number: pr.number) }
            }
        }
        if let number, number > 0, !prs.contains(where: { $0.number == number }) {
            items.append(PaletteCommand(title: "Open pull request #\(number)", subtitle: "Fetch from GitHub", iconName: "gitxx.pr.OPEN", shortcut: nil, section: "Pull requests", score: 1500) {
                Task { await state.openPullRequest(number: number) }
            })
        }
        return items
    }

    private func urlResults(_ target: GitHubURLTarget) -> [PaletteCommand] {
        let isLocal = state.localRepository(owner: target.owner, repo: target.repo) != nil
        var items: [PaletteCommand] = []
        if isLocal {
            items.append(PaletteCommand(title: target.title, subtitle: "\(target.slug) · open in GitXX", iconName: "arrow.right.circle.fill", shortcut: "↩", section: "GitHub link") {
                state.openGitHubTarget(target)
            })
        }
        items.append(PaletteCommand(title: "Open in browser", subtitle: isLocal ? target.url.absoluteString : "\(target.slug) isn't open locally · \(target.url.absoluteString)", iconName: "safari", shortcut: isLocal ? nil : "↩", section: "GitHub link") {
            NSWorkspace.shared.open(target.url)
        })
        return items
    }

    private func gitResults() -> [PaletteCommand] {
        var result: [PaletteCommand] = []
        let cmdToRun = cleanGitCommandString
        let hasArgs = cmdToRun != "git" && !cmdToRun.isEmpty
        if hasArgs {
            result.append(PaletteCommand(
                title: "Run: \(cmdToRun)",
                subtitle: "Execute native git command in '\(state.currentRepo?.name ?? "current repo")'",
                iconName: "terminal.fill",
                shortcut: "↩ Run"
            ) {
                state.executeNativeGitCommand(cmdToRun)
            })
        }

        let presets: [(cmd: String, desc: String)] = [
            ("git status -s", "Show concise working tree status"),
            ("git diff --stat", "Summary of insertions and deletions across files"),
            ("git log --oneline -n 10", "Inspect last 10 commits concisely"),
            ("git branch -a", "List all local and remote branches"),
            ("git stash list", "List all stashed state modifications"),
            ("git remote -v", "Inspect remote repository URLs"),
            ("git clean -nd", "Dry-run preview of untracked files cleanup"),
            ("git fetch --all --prune", "Fetch all remotes and prune deleted branches")
        ]
        let lowerQuery = cmdToRun.lowercased()
        for preset in presets where (!hasArgs || preset.cmd.contains(lowerQuery)) && preset.cmd != cmdToRun {
            result.append(PaletteCommand(title: preset.cmd, subtitle: preset.desc, iconName: "terminal.fill", shortcut: nil) {
                state.executeNativeGitCommand(preset.cmd)
            })
        }

        if lowerQuery.hasPrefix("git checkout ") || lowerQuery.hasPrefix("git switch ") {
            let prefix = lowerQuery.hasPrefix("git switch ") ? "git switch" : "git checkout"
            let typedBranch = String(lowerQuery.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            for branch in state.branches where typedBranch.isEmpty || branch.displayName.localizedCaseInsensitiveContains(typedBranch) {
                let branchCmd = "\(prefix) \(branch.displayName)"
                guard branchCmd != cmdToRun else { continue }
                result.append(PaletteCommand(title: branchCmd, subtitle: branch.isRemote ? "Checkout remote branch" : "Checkout local branch", iconName: "arrow.triangle.branch", shortcut: nil) {
                    state.executeNativeGitCommand(branchCmd)
                })
            }
        }
        return result
    }

    var filteredCommands: [PaletteCommand] {
        let term = searchTerm
        switch activeMode {
        case .git:
            return gitResults()
        case .commands:
            return ranked(commandResults(term) + actionsResults(term))
        case .repositories:
            return ranked(repositoryResults(term))
        case .branches:
            return ranked(branchResults(term))
        case .pullRequests:
            return ranked(pullRequestResults(term), limit: 60)
        case .all:
            if let target = pastedURLTarget { return urlResults(target) }
            if term.isEmpty {
                return baseCommands.map { var c = $0; c.section = "Commands"; return c }
            }
            if let n = Int(term.hasPrefix("#") ? String(term.dropFirst()) : term), n > 0 {
                return ranked(pullRequestResults(term), limit: 6) + ranked(commandResults(term), limit: 4)
            }
            return ranked(commandResults(term), limit: 6)
                + ranked(actionsResults(term), limit: 5)
                + ranked(pullRequestResults(term), limit: 6)
                + ranked(branchResults(term), limit: 5)
                + ranked(repositoryResults(term), limit: 4)
        }
    }

    // MARK: - View

    @ViewBuilder
    private func rowIcon(_ cmd: PaletteCommand, isSelected: Bool) -> some View {
        if cmd.iconName == "terminal.fill" {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.white.opacity(0.2) : Color.black.opacity(0.4))
                    .frame(width: 26, height: 26)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isSelected ? Color.white : Color(nsColor: .systemGreen))
            }
        } else if cmd.iconName.hasPrefix("gitxx.pr.") {
            let raw = String(cmd.iconName.dropFirst("gitxx.pr.".count))
            let color: Color = {
                switch PullRequestState(rawValue: raw) {
                case .merged: return Color(nsColor: .systemPurple)
                case .closed: return Color(nsColor: .systemRed)
                case .draft: return .secondary
                default: return Color(nsColor: .systemGreen)
                }
            }()
            PullRequestGlyph(size: 15, color: color)
                .frame(width: 26)
        } else {
            Image(systemName: cmd.iconName)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 26)
        }
    }

    private var modeChips: some View {
        HStack(spacing: 6) {
            ForEach(PaletteMode.allCases) { mode in
                let isActive = mode == activeMode
                Button {
                    switchMode(to: mode)
                } label: {
                    HStack(spacing: 4) {
                        Text(mode.title)
                            .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                        if !mode.prefix.isEmpty {
                            Text(mode.prefix)
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .background(isActive ? Color.white.opacity(0.18) : Color.primary.opacity(0.05))
                    .overlay(Capsule().strokeBorder(isActive ? Color.white.opacity(0.28) : Color.clear, lineWidth: 1))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.hoverPlain)
                .pointerCursor()
                .help(mode.prefix.isEmpty ? "Search everything" : "Type “\(mode.prefix)” to search \(mode.title.lowercased())")
            }
            Spacer()
            Text("⇥ next mode")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    public var body: some View {
        let commands = filteredCommands
        let isGit = activeMode == .git
        VStack(spacing: 0) {
            // Search Input Header
            HStack(spacing: 10) {
                if isGit {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .transition(.scale.combined(with: .opacity))
                } else if pastedURLTarget != nil {
                    Image(systemName: "link")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .transition(.scale.combined(with: .opacity))
                }

                PaletteSearchField(
                    text: $query,
                    placeholder: activeMode.placeholder,
                    onSubmit: {
                        executeSelected()
                    },
                    onDownArrow: { moveSelection(1, count: commands.count) },
                    onUpArrow: { moveSelection(-1, count: commands.count) },
                    onEscape: {
                        if activeMode != .all || !query.isEmpty {
                            query = ""
                        } else {
                            state.showCommandPalette = false
                        }
                    },
                    onTab: { backwards in
                        cycleMode(backwards: backwards)
                    }
                )
                .frame(height: 26)

                if isGit {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                        Text("GIT CLI")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                    }
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .systemGreen).opacity(0.14))
                    .clipShape(Capsule())
                    .transition(.opacity.combined(with: .scale))
                }

                Text("esc")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            modeChips

            Divider()

            // Command Items List
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if commands.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.tertiary)
                                Text(activeMode == .pullRequests && state.searchablePullRequests.isEmpty
                                     ? "No pull requests loaded yet — type a number to fetch one"
                                     : "No matches")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                        }
                        ForEach(Array(commands.enumerated()), id: \.offset) { index, cmd in
                            let isSelected = index == selectedIndex
                            let isCLI = cmd.iconName == "terminal.fill"

                            if !cmd.section.isEmpty, index == 0 || commands[index - 1].section != cmd.section {
                                Text(cmd.section.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(0.6)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, index == 0 ? 2 : 10)
                                    .padding(.bottom, 2)
                            }

                            Button {
                                cmd.action()
                                state.showCommandPalette = false
                            } label: {
                                HStack(spacing: 12) {
                                    rowIcon(cmd, isSelected: isSelected)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(cmd.title)
                                                .font(.system(size: 13, weight: isCLI ? .bold : .semibold, design: isCLI ? .monospaced : .default))
                                                .foregroundStyle(isSelected ? Color.white : (isCLI ? Color(nsColor: .systemGreen) : Color.primary))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }

                                        Text(cmd.subtitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer(minLength: 8)

                                    if let shortcut = cmd.shortcut {
                                        Text(shortcut)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2.5)
                                            .background(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.12))
                                            .foregroundStyle(isSelected ? Color.white : Color.secondary)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                            .background(isSelected ? Color.white.opacity(0.14) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onContinuousHover(coordinateSpace: .global) { phase in
                                // Rows sliding under a still pointer while scrolling report the same location; only a real move selects.
                                guard case .active(let point) = phase, point != lastPointer else { return }
                                lastPointer = point
                                if selectedIndex != index { selectedIndex = index }
                            }
                            .id(index)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 400)
                .onChange(of: selectedIndex) { _, newIndex in
                    guard scrollToSelection else { return }
                    scrollToSelection = false
                    if commands.indices.contains(newIndex) {
                        proxy.scrollTo(newIndex, anchor: nil)
                    }
                }
                .onChange(of: query) { _, _ in
                    selectedIndex = 0
                }
            }

            Divider()

            // Footer hints
            HStack(spacing: 14) {
                footerHint("↑↓", "navigate")
                footerHint("↩", isGit ? "run" : "open")
                footerHint("⇥", "switch mode")
                Spacer()
                Text(isGit ? "Runs in \(state.currentRepo?.name ?? "active repo")" : "Paste a github.com link to jump to it")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isGit ? Color(nsColor: .systemGreen).opacity(0.06) : Color.primary.opacity(0.02))
        }
        .onAppear {
            if !state.commandPaletteInitialQuery.isEmpty {
                query = state.commandPaletteInitialQuery
                state.commandPaletteInitialQuery = ""
            }
            installKeyMonitor()
            WebScrollForwarding.suspended = true
        }
        .onDisappear {
            WebScrollForwarding.suspended = false
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .frame(width: 640)
        .themedSurface(state.accentTheme, .elevated)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: isGit ?
                            [Color(nsColor: .systemGreen).opacity(0.6), Color(nsColor: .systemGreen).opacity(0.15)] :
                            [Color.white.opacity(0.4), Color.white.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.35), radius: 32, x: 0, y: 14)
        .animation(.easeInOut(duration: 0.18), value: isGit)
    }

    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.secondary.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: 10.5))
        }
        .foregroundStyle(.secondary)
    }

    private func moveSelection(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        scrollToSelection = true
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    /// Arrow keys, Return and Escape work while the palette is open even if the search field lost focus.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard state.showCommandPalette,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            switch event.keyCode {
            case 125: moveSelection(1, count: filteredCommands.count); return nil
            case 126: moveSelection(-1, count: filteredCommands.count); return nil
            case 36, 76:
                if event.window?.firstResponder is NSTextView, (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
                executeSelected(); return nil
            case 53:
                if activeMode != .all || !query.isEmpty { query = "" } else { state.showCommandPalette = false }
                return nil
            default:
                return event
            }
        }
    }

    private func executeSelected() {
        guard !filteredCommands.isEmpty else { return }
        let index = min(max(selectedIndex, 0), filteredCommands.count - 1)
        filteredCommands[index].action()
        state.showCommandPalette = false
    }
}

