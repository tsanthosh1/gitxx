import Foundation

/// Where tools run, captured when the prompt is sent so navigating away doesn't change a running task.
public struct AIToolContext: Sendable {
    public let repoPath: String?
    public let repoSlug: String?
    public let githubToken: String?
}

/// Tools the assistant can call. Read-only operations run immediately; anything that could change
/// the repository, GitHub or the machine needs the user's approval (unless auto-approve is on).
public enum AIChatTools {
    public static let specs: [AIToolSpec] = [
        AIToolSpec(
            name: "run_git",
            description: "Run a git command in the current repository. Pass arguments without the leading 'git', e.g. [\"log\", \"--oneline\", \"-10\"]. Output is plain text without a pager.",
            parametersJSON: #"{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"},"description":"git arguments"}},"required":["args"]}"#
        ),
        AIToolSpec(
            name: "run_gh",
            description: "Run a GitHub CLI (gh) command in the current repository, already authenticated. Pass arguments without the leading 'gh', e.g. [\"pr\", \"checks\", \"123\"] or [\"pr\", \"view\", \"123\", \"--json\", \"title,body,reviews\"]. Prefer --json output for structured data.",
            parametersJSON: #"{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"},"description":"gh arguments"}},"required":["args"]}"#
        ),
        AIToolSpec(
            name: "github_api",
            description: "Call the GitHub REST API (path like /repos/{owner}/{repo}/pulls/1) or GraphQL (path /graphql with body {\"query\": \"...\"}). Use when gh is unavailable or for endpoints gh doesn't cover.",
            parametersJSON: #"{"type":"object","properties":{"method":{"type":"string","enum":["GET","POST","PATCH","PUT","DELETE"]},"path":{"type":"string"},"body":{"type":"object","description":"JSON body for POST/PATCH/PUT or GraphQL"}},"required":["path"]}"#
        ),
        AIToolSpec(
            name: "read_file",
            description: "Read a text file from the current repository's working tree. Optional 1-based line range; at most 400 lines are returned.",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the repository root"},"start_line":{"type":"integer"},"end_line":{"type":"integer"}},"required":["path"]}"#
        ),
        AIToolSpec(
            name: "edit_file",
            description: "Edit a text file in the current repository's working tree by replacing old_string (must occur exactly once; include enough surrounding lines to make it unique) with new_string. To create a new file, pass an empty old_string and the whole content as new_string. Read the file first.",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":"Path relative to the repository root"},"old_string":{"type":"string"},"new_string":{"type":"string"}},"required":["path","old_string","new_string"]}"#
        ),
        AIToolSpec(
            name: "open_pull_request",
            description: "Open a pull request of the current repository in GitXX so the user can see it.",
            parametersJSON: #"{"type":"object","properties":{"number":{"type":"integer"}},"required":["number"]}"#
        ),
    ] + AIChatCITools.specs + AIAppActions.specs

    // MARK: Arguments

