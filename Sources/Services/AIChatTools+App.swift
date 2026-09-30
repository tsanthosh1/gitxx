import Foundation

/// Tools that drive the GitXX window itself: open a repository, switch tabs, open a PR or workflow, start a branch…
enum AIAppActions {
    static let actions = [
        "open_repository", "go_home", "switch_tab", "open_pull_request", "open_workflow", "open_actions_run",
        "create_pull_request", "new_branch", "switch_branch", "fetch", "pull", "push", "open_settings", "open_command_palette",
        "resolve_conflicts",
    ]

    static let specs: [AIToolSpec] = [
        AIToolSpec(
            name: "list_repositories",
            description: "List the repositories GitXX knows about (name, owner/repo, local path, current branch), current one first. Use it to resolve a spoken or misspelled repository name before open_repository.",
            parametersJSON: #"{"type":"object","properties":{}}"#
        ),
        AIToolSpec(
            name: "app_action",
            description: """
            Do something in the GitXX app window for the user (it changes what they see, not their code unless noted). Actions:
            - open_repository: target = repository name, owner/repo or path (fuzzy; e.g. a dictated "charge bee js" finds chargebee-js). Opens it in this window.
            - go_home: the Home page (recent repositories, my pull requests).
            - switch_tab: target = changes | history | pull_requests | actions | terminal.
            - open_pull_request: number = PR number in the current repository.
            - open_workflow: target = workflow name or file; shows its runs in the Actions tab.
            - open_actions_run: number = workflow run id.
            - create_pull_request: opens the Create pull request sheet for the current branch.
            - new_branch: opens the Create branch dialog; optional target = suggested name.
            - switch_branch: target = branch name; checks it out (needs approval).
            - fetch, pull, push: sync the current branch with origin (pull and push need approval).
            - open_settings: optional target = general | appearance | shortcuts | profiles | github | api | ai | commits | terminal | cli | about.
            - open_command_palette: optional target = text to search for.
            - resolve_conflicts: opens the conflict resolver (three-pane merge); optional target = file path to merge.
            """,
            parametersJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["open_repository","go_home","switch_tab","open_pull_request","open_workflow","open_actions_run","create_pull_request","new_branch","switch_branch","fetch","pull","push","open_settings","open_command_palette","resolve_conflicts"]},"target":{"type":"string"},"number":{"type":"integer"}},"required":["action"]}"#
        ),
    ]

    static let names: Set<String> = Set(specs.map(\.name))

    static func requiresApproval(args: [String: Any]) -> Bool {
        ["switch_branch", "pull", "push"].contains(args["action"] as? String ?? "")
    }

    static func summary(name: String, args: [String: Any]) -> String {
        if name == "list_repositories" { return "list repositories" }
        let action = (args["action"] as? String ?? "?").replacingOccurrences(of: "_", with: " ")
        if let target = args["target"] as? String, !target.isEmpty { return "\(action): \(target)" }
        if let number = args["number"] { return "\(action) #\(number)" }
        return action
    }

    // MARK: Execution

    struct Request: Sendable {
        let name: String
        let action: String
        let target: String
        let number: Int?

        init(name: String, args: [String: Any]) {
            self.name = name
            action = args["action"] as? String ?? ""
            target = (args["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            number = args["number"] as? Int ?? Int(target.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        }
    }

    @MainActor
    static func execute(_ request: Request, state: AppState) async -> (output: String, ok: Bool) {
        if request.name == "list_repositories" { return (listRepositories(state), true) }
        let target = request.target
        let number = request.number

        switch request.action {
        case "open_repository":
            guard !target.isEmpty else { return ("Say which repository to open.", false) }
            if target.hasPrefix("/") || target.hasPrefix("~") {
                state.requestOpenRepo(path: (target as NSString).expandingTildeInPath)
                return ("Opening \(target).", true)
            }
            let matches = rankRepositories(target, in: repositories(state))
            guard let best = matches.first else {
                return ("No known repository matches “\(target)”. Known: " + repositories(state).map(\.name).joined(separator: ", "), false)
            }
            if matches.count > 1, matches[0].score == matches[1].score {
                return ("“\(target)” is ambiguous: " + matches.prefix(4).map { "\($0.repo.name) (\($0.repo.path))" }.joined(separator: ", ") + ". Ask which one.", false)
            }
            if best.repo.path == state.currentRepo?.path, !state.showHome {
                return ("\(best.repo.name) is already open.", true)
            }
            state.openRepoFromHome(best.repo)
            return ("Opened \(best.repo.name) (\(best.repo.path)).", true)

        case "go_home":
            state.goHome()
            return ("Showing Home.", true)

        case "switch_tab":
            let key = normalize(target)
            let tab: AppTab? = key.contains("change") || key.contains("commit") || key.contains("stag") ? .changes
                : key.contains("hist") || key.contains("log") ? .history
                : key.contains("pull") || key == "pr" || key == "prs" ? .pullRequests
                : key.contains("action") || key.contains("workflow") || key.contains("ci") ? .actions
                : key.contains("term") || key.contains("shell") ? .terminal : nil
            guard let tab else { return ("Unknown tab “\(target)”. Use changes, history, pull_requests, actions or terminal.", false) }
            state.showHome = false
            state.activeTab = tab
            return ("Switched to \(tab.rawValue).", true)

        case "open_pull_request":
            guard let number else { return ("Pass the pull request number.", false) }
            state.showHome = false
            await state.openPullRequest(number: number)
            return ("Opened pull request #\(number).", true)

        case "open_workflow":
            state.showHome = false
            state.activeTab = .actions
            state.actions.activate()
            for _ in 0..<40 where state.actions.workflows.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
            }
            let workflows = state.actions.workflows
            guard !workflows.isEmpty else { return ("Opened Actions, but no workflows loaded for this repository.", false) }
            guard !target.isEmpty else { return ("Opened Actions.", true) }
            let q = normalize(target)
            let ranked = workflows.map { wf -> (ActionsWorkflow, Int) in
                let n = normalize(wf.name), f = normalize(wf.fileName)
                let score = n == q || f == q ? 100 : (n.contains(q) || f.contains(q) ? 80 : (q.contains(n) ? 60 : similarity(q, n)))
                return (wf, score)
            }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first, best.1 >= 50 else {
                return ("No workflow matches “\(target)”. Workflows: " + workflows.prefix(40).map(\.name).joined(separator: ", "), false)
            }
            state.actions.filter.workflowId = best.0.id
            return ("Showing runs of \(best.0.name) (\(best.0.path)).", true)

        case "open_actions_run":
            guard let number else { return ("Pass the run id.", false) }
            state.showHome = false
            state.activeTab = .actions
            state.actions.activate()
            state.actions.openRun(id: number)
            return ("Opened run \(number).", true)

        case "create_pull_request":
            guard state.currentRepo != nil else { return ("No repository is open.", false) }
            state.showHome = false
            state.showCreatePRSheet = true
            return ("Opened the Create pull request sheet.", true)

        case "new_branch":
            guard state.currentRepo != nil else { return ("No repository is open.", false) }
            state.showHome = false
            state.beginNewBranch(name: target)
            return ("Opened the Create branch dialog" + (target.isEmpty ? "." : " with “\(target)”."), true)

        case "switch_branch":
            guard !target.isEmpty else { return ("Say which branch.", false) }
            let local = state.branches.filter { !$0.isRemote }
            guard let branch = local.first(where: { $0.name == target })
                    ?? local.first(where: { $0.name.localizedCaseInsensitiveContains(target) })
                    ?? state.branches.first(where: { $0.isRemote && $0.displayName == target }) else {
                return ("No branch named “\(target)”.", false)
            }
            state.checkoutBranch(branch.isRemote ? branch.displayName : branch.name)
            return ("Switching to \(branch.isRemote ? branch.displayName : branch.name).", true)

        case "fetch":
            state.fetchOrigin()
            return ("Fetching origin.", true)
        case "pull":
            state.pullOrigin()
            return ("Pulling the current branch.", true)
        case "push":
            state.pushOrigin()
            return ("Pushing the current branch.", true)

        case "open_settings":
            let category = settingsCategory(target)
            state.initialPreferencesCategory = category.rawValue
            state.showSettings = true
            return ("Opened Settings › \(category.shortTitle).", true)

        case "resolve_conflicts":
            guard state.currentRepo != nil else { return ("No repository is open.", false) }
            state.openConflictResolver(path: target.isEmpty ? nil : target)
            let count = state.conflictedPaths.count
            return (count == 0 ? "Opened the conflict resolver; there are no conflicted files right now." : "Opened the conflict resolver (\(count) conflicted file\(count == 1 ? "" : "s")).", true)

        case "open_command_palette":
            state.commandPaletteInitialQuery = target
            state.showCommandPalette = true
            return ("Opened the command palette" + (target.isEmpty ? "." : " searching “\(target)”."), true)

        default:
            return ("Unknown action. Use one of: " + actions.joined(separator: ", "), false)
        }
    }

    // MARK: Repositories

    @MainActor
    private static func repositories(_ state: AppState) -> [GitRepository] {
        var list = state.recentRepos
        if let current = state.currentRepo, !list.contains(where: { $0.path == current.path }) { list.insert(current, at: 0) }
        return list
    }

    @MainActor
    private static func listRepositories(_ state: AppState) -> String {
        let repos = repositories(state)
        guard !repos.isEmpty else { return "No repositories yet. The user can open one with ⌘O." }
        return repos.map { repo in
            let slug = GitHubAPIService.shared.parseRepoOwnerAndName(from: repo.remoteUrl).map { "\($0.owner)/\($0.name)" } ?? "-"
            let mark = repo.path == state.currentRepo?.path ? " (open)" : ""
            return "- \(repo.name)\(mark) · \(slug) · \(repo.path) · on \(repo.currentBranch)"
        }.joined(separator: "\n")
    }

    private static func rankRepositories(_ query: String, in repos: [GitRepository]) -> [(repo: GitRepository, score: Int)] {
        let q = normalize(query.replacingOccurrences(of: "repository", with: "").replacingOccurrences(of: "repo", with: ""))
        guard !q.isEmpty else { return [] }
        return repos.compactMap { repo -> (GitRepository, Int)? in
            let slug = GitHubAPIService.shared.parseRepoOwnerAndName(from: repo.remoteUrl)
            let names = [repo.name, slug?.name ?? "", slug.map { "\($0.owner)/\($0.name)" } ?? ""].map(normalize).filter { !$0.isEmpty }
            var best = 0
            for n in names {
                let score = n == q ? 100 : (n.hasPrefix(q) ? 85 : (n.contains(q) ? 75 : (q.contains(n) ? 65 : similarity(q, n))))
                best = max(best, score)
            }
            return best >= 55 ? (repo, best) : nil
        }
        .sorted { $0.1 > $1.1 }
        .map { (repo: $0.0, score: $0.1) }
    }

    /// Lowercased letters and digits only, so "Charge Bee-JS" and "chargebee_js" compare equal.
    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// 0–100 from edit distance; tolerant of dictation slips like "chargevia" → "chargebee".
    private static func similarity(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return max(0, 100 - prev[y.count] * 100 / max(x.count, y.count))
    }

    private static func settingsCategory(_ target: String) -> PreferenceCategory {
        let key = normalize(target)
        let map: [(String, PreferenceCategory)] = [
            ("appear", .appearance), ("theme", .appearance), ("color", .appearance), ("shortcut", .shortcuts), ("key", .shortcuts),
            ("profile", .gitUsers), ("user", .gitUsers), ("identity", .gitUsers), ("api", .network), ("network", .network),
            ("rate", .network), ("github", .github), ("account", .github), ("commit", .aiWriting), ("assistant", .aiWriting),
            ("instruction", .aiWriting), ("ai", .aiCopilot), ("copilot", .aiCopilot), ("model", .aiCopilot),
            ("terminal", .terminal), ("shell", .terminal), ("cli", .cli), ("command", .cli), ("about", .about),
        ]
        return map.first { key.contains($0.0) }?.1 ?? .general
    }
}
