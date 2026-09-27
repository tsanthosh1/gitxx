import SwiftUI

/// What the user was looking at when they sent a message.
public struct AIPageContext: Sendable, Hashable {
    public var label: String
    public var details: [String]
    public var repoPath: String?
    public var repoSlug: String?

    @MainActor
    static func capture(from state: AppState) -> AIPageContext {
        var details: [String] = []
        let repo = state.currentRepo
        let slug = repo.flatMap { state.gitHubService.parseRepoOwnerAndName(from: $0.remoteUrl) }.map { "\($0.owner)/\($0.name)" }
        if let repo {
            details.append("Repository: \(slug ?? repo.name) at \(repo.path), current branch \(state.currentBranch)")
        }
        let label: String
        if state.showHome {
            label = "Home"
            details.append("Page: Home (\(state.homeTab.rawValue))")
        } else {
            switch state.activeTab {
            case .pullRequests:
                if let pr = state.selectedPR {
                    label = "PR #\(pr.number)"
                    details.append("Page: pull request #\(pr.number) \"\(pr.title)\" (\(String(describing: state.selectedPRTab)) tab)")
                    details.append("PR state: \(pr.state.rawValue)\(pr.isDraft ? ", draft" : ""); author \(pr.authorName); \(pr.url)")
                    details.append("PR head branch: \(pr.headBranch); PR base branch: \(pr.baseBranch) (the locally checked-out branch above is unrelated unless it has the same name)")
                    if let file = state.selectedPRFile, state.selectedPRTab == .filesChanged {
                        details.append("Viewing file in PR: \(file.filename)")
                    }
                } else {
                    label = "Pull requests"
                    details.append("Page: pull request list (filter \(String(describing: state.prFilter)))")
                }
            case .changes:
                label = "Changes"
                details.append("Page: local changes (\(state.files.count) changed file entries)")
                if let file = state.selectedFile { details.append("Selected file: \(file.path)") }
            case .history:
                label = "History"
                details.append("Page: commit history")
                if let c = state.selectedCommit { details.append("Selected commit: \(c.shortSha) \"\(c.summary)\" by \(c.authorName)") }
            case .terminal:
                label = "Terminal"
                details.append("Page: embedded terminal")
            }
        }
        let prefix = repo.map { "\($0.name) · " } ?? ""
        return AIPageContext(label: label == "Home" ? label : prefix + label, details: details, repoPath: repo?.path, repoSlug: slug)
    }
}

public struct AIChatItem: Identifiable, Sendable {
    public enum ToolStatus: Sendable, Equatable { case awaitingApproval, running, done, failed, denied }

    public enum Kind: Sendable {
        case user(String, context: AIPageContext)
        case assistant(String)
        case tool(name: String, summary: String, status: ToolStatus, output: String)
        case error(String)
    }

    public let id = UUID()
    public var kind: Kind
}

/// What the current conversation has cost so far.
public struct AIChatUsage: Sendable, Equatable {
    public var modelCalls = 0
    public var userTurns = 0
    public var promptTokens = 0
    public var completionTokens = 0
    /// Copilot premium-request balance when the conversation started and after the latest reply.
    public var premiumAtStart: Double?
    public var premiumNow: Double?
    public var premiumEntitlement: Double?
    public var premiumUnlimited = false
    public var resetDate: String?

    public var totalTokens: Int { promptTokens + completionTokens }
    public var premiumUsed: Double? {
        guard let start = premiumAtStart, let now = premiumNow else { return nil }
        return max(0, start - now)
    }
}

/// App-wide assistant conversation. It lives outside any page, so a running prompt keeps going
/// (with the context captured when it was sent) while the user navigates.
@MainActor
public final class AIChatStore: ObservableObject {
    public static let shared = AIChatStore()