    public static func parse(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    static func stringArgs(_ args: [String: Any]) -> [String] {
        if let list = args["args"] as? [String] { return list }
        if let line = args["args"] as? String { return line.split(separator: " ").map(String.init) }
        return []
    }

    /// Human-readable form shown in the chat, e.g. "git log --oneline -5".
    public static func summary(name: String, args: [String: Any]) -> String {
        func quoted(_ list: [String]) -> String {
            list.map { $0.contains(" ") || $0.isEmpty ? "'\($0)'" : $0 }.joined(separator: " ")
        }
        switch name {
        case "run_git": return "git " + quoted(stringArgs(args))
        case "run_gh": return "gh " + quoted(stringArgs(args))
        case "github_api":
            let method = (args["method"] as? String)?.uppercased() ?? "GET"
            return "\(method) \(args["path"] as? String ?? "/")"
        case "read_file":
            let path = args["path"] as? String ?? ""
            if let s = args["start_line"] as? Int { return "read \(path):\(s)-\(args["end_line"] as? Int ?? s + 399)" }
            return "read \(path)"
        case "open_pull_request": return "open PR #\(args["number"] as? Int ?? 0)"
        case "edit_file":
            let path = args["path"] as? String ?? ""
            let old = (args["old_string"] as? String) ?? "", new = (args["new_string"] as? String) ?? ""
            func preview(_ text: String, _ mark: String) -> [String] {
                let lines = text.components(separatedBy: "\n")
                return lines.prefix(30).map { mark + $0 } + (lines.count > 30 ? ["\(mark)… \(lines.count - 30) more lines"] : [])
            }
            let diff = (old.isEmpty ? [] : preview(old, "- ")) + preview(new, "+ ")
            return ([old.isEmpty ? "create \(path)" : "edit \(path)"] + diff).joined(separator: "\n")
        case _ where AIAppActions.names.contains(name): return AIAppActions.summary(name: name, args: args)
        case "get_pr_checks": return "checks of PR #\(args["number"] ?? "?")"
        case "get_ci_logs":
            let target = args["job_id"].map { "job \($0)" } ?? args["run_id"].map { "run \($0)" } ?? args["pr_number"].map { "failed jobs of PR #\($0)" } ?? "?"
            return "CI logs of \(target)" + ((args["grep"] as? String).map { " matching /\($0)/" } ?? "")
        default: return name
        }
    }

    // MARK: Approval

    private static let gitReadOnly: Set<String> = [
        "status", "log", "diff", "show", "blame", "rev-parse", "ls-files", "ls-tree", "describe", "shortlog",
        "reflog", "cat-file", "grep", "merge-base", "rev-list", "name-rev", "for-each-ref", "show-ref", "count-objects",
    ]
    private static let ghReadVerbs: Set<String> = ["list", "view", "status", "diff", "checks"]

    public static func requiresApproval(name: String, args: [String: Any]) -> Bool {
        switch name {
        case "read_file", "open_pull_request", "get_pr_checks", "get_ci_logs", "list_repositories":
            return false
        case "app_action":
            return AIAppActions.requiresApproval(args: args)
        case "run_git":
            let a = stringArgs(args).filter { $0 != "--no-pager" }
            guard let cmd = a.first else { return false }
            let rest = Array(a.dropFirst())
            if gitReadOnly.contains(cmd) { return cmd == "reflog" && rest.first.map { ["delete", "expire"].contains($0) } == true }
            switch cmd {
            case "branch":
                let destructive: Set<String> = ["-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy", "-u", "--set-upstream-to", "--unset-upstream", "-f", "--force"]
                return rest.contains { !$0.hasPrefix("-") || destructive.contains($0) }
            case "tag":
                let destructive: Set<String> = ["-d", "--delete", "-a", "-s", "-f", "-m", "--annotate", "--sign", "--force"]
                return rest.contains { !$0.hasPrefix("-") || destructive.contains($0) } && !rest.contains("-l") && !rest.contains("--list")
            case "remote": return !(rest.isEmpty || ["-v", "show", "get-url"].contains(rest[0]))
            case "stash": return !(rest.first.map { ["list", "show"].contains($0) } ?? false)
            case "config": return !rest.contains { ["--get", "--get-all", "--get-regexp", "--list", "-l"].contains($0) }
            case "worktree": return rest.first != "list"
            case "fetch":
                // Plain fetches only move remote-tracking refs / FETCH_HEAD; a `src:dst` refspec can overwrite a local branch.
                return rest.contains { $0.contains(":") || $0 == "--update-head-ok" || $0 == "-u" }
            default: return true
            }
        case "run_gh":
            let a = stringArgs(args)
            guard let group = a.first else { return false }
            if group == "status" || group == "search" { return false }
            if group == "auth" { return a.dropFirst().first != "status" }
            if group == "api" {
                let writesFields = a.contains { ["-f", "-F", "--field", "--raw-field", "--input"].contains($0) }
                if let i = a.firstIndex(where: { $0 == "-X" || $0 == "--method" }), i + 1 < a.count {
                    return a[i + 1].uppercased() != "GET" || writesFields
                }
                if let m = a.first(where: { $0.hasPrefix("--method=") }) { return m.dropFirst(9).uppercased() != "GET" || writesFields }
                return writesFields
            }
            guard a.count > 1 else { return true }
            return !ghReadVerbs.contains(a[1])
        case "github_api":
            let method = (args["method"] as? String)?.uppercased() ?? "GET"
            if (args["path"] as? String)?.hasSuffix("graphql") == true {
                let query = ((args["body"] as? [String: Any])?["query"] as? String) ?? ""
                return query.range(of: "mutation", options: .caseInsensitive) != nil
            }
            return method != "GET"
        default:
            return true
        }
    }

    // MARK: Execution

    private static let maxOutput = 12_000

    public static func execute(name: String, args: [String: Any], context: AIToolContext) async -> (output: String, ok: Bool) {
        switch name {
        case "run_git":
            guard let repo = context.repoPath else { return ("No repository is open.", false) }
            let res = await runProcess("/usr/bin/git", ["--no-pager"] + stringArgs(args), cwd: repo, env: [
                "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "PAGER": "cat",
            ])
            return (format(res), res.code == 0)
        case "run_gh":
            guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return ("The GitHub CLI (gh) isn't installed. Use github_api instead.", false)
            }
            var env = ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1", "GH_PAGER": "cat", "PAGER": "cat"]
            if let token = context.githubToken, !token.isEmpty { env["GH_TOKEN"] = token }
            let ghArgs = stringArgs(args)
            let res = await runProcess(gh, ghArgs, cwd: context.repoPath ?? NSHomeDirectory(), env: env)
            // `gh pr checks` exits 1 when a check failed and 8 while checks are pending; the listing is still valid.
            if ghArgs.prefix(2) == ["pr", "checks"], [1, 8].contains(res.code), !res.out.isEmpty {
                return (truncate((res.code == 1 ? "Some checks failed:\n" : "Some checks are pending:\n") + res.out), true)
            }
            return (format(res), res.code == 0)
        case "github_api":
            return await callGitHubAPI(args, token: context.githubToken)
        case "read_file":
            return readFile(args, repoPath: context.repoPath)
        case "edit_file":
            return editFile(args, repoPath: context.repoPath)
        case _ where AIChatCITools.names.contains(name):
            return await AIChatCITools.execute(name: name, args: args, context: context)
        default:
            return ("Unknown tool \(name).", false)
        }
    }

