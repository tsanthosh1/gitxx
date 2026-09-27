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
            name: "open_pull_request",
            description: "Open a pull request of the current repository in GitXX so the user can see it.",
            parametersJSON: #"{"type":"object","properties":{"number":{"type":"integer"}},"required":["number"]}"#
        ),
    ]

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
        case "read_file", "open_pull_request":
            return false
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
            let res = await runProcess(gh, stringArgs(args), cwd: context.repoPath ?? NSHomeDirectory(), env: env)
            return (format(res), res.code == 0)
        case "github_api":
            return await callGitHubAPI(args, token: context.githubToken)
        case "read_file":
            return readFile(args, repoPath: context.repoPath)
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

    private static func runProcess(_ executable: String, _ arguments: [String], cwd: String, env extra: [String: String]) async -> (code: Int32, out: String, err: String) {
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
                do { try process.run() } catch {
                    continuation.resume(returning: (127, "", error.localizedDescription))
                    return
                }
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                continuation.resume(returning: (process.terminationStatus,
                                                String(decoding: outData, as: UTF8.self),
                                                String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    private static func callGitHubAPI(_ args: [String: Any], token: String?) async -> (output: String, ok: Bool) {
        guard let token, !token.isEmpty else { return ("No GitHub token is configured.", false) }
        var path = args["path"] as? String ?? "/"
        if path.hasPrefix("https://api.github.com") { path = String(path.dropFirst("https://api.github.com".count)) }
        guard !path.contains("://"), let url = URL(string: "https://api.github.com" + (path.hasPrefix("/") ? path : "/" + path)) else {
            return ("Only api.github.com paths are allowed.", false)
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