    @Published public var isOpen = false
    @Published public var items: [AIChatItem] = []
    @Published public var input = ""
    @Published public private(set) var isRunning = false
    @Published public var hasUnread = false
    @Published public var autoApprove = UserDefaults.standard.bool(forKey: "gitxx_ai_auto_approve") {
        didSet { UserDefaults.standard.set(autoApprove, forKey: "gitxx_ai_auto_approve") }
    }
    @Published public var isExpanded = UserDefaults.standard.bool(forKey: "gitxx_ai_chat_expanded") {
        didSet { UserDefaults.standard.set(isExpanded, forKey: "gitxx_ai_chat_expanded") }
    }
    @Published public private(set) var usage = AIChatUsage()

    public static let customInstructionsKey = "gitxx_ai_custom_instructions"

    private var wire: [ChatWireMessage] = []
    private var runTask: Task<Void, Never>?
    private var approval: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?

    public var pendingApprovalID: UUID? { approval?.id }

    private static let basePrompt = """
    You are the assistant built into GitXX, a native macOS Git and GitHub client. You help with the user's \
    repositories, local changes, commits, branches and pull requests.

    ## Tools
    - Look things up instead of guessing: run_git for local repository state, run_gh (preferred) or github_api \
    for GitHub (pull requests, checks, reviews, issues, workflow runs), read_file for files in the repository.
    - Read before you write: fetch the current value (e.g. `gh pr view N --json title,body`) before editing it.

    ## Context
    - Each user message ends with a "[Page when sent]" block describing the screen the user was on. "This PR", \
    "this file", "this commit", "here" refer to it. Never act on a different PR, branch or repository than the \
    one on that page unless the user names it.

    ## Understand the target before changing anything
    - Work out which object the user means and act only on that object. Common confusions:
      - On a pull request, "the template", "fill the template", "update the PR template" almost always means \
    the PR's description (its body, which is usually written in the repository's template format). Edit the \
    body with `gh pr edit <number> --body ...`. Only touch template files such as \
    `.github/pull_request_template.md` when the user explicitly says the template *file* or the repository's template.
      - "Description", "summary", "body" of a PR are the PR body, not a commit message or a file.
      - "Update the PR" (without more) means its title/body/metadata, not pushing code, unless they talk about code.
      - "Update the branch" means merging the base branch into the PR branch, not renaming it.
    - Messages are often dictated, so expect speech-to-text slips and read them by intent: "peer", "p r", \
    "pier" usually mean "PR"; "get" may mean "git"; "hub" may mean "GitHub".
    - Only ask a question when the *target* is genuinely ambiguous (two different objects would be changed). \
    Never ask about content you can work out yourself from the repository, the diff, commits or the page.

    ## Act, don't ask
    - When the intent is clear, do the whole job in this turn: gather what you need with read-only tools, \
    then call the tool that makes the change. Do not stop to show a draft and ask "should I proceed?" or \
    "what should I write?"; the user approves every changing command with a Run/Skip card, and that card \
    is the confirmation. If they skip it they will tell you what to change.
    - Before the changing call, say in one line what you are changing, e.g. "Updating the description of PR #123."
    - Make reasonable assumptions and state them briefly afterwards instead of asking up front.
    - A failed tool call is not a reason to stop. Read the error and try the next approach (another command, \
    a fallback from the playbooks below, or a narrower query) before replying.
    - When the user asked for a change, your turn is not finished until you have called the tool that makes it \
    (or explained a real blocker). Never end with "let me know if you need updates" in place of doing the work.

    ## Playbook: write or update a PR description ("update the description based on the changes", \
    "fill the template", "describe this PR")
    1. `gh pr view <n> --json title,body,headRefName,baseRefName,commits` for the current body, branches and \
    commits. Don't add `files` here: on big PRs it pushes the rest of the output past the tool's size limit.
    2. `gh pr diff <n>` to see what actually changed. GitHub refuses diffs for very large PRs (over 300 files \
    or 20k lines); if it fails, don't give up. Take `<base>` = baseRefName and `<head>` = headRefName from \
    step 1 (never the locally checked-out branch, which is usually a different branch), run \
    `git fetch origin <base> <head>` (no approval needed), then \
    `git diff --dirstat=files,3 origin/<base>...origin/<head>` and \
    `git diff --stat=160 --stat-count=60 origin/<base>...origin/<head>` for the overview, and \
    `git diff origin/<base>...origin/<head> -- <path>` for a few key files (config, entry points, the most \
    changed modules). Commit messages fill in the rest. Empty diff output almost always means wrong refs; \
    re-check the branch names rather than concluding nothing changed.
    3. Write the full new body. If the current body follows a template (headings, `REPLACE_ME…` placeholders, \
    checklists), keep every heading and its order, and replace each placeholder with real content: \
    changelog and summary from the diff and commits; areas of impact from the changed modules; tick (`[x]`) \
    the checkboxes that apply (type of change, yes/no questions) and leave the others unticked. For values \
    you cannot know (test report URLs, links to other PRs, ticket numbers not in the branch/commits), write \
    `N/A` or `TBD` rather than inventing them, and list those at the end of your reply.
    4. Immediately call `gh pr edit <n> --body "<full new body>"` (pass the whole body as one argument).
    5. Reply with a two-line summary of what you filled in and anything left as TBD.
    - "Update the description based on the changes" means re-derive it from the current changes even when \
    a description already exists: the code may have moved on since it was written. Keep details that are \
    still true, correct what is outdated, add what is missing, then propose the edit. Only skip the edit if \
    the new body would be identical, and say so.

    ## Making changes
    - Commands that change anything (edit, commit, push, merge, comment, close, delete, label…) are shown to \
    the user for approval before they run. Only run them when the user asked for that outcome.
    - Keep edits minimal: change only what was asked. Never drop template sections.
    - Never force-push, delete branches, rewrite history, change repository settings or files outside the \
    request unless the user explicitly asks.
    - After a change, confirm briefly what changed. GitXX refreshes the open page automatically.

    ## Style
    - Short and scannable, GitHub-flavoured Markdown. Quote commands, branches and paths in backticks.
    """

