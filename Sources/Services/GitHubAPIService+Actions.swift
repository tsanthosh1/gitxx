import Foundation

// MARK: - GitHub Actions (workflows, runs, jobs, logs, artifacts)

extension GitHubAPIService {

    public func fetchWorkflows(owner: String, repo: String, token: String?) async throws -> [ActionsWorkflow] {
        let data = try await sendREST(method: "GET", path: "/repos/\(owner)/\(repo)/actions/workflows?per_page=100", token: token, actionName: "Load workflows")
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["workflows"] as? [[String: Any]] ?? []).compactMap { w in
            guard let id = w["id"] as? Int, let name = w["name"] as? String else { return nil }
            return ActionsWorkflow(
                id: id, name: name, path: (w["path"] as? String) ?? "",
                state: (w["state"] as? String) ?? "active", htmlUrl: w["html_url"] as? String
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func fetchWorkflowRuns(
        owner: String, repo: String, filter: ActionsRunFilter, page: Int, perPage: Int = 40, token: String?
    ) async throws -> (runs: [ActionsRun], totalCount: Int) {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: String(page))
        ]
        if let branch = filter.branch { query.append(URLQueryItem(name: "branch", value: branch)) }
        if let event = filter.event { query.append(URLQueryItem(name: "event", value: event)) }
        if let status = filter.status { query.append(URLQueryItem(name: "status", value: status)) }
        if let actor = filter.actor { query.append(URLQueryItem(name: "actor", value: actor)) }
        var components = URLComponents()
        components.queryItems = query
        let base = filter.workflowId.map { "/repos/\(owner)/\(repo)/actions/workflows/\($0)/runs" } ?? "/repos/\(owner)/\(repo)/actions/runs"
        let data = try await sendREST(method: "GET", path: base + (components.percentEncodedQuery.map { "?" + $0 } ?? ""), token: token, actionName: "Load workflow runs")
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let runs = (json?["workflow_runs"] as? [[String: Any]] ?? []).compactMap(Self.parseRun)
        return (runs, (json?["total_count"] as? Int) ?? runs.count)
    }

    public func fetchWorkflowRun(owner: String, repo: String, runId: Int, token: String?) async throws -> ActionsRun? {
        let data = try await sendREST(method: "GET", path: "/repos/\(owner)/\(repo)/actions/runs/\(runId)", token: token, actionName: "Load workflow run")
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap(Self.parseRun)
    }

    public func fetchRunJobs(owner: String, repo: String, runId: Int, attempt: Int? = nil, token: String?) async throws -> [ActionsJob] {
        let base = attempt.map { "/repos/\(owner)/\(repo)/actions/runs/\(runId)/attempts/\($0)/jobs" }
            ?? "/repos/\(owner)/\(repo)/actions/runs/\(runId)/jobs"
        var jobs: [ActionsJob] = []
        for page in 1...5 {
            let data = try await sendREST(method: "GET", path: "\(base)?per_page=100&page=\(page)", token: token, actionName: "Load jobs")
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let batch = (json?["jobs"] as? [[String: Any]] ?? []).compactMap { Self.parseJob($0, runId: runId) }
            jobs += batch
            if batch.count < 100 || jobs.count >= (json?["total_count"] as? Int ?? 0) { break }
        }
        return jobs
    }

    public func fetchRunArtifacts(owner: String, repo: String, runId: Int, token: String?) async throws -> [ActionsArtifact] {
        let data = try await sendREST(method: "GET", path: "/repos/\(owner)/\(repo)/actions/runs/\(runId)/artifacts?per_page=100", token: token, actionName: "Load artifacts")
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (json?["artifacts"] as? [[String: Any]] ?? []).compactMap { a in
            guard let id = a["id"] as? Int, let name = a["name"] as? String else { return nil }
            return ActionsArtifact(
                id: id, name: name, sizeInBytes: (a["size_in_bytes"] as? Int) ?? 0,
                expired: (a["expired"] as? Bool) ?? false, expiresAt: Self.actionsDate(a["expires_at"]),
                archiveDownloadUrl: (a["archive_download_url"] as? String) ?? ""
            )
        }
    }

    public func fetchJob(owner: String, repo: String, jobId: Int, token: String?) async throws -> ActionsJob? {
        let data = try await sendREST(method: "GET", path: "/repos/\(owner)/\(repo)/actions/jobs/\(jobId)", token: token, actionName: "Load job")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return Self.parseJob(json, runId: json["run_id"] as? Int ?? 0)
    }

