import SwiftUI

/// What the user was looking at when they sent a message.
public struct AIPageContext: Sendable, Hashable, Codable {
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
                    let checks = state.prChecks
                    if !checks.isEmpty {
                        let failing = PRCheckRun.sortedByBlockerPriority(checks.filter(\.isFailure)).map { c in
                            "\(c.name) [\(c.isRequired ? "required" : "optional")]\(c.actionsJobId.map { " job_id=\($0)" } ?? "")"
                        }
                        let running = checks.filter(\.isPending).count
                        details.append("Checks (as shown on the page): \(failing.count) failing, \(running) running, \(checks.count - failing.count - running) passed/skipped"
                                       + (failing.isEmpty ? "" : ". Failing: " + failing.prefix(8).joined(separator: "; ")))
                    }
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
                if let op = state.operationInProgress {
                    let conflicted = state.conflictedPaths.count
                    details.append("\(op.title) in progress: " + (conflicted > 0 ? "\(conflicted) files still conflicted" : "all conflicts resolved, not committed yet"))
                }
                if let rejected = state.parkedOperationError ?? state.operationError {
                    details.append("Last git failure: \(rejected.title)" + (rejected.highlights.isEmpty ? "" : " — " + rejected.highlights.prefix(3).joined(separator: " | ")))
                }
                if let file = state.selectedFile { details.append("Selected file: \(file.path)") }
            case .history:
                label = "History"
                details.append("Page: commit history")
                if let c = state.selectedCommit { details.append("Selected commit: \(c.shortSha) \"\(c.summary)\" by \(c.authorName)") }
            case .actions:
                label = "Actions"
                let store = state.actions
                details.append("Page: GitHub Actions workflow runs\(store.filter.branch.map { " filtered to branch \($0)" } ?? "")")
                if let run = store.selectedRun {
                    details.append("Selected run: \(run.workflowName) #\(run.runNumber) \"\(run.displayTitle)\" (id \(run.id), \(run.actionsStatus.label), event \(run.event), branch \(run.headBranch), sha \(run.shortSha)) \(run.htmlUrl)")
                    let failed = store.jobs.filter { $0.actionsStatus == .failure }.map(\.name)
                    if !failed.isEmpty { details.append("Failed jobs: \(failed.joined(separator: ", ")) — use get_ci_logs run_id=\(run.id) to read why") }
                    if let job = store.selectedJob { details.append("Viewing job: \(job.name) (job_id \(job.id), \(job.actionsStatus.label))") }
                }
            case .terminal:
                label = "Terminal"
                details.append("Page: embedded terminal")
            }
        }
        let prefix = repo.map { "\($0.name) · " } ?? ""
        return AIPageContext(label: label == "Home" ? label : prefix + label, details: details, repoPath: repo?.path, repoSlug: slug)
    }
}

public struct AIChatItem: Identifiable, Sendable, Codable {
    public enum ToolStatus: Sendable, Equatable, Codable { case awaitingApproval, running, done, failed, denied }

    public enum Kind: Sendable, Codable {
        case user(String, context: AIPageContext)
        case assistant(String)
        case tool(name: String, summary: String, status: ToolStatus, output: String)
        case error(String)
    }

    public var id = UUID()
    public var kind: Kind

    public init(kind: Kind) { self.kind = kind }
}