    private static func systemPrompt(repoPath: String?) -> String {
        var parts = [basePrompt]
        let date = Date().formatted(date: .complete, time: .omitted)
        parts.append("Today is \(date).")
        if let custom = UserDefaults.standard.string(forKey: customInstructionsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            parts.append("## Instructions from the user (always follow these)\n" + custom)
        }
        if let repoPath {
            let url = URL(fileURLWithPath: repoPath).appendingPathComponent(".github/copilot-instructions.md")
            if let text = try? String(contentsOf: url, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("## Repository instructions (.github/copilot-instructions.md)\n" + String(text.prefix(4000)))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    public func toggle() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isOpen.toggle() }
        if isOpen { hasUnread = false }
    }

    public func newChat() {
        stop()
        items = []
        wire = []
        usage = AIChatUsage()
    }

    public func toggleExpanded() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { isExpanded.toggle() }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        resolveApproval(false)
        isRunning = false
    }

    public func resolveApproval(_ allowed: Bool) {
        guard let pending = approval else { return }
        approval = nil
        pending.continuation.resume(returning: allowed)
    }

    public func send(_ text: String? = nil, state: AppState) {
        let prompt = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        if text == nil { input = "" }
        let context = AIPageContext.capture(from: state)
        items.append(AIChatItem(kind: .user(prompt, context: context)))
        let system = ChatWireMessage.system(Self.systemPrompt(repoPath: context.repoPath))
        if wire.first?.role == .system { wire[0] = system } else { wire.insert(system, at: 0) }
        answerDanglingToolCalls()
        wire.append(.user(prompt + "\n\n[Page when sent]\n" + context.details.map { "- " + $0 }.joined(separator: "\n")))

        let toolContext = AIToolContext(repoPath: context.repoPath, repoSlug: context.repoSlug, githubToken: state.effectiveGitHubToken)
        let provider = state.aiProvider, model = state.copilotModel.rawValue
        usage.userTurns += 1
        isRunning = true
        runTask = Task { [weak self, weak state] in
            await self?.run(provider: provider, model: model, tools: toolContext, state: state)
        }
    }