    /// Check-run annotations for a job (a job id is also its check-run id).
    public func fetchJobAnnotations(owner: String, repo: String, job: ActionsJob, token: String?) async throws -> [ActionsAnnotation] {
        let data = try await sendREST(method: "GET", path: "/repos/\(owner)/\(repo)/check-runs/\(job.id)/annotations?per_page=50", token: token, actionName: "Load annotations")
        let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return array.compactMap { a in
            guard let message = a["message"] as? String else { return nil }
            return ActionsAnnotation(
                jobId: job.id, jobName: job.name,
                level: (a["annotation_level"] as? String) ?? "notice",
                title: a["title"] as? String, message: message,
                path: (a["path"] as? String) ?? "", startLine: (a["start_line"] as? Int) ?? 0
            )
        }
    }

    public func cancelWorkflowRun(owner: String, repo: String, runId: Int, force: Bool = false, token: String?) async throws {
        try await sendREST(method: "POST", path: "/repos/\(owner)/\(repo)/actions/runs/\(runId)/\(force ? "force-cancel" : "cancel")", token: token, actionName: "Cancel run")
    }

    public func rerunWorkflowRun(owner: String, repo: String, runId: Int, debug: Bool = false, token: String?) async throws {
        try await sendREST(method: "POST", path: "/repos/\(owner)/\(repo)/actions/runs/\(runId)/rerun", body: ["enable_debug_logging": debug], token: token, actionName: "Re-run workflow")
    }

    public func setWorkflowEnabled(owner: String, repo: String, workflowId: Int, enabled: Bool, token: String?) async throws {
        try await sendREST(method: "PUT", path: "/repos/\(owner)/\(repo)/actions/workflows/\(workflowId)/\(enabled ? "enable" : "disable")", token: token, actionName: enabled ? "Enable workflow" : "Disable workflow")
    }

    public func dispatchWorkflow(owner: String, repo: String, workflowId: Int, ref: String, inputs: [String: String], token: String?) async throws {
        try await sendREST(
            method: "POST", path: "/repos/\(owner)/\(repo)/actions/workflows/\(workflowId)/dispatches",
            body: ["ref": ref, "inputs": inputs], token: token, actionName: "Run workflow"
        )
    }