/// Clickable answers for a reply that ends in a question. The model marks them with a final
/// `[[choices: A | B]]` line; a plain yes/no question ("Shall I…?", "Do you want…?") gets Yes / No.
public enum AIQuickReplies {
    private static let marker = try! NSRegularExpression(pattern: #"\n?\s*\[\[\s*choices\s*:\s*([^\]]+)\]\]\s*$"#, options: [.caseInsensitive])
    private static let yesNoStarts = ["shall ", "should i", "should we", "do you want", "would you like", "want me to", "can i ", "may i ",
                                      "do you", "is it ok", "is that ok", "ok to", "proceed", "continue", "let me know if you'd like",
                                      "let me know if you want"]

    public static func stripMarker(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return marker.stringByReplacingMatches(in: text, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func choices(in text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        if let m = marker.firstMatch(in: text, range: range), let r = Range(m.range(at: 1), in: text) {
            let options = text[r].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return options.isEmpty ? nil : Array(options.prefix(5))
        }
        let lastLine = (text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_` ").union(.whitespaces))
        let isQuestion = lastLine.hasSuffix("?")
        let body = lastLine.trimmingCharacters(in: CharacterSet(charactersIn: ".?! "))
        let sentence = (body.components(separatedBy: CharacterSet(charactersIn: ".!?")).last ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_` ").union(.whitespaces)).lowercased()
        guard isQuestion || sentence.hasPrefix("let me know if") else { return nil }
        return yesNoStarts.contains { sentence.hasPrefix($0) } ? ["Yes", "No"] : nil
    }
}

/// What the current conversation has cost so far.
public struct AIChatUsage: Sendable, Equatable, Codable {
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

/// A saved conversation, listed in the chat's history and on Home.
public struct AIChatThreadSummary: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var title: String
    /// Page label of the first message, e.g. "chargebee-js · PR #1994".
    public var context: String
    public var repoPath: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int
    public var preview: String
}

/// Conversations saved as one JSON file each, plus an index of summaries.
enum AIChatHistory {
    private struct Thread: Codable {
        var summary: AIChatThreadSummary
        var items: [AIChatItem]
        var wire: [ChatWireMessage]
        var usage: AIChatUsage
    }

    static let maxThreads = 200

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("GitXX/ai-chats", isDirectory: true)
    }()
    private static var indexURL: URL { directory.appendingPathComponent("index.json") }
    private static func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func loadIndex() -> [AIChatThreadSummary] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? decoder.decode([AIChatThreadSummary].self, from: data) else { return [] }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func saveIndex(_ list: [AIChatThreadSummary]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? encoder.encode(list) { try? data.write(to: indexURL, options: .atomic) }
    }

    static func save(_ summary: AIChatThreadSummary, items: [AIChatItem], wire: [ChatWireMessage], usage: AIChatUsage) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let thread = Thread(summary: summary, items: items, wire: wire.filter { $0.role != .system }, usage: usage)
        if let data = try? encoder.encode(thread) { try? data.write(to: url(summary.id), options: .atomic) }
    }

    static func load(_ id: UUID) -> (items: [AIChatItem], wire: [ChatWireMessage], usage: AIChatUsage)? {
        guard let data = try? Data(contentsOf: url(id)), let thread = try? decoder.decode(Thread.self, from: data) else { return nil }
        return (thread.items, thread.wire, thread.usage)
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
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
    /// Saved conversations, newest first; the current one is saved as it changes.
    @Published public private(set) var threads: [AIChatThreadSummary] = AIChatHistory.loadIndex()
    @Published public private(set) var currentThreadId: UUID?

    public static let customInstructionsKey = "gitxx_ai_custom_instructions"

    private var wire: [ChatWireMessage] = []
    private var runTask: Task<Void, Never>?
    private var approval: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?

    public var pendingApprovalID: UUID? { approval?.id }

    /// Answers offered as buttons when the conversation ends with a question from the assistant.
    public var quickReplies: [String]? {
        guard let last = items.last, case let .assistant(text) = last.kind else { return nil }
        return AIQuickReplies.choices(in: text)
    }

    private static let basePrompt = """
    You are the assistant built into GitXX, a native macOS Git and GitHub client. You help with the user's \
    repositories, local changes, commits, branches and pull requests.

    ## Tools
    - Look things up instead of guessing: run_git for local repository state, run_gh (preferred) or github_api \
    for GitHub (pull requests, reviews, issues), read_file for files in the repository, edit_file to change them.
    - CI: get_pr_checks for a PR's checks and get_ci_logs for why a job failed. Don't use `gh pr checks`, \
    `gh run view --log`, `/pulls/{n}/check-runs` (not an endpoint) or `/commits/{sha}/status` (legacy statuses \
    only; it says "success" while check runs fail). Trust the page's check list over an API that disagrees.
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
    - Keep going on your own through a multi-step fix: when a step fails or a first attempt doesn't solve it, \
    diagnose and try the next reasonable approach yourself (a few attempts) instead of ending the turn with \
    "shall I try X?", "should I proceed?" or "let me know if you'd like me to…". A "yes" from the user earlier \
    in the conversation covers the follow-up steps of the same fix.
    - Stop and ask only for a real decision: two fixes with different outcomes, something destructive or \
    irreversible, or information you cannot find. Then end the message with one line listing the answers as \
    `[[choices: First option | Second option]]` (2–4 short options, e.g. `[[choices: Yes | No]]`); the app \
    turns it into buttons. Don't use it for anything else.

    ## Local git operations in progress
    - The page context says when a merge, rebase, cherry-pick or revert is in progress. Never conclude one with \
    `git commit -m …` (it throws away the prepared merge message): use `git commit --no-edit` for a merge or \
    cherry-pick/revert, and `git -c core.editor=true rebase --continue` for a rebase.
    - Commits run the repository's hooks (husky, lint-staged, pre-commit), which can take minutes on large \
    merges. Never bypass them with `--no-verify` or `core.hooksPath` unless the user explicitly asks.

    ## Before editing a PR's title, description, labels or other metadata: learn the repository's rules
    Repositories often lint PR content in CI, so a PR that only "looks right" still fails checks. Before writing, \
    find every rule that applies (read-only, no approval needed; do it in this turn, don't ask first):
    - Linting workflows: list `.github/workflows/` (`gh api repos/{owner}/{repo}/contents/.github/workflows`, or \
    run_git `ls-files .github`) and read the ones that run on `pull_request`/`pull_request_target` and read the PR \
    (look for `pull_request.title`, `pull_request.body`, `github.event.pull_request`, danger, semantic/conventional \
    PR title, label, branch-name or "pr-lint" steps). Follow what they call: scripts under `.github/` (e.g. \
    `pr-lint.js`), a `dangerfile.js`/`dangerfile.ts`, or reusable workflows and composite actions in other \
    repositories (`uses: org/repo/.github/actions/x@ref` → read that file with \
    `gh api repos/org/repo/contents/<path>?ref=<ref>` and decode the base64 content). Extract the exact rules: \
    required sections, regexes and formats (e.g. changelog line format, title prefix, ticket id), mandatory \
    checkboxes, values that are rejected (such as `N/A`, `TBD` or placeholder URLs), and length limits.
    - The template: `.github/pull_request_template.md`, `.github/PULL_REQUEST_TEMPLATE/*`, `docs/` or root \
    `pull_request_template.md`.
    - Examples that passed: 2–3 recently merged PRs against the same base branch \
    (`gh pr list --state merged --base <base> --limit 5 --json number,title,body,author`), preferring ones whose \
    checks passed. Copy their conventions: title format, changelog line wording, how each section is filled.
    - The current PR's failing check output, when there is one (get_pr_checks / get_ci_logs); linter findings \
    are the most direct statement of what's wrong.
    Then write content that satisfies all of it: match the formats exactly (fill in real values such as the \
    Jira id from the branch name or commits, the PR number and the author's handle), tick exactly one option \
    where a yes/no choice is required, keep every template section. Where a rule requires a value you cannot \
    know (a real URL, a ticket that isn't in the branch or commits), don't put a value the linter rejects: keep \
    the existing value if it is valid, otherwise leave the placeholder and ask the user for it in your reply, \
    naming the rule. In the reply, list the rules you followed in one line each.

    ## Playbook: write or update a PR description ("update the description based on the changes", \
    "fill the template", "describe this PR")
    0. Learn the repository's rules first (section above).
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
    the checkboxes that apply (type of change, yes/no questions) and leave the others unticked. Follow the \
    rules from step 0 exactly. Never invent values you cannot know (test report URLs, links to other PRs, \
    ticket numbers not in the branch/commits): use `N/A`/`TBD` only when the linter accepts it, otherwise \
    keep the placeholder, and list those at the end of your reply.
    4. Immediately call `gh pr edit <n> --body "<full new body>"` (pass the whole body as one argument).
    5. Reply with a two-line summary of what you filled in and anything left as TBD.
    - "Update the description based on the changes" means re-derive it from the current changes even when \
    a description already exists: the code may have moved on since it was written. Keep details that are \
    still true, correct what is outdated, add what is missing, then propose the edit. Only skip the edit if \
    the new body would be identical, and say so.

    ## Playbook: failing checks ("why is CI failing", "check the failing check and make fixes", a pasted check name)
    1. get_pr_checks <n> (skip if the page already lists the failing checks with job ids). A pasted \
    "Workflow / Job (event)" line names a check: match it to a job_id there.
    2. get_ci_logs job_id=<id> for each failing Actions job (or pr_number=<n> for all). The result is already cut \
    down to the failed step and its errors, so never say a log is too large. If the cause still isn't visible, call \
    it again with grep (e.g. "error|warn|fail|✖"). Non-Actions checks (Sonar, Vercel…) only have their summary \
    and link; report those.
    3. State the root cause in one or two lines, quoting the decisive log line.
    4. Fix it in the same turn when the user asked for fixes:
      - PR-metadata linters (Danger, PR title/semantic/label/branch-name/description checks) fail on the PR itself: \
    learn the repository's rules (section above), then fix the title, body or labels with `gh pr edit` so every \
    rule passes, not only the one in the message.
      - Code failures (lint, types, tests, build): the fix goes on the PR's head branch. If \
    `git branch --show-current` isn't headRefName, say so and ask before checking it out. Otherwise read_file the \
    reported files and lines, edit_file the fix, then commit with a clear message and push (both need approval).
      - Flaky or infrastructure failures (network, timeouts, runner lost, rate limits, cancelled): suggest \
    `gh run rerun <run_id> --failed` rather than code changes.
    5. After a metadata fix or push, say which checks will re-run. Don't claim they pass until they do.

    ## Making changes
    - Commands that change anything (edit, commit, push, merge, comment, close, delete, label…) are shown to \
    the user for approval before they run. Only run them when the user asked for that outcome.
    - Keep edits minimal: change only what was asked. Never drop template sections.
    - Never force-push, delete branches, rewrite history, change repository settings or files outside the \
    request unless the user explicitly asks.
    - After a change, confirm briefly what changed. GitXX refreshes the open page automatically.

    ## Controlling GitXX
    - You can operate the app with `app_action`: open a repository in this window, go Home, switch tabs, open a pull \
    request, workflow or run, open the Create branch / Create pull request dialogs, switch branch, fetch/pull/push, \
    open Settings or the command palette. When the user asks to open, show, go to or switch to something, do it \
    with `app_action` instead of explaining how.
    - Requests are often dictated, so names can be misheard ("charge via" → chargebee). Call `list_repositories` \
    first when a repository name isn't an exact match, then open the closest one; ask only if two are equally likely.
    - After an app action, reply in one short line.

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
        if isOpen { hasUnread = false } else { AIVoiceInput.shared.stop() }
    }

    /// Opens the assistant and starts dictating into the composer; stops if already listening.
    public func toggleVoice() {
        if !isOpen {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isOpen = true }
            hasUnread = false
            AIVoiceInput.shared.start(chat: self)
        } else {
            AIVoiceInput.shared.toggle(chat: self)
        }
    }

    public func newChat() {
        stop()
        saveThread()
        items = []
        wire = []
        usage = AIChatUsage()
        currentThreadId = nil
    }

    // MARK: History

    /// Continues a saved conversation (stopping one that is still running).
    public func openThread(_ id: UUID) {
        if id != currentThreadId {
            guard let saved = AIChatHistory.load(id) else {
                threads.removeAll { $0.id == id }
                AIChatHistory.saveIndex(threads)
                return
            }
            stop()
            saveThread()
            items = saved.items.map { item in
                guard case let .tool(name, summary, status, output) = item.kind,
                      status == .awaitingApproval || status == .running else { return item }
                var copy = item
                copy.kind = .tool(name: name, summary: summary, status: .denied, output: output.isEmpty ? "Interrupted." : output)
                return copy
            }
            wire = saved.wire
            usage = saved.usage
            usage.premiumAtStart = nil
            currentThreadId = id
        }
        if !isOpen { toggle() }
    }

    public func deleteThread(_ id: UUID) {
        if id == currentThreadId {
            stop()
            items = []
            wire = []
            usage = AIChatUsage()
            currentThreadId = nil
        }
        AIChatHistory.delete(id)
        threads.removeAll { $0.id == id }
        AIChatHistory.saveIndex(threads)
    }

    public func deleteAllThreads() {
        newChat()
        for thread in threads { AIChatHistory.delete(thread.id) }
        threads = []
        AIChatHistory.saveIndex(threads)
    }

    /// Writes the current conversation and refreshes its entry in the history.
    func saveThread() {
        let firstUser = items.lazy.compactMap { item -> (String, AIPageContext)? in
            if case let .user(text, context) = item.kind { return (text, context) }
            return nil
        }.first
        guard let (firstText, context) = firstUser else { return }
        let id = currentThreadId ?? UUID()
        currentThreadId = id
        let lastText = items.reversed().lazy.compactMap { item -> String? in
            switch item.kind {
            case .assistant(let text), .user(let text, _): return text
            default: return nil
            }
        }.first ?? ""
        let oneLine = { (text: String, limit: Int) in
            String(text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces).prefix(limit))
        }
        let existing = threads.first { $0.id == id }
        let summary = AIChatThreadSummary(
            id: id,
            title: existing?.title ?? oneLine(firstText, 90),
            context: existing?.context ?? context.label,
            repoPath: existing?.repoPath ?? context.repoPath,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date(),
            messageCount: items.filter { if case .user = $0.kind { return true }; return false }.count,
            preview: oneLine(lastText, 160)
        )
        AIChatHistory.save(summary, items: items, wire: wire, usage: usage)
        threads.removeAll { $0.id == id }
        threads.insert(summary, at: 0)
        if threads.count > AIChatHistory.maxThreads {
            for old in threads[AIChatHistory.maxThreads...] { AIChatHistory.delete(old.id) }
            threads.removeLast(threads.count - AIChatHistory.maxThreads)
        }
        AIChatHistory.saveIndex(threads)
    }

    public func toggleExpanded() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { isExpanded.toggle() }
    }

    /// Cancels the run, killing a command that is still executing (with any hooks it started).
    public func stop() {
        let wasRunning = isRunning
        runTask?.cancel()
        runTask = nil
        resolveApproval(false)
        isRunning = false
        for item in items {
            guard case let .tool(_, _, status, output) = item.kind, status == .running || status == .awaitingApproval else { continue }
            update(item.id, status: .denied, output: output.isEmpty ? "Stopped by you." : output)
        }
        if wasRunning { items.append(AIChatItem(kind: .error("Stopped. Send a message to continue from here."))) }
    }

    public func resolveApproval(_ allowed: Bool) {
        guard let pending = approval else { return }
        approval = nil
        pending.continuation.resume(returning: allowed)
    }

    public func send(_ text: String? = nil, state: AppState) {
        let prompt = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning else { return }
        AIVoiceInput.shared.stop()
        if text == nil { input = "" }
        let context = AIPageContext.capture(from: state)
        items.append(AIChatItem(kind: .user(prompt, context: context)))
        let system = ChatWireMessage.system(Self.systemPrompt(repoPath: context.repoPath))
        if wire.first?.role == .system { wire[0] = system } else { wire.insert(system, at: 0) }
        answerDanglingToolCalls()
        wire.append(.user(prompt + "\n\n[Page when sent]\n" + context.details.map { "- " + $0 }.joined(separator: "\n")))
        saveThread()

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
            saveThread()
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
                } else if AIAppActions.names.contains(call.name) {
                    if let state {
                        result = await AIAppActions.execute(AIAppActions.Request(name: call.name, args: args), state: state)
                    } else {
                        result = ("GitXX window is gone.", false)
                    }
                } else {
                    result = await AIChatTools.execute(name: call.name, args: args, context: tools)
                }
                if Task.isCancelled { return }
                update(item.id, status: result.ok ? .done : .failed, output: result.output)
                wire.append(.tool(id: call.id, output: result.output))
                if changesThings, result.ok, call.name != "open_pull_request", !AIAppActions.names.contains(call.name) {
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
