import SwiftUI
import Foundation
import AppKit
import WebKit

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
        case let s where s.hasPrefix("picker-keys:"):
            // `picker-keys:branch:3` opens a picker and presses ↓ that many times, as the keyboard would.
            let parts = s.split(separator: ":")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if parts[1] == "repo" { state.showRepoPicker = true } else { state.showBranchPicker = true }
                try? await Task.sleep(for: .milliseconds(700))
                let editor = NSApp.keyWindow?.firstResponder as? NSTextView
                for _ in 0..<(parts.count > 2 ? Int(parts[2]) ?? 1 : 1) {
                    editor?.doCommand(by: #selector(NSResponder.moveDown(_:)))
                    try? await Task.sleep(for: .milliseconds(150))
                }
                print("PICKER_KEYS \(parts[1]) fieldEditor=\(editor != nil)")
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
        case let s where s.hasPrefix("render-open-with:"):
            // `render-open-with:<out.png>[:<changed file>]` draws the popover offscreen (popovers are separate windows).
            let parts = s.split(separator: ":").map(String.init)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if parts.count > 2 {
                    state.activeTab = .changes
                    state.selectedFile = state.files.first { $0.path == parts[2] }
                }
                let host = NSHostingView(rootView: OpenWithPopover(state: state, targets: state.openWithTargets)
                    .background(Color(NSColor.windowBackgroundColor)).environment(\.colorScheme, .dark))
                host.frame = NSRect(x: 0, y: 0, width: 350, height: 520)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.orderBack(nil)
                try? await Task.sleep(for: .seconds(1.5))
                host.frame.size = host.fittingSize
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
                }
                window.close()
                print("RENDERED_OPEN_WITH targets=\(state.openWithTargets.map(\.kind.rawValue))")
            }
        case let s where s.hasPrefix("render-diff-review:"):
            // `render-diff-review:<out.png>` draws the changed-files diff sheet for the first few changed files.
            let out = String(s.dropFirst("render-diff-review:".count))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let paths = Array(state.workingChanges.prefix(6).map(\.path))
                let host = NSHostingView(rootView: ChangedFilesDiffSheet(state: state, title: "Local changes blocking this pull", paths: paths,
                                                                          initial: paths.dropFirst().first ?? paths.first) { _ in }
                    .frame(width: 1100, height: 680)
                    .background(Color(NSColor.windowBackgroundColor)).environment(\.colorScheme, .dark))
                host.frame = NSRect(x: 0, y: 0, width: 1100, height: 680)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.orderBack(nil)
                try? await Task.sleep(for: .seconds(3))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                window.close()
                print("RENDERED_DIFF_REVIEW \(paths.count)")
            }
        case let s where s.hasPrefix("render-new-branch:"):
            // `render-new-branch:<out.png>[:picker]` draws the Create branch sheet, optionally with the base list open.
            let parts = s.split(separator: ":").map(String.init)
            let out = parts[1]
            let picker = parts.count > 2
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let host = NSHostingView(rootView: NewBranchSheet(state: state, request: NewBranchRequest(initialName: "feat/new branch ui"), showBasePicker: picker)
                    .background(Color(NSColor.windowBackgroundColor)).environment(\.colorScheme, .dark))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.orderBack(nil)
                try? await Task.sleep(for: .seconds(2))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                window.close()
                print("RENDERED_NEW_BRANCH")
            }
        case let s where s.hasPrefix("render-conflict:"):
            // `render-conflict:<out.png>:<file>` draws the three-pane merge; `list` as the file draws the conflicts list.
            let parts = s.split(separator: ":").map(String.init)
            let out = parts[1], file = parts.count > 2 ? parts[2] : "list"
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard let repo = state.currentRepo?.path else { return }
                let sides = await ConflictMerge.sides(repo: repo)
                let root: AnyView
                if file == "list" {
                    root = AnyView(ConflictsListSheet(state: state, request: ConflictResolverRequest(path: nil)))
                } else {
                    let view = ConflictResolverView(state: state, repo: repo, path: file, sides: sides) { _ in }
                    root = AnyView(view.frame(width: 1280, height: 720))
                }
                let host = NSHostingView(rootView: root.background(Color(NSColor.windowBackgroundColor)).environment(\.colorScheme, .dark))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.orderBack(nil)
                try? await Task.sleep(for: .seconds(2))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                window.close()
                print("RENDERED_CONFLICT")
            }
        case let s where s.hasPrefix("render-pull-failed:"):
            // `render-pull-failed:<out.png>` draws the Pull failed dialog as it looks after returning from the diff review.
            let out = String(s.dropFirst("render-pull-failed:".count))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let files = Array(state.workingChanges.prefix(2).map(\.path)) + ["packages/payment-button/package.json"]
                state.presentGitFailure(GitRetryableOperation(title: "Pull failed", verb: "pull") {},
                                        error: NSError(domain: "git", code: 1, userInfo: [NSLocalizedDescriptionKey:
                                            "error: Your local changes to the following files would be overwritten by merge:\n\t" + files.joined(separator: "\n\t") + "\nPlease commit your changes or stash them before you merge.\nAborting"]))
                guard let error = state.operationError else { return }
                state.operationError = nil
                let host = NSHostingView(rootView: GitErrorSheet(state: state, error: error, startReviewed: true)
                    .background(Color(NSColor.windowBackgroundColor)).environment(\.colorScheme, .dark))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.orderBack(nil)
                try? await Task.sleep(for: .seconds(2))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                window.close()
                print("RENDERED_PULL_FAILED")
            }
        case let s where s.hasPrefix("render-dispatch:"):
            // `render-dispatch:<out.png>[:<workflow name filter>]` draws the Run workflow sheet offscreen.
            let parts = s.split(separator: ":").map(String.init)
            state.activeTab = .actions
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                let store = state.actions
                let filter = parts.count > 2 ? parts[2].lowercased() : ""
                guard let workflow = store.workflows.first(where: { $0.isActive && (filter.isEmpty || $0.name.lowercased().contains(filter)) }) else {
                    print("RENDER_DISPATCH no workflow (\(store.workflows.count) loaded)")
                    return
                }
                let host = NSHostingView(rootView: ActionsDispatchSheet(state: state, store: store, workflow: workflow)
                    .background(Color(NSColor.windowBackgroundColor)).environment(\.colorScheme, .dark))
                host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.orderBack(nil)
                try? await Task.sleep(for: .seconds(4))
                host.frame.size = host.fittingSize
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
                }
                window.close()
                print("RENDERED_DISPATCH \(workflow.name)")
            }
        case let s where s.hasPrefix("open-with"):
            // `open-with` (repository) or `open-with:<path>` (selects that changed file first).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if let path = s.split(separator: ":").dropFirst().first.map(String.init) {
                    state.activeTab = .changes
                    state.selectedFile = state.files.first { $0.path == path }
                }
                state.showOpenWith = true
            }
        case "home-chats":
            state.homeTab = .conversations
            state.goHome()
        case "chat-seed":
            // Saves two sample conversations (no model calls) and opens Home › AI conversations.
            let chat = AIChatStore.shared
            let context = AIPageContext.capture(from: state)
            for (question, answer) in [
                ("Why is CI failing on this PR?", "**Custom PR Lint** needs a real *Review URL*; `N/A` is rejected."),
                ("Update the description based on the changes", "Updated the description of PR #1994."),
            ] {
                chat.newChat()
                chat.items = [AIChatItem(kind: .user(question, context: context)),
                              AIChatItem(kind: .tool(name: "get_pr_checks", summary: "checks of PR #1994", status: .done, output: "3 failing")),
                              AIChatItem(kind: .assistant(answer))]
                chat.saveThread()
            }
            chat.newChat()
            state.homeTab = .conversations
            state.goHome()
        case let s where s.hasPrefix("chat-thread"):
            // `chat-thread` opens the newest saved conversation in the assistant panel.
            if let first = AIChatStore.shared.threads.first { AIChatStore.shared.openThread(first.id) }
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
        case let s where s.hasPrefix("pr-to-actions:"):
            // Opens a PR's checks, then follows the first Actions check into the Actions tab.
            if let number = Int(s.dropFirst("pr-to-actions:".count)) {
                Task {
                    await state.openPullRequest(number: number, tab: .checks)
                    for _ in 0..<60 where !state.prChecks.contains(where: { $0.actionsRunId != nil }) { try? await Task.sleep(for: .milliseconds(200)) }
                    guard let check = state.prChecks.first(where: { $0.actionsRunId != nil }),
                          let runId = check.actionsRunId.flatMap(Int.init) else { print("PR_TO_ACTIONS none"); return }
                    state.openActionsRun(runId: runId, jobId: check.actionsJobId.flatMap(Int.init))
                    try? await Task.sleep(for: .seconds(4))
                    print("PR_TO_ACTIONS run=\(runId) selected=\(String(describing: state.actions.selectedRunId)) job=\(String(describing: state.actions.selectedJobId)) prs=\(state.actions.selectedRun.map { state.actions.pullRequestNumbers(for: $0) } ?? [])")
                }
            }
        case let s where s.hasPrefix("pr-merge:"):
            if let number = Int(s.dropFirst("pr-merge:".count)) {
                Task {
                    await state.openPullRequest(number: number)
                    try? await Task.sleep(for: .seconds(6))
                    state.prScrollToMergeBoxRequested = true
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
        case "actions":
            state.activeTab = .actions
        case let s where s.hasPrefix("actions-workflow:"):
            // `actions-workflow:<workflowId>` selects a workflow in the sidebar.
            state.activeTab = .actions
            if let id = Int(s.dropFirst("actions-workflow:".count)) {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    state.actions.filter.workflowId = id
                }
            }
        case "actions-branch":
            state.showActions(branch: state.currentRepo?.currentBranch)
        case let s where s.hasPrefix("actions-run"):
            // `actions-run` (first failed run, else first), `actions-run:job` (also opens its failed job), `actions-run:<runId>`.
            state.activeTab = .actions
            let arg = s.split(separator: ":").dropFirst().first.map(String.init)
            Task {
                if let arg, let id = Int(arg) {
                    state.openActionsRun(runId: id)
                    return
                }
                for _ in 0..<60 where state.actions.runs.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                guard let run = state.actions.runs.first(where: { $0.actionsStatus == .failure }) ?? state.actions.runs.first else { return }
                state.actions.selectRun(run)
                if arg != "job" {
                    for _ in 0..<60 where state.actions.jobs.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                    state.actions.selectJob(nil)
                }
                print("ACTIONS_RUN \(run.id) \(run.workflowName) #\(run.runNumber) jobs=\(state.actions.jobs.count)")
            }
        case let s where s.hasPrefix("pr-js:"):
            // `pr-js:<number>|<javascript>` opens the PR conversation and runs the script in its page once loaded.
            let rest = s.dropFirst("pr-js:".count)
            let parts = rest.split(separator: "|", maxSplits: 1).map(String.init)
            if let number = parts.first.flatMap({ Int($0) }) {
                Task {
                    await state.openPullRequest(number: number)
                    try? await Task.sleep(for: .seconds(7))
                    guard parts.count > 1 else { return }
                    @MainActor func find(_ view: NSView) -> WKWebView? {
                        if let web = view as? WKWebView { return web }
                        for sub in view.subviews { if let hit = find(sub) { return hit } }
                        return nil
                    }
                    let web = NSApp.windows.lazy.compactMap { $0.contentView.flatMap(find) }.first
                    web?.evaluateJavaScript(parts[1]) { _, error in if let error { print("PR_JS error \(error)") } }
                }
            }
        case let s where s.hasPrefix("changes-select:"):
            // `changes-select:<index>` selects the Nth changed file (the list should scroll to it).
            state.activeTab = .changes
            let index = Int(s.dropFirst("changes-select:".count)) ?? 0
            Task {
                for _ in 0..<50 where state.workingChanges.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                try? await Task.sleep(for: .seconds(1))
                let changes = state.workingChanges
                if !changes.isEmpty { state.selectFile(changes[min(index, changes.count - 1)].primary) }
            }
        case "settings-appearance":
            state.showSettings = true
        case let s where s.hasPrefix("settings:"):
            state.initialPreferencesCategory = String(s.dropFirst("settings:".count))
            state.showSettings = true
        case "history-longest":
            state.activeTab = .history
            Task {
                for _ in 0..<50 where state.commits.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                if let commit = state.commits.prefix(400).max(by: { $0.body.count < $1.body.count }) {
                    state.selectCommit(commit)
                    print("HISTORY_LONGEST \(commit.shortSha) body=\(commit.body.count)")
                }
            }
        case let s where s.hasPrefix("actions-fullscreen:"):
            state.activeTab = .actions
            if let runId = Int(s.dropFirst("actions-fullscreen:".count)) {
                Task {
                    state.openActionsRun(runId: runId)
                    for _ in 0..<60 where state.actions.jobs.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                    guard let job = state.actions.jobs.first(where: { $0.actionsStatus == .failure }) ?? state.actions.jobs.first else { return }
                    state.actions.selectJob(job.id)
                    try? await Task.sleep(for: .seconds(3))
                    state.actions.fullScreenLog = ActionsFullScreenLog(jobId: job.id,
                        expanded: Set(job.steps.filter { $0.actionsStatus == .failure }.map(\.number)), query: "")
                }
            }
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
        if let idx = args.firstIndex(of: "--dev-ai-tool"), idx + 4 < args.count {
            // --dev-ai-tool <repo> <owner/name> <tool> <json-args>; token from GITXX_DEV_TOKEN.
            let context = AIToolContext(repoPath: args[idx + 1], repoSlug: args[idx + 2],
                                        githubToken: ProcessInfo.processInfo.environment["GITXX_DEV_TOKEN"])
            let name = args[idx + 3], toolArgs = AIChatTools.parse(args[idx + 4])
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                print(AIChatTools.summary(name: name, args: toolArgs))
                let result = await AIChatTools.execute(name: name, args: toolArgs, context: context)
                print("ok=\(result.ok) chars=\(result.output.count)\n\(result.output)")
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