    /// Downloads an artifact zip into ~/Downloads and returns its location.
    public func downloadArtifact(_ artifact: ActionsArtifact, token: String?) async throws -> URL {
        let data = try await sendREST(method: "GET", path: artifact.archiveDownloadUrl, token: token, actionName: "Download artifact")
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var target = downloads.appendingPathComponent("\(artifact.name).zip")
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            n += 1
            target = downloads.appendingPathComponent("\(artifact.name) (\(n)).zip")
        }
        try data.write(to: target)
        return target
    }

    /// `workflow_dispatch` inputs declared in the workflow file on `ref`; nil when the workflow can't be run manually.
    public func fetchDispatchInputs(owner: String, repo: String, workflow: ActionsWorkflow, ref: String, token: String?) async throws -> [ActionsDispatchInput]? {
        let encodedRef = ref.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ref
        let data = try await sendREST(method: "GET", path: "/repos/\(owner)/\(repo)/contents/\(workflow.path)?ref=\(encodedRef)", token: token, actionName: "Load workflow file")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = json["content"] as? String,
              let decoded = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")) else { return nil }
        return Self.parseDispatchInputs(yaml: String(decoding: decoded, as: UTF8.self))
    }

    // MARK: Parsing

    static func parseRun(_ r: [String: Any]) -> ActionsRun? {
        guard let id = r["id"] as? Int else { return nil }
        let actor = (r["triggering_actor"] as? [String: Any]) ?? (r["actor"] as? [String: Any])
        let prs = (r["pull_requests"] as? [[String: Any]] ?? []).compactMap { $0["number"] as? Int }
        return ActionsRun(
            id: id,
            workflowId: (r["workflow_id"] as? Int) ?? 0,
            workflowName: (r["name"] as? String) ?? "Workflow",
            displayTitle: (r["display_title"] as? String) ?? ((r["head_commit"] as? [String: Any])?["message"] as? String ?? "").components(separatedBy: "\n").first ?? "",
            runNumber: (r["run_number"] as? Int) ?? 0,
            runAttempt: (r["run_attempt"] as? Int) ?? 1,
            event: (r["event"] as? String) ?? "",
            status: (r["status"] as? String) ?? "queued",
            conclusion: r["conclusion"] as? String,
            headBranch: (r["head_branch"] as? String) ?? "",
            headSha: (r["head_sha"] as? String) ?? "",
            actorLogin: (actor?["login"] as? String) ?? "",
            actorAvatarUrl: actor?["avatar_url"] as? String,
            createdAt: actionsDate(r["created_at"]) ?? Date(),
            updatedAt: actionsDate(r["updated_at"]) ?? Date(),
            runStartedAt: actionsDate(r["run_started_at"]),
            htmlUrl: (r["html_url"] as? String) ?? "",
            workflowPath: (r["path"] as? String) ?? "",
            pullRequestNumbers: prs
        )
    }

    static func parseJob(_ j: [String: Any], runId: Int) -> ActionsJob? {
        guard let id = j["id"] as? Int else { return nil }
        let steps = (j["steps"] as? [[String: Any]] ?? []).compactMap { s -> ActionsStep? in
            guard let number = s["number"] as? Int else { return nil }
            return ActionsStep(
                number: number, name: (s["name"] as? String) ?? "Step \(number)",
                status: (s["status"] as? String) ?? "queued", conclusion: s["conclusion"] as? String,
                startedAt: actionsDate(s["started_at"]), completedAt: actionsDate(s["completed_at"])
            )
        }
        return ActionsJob(
            id: id, runId: runId, name: (j["name"] as? String) ?? "Job",
            status: (j["status"] as? String) ?? "queued", conclusion: j["conclusion"] as? String,
            startedAt: actionsDate(j["started_at"]), completedAt: actionsDate(j["completed_at"]),
            htmlUrl: j["html_url"] as? String, runnerName: j["runner_name"] as? String,
            labels: (j["labels"] as? [String]) ?? [], steps: steps
        )
    }

    nonisolated(unsafe) private static let actionsDateFormatter = ISO8601DateFormatter()

    static func actionsDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return actionsDateFormatter.date(from: string)
    }

    /// Minimal YAML reader for `on.workflow_dispatch.inputs` (indentation-based; enough for typical workflow files).
    static func parseDispatchInputs(yaml: String) -> [ActionsDispatchInput]? {
        let lines = yaml.components(separatedBy: "\n").map { line -> String in
            // Drop comments that aren't inside quotes.
            if let hash = line.range(of: " #"), !line[..<hash.lowerBound].contains("\"") { return String(line[..<hash.lowerBound]) }
            return line.hasPrefix("#") ? "" : line
        }
        func indent(_ s: String) -> Int { s.prefix(while: { $0 == " " }).count }
        func keyValue(_ s: String) -> (String, String)? {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard let colon = t.firstIndex(of: ":") else { return nil }
            let key = t[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            let value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return (key, value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
        }

        let flat = yaml.replacingOccurrences(of: " ", with: "")
        guard let dispatchIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("workflow_dispatch") }) else {
            // `on: [push, workflow_dispatch]` or `on: workflow_dispatch`
            return flat.contains("workflow_dispatch") ? [] : nil
        }
        let dispatchIndent = indent(lines[dispatchIndex])
        var i = dispatchIndex + 1
        var inputsIndent: Int?
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            if indent(line) <= dispatchIndent { return [] }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("inputs:") { inputsIndent = indent(line); i += 1; break }
            i += 1
        }
        guard let inputsIndent else { return [] }

        var inputs: [ActionsDispatchInput] = []
        var nameIndent: Int?
        var inOptions = false
        while i < lines.count {
            let line = lines[i]
            i += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let level = indent(line)
            if level <= inputsIndent { break }
            if nameIndent == nil { nameIndent = level }
            if level == nameIndent, let (key, _) = keyValue(line) {
                inputs.append(ActionsDispatchInput(name: key))
                inOptions = false
                continue
            }
            guard !inputs.isEmpty else { continue }
            if trimmed.hasPrefix("- "), inOptions {
                inputs[inputs.count - 1].options.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
                continue
            }
            guard let (key, value) = keyValue(line) else { continue }
            inOptions = false
            switch key {
            case "description": inputs[inputs.count - 1].description = value
            case "type": inputs[inputs.count - 1].type = value
            case "required": inputs[inputs.count - 1].required = value == "true"
            case "default": inputs[inputs.count - 1].defaultValue = value
            case "options":
                if value.hasPrefix("[") {
                    inputs[inputs.count - 1].options = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                } else {
                    inOptions = true
                }
            default: break
            }
        }
        return inputs
    }
}
