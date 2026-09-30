import Foundation

/// CI-aware tools: the same check list the PR page shows, and failure-focused excerpts of Actions logs
/// (full job logs are routinely megabytes, far past what a tool result can carry).
enum AIChatCITools {
    static let specs: [AIToolSpec] = [
        AIToolSpec(
            name: "get_pr_checks",
            description: "List every CI check of a pull request (GitHub Actions check runs and commit statuses), sorted failing first, with Required/Optional, the Actions run and job ids, and each check's summary. Use this instead of `gh pr checks` or the commit status API (which misses check runs).",
            parametersJSON: #"{"type":"object","properties":{"number":{"type":"integer","description":"Pull request number"}},"required":["number"]}"#
        ),
        AIToolSpec(
            name: "get_ci_logs",
            description: "Read why a GitHub Actions job failed: annotations plus an excerpt of each failed step's log (the command, lines around errors, and the tail). Handles logs of any size. Pass job_id (from get_pr_checks), or run_id for all failed jobs of a run, or pr_number for all failed Actions checks of a PR. Pass grep (case-insensitive regex) to search the whole log instead, e.g. when the excerpt doesn't show the cause.",
            parametersJSON: #"{"type":"object","properties":{"job_id":{"type":"integer"},"run_id":{"type":"integer"},"pr_number":{"type":"integer"},"grep":{"type":"string","description":"Regex to search the full job log"}}}"#
        ),
    ]

    static let names: Set<String> = Set(specs.map(\.name))

    private static let budget = 11_000

    static func execute(name: String, args: [String: Any], context: AIToolContext) async -> (output: String, ok: Bool) {
        guard let slug = context.repoSlug, let slash = slug.firstIndex(of: "/") else {
            return ("The current repository has no GitHub remote.", false)
        }
        guard let token = context.githubToken, !token.isEmpty else { return ("No GitHub token is configured.", false) }
        let owner = String(slug[..<slash]), repo = String(slug[slug.index(after: slash)...])
        do {
            switch name {
            case "get_pr_checks":
                guard let number = intArg(args["number"]) else { return ("Pass the pull request number.", false) }
                return (try await prChecks(owner: owner, repo: repo, number: number, token: token), true)
            case "get_ci_logs":
                return try await ciLogs(owner: owner, repo: repo, args: args, token: token)
            default:
                return ("Unknown tool \(name).", false)
            }
        } catch {
            return ("GitHub request failed: \(error.localizedDescription)", false)
        }
    }