    private func run(provider: AIProvider, model: String, tools: AIToolContext, state: AppState?) async {
        defer {
            isRunning = false
            runTask = nil
            if !isOpen { hasUnread = true }
            if provider == .githubCopilot { Task { await self.refreshPremiumBalance() } }
        }
        if provider == .githubCopilot, usage.premiumAtStart == nil {
            await refreshPremiumBalance()
            usage.premiumAtStart = usage.premiumNow
        }
        for turn in 0..<16 {
            let reply: AIChatReply
            do {
                reply = try await AIChatService.complete(provider: provider, model: model, githubToken: tools.githubToken,
                                                         messages: wire, tools: AIChatTools.specs, userInitiated: turn == 0)
            } catch {
                if Task.isCancelled { return }
                items.append(AIChatItem(kind: .error(error.localizedDescription)))
                return
            }
            if Task.isCancelled { return }
            usage.modelCalls += 1
            usage.promptTokens += reply.promptTokens
            usage.completionTokens += reply.completionTokens
            wire.append(ChatWireMessage(role: .assistant, content: reply.content, toolCalls: reply.toolCalls))
            if let text = reply.content { items.append(AIChatItem(kind: .assistant(text))) }
            guard !reply.toolCalls.isEmpty else { return }

            for call in reply.toolCalls {
                let args = AIChatTools.parse(call.arguments)
                let summary = AIChatTools.summary(name: call.name, args: args)
                let changesThings = AIChatTools.requiresApproval(name: call.name, args: args)
                let needsApproval = changesThings && !autoApprove
                let item = AIChatItem(kind: .tool(name: call.name, summary: summary, status: needsApproval ? .awaitingApproval : .running, output: ""))
                items.append(item)

                if needsApproval {
                    let allowed = await withCheckedContinuation { continuation in
                        approval = (item.id, continuation)
                    }
                    if Task.isCancelled {
                        update(item.id, status: .denied, output: "Stopped.")
                        return
                    }
                    guard allowed else {
                        update(item.id, status: .denied, output: "")
                        wire.append(.tool(id: call.id, output: "The user declined to run this command."))
                        continue
                    }
                    update(item.id, status: .running, output: "")
                }

                let result: (output: String, ok: Bool)
                if call.name == "open_pull_request", let number = args["number"] as? Int {
                    if let state {
                        await state.openPullRequest(number: number)
                        result = ("Opened pull request #\(number) in GitXX.", true)
                    } else {
                        result = ("GitXX window is gone.", false)
                    }
                } else {
                    result = await AIChatTools.execute(name: call.name, args: args, context: tools)
                }
                if Task.isCancelled { return }
                update(item.id, status: result.ok ? .done : .failed, output: result.output)
                wire.append(.tool(id: call.id, output: result.output))
                if changesThings, result.ok, call.name != "open_pull_request" {
                    state?.refreshAfterExternalChange()
                }
            }
        }
        items.append(AIChatItem(kind: .error("Stopped after too many tool calls. Ask a narrower question or continue.")))
    }

    private func refreshPremiumBalance() async {
        guard let balance = await CopilotAuthService.shared.fetchPremiumUsage() else { return }
        usage.premiumNow = balance.remaining
        usage.premiumEntitlement = balance.entitlement
        usage.premiumUnlimited = balance.unlimited
        usage.resetDate = balance.resetDate
    }

    /// A stopped run can leave tool calls without results, which providers reject on the next request.
    private func answerDanglingToolCalls() {
        let answered = Set(wire.compactMap(\.toolCallID))
        for call in wire.flatMap(\.toolCalls) where !answered.contains(call.id) {
            wire.append(.tool(id: call.id, output: "Cancelled by the user."))
        }
    }

    private func update(_ id: UUID, status: AIChatItem.ToolStatus, output: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), case let .tool(name, summary, _, _) = items[i].kind else { return }
        items[i].kind = .tool(name: name, summary: summary, status: status, output: output)
    }
}