    private static func format(_ res: (code: Int32, out: String, err: String)) -> String {
        var text = res.out
        if !res.err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += (text.isEmpty ? "" : "\n") + res.err
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = "(no output)" }
        if res.code != 0 { text = "exit code \(res.code)\n" + text }
        return truncate(text)
    }

    private static func truncate(_ text: String) -> String {
        text.count > maxOutput ? String(text.prefix(maxOutput)) + "\n…[output truncated]" : text
    }

    /// The running process, so cancelling the chat (Stop) can kill it together with hooks it spawned.
    private final class RunningProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        /// Returns false when the run was already cancelled.
        func attach(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            self.process = process
            return !cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let target = process
            lock.unlock()
            guard let target, target.isRunning else { return }
            Self.killTree(target.processIdentifier)
        }

        /// SIGTERM to the process and every descendant (git → husky → npx → prettier…), children first.
        static func killTree(_ root: pid_t) {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-A", "-o", "pid=,ppid="]
            let pipe = Pipe()
            ps.standardOutput = pipe
            ps.standardError = FileHandle.nullDevice
            var children: [pid_t: [pid_t]] = [:]
            if (try? ps.run()) != nil {
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                ps.waitUntilExit()
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: " ").compactMap { pid_t($0) }
                    if parts.count == 2 { children[parts[1], default: []].append(parts[0]) }
                }
            }
            func visit(_ pid: pid_t) {
                for child in children[pid] ?? [] { visit(child) }
                kill(pid, SIGTERM)
            }
            visit(root)
        }
    }

    /// Commands that run hooks or talk to a remote get longer than the default 90 s.
    private static func timeout(for arguments: [String]) -> TimeInterval {
        let slow: Set<String> = ["commit", "merge", "rebase", "cherry-pick", "revert", "push", "pull", "fetch", "clone"]
        return arguments.contains { slow.contains($0) } ? 900 : 90
    }

    private static func runProcess(_ executable: String, _ arguments: [String], cwd: String, env extra: [String: String]) async -> (code: Int32, out: String, err: String) {
        let running = RunningProcess()
        let limit = timeout(for: arguments)
        return await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
                env["LC_ALL"] = "en_US.UTF-8"
                env.merge(GitService.remoteEnvironment(arguments: arguments, directory: cwd, base: env)) { _, new in new }
                env.merge(extra) { _, new in new }
                process.environment = env
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                guard running.attach(process) else {
                    continuation.resume(returning: (130, "", "Stopped by the user."))
                    return
                }
                do { try process.run() } catch {
                    continuation.resume(returning: (127, "", error.localizedDescription))
                    return
                }
                let timeout = DispatchWorkItem { if process.isRunning { RunningProcess.killTree(process.processIdentifier) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: timeout)
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                continuation.resume(returning: (process.terminationStatus,
                                                String(decoding: outData, as: UTF8.self),
                                                String(decoding: errData, as: UTF8.self)))
            }
          }
        } onCancel: {
            running.cancel()
        }
    }

    private static func callGitHubAPI(_ args: [String: Any], token: String?) async -> (output: String, ok: Bool) {
        guard let token, !token.isEmpty else { return ("No GitHub token is configured.", false) }
        var path = args["path"] as? String ?? "/"
        if path.hasPrefix(GitHubHost.api) { path = String(path.dropFirst(GitHubHost.api.count)) }
        guard !path.contains("://"), let url = URL(string: GitHubHost.api + (path.hasPrefix("/") ? path : "/" + path)) else {
            return ("Only GitHub API paths are allowed.", false)
        }
        var request = URLRequest(url: url)
        let isGraphQL = path.hasSuffix("graphql")
        request.httpMethod = isGraphQL ? "POST" : ((args["method"] as? String)?.uppercased() ?? "GET")
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let body = args["body"], !(body is NSNull), request.httpMethod != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var text = String(decoding: data, as: UTF8.self)
            if let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                text = String(decoding: pretty, as: UTF8.self)
            }
            return (truncate("HTTP \(status)\n\(text)"), (200...299).contains(status))
        } catch {
            return ("Request failed: \(error.localizedDescription)", false)
        }
    }

    private static func resolve(_ rel: String, in repoPath: String) -> String? {
        let root = URL(fileURLWithPath: repoPath).standardizedFileURL.path
        let full = URL(fileURLWithPath: rel, relativeTo: URL(fileURLWithPath: repoPath + "/")).standardizedFileURL.path
        guard full.hasPrefix(root + "/"), !full.hasPrefix(root + "/.git/") else { return nil }
        return full
    }

    private static func editFile(_ args: [String: Any], repoPath: String?) -> (output: String, ok: Bool) {
        guard let repoPath, let rel = args["path"] as? String else { return ("No repository is open.", false) }
        guard let full = resolve(rel, in: repoPath) else { return ("Path is outside the repository.", false) }
        let old = args["old_string"] as? String ?? "", new = args["new_string"] as? String ?? ""
        let fm = FileManager.default
        if old.isEmpty {
            guard !fm.fileExists(atPath: full) else { return ("\(rel) already exists; pass old_string to edit it.", false) }
            do {
                try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try new.write(toFile: full, atomically: true, encoding: .utf8)
            } catch { return ("Couldn't create \(rel): \(error.localizedDescription)", false) }
            return ("Created \(rel) (\(new.components(separatedBy: "\n").count) lines).", true)
        }
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { return ("Couldn't read \(rel) as UTF-8 text.", false) }
        let count = text.components(separatedBy: old).count - 1
        guard count == 1 else {
            return (count == 0 ? "old_string not found in \(rel). Read the file again and copy the text exactly." : "old_string occurs \(count) times in \(rel); include more surrounding lines.", false)
        }
        do { try text.replacingOccurrences(of: old, with: new).write(toFile: full, atomically: true, encoding: .utf8) }
        catch { return ("Couldn't write \(rel): \(error.localizedDescription)", false) }
        let line = text.components(separatedBy: old)[0].components(separatedBy: "\n").count
        return ("Edited \(rel) at line \(line): replaced \(old.components(separatedBy: "\n").count) lines with \(new.components(separatedBy: "\n").count).", true)
    }

    private static func readFile(_ args: [String: Any], repoPath: String?) -> (output: String, ok: Bool) {
        guard let repoPath, let rel = args["path"] as? String else { return ("No repository is open.", false) }
        let root = URL(fileURLWithPath: repoPath).standardizedFileURL.path
        let full = URL(fileURLWithPath: rel, relativeTo: URL(fileURLWithPath: repoPath + "/")).standardizedFileURL.path
        guard full.hasPrefix(root + "/") else { return ("Path is outside the repository.", false) }
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { return ("Couldn't read \(rel) as UTF-8 text.", false) }
        let lines = text.components(separatedBy: "\n")
        let start = max(1, args["start_line"] as? Int ?? 1)
        let end = min(lines.count, args["end_line"] as? Int ?? start + 399, start + 399)
        guard start <= end else { return ("\(rel) has \(lines.count) lines.", true) }
        let body = (start...end).map { "\($0)\t\(lines[$0 - 1])" }.joined(separator: "\n")
        return (truncate("\(rel) (lines \(start)-\(end) of \(lines.count))\n\(body)"), true)
    }
}