    private static func intArg(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let s = value as? String { return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "# "))) }
        return nil
    }

    // MARK: Checks

    private static func fetchChecks(owner: String, repo: String, number: Int, token: String) async throws -> (checks: [PRCheckRun], pr: [String: Any]) {
        let api = GitHubAPIService.shared
        let data = try await api.sendREST(method: "GET", path: "/repos/\(owner)/\(repo)/pulls/\(number)", token: token, actionName: "Load pull request")
        let pr = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let sha = (pr["head"] as? [String: Any])?["sha"] as? String
        let base = (pr["base"] as? [String: Any])?["ref"] as? String
        let checks = try await api.fetchPRChecks(owner: owner, repo: repo, headSha: sha, baseBranch: base, token: token)
        return (PRCheckRun.sortedByBlockerPriority(checks), pr)
    }

    private static func prChecks(owner: String, repo: String, number: Int, token: String) async throws -> String {
        let (checks, pr) = try await fetchChecks(owner: owner, repo: repo, number: number, token: token)
        let head = (pr["head"] as? [String: Any])
        var out = ["PR #\(number) head \(head?["ref"] as? String ?? "?") @ \(String((head?["sha"] as? String ?? "").prefix(10)))"]
        let counts = Dictionary(grouping: checks, by: \.group).mapValues(\.count)
        out.append("\(checks.count) checks: \(counts[.failing] ?? 0) failing, \(counts[.running] ?? 0) running, \(counts[.passing] ?? 0) passed, \(counts[.skipped] ?? 0) skipped")
        if checks.isEmpty { out.append("No checks reported for the head commit.") }
        for check in checks {
            var line = "- \(check.displayConclusion.uppercased()) [\(check.isRequired ? "required" : "optional")] \(check.name)"
            if let app = check.appName { line += " (\(app))" }
            if let run = check.actionsRunId { line += " run_id=\(run)" }
            if let job = check.actionsJobId { line += " job_id=\(job)" }
            if check.actionsJobId == nil, let url = check.htmlUrl { line += " \(url)" }
            out.append(line)
            guard check.group == .failing || check.group == .running else { continue }
            let summary = [check.outputTitle, check.outputSummary].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: " — ")
            if !summary.isEmpty { out.append("    " + String(summary.prefix(600)).replacingOccurrences(of: "\n", with: "\n    ")) }
        }
        if checks.contains(where: { $0.isFailure && $0.actionsJobId != nil }) {
            out.append("Next: get_ci_logs with a job_id above (or pr_number=\(number)) to see why it failed.")
        }
        return out.joined(separator: "\n")
    }

    // MARK: Logs

    private static func ciLogs(owner: String, repo: String, args: [String: Any], token: String) async throws -> (output: String, ok: Bool) {
        let api = GitHubAPIService.shared
        var jobs: [ActionsJob] = []
        var notes: [String] = []
        if let jobId = intArg(args["job_id"]) {
            guard let job = try await api.fetchJob(owner: owner, repo: repo, jobId: jobId, token: token) else {
                return ("Job \(jobId) not found. Job ids come from get_pr_checks (job_id=…).", false)
            }
            jobs = [job]
        } else if let runId = intArg(args["run_id"]) {
            let all = try await api.fetchRunJobs(owner: owner, repo: repo, runId: runId, token: token)
            jobs = all.filter { $0.actionsStatus == .failure }
            if jobs.isEmpty { return ("Run \(runId) has no failed jobs (\(all.count) jobs: \(all.map { "\($0.name) \($0.actionsStatus.label)" }.joined(separator: ", "))).", true) }
        } else if let number = intArg(args["pr_number"]) {
            let (checks, _) = try await fetchChecks(owner: owner, repo: repo, number: number, token: token)
            let failed = checks.filter(\.isFailure)
            for check in failed where check.actionsJobId == nil {
                notes.append("\(check.name) is not a GitHub Actions job (\(check.appName ?? "external")); see \(check.htmlUrl ?? "its details page"). Summary: \(check.outputSummary.map { String($0.prefix(400)) } ?? "none")")
            }
            for id in failed.compactMap({ $0.actionsJobId.flatMap(Int.init) }) {
                if let job = try await api.fetchJob(owner: owner, repo: repo, jobId: id, token: token) { jobs.append(job) }
            }
            if jobs.isEmpty && notes.isEmpty { return ("PR #\(number) has no failed checks.", true) }
        } else {
            return ("Pass job_id, run_id or pr_number.", false)
        }

        let shown = Array(jobs.prefix(4))
        if jobs.count > shown.count { notes.append("\(jobs.count - shown.count) more failed jobs not shown: \(jobs.dropFirst(4).map { "\($0.name) job_id=\($0.id)" }.joined(separator: ", "))") }
        let grep = (args["grep"] as? String).flatMap { $0.isEmpty ? nil : try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        let perJob = budget / max(1, shown.count)

        var sections: [String] = []
        var commentIds = notes.flatMap(issueCommentIds)
        for job in shown {
            var lines = ["## Job \"\(job.name)\" job_id=\(job.id) run_id=\(job.runId) — \(job.actionsStatus.label)"]
            if let url = job.htmlUrl { lines.append(url) }
            let annotations = ((try? await api.fetchJobAnnotations(owner: owner, repo: repo, job: job, token: token)) ?? [])
                .filter { $0.level != "notice" && !($0.level == "warning" && $0.message.hasPrefix("Node.js ")) }
            if !annotations.isEmpty {
                lines.append("Annotations:")
                for a in annotations.prefix(12) {
                    let place = a.path.isEmpty || a.path == ".github" ? "" : "\(a.path):\(a.startLine) "
                    lines.append("- \(a.level) \(place)\(a.title.map { "\($0): " } ?? "")\(a.message.prefix(400))")
                }
            }
            let raw: String
            do {
                raw = try await api.fetchJobLog(owner: owner, repo: repo, jobId: String(job.id), token: token)
            } catch {
                lines.append("Log unavailable (\(error.localizedDescription))\(job.actionsStatus.isActive ? "; the job is still running" : "").")
                sections.append(lines.joined(separator: "\n"))
                continue
            }
            commentIds += issueCommentIds(in: raw)
            let head = lines.joined(separator: "\n")
            let room = max(1500, perJob - head.count)
            if let grep {
                sections.append(head + "\n" + grepLog(clean(raw), regex: grep, budget: room))
            } else {
                sections.append(head + "\n" + failedStepExcerpt(raw: raw, job: job, budget: room))
            }
        }
        var seen = Set<Int>()
        for id in commentIds where seen.insert(id).inserted && seen.count <= 3 {
            guard let data = try? await api.sendREST(method: "GET", path: "/repos/\(owner)/\(repo)/issues/comments/\(id)", token: token, actionName: "Load comment"),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let body = json["body"] as? String else { continue }
            let author = (json["user"] as? [String: Any])?["login"] as? String ?? "?"
            notes.append("## Feedback comment by \(author) (linked from the failure, comment id \(id)):\n" + String(stripHTML(body).prefix(3000)))
        }
        return ((sections + notes).joined(separator: "\n\n"), true)
    }

    nonisolated(unsafe) private static let commentLink = try! NSRegularExpression(pattern: #"#issuecomment-(\d+)"#)
    nonisolated(unsafe) private static let htmlTag = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->|</?(table|thead|tbody|tr|td|th|div|span|p|br|img|sub|sup|details|summary)\b[^>]*>"#, options: [.caseInsensitive])

    /// Linters such as Danger put the actual findings in a PR comment and only link to it from the log.
    private static func issueCommentIds(in text: String) -> [Int] {
        commentLink.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            Range(m.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
    }

    private static func stripHTML(_ text: String) -> String {
        let stripped = htmlTag.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        return stripped.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    private static func failedStepExcerpt(raw: String, job: ActionsJob, budget: Int) -> String {
        let chunks = ActionsStepLog.split(raw: raw, steps: job.steps)
        let failed = job.steps.filter { $0.actionsStatus == .failure }
        let stepList = job.steps.map { "\($0.number). \($0.name) — \($0.actionsStatus.label)" }.joined(separator: "\n")
        var out = "Steps:\n" + stepList
        let targets = failed.compactMap { step in chunks[step.number].map { (step, $0) } }
        if targets.isEmpty {
            out += "\nLog tail:\n" + excerpt(clean(raw), budget: budget - out.count)
            return out
        }
        let each = max(1200, (budget - out.count) / targets.count)
        for (step, text) in targets {
            out += "\n\nFailed step \(step.number) \"\(step.name)\" log:\n" + excerpt(clean(text), budget: each)
        }
        return out
    }

    nonisolated(unsafe) private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")
    nonisolated(unsafe) private static let errorLine = try! NSRegularExpression(
        pattern: #"##\[error\]|\berror\b|\bfail(ed|ure|ing)?\b|exception|traceback|panic|fatal|assert|✖|✗|×|ERR!|exit code [1-9]"#,
        options: [.caseInsensitive])

    /// Drops timestamps, colour codes and group markers, and shortens very long lines.
    static func clean(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { sub in
            var line = sub
            if ActionsStepLog.timestamp(line) != nil, let space = line.firstIndex(of: " ") { line = line[line.index(after: space)...] }
            var s = String(line)
            if s.contains("\u{1B}") { s = ansi.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "") }
            if s.hasPrefix("##[endgroup]") { return nil }
            if s.hasPrefix("##[group]") { s = String(s.dropFirst(9)) }
            if s.count > 400 { s = String(s.prefix(400)) + "…" }
            return s
        }
    }

    private static func isError(_ line: String) -> Bool {
        errorLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// The step's command, every error with a little context, and the tail, within `budget` characters.
    static func excerpt(_ all: [String], budget: Int) -> String {
        var lines = all
        while lines.count > 1, lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if lines.reduce(0, { $0 + $1.count + 1 }) <= budget { return lines.joined(separator: "\n") }
        let n = lines.count
        let tailCount = min(n, 60)
        var keep = Set(0..<min(n, 12))
        keep.formUnion((n - tailCount)..<n)
        var errorContext = Set<Int>()
        for i in 0..<n where isError(lines[i]) {
            errorContext.formUnion(max(0, i - 3)...min(n - 1, i + 4))
            if errorContext.count > 300 { break }
        }
        func render(_ indices: Set<Int>) -> String {
            var out: [String] = []
            var prev = -1
            for i in indices.sorted() {
                if prev >= 0, i > prev + 1 { out.append("…[\(i - prev - 1) lines]") }
                out.append(lines[i])
                prev = i
            }
            return out.joined(separator: "\n")
        }
        var text = render(keep.union(errorContext))
        if text.count > budget {
            // Too many error-ish lines: keep the ones nearest the end, where the real failure usually is.
            var trimmed = keep
            for i in errorContext.sorted(by: >) {
                trimmed.insert(i)
                if render(trimmed).count > budget { trimmed.remove(i); break }
            }
            text = render(trimmed)
        }
        if text.count > budget { text = "…" + String(text.suffix(budget)) }
        return text
    }

    private static func grepLog(_ lines: [String], regex: NSRegularExpression, budget: Int) -> String {
        var hits: [Int] = []
        for (i, line) in lines.enumerated() where regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            hits.append(i)
        }
        guard !hits.isEmpty else { return "No lines match \"\(regex.pattern)\" in \(lines.count) log lines." }
        var keep = Set<Int>()
        for i in hits { keep.formUnion(max(0, i - 2)...min(lines.count - 1, i + 2)) }
        var out = ["\(hits.count) matching lines of \(lines.count):"]
        var prev = -1, size = 0
        for i in keep.sorted() {
            if prev >= 0, i > prev + 1 { out.append("…") }
            let line = "\(i + 1): \(lines[i])"
            size += line.count + 1
            if size > budget { out.append("…[more matches truncated; narrow the pattern]"); break }
            out.append(line)
            prev = i
        }
        return out.joined(separator: "\n")
    }
}
