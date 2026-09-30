import Foundation

// MARK: - Pull Request Write Actions & Detail Metadata

extension GitHubAPIService {

    private static let graphQLEndpoint = URL(string: "https://api.github.com/graphql")!

    // MARK: Transport helpers

    /// Sends a JSON REST request, records it in the API log, and throws a readable error for non-2xx responses.
    @discardableResult
    func sendREST(
        method: String,
        path: String,
        body: [String: Any]? = nil,
        token: String?,
        actionName: String
    ) async throws -> Data {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw NSError(domain: "GitHubAPI", code: 401, userInfo: [NSLocalizedDescriptionKey: "No GitHub token configured."])
        }
        let urlString = path.hasPrefix("http") ? path : "https://api.github.com\(path)"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "GitHubAPI", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(urlString)"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitXX-macOS-Client", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let start = DispatchTime.now()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await GitHubHTTP.session.data(for: request)
        } catch {
            await GitHubAPILogger.shared.record(
                method: method, urlString: urlString, statusCode: 0,
                durationMs: Self.elapsedMs(since: start), isCached304: false,
                responseSizeBytes: 0, errorDescription: error.localizedDescription
            )
            throw error
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
        await GitHubAPILogger.shared.record(
            method: method, urlString: urlString, statusCode: status,
            durationMs: Self.elapsedMs(since: start), isCached304: false,
            responseSizeBytes: data.count,
            errorDescription: status >= 400 ? String(data: data, encoding: .utf8) : nil
        )

        guard (200..<300).contains(status) else {
            throw NSError(domain: "GitHubAPI", code: status, userInfo: [
                NSLocalizedDescriptionKey: "\(actionName) failed: \(Self.readableError(from: data, status: status))"
            ])
        }
        return data
    }

    /// Runs a GraphQL query/mutation and returns the `data` dictionary, throwing on transport or GraphQL errors.
    func sendGraphQL(
        query: String,
        variables: [String: Any],
        token: String?,
        actionName: String
    ) async throws -> [String: Any] {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw NSError(domain: "GitHubAPI", code: 401, userInfo: [NSLocalizedDescriptionKey: "No GitHub token configured."])
        }
        var request = URLRequest(url: Self.graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("GitXX-macOS-Client", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let start = DispatchTime.now()
        let (data, response) = try await GitHubHTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 500
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let errors = json?["errors"] as? [[String: Any]]
        let errorText = errors?.compactMap { $0["message"] as? String }.joined(separator: "; ")

        await GitHubAPILogger.shared.record(
            method: "POST", urlString: "\(Self.graphQLEndpoint.absoluteString) (\(actionName))",
            statusCode: status, durationMs: Self.elapsedMs(since: start), isCached304: false,
            responseSizeBytes: data.count,
            errorDescription: status >= 400 || !(errorText ?? "").isEmpty ? (errorText ?? String(data: data, encoding: .utf8)) : nil
        )

        guard status == 200, let dataDict = json?["data"] as? [String: Any] else {
            let msg = errorText ?? Self.readableError(from: data, status: status)
            throw NSError(domain: "GitHubGraphQL", code: status, userInfo: [NSLocalizedDescriptionKey: "\(actionName) failed: \(msg)"])
        }
        if let errorText, !errorText.isEmpty, dataDict.values.allSatisfy({ $0 is NSNull }) {
            throw NSError(domain: "GitHubGraphQL", code: 422, userInfo: [NSLocalizedDescriptionKey: "\(actionName) failed: \(errorText)"])
        }
        return dataDict
    }

    private static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
    }

    private static func readableError(from data: Data, status: Int) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "HTTP \(status)"
        }
        var message = (json["message"] as? String) ?? "HTTP \(status)"
        if let errors = json["errors"] as? [[String: Any]] {
            let details = errors.compactMap { ($0["message"] as? String) ?? ($0["code"] as? String) }
            if !details.isEmpty { message += " (\(details.joined(separator: ", ")))" }
        } else if let errors = json["errors"] as? [String], !errors.isEmpty {
            message += " (\(errors.joined(separator: ", ")))"
        }
        return message
    }

    private static func idString(_ value: Any?) -> String? {
        if let n = value as? Int { return String(n) }
        if let n = value as? NSNumber { return n.stringValue }
        if let s = value as? String { return s }
        return nil
    }

    // MARK: Detail metadata (labels, reviewers, thread resolution, merge settings)

    public func fetchPRDetailMeta(owner: String, repo: String, prNumber: Int, token: String?) async throws -> PRDetailMeta {
        let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          viewer { login }
          repository(owner: $owner, name: $name) {
            mergeCommitAllowed
            squashMergeAllowed
            rebaseMergeAllowed
            deleteBranchOnMerge
            viewerPermission
            pullRequest(number: $number) {
              id
              viewerDidAuthor
              labels(first: 50) { nodes { name color description } }
              reviewRequests(first: 30) {
                nodes {
                  requestedReviewer {
                    __typename
                    ... on User { login avatarUrl }
                    ... on Bot { login avatarUrl }
                    ... on Team { name slug }
                  }
                }
              }
              reviewDecision
              mergeStateStatus
              baseRef { refUpdateRule { viewerCanPush requiredApprovingReviewCount } }
              latestOpinionatedReviews(first: 30) {
                nodes { state author { login avatarUrl } }
              }
              latestReviews(first: 50) {
                nodes { state author { login avatarUrl } }
              }
              assignees(first: 20) { nodes { login avatarUrl } }
              participants(first: 40) { nodes { login avatarUrl } }
              reviewThreads(first: 100) {
                nodes {
                  id
                  isResolved
                  isOutdated
                  resolvedBy { login }
                  comments(first: 1) { nodes { databaseId } }
                }
              }
            }
          }
        }
        """
        let data = try await sendGraphQL(
            query: query,
            variables: ["owner": owner, "name": repo, "number": prNumber],
            token: token,
            actionName: "Load PR details"
        )
        guard let repoDict = data["repository"] as? [String: Any],
              let prDict = repoDict["pullRequest"] as? [String: Any],
              let nodeId = prDict["id"] as? String else {
            throw NSError(domain: "GitHubGraphQL", code: 404, userInfo: [NSLocalizedDescriptionKey: "Pull request #\(prNumber) not found."])
        }

        let labels: [PRLabel] = ((prDict["labels"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap {
            guard let name = $0["name"] as? String else { return nil }
            return PRLabel(name: name, color: ($0["color"] as? String) ?? "8b949e", description: $0["description"] as? String)
        }

        var reviewers: [PRReviewerStatus] = []
        var seen = Set<String>()
        for node in (prDict["latestOpinionatedReviews"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [] {
            guard let author = node["author"] as? [String: Any], let login = author["login"] as? String,
                  let state = node["state"] as? String, !seen.contains(login) else { continue }
            seen.insert(login)
            reviewers.append(PRReviewerStatus(login: login, avatarUrl: author["avatarUrl"] as? String, state: state))
        }
        for node in (prDict["latestReviews"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [] {
            guard let author = node["author"] as? [String: Any], let login = author["login"] as? String,
                  !seen.contains(login) else { continue }
            seen.insert(login)
            reviewers.append(PRReviewerStatus(login: login, avatarUrl: author["avatarUrl"] as? String, state: (node["state"] as? String) ?? "COMMENTED"))
        }
        for node in (prDict["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [] {
            guard let reviewer = node["requestedReviewer"] as? [String: Any] else { continue }
            let isTeam = (reviewer["__typename"] as? String) == "Team"
            guard let login = isTeam ? (reviewer["name"] as? String) : (reviewer["login"] as? String) else { continue }
            if let idx = reviewers.firstIndex(where: { $0.login == login }) {
                // Re-requested after an earlier review: GitHub shows them as awaiting review again.
                reviewers[idx] = PRReviewerStatus(login: login, avatarUrl: reviewers[idx].avatarUrl, isTeam: isTeam, state: "REQUESTED")
            } else {
                reviewers.append(PRReviewerStatus(login: login, avatarUrl: reviewer["avatarUrl"] as? String, isTeam: isTeam, state: "REQUESTED"))
            }
        }

        let threads: [PRThreadMeta] = ((prDict["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { node in
            guard let id = node["id"] as? String,
                  let first = ((node["comments"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first,
                  let dbId = Self.idString(first["databaseId"]) else { return nil }
            return PRThreadMeta(
                nodeId: id,
                isResolved: (node["isResolved"] as? Bool) ?? false,
                isOutdated: (node["isOutdated"] as? Bool) ?? false,
                resolvedBy: (node["resolvedBy"] as? [String: Any])?["login"] as? String,
                firstCommentDatabaseId: dbId
            )
        }

        func users(_ key: String) -> [PRReviewerStatus] {
            ((prDict[key] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap {
                guard let login = $0["login"] as? String else { return nil }
                return PRReviewerStatus(login: login, avatarUrl: $0["avatarUrl"] as? String, state: "")
            }
        }

        let rule = (prDict["baseRef"] as? [String: Any])?["refUpdateRule"] as? [String: Any]
        return PRDetailMeta(
            prNumber: prNumber,
            nodeId: nodeId,
            labels: labels,
            reviewers: reviewers,
            threads: threads,
            assignees: users("assignees"),
            participants: users("participants"),
            reviewDecision: prDict["reviewDecision"] as? String,
            mergeStateStatus: prDict["mergeStateStatus"] as? String,
            viewerCanPushToBase: rule?["viewerCanPush"] as? Bool,
            requiredApprovingReviewCount: rule?["requiredApprovingReviewCount"] as? Int,
            viewerLogin: (data["viewer"] as? [String: Any])?["login"] as? String,
            viewerPermission: repoDict["viewerPermission"] as? String,
            viewerDidAuthor: (prDict["viewerDidAuthor"] as? Bool) ?? false,
            mergeCommitAllowed: (repoDict["mergeCommitAllowed"] as? Bool) ?? true,
            squashMergeAllowed: (repoDict["squashMergeAllowed"] as? Bool) ?? true,
            rebaseMergeAllowed: (repoDict["rebaseMergeAllowed"] as? Bool) ?? true,
            deleteBranchOnMerge: (repoDict["deleteBranchOnMerge"] as? Bool) ?? false
        )
    }

    // MARK: Review threads

    public func setReviewThreadResolved(threadNodeId: String, resolved: Bool, token: String?) async throws {
        let mutation = resolved
            ? "mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id isResolved } } }"
            : "mutation($id: ID!) { unresolveReviewThread(input: {threadId: $id}) { thread { id isResolved } } }"
        _ = try await sendGraphQL(
            query: mutation,
            variables: ["id": threadNodeId],
            token: token,
            actionName: resolved ? "Resolve conversation" : "Unresolve conversation"
        )
    }

    public func replyToReviewComment(
        owner: String, repo: String, prNumber: Int, commentId: String, body: String, token: String?
    ) async throws -> PRReviewComment {
        let data = try await sendREST(
            method: "POST",
            path: "/repos/\(owner)/\(repo)/pulls/\(prNumber)/comments/\(commentId)/replies",
            body: ["body": body],
            token: token,
            actionName: "Reply"
        )
        await invalidateTimelineCaches(owner: owner, repo: repo, prNumber: prNumber)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let user = json["user"] as? [String: Any]
        let iso = ISO8601DateFormatter()
        return PRReviewComment(
            id: Self.idString(json["id"]) ?? UUID().uuidString,
            authorName: (user?["login"] as? String) ?? "you",
            authorAvatarUrl: user?["avatar_url"] as? String,
            body: (json["body"] as? String) ?? body,
            createdAt: (json["created_at"] as? String).flatMap { iso.date(from: $0) } ?? Date(),
            path: json["path"] as? String,
            line: json["line"] as? Int,
            diffHunk: json["diff_hunk"] as? String,
            inReplyToId: commentId,
            htmlUrl: json["html_url"] as? String
        )
    }

    /// Creates a single inline review comment on one line of the diff.
    public func createReviewComment(
        owner: String, repo: String, prNumber: Int, commitId: String,
        path: String, line: Int, side: String, body: String, token: String?
    ) async throws -> PRReviewComment {
        let data = try await sendREST(
            method: "POST",
            path: "/repos/\(owner)/\(repo)/pulls/\(prNumber)/comments",
            body: ["body": body, "commit_id": commitId, "path": path, "line": line, "side": side],
            token: token,
            actionName: "Comment"
        )
        await invalidateTimelineCaches(owner: owner, repo: repo, prNumber: prNumber)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let user = json["user"] as? [String: Any]
        return PRReviewComment(
            id: Self.idString(json["id"]) ?? UUID().uuidString,
            authorName: (user?["login"] as? String) ?? "you",
            authorAvatarUrl: user?["avatar_url"] as? String,
            body: (json["body"] as? String) ?? body,
            createdAt: (json["created_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(),
            path: path,
            line: line,
            diffHunk: json["diff_hunk"] as? String,
            htmlUrl: json["html_url"] as? String,
            side: side
        )
    }

    /// Text of a file at a commit, via the contents API (files up to 1 MB).
    public func fetchFileContent(owner: String, repo: String, path: String, ref: String, token: String?) async throws -> String {
        let encodedPath = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let data = try await sendREST(
            method: "GET",
            path: "/repos/\(owner)/\(repo)/contents/\(encodedPath)?ref=\(ref)",
            token: token,
            actionName: "Load file"
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = json["content"] as? String,
              let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            throw NSError(domain: "GitHubAPI", code: 422, userInfo: [NSLocalizedDescriptionKey: "File is too large or not a text file."])
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    // MARK: Conversation comments

    public func postIssueComment(owner: String, repo: String, prNumber: Int, body: String, token: String?) async throws -> PRComment {
        let data = try await sendREST(
            method: "POST",
            path: "/repos/\(owner)/\(repo)/issues/\(prNumber)/comments",
            body: ["body": body],
            token: token,
            actionName: "Comment"
        )
        await invalidateTimelineCaches(owner: owner, repo: repo, prNumber: prNumber)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let user = json["user"] as? [String: Any]
        let iso = ISO8601DateFormatter()
        return PRComment(
            id: Self.idString(json["id"]) ?? UUID().uuidString,
            authorName: (user?["login"] as? String) ?? "you",
            authorAvatarUrl: user?["avatar_url"] as? String,
            body: (json["body"] as? String) ?? body,
            createdAt: (json["created_at"] as? String).flatMap { iso.date(from: $0) } ?? Date()
        )
    }

    // MARK: Labels

    public func fetchRepoLabels(owner: String, repo: String, token: String?) async throws -> [PRLabel] {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/labels?per_page=100") else { return [] }
        let data = try await sendREST(method: "GET", path: url.absoluteString, token: token, actionName: "Load labels")
        let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return array.compactMap {
            guard let name = $0["name"] as? String else { return nil }
            return PRLabel(name: name, color: ($0["color"] as? String) ?? "8b949e", description: $0["description"] as? String)
        }
    }

    public func setPRLabels(owner: String, repo: String, prNumber: Int, labels: [String], token: String?) async throws -> [PRLabel] {
        let data = try await sendREST(
            method: "PUT",
            path: "/repos/\(owner)/\(repo)/issues/\(prNumber)/labels",
            body: ["labels": labels],
            token: token,
            actionName: "Update labels"
        )
        let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return array.compactMap {
            guard let name = $0["name"] as? String else { return nil }
            return PRLabel(name: name, color: ($0["color"] as? String) ?? "8b949e", description: $0["description"] as? String)
        }
    }

    // MARK: CI re-runs

    public func rerunFailedJobs(owner: String, repo: String, runId: String, token: String?) async throws {
        try await sendREST(
            method: "POST",
            path: "/repos/\(owner)/\(repo)/actions/runs/\(runId)/rerun-failed-jobs",
            token: token,
            actionName: "Re-run failed jobs"
        )
    }

    public func rerunJob(owner: String, repo: String, jobId: String, token: String?) async throws {
        try await sendREST(
            method: "POST",
            path: "/repos/\(owner)/\(repo)/actions/jobs/\(jobId)/rerun",
            token: token,
            actionName: "Re-run job"
        )
    }

    /// Raw plain-text log of a GitHub Actions job (the API redirects to a short-lived download URL).
    public func fetchJobLog(owner: String, repo: String, jobId: String, token: String?) async throws -> String {
        let data = try await sendREST(
            method: "GET",
            path: "/repos/\(owner)/\(repo)/actions/jobs/\(jobId)/logs",
            token: token,
            actionName: "Load job log"
        )
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Revert

    /// Opens a new PR that reverts a merged PR (GitHub creates the revert branch and commit server-side).
    public func revertPullRequest(prNodeId: String, title: String, body: String, draft: Bool, token: String?) async throws -> (number: Int, url: String) {
        let mutation = """
        mutation($id: ID!, $title: String, $body: String, $draft: Boolean) {
          revertPullRequest(input: {pullRequestId: $id, title: $title, body: $body, draft: $draft}) {
            revertPullRequest { number url }
          }
        }
        """
        let data = try await sendGraphQL(
            query: mutation,
            variables: ["id": prNodeId, "title": title, "body": body, "draft": draft],
            token: token,
            actionName: "Revert pull request"
        )
        guard let revert = (data["revertPullRequest"] as? [String: Any])?["revertPullRequest"] as? [String: Any],
              let number = revert["number"] as? Int else {
            throw NSError(domain: "GitHubGraphQL", code: 422, userInfo: [NSLocalizedDescriptionKey: "Revert pull request failed: GitHub returned no pull request."])
        }
        return (number, (revert["url"] as? String) ?? "")
    }

    // MARK: Draft state

    public func setPRDraft(prNodeId: String, draft: Bool, token: String?) async throws {
        let mutation = draft
            ? "mutation($id: ID!) { convertPullRequestToDraft(input: {pullRequestId: $id}) { pullRequest { isDraft } } }"
            : "mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { isDraft } } }"
        _ = try await sendGraphQL(
            query: mutation,
            variables: ["id": prNodeId],
            token: token,
            actionName: draft ? "Convert to draft" : "Mark ready for review"
        )
    }

    // MARK: Branches

    public func deleteBranch(owner: String, repo: String, branch: String, token: String?) async throws {
        let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        try await sendREST(
            method: "DELETE",
            path: "/repos/\(owner)/\(repo)/git/refs/heads/\(encoded)",
            token: token,
            actionName: "Delete branch"
        )
    }

    // MARK: Cache invalidation

    public func invalidateTimelineCaches(owner: String, repo: String, prNumber: Int) async {
        let base = "https://api.github.com/repos/\(owner)/\(repo)"
        for suffix in [
            "/issues/\(prNumber)/comments?per_page=100",
            "/pulls/\(prNumber)/reviews?per_page=100",
            "/pulls/\(prNumber)/comments?per_page=100",
            "/pulls/\(prNumber)"
        ] {
            await GitHubHTTPCache.shared.remove(for: base + suffix)
        }
    }

    public func invalidateChecksCache(owner: String, repo: String, headSha: String) async {
        let base = "https://api.github.com/repos/\(owner)/\(repo)/commits/\(headSha)"
        await GitHubHTTPCache.shared.remove(for: "\(base)/check-runs?per_page=50")
        await GitHubHTTPCache.shared.remove(for: "\(base)/status")
    }
}

// MARK: - User Suggestions

public struct GitHubUserSuggestion: Identifiable, Hashable, Sendable {
    public var id: String { login.lowercased() }
    public let login: String
    public let name: String?
    public let avatarUrl: String?
}

extension GitHubAPIService {
    /// People who can be mentioned in the repo (collaborators and org members with access), matched on login or name.
    public func searchMentionableUsers(owner: String, repo: String, query: String, token: String?) async throws -> [GitHubUserSuggestion] {
        let gql = """
        query($owner: String!, $repo: String!, $q: String!) {
          repository(owner: $owner, name: $repo) {
            mentionableUsers(query: $q, first: 20) { nodes { login name avatarUrl } }
          }
        }
        """
        let data = try await sendGraphQL(query: gql, variables: ["owner": owner, "repo": repo, "q": query],
                                         token: token, actionName: "Search users")
        let nodes = (((data["repository"] as? [String: Any])?["mentionableUsers"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        return nodes.compactMap { node in
            guard let login = node["login"] as? String else { return nil }
            return GitHubUserSuggestion(login: login, name: node["name"] as? String, avatarUrl: node["avatarUrl"] as? String)
        }
    }
}
