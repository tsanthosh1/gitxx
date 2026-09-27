import Foundation
import AppKit

/// Developer hooks for exercising web-rendered views outside the app (e.g. in a headless browser).
enum DevFixtures {
    /// Drives the UI into a named state for `--snapshot-scene` screenshots.
    @MainActor
    static func applyScene(_ scene: String, state: AppState) {
        if state.pendingFirstTimeRepo != nil {
            state.confirmOpenFirstTimeRepo()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { applyScene(scene, state: state) }
            return
        }
        switch scene {
        case let s where s.hasPrefix("repo-switch:"):
            // `repo-switch:/path/a,/path/b,…` switches in turn and prints when each piece of the page updates.
            let paths = s.dropFirst("repo-switch:".count).split(separator: ",").map(String.init)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                for path in paths {
                    let start = Date()
                    func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
                    var marks: [String: Int] = [:]
                    let staleFiles = state.files.map(\.path)
                    state.loadRepo(path: path)
                    marks["sync"] = ms()
                    if state.files.map(\.path) == staleFiles && !staleFiles.isEmpty { marks["STALE_FILES_AFTER_SYNC"] = 1 }
                    while state.switchingRepoPath != nil && ms() < 20_000 {
                        if marks["repo"] == nil, state.currentRepo?.path == path { marks["repo"] = ms() }
                        if marks["files"] == nil, !state.files.isEmpty { marks["files"] = ms() }
                        if marks["commits"] == nil, !state.commits.isEmpty { marks["commits"] = ms() }
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    marks["done"] = ms()
                    print("REPO_SWITCH \((path as NSString).lastPathComponent) branch=\(state.currentBranch) files=\(state.files.count) commits=\(state.commits.count) \(marks.sorted { $0.value < $1.value }.map { "\($0.key)=\($0.value)ms" }.joined(separator: " "))")
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        case "picker-focus":
            Task { @MainActor in
                for (name, open) in [("repo", { state.showRepoPicker = true }), ("branch", { state.showBranchPicker = true })] {
                    try? await Task.sleep(for: .seconds(2))
                    open()
                    try? await Task.sleep(for: .milliseconds(600))
                    let responder = NSApp.keyWindow?.firstResponder
                    let editing = (responder as? NSTextView)?.isFieldEditor == true
                    let field = ((responder as? NSTextView)?.delegate as? NSTextField)?.placeholderString ?? "?"
                    print("PICKER_FOCUS \(name) fieldEditorFocused=\(editing) field=\(field)")
                    state.showRepoPicker = false
                    state.showBranchPicker = false
                }
            }
        case let s where s.hasPrefix("branch-switch:"):
            let names = s.dropFirst("branch-switch:".count).split(separator: ",").map(String.init)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                for name in names {
                    let start = Date()
                    func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
                    state.checkoutBranch(name)
                    let busyAtStart = state.switchingBranchTo != nil
                    var branchAt = -1
                    while ms() < 20_000 {
                        if branchAt < 0, state.currentBranch == name { branchAt = ms() }
                        if branchAt >= 0, state.switchingBranchTo == nil { break }
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    print("BRANCH_SWITCH \(name) spinner=\(busyAtStart) branchShown=\(branchAt)ms")
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        case let s where s.hasPrefix("ai-chat"):
            state.activeTab = .changes
            AIChatStore.shared.isOpen = true
            let name = s.split(separator: ":", maxSplits: 1).first.map(String.init) ?? s
            AIChatStore.shared.isExpanded = name.contains("-xl")
            let prNumber = name.split(separator: "#").dropFirst().first.flatMap { Int($0) }
            if let prompt = s.split(separator: ":", maxSplits: 1).dropFirst().first {
                Task {
                    if let prNumber {
                        try? await Task.sleep(for: .seconds(3))
                        await state.openPullRequest(number: prNumber)
                        try? await Task.sleep(for: .seconds(3))
                        AIChatStore.shared.isOpen = true
                        print("AI_SCENE_PR selected=\(state.selectedPR?.number ?? -1)")
                    }
                    let chat = AIChatStore.shared
                    chat.send(String(prompt), state: state)
                    while chat.isRunning && chat.pendingApprovalID == nil { try? await Task.sleep(for: .milliseconds(500)) }
                    if !chat.isOpen { print("AI_SCENE chat was minimized"); chat.isOpen = true }
                    for item in chat.items {
                        switch item.kind {
                        case .user(let t, _): print("AI_ITEM user: \(t.prefix(80))")
                        case .assistant(let t): print("AI_ITEM assistant: \(t.prefix(300).replacingOccurrences(of: "\n", with: " ⏎ "))")
                        case .tool(_, let summary, let status, let out): print("AI_ITEM tool[\(status)]: \(summary.prefix(160).replacingOccurrences(of: "\n", with: " ⏎ ")) -> \(out.prefix(160).replacingOccurrences(of: "\n", with: " ⏎ "))")
                        case .error(let e): print("AI_ITEM error: \(e)")
                        }
                    }
                }
            }
            if name.contains("-scroll") {
                // Scroll every scroll view in the window up, down and past the end, the way the hang was hit.
                Task { @MainActor in
                    while AIChatStore.shared.isRunning || AIChatStore.shared.items.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                    try? await Task.sleep(for: .seconds(1))
                    guard let root = NSApp.windows.first?.contentView else { return }
                    var found: [NSScrollView] = []
                    var queue: [NSView] = [root]
                    while let v = queue.popLast() {
                        if let sv = v as? NSScrollView { found.append(sv) }
                        queue.append(contentsOf: v.subviews)
                    }
                    func scrollViews(_: NSView) -> [NSScrollView] { found }
                    for round in 0..<60 {
                        for sv in scrollViews(root) {
                            let docHeight = sv.documentView?.frame.height ?? 0
                            let y = round % 3 == 0 ? docHeight + 400 : (round % 3 == 1 ? 0 : docHeight / 2)
                            sv.contentView.scroll(to: NSPoint(x: 0, y: y))
                            sv.reflectScrolledClipView(sv.contentView)
                        }
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    print("SCROLL_STRESS_DONE")
                }
            }
        case "changes":
            state.activeTab = .changes
            if let file = state.files.first(where: { !$0.isStaged }) { state.selectFile(file) }
        case "pull":
            state.activeTab = .changes
            state.pullOrigin()
        case "pull-fix", "pull-fix-keep":
            state.activeTab = .changes
            state.pullOrigin()
            Task {
                try? await Task.sleep(for: .seconds(3))
                if let fix = state.operationError?.actions.dropFirst(scene == "pull-fix-keep" ? 1 : 0).first {
                    state.operationError = nil
                    await fix.perform()
                }
            }
        case "pull-inspect":
            state.activeTab = .changes
            state.pullOrigin()
            Task {
                try? await Task.sleep(for: .seconds(3))
                if let file = state.operationError?.files.first { state.inspectFileFromError(file) }
            }
        case "create-pr":
            state.activeTab = .pullRequests
            state.showCreatePRSheet = true
        case "prs":
            state.activeTab = .pullRequests
        case "home":
            state.homeTab = .repositories
            state.goHome()
        case "home-prs":
            state.homeTab = .pullRequests
            state.goHome()
        case "home-open-pr-back":
            state.homeTab = .pullRequests
            state.goHome()
            Task {
                for _ in 0..<40 where state.myPullRequests.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                if let item = state.myPullRequests.first(where: { state.localRepository(slug: $0.repository) != nil }) {
                    state.openPullRequestFromHome(item)
                }
                try? await Task.sleep(for: .seconds(4))
                print("NAV_BEFORE_BACK: \(state.currentNavigationLocation.title) back=\(state.backStack.map(\.title))")
                state.navigateBack()
                try? await Task.sleep(for: .milliseconds(500))
                print("NAV_AFTER_BACK: \(state.currentNavigationLocation.title) forward=\(state.forwardStack.map(\.title))")
            }
        case let s where s.hasPrefix("stage-files:"):
            state.activeTab = .changes
            Task {
                try? await Task.sleep(for: .seconds(2))
                for token in s.dropFirst("stage-files:".count).split(separator: ",") {
                    let path = String(token.dropFirst())
                    let started = Date()
                    state.setFilesStaged([path], staged: token.hasPrefix("+"))
                    let entry = state.workingChanges.first { $0.path == path }
                    print("STAGE_UI \(token) -> \(String(describing: entry?.stageState)) in \(Int(Date().timeIntervalSince(started) * 1000))ms")
                }
            }
        case let s where s.hasPrefix("narrow:"):
            NSApp.windows.first(where: { $0.isVisible && !$0.isSheet })?.setContentSize(NSSize(width: 720, height: 640))
            applyScene(String(s.dropFirst("narrow:".count)), state: state)
        case "home-open-pr":
            state.homeTab = .pullRequests
            state.goHome()
            Task {
                for _ in 0..<40 where state.myPullRequests.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                if let item = state.myPullRequests.first(where: { state.localRepository(slug: $0.repository) != nil }) {
                    state.openPullRequestFromHome(item)
                }
            }
        case let s where s.hasPrefix("select-files:"):
            state.activeTab = .changes
            Task {
                try? await Task.sleep(for: .seconds(2))
                for path in s.dropFirst("select-files:".count).split(separator: ",").map(String.init) {
                    guard let file = state.files.first(where: { $0.path == path }) else { print("SELECT_MISSING \(path)"); continue }
                    let started = Date()
                    state.selectFile(file)
                    while state.currentDiff?.path != path, Date().timeIntervalSince(started) < 3 {
                        try? await Task.sleep(for: .milliseconds(2))
                    }
                    let loaded = Int(Date().timeIntervalSince(started) * 1000)
                    await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
                    print("SELECT \(path) diff=\(loaded)ms rendered=\(Int(Date().timeIntervalSince(started) * 1000))ms")
                    try? await Task.sleep(for: .milliseconds(600))
                }
            }
        case let s where s.hasPrefix("pr:"):
            // `pr:658` or `pr:658@720` (window width applied once the PR is open).
            let parts = s.dropFirst("pr:".count).split(separator: "@")
            if let number = parts.first.flatMap({ Int($0) }) {
                Task {
                    await state.openPullRequest(number: number)
                    if parts.count > 1, let width = Double(parts[1]) {
                        try? await Task.sleep(for: .seconds(2))
                        NSApp.windows.first(where: { $0.isVisible && !$0.isSheet })?.setContentSize(NSSize(width: width, height: 640))
                    }
                }
            }
        case let s where s.hasPrefix("prs-author-closed:"):
            state.activeTab = .pullRequests
            state.setPRFilter(.closed)
            state.setPRAuthorFilter(String(s.dropFirst("prs-author-closed:".count)))
        case "home-switch":
            state.homeTab = .repositories
            state.goHome()
            Task {
                try? await Task.sleep(for: .seconds(3))
                let started = Date()
                state.homeTab = .pullRequests
                DispatchQueue.main.async {
                    print("HOME_SWITCH \(Int(Date().timeIntervalSince(started) * 1000))ms")
                }
            }
        case let s where s.hasPrefix("prs-author:"):
            state.activeTab = .pullRequests
            state.setPRAuthorFilter(String(s.dropFirst("prs-author:".count)))
        case "stash":
            state.activeTab = .changes
            state.showStashDrawer = true
        case "history":
            state.activeTab = .history
        case "history-branch":
            state.activeTab = .history
            let branch = state.branches.first { !$0.isCurrent && !$0.isRemote }?.name ?? state.branches.first { $0.isRemote }?.name
            state.setHistoryRef(branch)
        case "tag":
            state.activeTab = .history
            state.tagTargetCommit = state.commits.first
        case "rebase":
            state.activeTab = .history
            if state.commits.count > 3 { state.rebaseTargetCommit = state.commits[3] }
        case let s where s.hasPrefix("changes-stage:"):
            // `changes-stage:+H:L,-H:L` toggles rows of the selected file's diff once it has loaded.
            state.activeTab = .changes
            Task {
                try? await Task.sleep(for: .seconds(2))
                for token in s.dropFirst("changes-stage:".count).split(separator: ",") {
                    let parts = token.dropFirst().split(separator: ":").compactMap { Int($0) }
                    guard parts.count == 2 else { continue }
                    state.setLinesStaged([DiffLineKey(hunk: parts[0], line: parts[1])], staged: token.hasPrefix("+"))
                }
            }
        case let s where s.hasPrefix("pr-files:") || s.hasPrefix("pr-checks:") || s.hasPrefix("pr-commits:"):
            guard let number = Int(s.split(separator: ":").last ?? "") else { return }
            let tab: PRDetailTab = s.hasPrefix("pr-files") ? .filesChanged : (s.hasPrefix("pr-checks") ? .checks : .commits)
            Task { await state.openPullRequest(number: number, tab: tab) }
        default:
            break
        }
    }

    /// `--dev-render-files <repo> <out.html> [--range <rev>] [--split]` writes the Files-changed page for a local diff.
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--dev-render-conversation"), idx + 1 < args.count {
            renderConversation(out: args[idx + 1])
        }
        if let idx = args.firstIndex(of: "--dev-rebase"), idx + 2 < args.count {
            // --dev-rebase <repo> <base|--root> action:sha[:message] ... (oldest first)
            let repo = args[idx + 1], base = args[idx + 2]
            let steps = args[(idx + 3)...].compactMap { spec -> GitService.RebaseStep? in
                let parts = spec.split(separator: ":", maxSplits: 2).map(String.init)
                guard parts.count >= 2, let action = GitService.RebaseStep.Action(rawValue: parts[0]) else { return nil }
                return GitService.RebaseStep(sha: parts[1], action: action, message: parts.count > 2 ? parts[2] : nil)
            }
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    try await GitService.shared.interactiveRebase(at: repo, onto: base == "--root" ? nil : base, steps: steps)
                    print("DEV_REBASE ok")
                } catch {
                    print("DEV_REBASE failed: \(error.localizedDescription)")
                }
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }
        if let idx = args.firstIndex(of: "--dev-stage-lines"), idx + 3 < args.count {
            stageLines(repo: args[idx + 1], file: args[idx + 2], spec: args[idx + 3])
        }
        guard let idx = args.firstIndex(of: "--dev-render-files"), idx + 2 < args.count else { return }
        let repo = args[idx + 1], out = args[idx + 2]
        let range = args.firstIndex(of: "--range").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "HEAD~1"
        let files = localDiffFiles(repo: repo, range: range)
        let html = PRFilesHTMLBuilder.buildHTML(
            files: files, mode: args.contains("--split") ? .split : .unified,
            viewedPaths: [], canOpenLocally: true, prURL: "https://github.com/example/repo/pull/1"
        )
        try? html.write(toFile: out, atomically: true, encoding: .utf8)
        print("DEV_RENDERED \(files.count) files -> \(out)")
        exit(0)
    }

    /// `--dev-stage-lines <repo> <file> <all|none|+H:L,-H:L,...>` sets which rows of the HEAD→worktree diff are
    /// staged (`+` adds to the current staged set, `-` removes) and prints the resulting staged diff.
    private static func stageLines(repo: String, file: String, spec: String) -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let git = GitService.shared
            do {
                let untracked = try await git.execute(arguments: ["ls-files", "--error-unmatch", "--", file], in: repo).exitCode != 0
                guard let (diff, staged) = try await git.workingDiff(at: repo, path: file, untracked: untracked) else {
                    print("DEV_STAGE no HEAD"); exit(2)
                }
                print("DEV_STAGE before: \(staged.sorted().map { "\($0.hunk):\($0.line)" })")
                var included = staged
                switch spec {
                case "all": included = PartialPatch.changedLines(in: diff)
                case "none": included = []
                default:
                    for token in spec.split(separator: ",") {
                        let parts = token.dropFirst().split(separator: ":").compactMap { Int($0) }
                        guard parts.count == 2 else { continue }
                        let key = DiffLineKey(hunk: parts[0], line: parts[1])
                        if token.hasPrefix("-") { included.remove(key) } else { included.insert(key) }
                    }
                }
                try await git.setStagedLines(at: repo, path: file, diff: diff, included: included)
                let after = try await git.workingDiff(at: repo, path: file, untracked: false)
                print("DEV_STAGE after: \((after?.staged ?? []).sorted().map { "\($0.hunk):\($0.line)" })")
                print("DEV_STAGE match: \(after?.staged == included)")
                print(try await git.execute(arguments: ["diff", "--cached", "--", file], in: repo).stdout)
            } catch {
                print("DEV_STAGE failed: \(error.localizedDescription)"); exit(1)
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    /// `--dev-render-conversation <out.html>` writes the Conversation page for a synthetic PR.
    private static func renderConversation(out: String) -> Never {
        let now = Date()
        let pr = PullRequest(
            number: 42, title: "Add retry logic to payment intents",
            body: "## Summary\n\nAdds **exponential backoff**.\n\n```swift\nlet x = 1\n```\n\n- [x] tests\n- [ ] docs",
            authorName: "octocat", headBranch: "feature/retry", headSha: "abc123",
            url: "https://github.com/example/repo/pull/42", createdAt: now.addingTimeInterval(-86_400)
        )
        var timeline: [PRTimelineItem] = [
            .issueComment(PRComment(id: "c1", authorName: "hubot", body: "Looks good, one question <script>alert(1)</script> about `retry()`.", createdAt: now.addingTimeInterval(-7200))),
            .reviewEvent(PRReviewEvent(id: "r1", authorName: "monalisa", submittedAt: now.addingTimeInterval(-3600), state: "APPROVED", body: "Ship it :rocket:")),
            .merged(authorName: "octocat", mergedAt: now, sha: "deadbeef"),
        ]
        for i in 0..<40 {
            timeline.insert(.reviewThread(PRReviewThread(
                id: "t\(i)", path: "src/file\(i % 5).swift", line: 10 + i,
                diffHunk: "@@ -1,3 +1,4 @@\n context\n-old\n+new line \(i)",
                comments: [PRReviewComment(id: "rc\(i)", authorName: "reviewer", body: "Comment **\(i)** with a [link](https://example.com)", createdAt: now.addingTimeInterval(Double(-5000 + i)), path: "src/file\(i % 5).swift", line: 10 + i)],
                isResolved: i % 3 == 0, nodeId: "n\(i)"
            )), at: 1)
        }
        let html = ConversationHTMLBuilder.buildHTML(pr: pr, timeline: timeline)
        try? html.write(toFile: out, atomically: true, encoding: .utf8)
        print("DEV_RENDERED conversation -> \(out)")
        exit(0)
    }

    private static func localDiffFiles(repo: String, range: String) -> [PRFileChange] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo, "diff", "--no-color", "-U3", range]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return PRFileChange.fromUnifiedDiff(String(decoding: data, as: UTF8.self))
    }
}
