import Foundation

public actor GitHubAPIService {
    public static let shared = GitHubAPIService()

    private var endpoint: URL { GitHubHost.graphQL }
    private var rateLimitInfo = GitHubRateLimitInfo()

    public init() {}

    public func getRateLimit() -> GitHubRateLimitInfo {
        return rateLimitInfo
    }

    public struct RepoOwnerAndName: Sendable {
        public let owner: String
        public let name: String
    }

    nonisolated public func parseRepoOwnerAndName(from remoteUrl: String?) -> RepoOwnerAndName? {
        guard var path = remoteUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        // https://host/owner/repo.git, ssh://git@host:22/owner/repo.git, or scp-style git@host:owner/repo.git
        if let scheme = path.range(of: "://") {
            path = String(path[scheme.upperBound...])
            path = path.firstIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? ""
        } else if let colon = path.firstIndex(of: ":"), !path[..<colon].contains("/") {
            path = String(path[path.index(after: colon)...])
        }
        if path.hasSuffix(".git") { path.removeLast(4) }

        let parts = path.components(separatedBy: "/").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return RepoOwnerAndName(owner: parts[0], name: parts[1])
        }
        return nil
    }

    public static func getGitHubCLIToken() -> String? {
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-c", "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; gh auth token\(GitHubHost.isEnterprise ? " --hostname \(GitHubHost.host)" : "") 2>/dev/null"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty, task.terminationStatus == 0 {
                return output
            }
        } catch {}
        return nil
    }

    // MARK: - HTTP Caching (304 Not Modified & ETag / Last-Modified Support)

    public struct CachedFetchResult: Sendable {
        public let data: Data
        public let isFromCache: Bool
        public let httpStatusCode: Int
    }

    private func executeCachedGET(
        url: URL,
        token: String
    ) async throws -> CachedFetchResult {
        let startTime = DispatchTime.now()
        let urlString = url.absoluteString
        await GitHubHTTPCache.shared.setScope(token: token)
        let cached = await GitHubHTTPCache.shared.get(for: urlString)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GitXX-macOS-Client", forHTTPHeaderField: "User-Agent")

        // Send ETag and Last-Modified headers if available locally
        if let etag = cached?.etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = cached?.lastModified, !lastModified.isEmpty {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await GitHubHTTP.session.data(for: request)
        } catch {
            if GitHubHTTP.isCancellation(error) { throw CancellationError() }
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
            await GitHubAPILogger.shared.record(
                method: "GET",
                urlString: urlString,
                statusCode: 0,
                durationMs: durationMs,
                isCached304: false,
                responseSizeBytes: 0,
                errorDescription: error.localizedDescription
            )
            // If network fails (e.g. offline, timeout), return cached data if available
            if let cached = cached {
                return CachedFetchResult(data: cached.data, isFromCache: true, httpStatusCode: 200)
            }
            throw error
        }

        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0

        guard let httpResponse = response as? HTTPURLResponse else {
            await GitHubAPILogger.shared.record(
                method: "GET",
                urlString: urlString,
                statusCode: 500,
                durationMs: durationMs,
                isCached304: false,
                responseSizeBytes: data.count,
                errorDescription: "Invalid server response"
            )
            if let cached = cached {
                return CachedFetchResult(data: cached.data, isFromCache: true, httpStatusCode: 200)
            }
            throw NSError(domain: "GitHubAPI", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid server response from GitHub."])
        }

        let remaining = httpResponse.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init)
        let limit = httpResponse.value(forHTTPHeaderField: "x-ratelimit-limit").flatMap(Int.init)
        var resetDate: Date? = nil
        if let resetStr = httpResponse.value(forHTTPHeaderField: "x-ratelimit-reset"),
           let resetEpoch = Double(resetStr) {
            resetDate = Date(timeIntervalSince1970: resetEpoch)
        }

        // Update rate limit tracking from response headers
        if let remaining = remaining, let limit = limit {
            // Note: HTTP 304 does NOT count against your hourly rate limit!
            self.rateLimitInfo = GitHubRateLimitInfo(
                remaining: remaining,
                limit: limit,
                resetAt: resetDate ?? Date().addingTimeInterval(3600),
                cost: httpResponse.statusCode == 304 ? 0 : 1
            )
        }

        // HTTP 304 Not Modified: Reuse local cached response, 0 rate limit cost!
        if httpResponse.statusCode == 304 {
            await GitHubAPILogger.shared.record(
                method: "GET",
                urlString: urlString,
                statusCode: 304,
                durationMs: durationMs,
                rateLimitRemaining: remaining,
                rateLimitLimit: limit,
                rateLimitReset: resetDate,
                isCached304: true,
                responseSizeBytes: cached?.data.count ?? data.count,
                errorDescription: nil
            )
            if let cached = cached {
                return CachedFetchResult(data: cached.data, isFromCache: true, httpStatusCode: 304)
            }
        }

        // HTTP 200 OK: Store new ETag, Last-Modified, and response body in cache
        if httpResponse.statusCode == 200 {
            let etag = httpResponse.value(forHTTPHeaderField: "ETag") ?? httpResponse.value(forHTTPHeaderField: "etag")
            let lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified") ?? httpResponse.value(forHTTPHeaderField: "last-modified")

            await GitHubHTTPCache.shared.store(
                urlString: urlString,
                etag: etag,
                lastModified: lastModified,
                data: data
            )

            await GitHubAPILogger.shared.record(
                method: "GET",
                urlString: urlString,
                statusCode: 200,
                durationMs: durationMs,
                rateLimitRemaining: remaining,
                rateLimitLimit: limit,
                rateLimitReset: resetDate,
                isCached304: false,
                responseSizeBytes: data.count,
                errorDescription: nil
            )

            return CachedFetchResult(data: data, isFromCache: false, httpStatusCode: 200)
        }

        // Handle specific error codes
        let errorMsg: String
        if httpResponse.statusCode == 401 {
            errorMsg = "GitHub Authentication Failed (401): Bad credentials. Your Personal Access Token is invalid or expired."
        } else if httpResponse.statusCode == 403 {
            errorMsg = parseErrorMessage(from: data) ?? "Access Forbidden (403): Organization SAML SSO authorization may be required for this token, or API rate limit exceeded."
        } else if httpResponse.statusCode == 404 {
            errorMsg = "Repository resource was not found on GitHub."
        } else {
            errorMsg = parseErrorMessage(from: data) ?? "GitHub API error (HTTP \(httpResponse.statusCode))"
        }

        await GitHubAPILogger.shared.record(
            method: "GET",
            urlString: urlString,
            statusCode: httpResponse.statusCode,
            durationMs: durationMs,
            rateLimitRemaining: remaining,
            rateLimitLimit: limit,
            rateLimitReset: resetDate,
            isCached304: false,
            responseSizeBytes: data.count,
            errorDescription: errorMsg
        )

        if httpResponse.statusCode == 403, let cached = cached {
            return CachedFetchResult(data: cached.data, isFromCache: true, httpStatusCode: 304)
        }

        throw NSError(domain: "GitHubAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
    }


    public func validateToken(_ token: String) async -> (isValid: Bool, username: String?, error: String?) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, nil, "Token is empty")
        }

        guard let url = URL(string: "\(GitHubHost.api)/user") else {
            return (false, nil, "Invalid URL")
        }

        do {
            let result = try await executeCachedGET(url: url, token: trimmed)
            if let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
               let login = json["login"] as? String {
                return (true, login, nil)
            }
            return (true, nil, nil)
        } catch {
            return (false, nil, error.localizedDescription)
        }
    }

    public func buildSearchQuery(owner: String, repo: String, filter: PRFilter) -> String {
        let base = "repo:\(owner)/\(repo) is:pr"
        switch filter {
        case .myOpen:
            return "\(base) is:open author:@me"
        case .myClosed:
            return "\(base) is:closed author:@me"
        case .open:
            return "\(base) is:open"
        case .closed:
            return "\(base) is:closed"
        case .reviewNeeded:
            return "\(base) is:open review-requested:@me"
        case .all:
            return base
        }
    }

    // MARK: - Paged PR list (fast path)

    public struct PRListPage: Sendable {
        public let prs: [PullRequest]
        public let totalCount: Int
        public let endCursor: String?
        public let hasNextPage: Bool
    }

    /// Search qualifier matching the list's sort menu, so pages continue in the order shown.
    public static func searchSortQualifier(_ sortRaw: String?) -> String {
        switch sortRaw {
        case "Newest": return "sort:created-desc"
        case "Oldest": return "sort:created-asc"
        case "Most commented": return "sort:comments-desc"
        default: return "sort:updated-desc"
        }
    }

    /// One page of the PR list with only cheap fields (~0.7s on large repos). Diff stats, review decision
    /// and CI rollups are fetched separately by `fetchPREnrichment`, since they multiply the query cost.
    public func fetchPRListPage(owner: String, repo: String, filter: PRFilter, sort: String?, after: String?,
                                author: String? = nil, label: String? = nil, pageSize: Int = 25, token: String?) async throws -> PRListPage {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return PRListPage(prs: [], totalCount: 0, endCursor: nil, hasNextPage: false)
        }
        let query = """
        query($q: String!, $first: Int!, $after: String) {
          search(query: $q, type: ISSUE, first: $first, after: $after) {
            issueCount
            pageInfo { endCursor hasNextPage }
            nodes {
              ... on PullRequest {
                number title body state isDraft url createdAt totalCommentsCount
                headRefName headRefOid baseRefName
                author { login avatarUrl }
                labels(first: 10) { nodes { name color } }
                reviewRequests(first: 10) { nodes { requestedReviewer {
                  ... on User { login avatarUrl }
                  ... on Team { name avatarUrl }
                } } }
                latestReviews(first: 10) { nodes { state author { __typename login avatarUrl } } }
              }
            }
          }
        }
        """
        var variables: [String: Any] = [
            "q": buildSearchQuery(owner: owner, repo: repo, filter: filter) + (author.map { " author:\($0)" } ?? "")
                + (label.map { " label:\"\($0.replacingOccurrences(of: "\"", with: ""))\"" } ?? "") + " " + Self.searchSortQualifier(sort),
            "first": pageSize,
        ]
        if let after { variables["after"] = after }
        let data = try await sendGraphQL(query: query, variables: variables, token: token, actionName: "Load pull requests")
        guard let search = data["search"] as? [String: Any], let nodes = search["nodes"] as? [[String: Any]] else {
            throw NSError(domain: "GitHubGraphQL", code: 422, userInfo: [NSLocalizedDescriptionKey: "Malformed GraphQL search response"])
        }
        let pageInfo = search["pageInfo"] as? [String: Any]
        return PRListPage(
            prs: parseGraphQLPRNodes(nodes),
            totalCount: (search["issueCount"] as? Int) ?? nodes.count,
            endCursor: pageInfo?["endCursor"] as? String,
            hasNextPage: (pageInfo?["hasNextPage"] as? Bool) ?? false
        )
    }

    /// The viewer's own PRs across every repository (newest activity first), for the Home page. Only cheap
    /// fields (~1.7s for 80 PRs); stats and CI come per repository from `fetchPREnrichment`.
    public func fetchMyPullRequests(open: Bool, token: String?) async throws -> [CrossRepoPullRequest] {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return [] }
        let query = """
        query($q: String!) {
          search(query: $q, type: ISSUE, first: 100) {
            nodes {
              ... on PullRequest {
                number title state isDraft url createdAt updatedAt totalCommentsCount
                headRefName headRefOid baseRefName
                author { login avatarUrl }
                repository { nameWithOwner }
              }
            }
          }
        }
        """
        let q = "is:pr author:@me archived:false \(open ? "is:open" : "is:closed") sort:updated-desc"
        let data = try await sendGraphQL(query: query, variables: ["q": q], token: token, actionName: "Load my pull requests")
        guard let search = data["search"] as? [String: Any], let nodes = search["nodes"] as? [[String: Any]] else {
            throw NSError(domain: "GitHubGraphQL", code: 422, userInfo: [NSLocalizedDescriptionKey: "Malformed GraphQL search response"])
        }
        let iso = ISO8601DateFormatter()
        return nodes.compactMap { node in
            guard let slug = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String,
                  let pr = parseGraphQLPRNodes([node]).first else { return nil }
            let updated = (node["updatedAt"] as? String).flatMap(iso.date(from:)) ?? pr.createdAt
            return CrossRepoPullRequest(repository: slug, pr: pr, updatedAt: updated)
        }
    }

    /// Diff stats, review decision and CI rollup counts for the given PRs, keyed by number.
    public func fetchPREnrichment(owner: String, repo: String, numbers: [Int], token: String?) async throws -> [Int: PullRequest] {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty, !numbers.isEmpty else { return [:] }
        let fields = """
        number title additions deletions changedFiles reviewDecision
        commits(last: 1) { nodes { commit { statusCheckRollup { state contexts {
          totalCount
          checkRunCountsByState { count state }
          statusContextCountsByState { count state }
        } } } } }
        """
        let aliases = numbers.map { "p\($0): pullRequest(number: \($0)) { \(fields) }" }.joined(separator: "\n")
        let query = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { \(aliases) } }"
        let data = try await sendGraphQL(query: query, variables: ["owner": owner, "name": repo], token: token, actionName: "Load PR status")
        guard let repository = data["repository"] as? [String: Any] else { return [:] }
        let nodes = repository.values.compactMap { $0 as? [String: Any] }
        return Dictionary(parseGraphQLPRNodes(nodes).map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Tab counts for every list filter in one request.
    /// With `author`, every tab except the "My …" ones is narrowed to that author, matching the list query.
    public func fetchPRTabCounts(owner: String, repo: String, author: String? = nil, token: String?) async throws -> [PRFilter: Int] {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return [:] }
        let filters: [(String, PRFilter)] = [("cMyOpen", .myOpen), ("cMyClosed", .myClosed), ("cOpen", .open),
                                             ("cClosed", .closed), ("cReviewNeeded", .reviewNeeded), ("cAll", .all)]
        let decls = filters.map { "$\($0.0): String!" }.joined(separator: ", ")
        let body = filters.map { "\($0.0): search(query: $\($0.0), type: ISSUE, first: 0) { issueCount }" }.joined(separator: "\n")
        var variables: [String: Any] = [:]
        for (key, filter) in filters {
            var q = buildSearchQuery(owner: owner, repo: repo, filter: filter)
            if let author, !author.isEmpty, filter != .myOpen, filter != .myClosed { q += " author:\(author)" }
            variables[key] = q
        }
        let data = try await sendGraphQL(query: "query(\(decls)) { \(body) }", variables: variables, token: token, actionName: "Load PR counts")
        var counts: [PRFilter: Int] = [:]
        for (key, filter) in filters {
            if let count = (data[key] as? [String: Any])?["issueCount"] as? Int { counts[filter] = count }
        }
        return counts
    }

    public func fetchPullRequestsServerFiltered(
        owner: String,
        repo: String,
        filter: PRFilter,
        token: String?
    ) async throws -> (prs: [PullRequest], counts: [PRFilter: Int]) {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return ([], [:])
        }

        do {
            return try await fetchPullRequestsFilteredGraphQL(owner: owner, repo: repo, filter: filter, token: token)
        } catch {
            if GitHubHTTP.isCancellation(error) { throw error }
            return try await fetchPullRequestsFilteredREST(owner: owner, repo: repo, filter: filter, token: token)
        }
    }

    private func fetchPullRequestsFilteredGraphQL(
        owner: String,
        repo: String,
        filter: PRFilter,
        token: String
    ) async throws -> (prs: [PullRequest], counts: [PRFilter: Int]) {
        let query = """
        query(
          $searchQuery: String!,
          $qMyOpen: String!,
          $qMyClosed: String!,
          $qOpen: String!,
          $qClosed: String!,
          $qReviewNeeded: String!,
          $qAll: String!
        ) {
          search(query: $searchQuery, type: ISSUE, first: 50) {
            issueCount
            nodes {
              ... on PullRequest {
                number
                title
                body
                state
                isDraft
                url
                createdAt
                changedFiles
                additions
                deletions
                totalCommentsCount
                reviewDecision
                headRefName
                headRefOid
                baseRefName
                author {
                  login
                  avatarUrl
                }
                commits(last: 1) {
                  nodes {
                    commit {
                      statusCheckRollup {
                        state
                        contexts {
                          totalCount
                          checkRunCountsByState {
                            count
                            state
                          }
                          statusContextCountsByState {
                            count
                            state
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
          cMyOpen: search(query: $qMyOpen, type: ISSUE, first: 0) { issueCount }
          cMyClosed: search(query: $qMyClosed, type: ISSUE, first: 0) { issueCount }
          cOpen: search(query: $qOpen, type: ISSUE, first: 0) { issueCount }
          cClosed: search(query: $qClosed, type: ISSUE, first: 0) { issueCount }
          cReviewNeeded: search(query: $qReviewNeeded, type: ISSUE, first: 0) { issueCount }
          cAll: search(query: $qAll, type: ISSUE, first: 0) { issueCount }
        }
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("GitXX-App", forHTTPHeaderField: "User-Agent")

        let payload: [String: Any] = [
            "query": query,
            "variables": [
                "searchQuery": buildSearchQuery(owner: owner, repo: repo, filter: filter),
                "qMyOpen": buildSearchQuery(owner: owner, repo: repo, filter: .myOpen),
                "qMyClosed": buildSearchQuery(owner: owner, repo: repo, filter: .myClosed),
                "qOpen": buildSearchQuery(owner: owner, repo: repo, filter: .open),
                "qClosed": buildSearchQuery(owner: owner, repo: repo, filter: .closed),
                "qReviewNeeded": buildSearchQuery(owner: owner, repo: repo, filter: .reviewNeeded),
                "qAll": buildSearchQuery(owner: owner, repo: repo, filter: .all)
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await GitHubHTTP.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "GitHubGraphQL", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "GraphQL request failed"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let searchDict = dataDict["search"] as? [String: Any],
              let nodes = searchDict["nodes"] as? [[String: Any]] else {
            throw NSError(domain: "GitHubGraphQL", code: 422, userInfo: [NSLocalizedDescriptionKey: "Malformed GraphQL search response"])
        }

        let prs = parseGraphQLPRNodes(nodes)

        var counts: [PRFilter: Int] = [:]
        if let c = dataDict["cMyOpen"] as? [String: Any], let count = c["issueCount"] as? Int {
            counts[.myOpen] = count
        }
        if let c = dataDict["cMyClosed"] as? [String: Any], let count = c["issueCount"] as? Int {
            counts[.myClosed] = count
        }
        if let c = dataDict["cOpen"] as? [String: Any], let count = c["issueCount"] as? Int {
            counts[.open] = count
        }
        if let c = dataDict["cClosed"] as? [String: Any], let count = c["issueCount"] as? Int {
            counts[.closed] = count
        }
        if let c = dataDict["cReviewNeeded"] as? [String: Any], let count = c["issueCount"] as? Int {
            counts[.reviewNeeded] = count
        }
        if let c = dataDict["cAll"] as? [String: Any], let count = c["issueCount"] as? Int {
            counts[.all] = count
        }

        if let currentSearchCount = searchDict["issueCount"] as? Int {
            counts[filter] = currentSearchCount
        } else {
            counts[filter] = max(counts[filter] ?? 0, prs.count)
        }

        return (prs, counts)
    }

    private func fetchPullRequestsFilteredREST(
        owner: String,
        repo: String,
        filter: PRFilter,
        token: String
    ) async throws -> (prs: [PullRequest], counts: [PRFilter: Int]) {
        let q = buildSearchQuery(owner: owner, repo: repo, filter: filter)
        guard let encodedQ = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(GitHubHost.api)/search/issues?q=\(encodedQ)&per_page=50&sort=updated&order=desc") else {
            throw NSError(domain: "GitHubAPI", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid GitHub repository search URL"])
        }

        let result = try await executeCachedGET(url: url, token: token)
        guard let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return ([], [:])
        }

        let totalCount = (json["total_count"] as? Int) ?? items.count
        let prs = try parseRESTPRs(data: try JSONSerialization.data(withJSONObject: items), repo: repo)
        var counts: [PRFilter: Int] = [:]
        counts[filter] = totalCount
        return (prs, counts)
    }

    public func fetchPullRequests(owner: String, repo: String, token: String?) async throws -> [PullRequest] {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return []
        }

        // 1. Try GraphQL first for full metadata (exact changedFiles, additions, deletions, reviewVerdict, ciStatus)
        do {
            let prs = try await fetchPullRequestsGraphQL(owner: owner, repo: repo, token: token)
            return prs
        } catch {
            // 2. Fallback to REST
            return try await fetchPullRequestsREST(owner: owner, repo: repo, token: token)
        }
    }

    public func fetchPullRequest(owner: String, repo: String, number: Int, token: String?) async throws -> PullRequest? {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              let url = URL(string: "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls/\(number)") else { return nil }
        let result = try await executeCachedGET(url: url, token: token)
        guard let object = try JSONSerialization.jsonObject(with: result.data) as? [String: Any] else { return nil }
        if object["number"] == nil, let message = object["message"] as? String {
            throw NSError(domain: "GitHubAPI", code: 404, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let wrapped = try JSONSerialization.data(withJSONObject: [object])
        return try parseRESTPRs(data: wrapped, repo: repo).first
    }

    private func fetchPullRequestsREST(owner: String, repo: String, token: String) async throws -> [PullRequest] {
        let urlString = "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls?state=all&per_page=50&sort=updated&direction=desc"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "GitHubAPI", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid GitHub repository URL for \(owner)/\(repo)."])
        }

        let result = try await executeCachedGET(url: url, token: token)
        return try parseRESTPRs(data: result.data, repo: repo)
    }

    private func fetchPullRequestsGraphQL(owner: String, repo: String, token: String) async throws -> [PullRequest] {
        let query = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            pullRequests(first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number
                title
                body
                state
                isDraft
                url
                createdAt
                changedFiles
                additions
                deletions
                totalCommentsCount
                reviewDecision
                headRefName
                headRefOid
                baseRefName
                author {
                  login
                  avatarUrl
                }
                commits(last: 1) {
                  nodes {
                    commit {
                      statusCheckRollup {
                        state
                        contexts {
                          totalCount
                          checkRunCountsByState {
                            count
                            state
                          }
                          statusContextCountsByState {
                            count
                            state
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("GitXX-App", forHTTPHeaderField: "User-Agent")

        let payload: [String: Any] = [
            "query": query,
            "variables": [
                "owner": owner,
                "name": repo
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await GitHubHTTP.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "GitHubGraphQL", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "GraphQL request failed"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let repoDict = dataDict["repository"] as? [String: Any],
              let prsDict = repoDict["pullRequests"] as? [String: Any],
              let nodes = prsDict["nodes"] as? [[String: Any]] else {
            throw NSError(domain: "GitHubGraphQL", code: 422, userInfo: [NSLocalizedDescriptionKey: "Malformed GraphQL response"])
        }

        return parseGraphQLPRNodes(nodes)
    }

    public func parseGraphQLPRNodes(_ nodes: [[String: Any]]) -> [PullRequest] {
        let isoFormatter = ISO8601DateFormatter()

        return nodes.compactMap { dict -> PullRequest? in
            guard let number = dict["number"] as? Int,
                  let title = dict["title"] as? String else {
                return nil
            }

            let body = (dict["body"] as? String) ?? ""
            let isDraft = (dict["isDraft"] as? Bool) ?? false
            let authorDict = dict["author"] as? [String: Any]
            let authorName = (authorDict?["login"] as? String) ?? "unknown"
            let authorAvatarUrl = authorDict?["avatarUrl"] as? String

            let headBranch = (dict["headRefName"] as? String) ?? "feature"
            let headSha = dict["headRefOid"] as? String
            let baseBranch = (dict["baseRefName"] as? String) ?? "main"
            let url = (dict["url"] as? String) ?? ""
            let createdAtStr = (dict["createdAt"] as? String) ?? ""
            let createdAt = isoFormatter.date(from: createdAtStr) ?? Date()

            let rawState = (dict["state"] as? String) ?? "OPEN"
            let state: PullRequestState
            if isDraft {
                state = .draft
            } else if rawState == "MERGED" {
                state = .merged
            } else if rawState == "CLOSED" {
                state = .closed
            } else {
                state = .open
            }

            let additions = (dict["additions"] as? Int) ?? 0
            let deletions = (dict["deletions"] as? Int) ?? 0
            let changedFiles = (dict["changedFiles"] as? Int) ?? 0
            let commentsCount = (dict["totalCommentsCount"] as? Int) ?? 0

            let reviewDecisionStr = dict["reviewDecision"] as? String
            let verdict: ReviewVerdict
            switch reviewDecisionStr {
            case "APPROVED": verdict = .approved
            case "CHANGES_REQUESTED": verdict = .changesRequested
            default: verdict = .pending
            }

            var ciStatus = "SUCCESS"
            var totalChecks = 0
            var passedChecks = 0
            if let commitsDict = dict["commits"] as? [String: Any],
               let commitNodes = commitsDict["nodes"] as? [[String: Any]],
               let firstNode = commitNodes.first,
               let commit = firstNode["commit"] as? [String: Any],
               let rollup = commit["statusCheckRollup"] as? [String: Any] {
                if let rollupState = rollup["state"] as? String {
                    switch rollupState.uppercased() {
                    case "SUCCESS": ciStatus = "SUCCESS"
                    case "FAILURE", "ERROR": ciStatus = "FAILURE"
                    case "PENDING", "EXPECTED": ciStatus = "PENDING"
                    default: ciStatus = "SUCCESS"
                    }
                }
                if let contexts = rollup["contexts"] as? [String: Any] {
                    totalChecks = (contexts["totalCount"] as? Int) ?? 0
                    var passed = 0
                    if let checkRunsByState = contexts["checkRunCountsByState"] as? [[String: Any]] {
                        for entry in checkRunsByState {
                            let st = (entry["state"] as? String)?.uppercased() ?? ""
                            let cnt = (entry["count"] as? Int) ?? 0
                            if st == "SUCCESS" || st == "SKIPPED" || st == "NEUTRAL" {
                                passed += cnt
                            }
                        }
                    }
                    if let statusByState = contexts["statusContextCountsByState"] as? [[String: Any]] {
                        for entry in statusByState {
                            let st = (entry["state"] as? String)?.uppercased() ?? ""
                            let cnt = (entry["count"] as? Int) ?? 0
                            if st == "SUCCESS" {
                                passed += cnt
                            }
                        }
                    }
                    passedChecks = passed
                }
            }

            var pr = PullRequest(
                number: number,
                title: title,
                body: body,
                state: state,
                isDraft: isDraft,
                authorName: authorName,
                authorAvatarUrl: authorAvatarUrl,
                headBranch: headBranch,
                baseBranch: baseBranch,
                headSha: headSha,
                url: url,
                createdAt: createdAt,
                commentsCount: commentsCount,
                additions: additions,
                deletions: deletions,
                changedFilesCount: changedFiles,
                reviewVerdict: verdict,
                comments: [],
                ciStatus: ciStatus,
                totalChecksCount: totalChecks,
                passedChecksCount: passedChecks
            )
            if let nodes = (dict["labels"] as? [String: Any])?["nodes"] as? [[String: Any]] {
                pr.labels = nodes.compactMap { node in
                    (node["name"] as? String).map { PRLabel(name: $0, color: (node["color"] as? String) ?? "8b949e") }
                }
            }
            if dict["reviewRequests"] != nil || dict["latestReviews"] != nil {
                pr.reviewers = Self.parseListReviewers(dict, author: authorName)
            }
            return pr
        }
    }

    /// Latest review per reviewer, then still-requested reviewers who haven't reviewed. The author's own
    /// comments on their PR aren't a review.
    private static func parseListReviewers(_ dict: [String: Any], author: String) -> [PRListReviewer] {
        var result: [PRListReviewer] = []
        var seen = Set<String>()
        for node in (dict["latestReviews"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [] {
            guard let who = node["author"] as? [String: Any], let login = who["login"] as? String,
                  who["__typename"] as? String != "Bot", login != author, !seen.contains(login.lowercased()) else { continue }
            let status: PRListReviewer.Status
            switch node["state"] as? String {
            case "APPROVED": status = .approved
            case "CHANGES_REQUESTED": status = .changesRequested
            case "COMMENTED": status = .commented
            default: continue
            }
            seen.insert(login.lowercased())
            result.append(PRListReviewer(login: login, avatarUrl: who["avatarUrl"] as? String, status: status))
        }
        for node in (dict["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [] {
            guard let who = node["requestedReviewer"] as? [String: Any],
                  let login = (who["login"] as? String) ?? (who["name"] as? String) else { continue }
            if seen.contains(login.lowercased()) {
                // Re-requested after reviewing: waiting on them again.
                result.removeAll { $0.login.lowercased() == login.lowercased() }
            }
            seen.insert(login.lowercased())
            result.append(PRListReviewer(login: login, avatarUrl: who["avatarUrl"] as? String, status: .requested))
        }
        return result
    }

    private func parseErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            return message
        }
        return nil
    }

    private func parseRESTPRs(data: Data, repo: String) throws -> [PullRequest] {
        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if let errorDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = errorDict["message"] as? String {
                throw NSError(domain: "GitHubAPI", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
            }
            return []
        }

        let isoFormatter = ISO8601DateFormatter()

        return jsonArray.compactMap { dict -> PullRequest? in
            guard let number = dict["number"] as? Int,
                  let title = dict["title"] as? String else {
                return nil
            }

            let body = (dict["body"] as? String) ?? ""
            let isDraft = (dict["draft"] as? Bool) ?? false
            let userDict = dict["user"] as? [String: Any]
            let authorName = (userDict?["login"] as? String) ?? "unknown"
            let authorAvatarUrl = userDict?["avatar_url"] as? String

            let headDict = dict["head"] as? [String: Any]
            let headBranch = (headDict?["ref"] as? String) ?? "feature"
            let headSha = headDict?["sha"] as? String

            let baseDict = dict["base"] as? [String: Any]
            let baseBranch = (baseDict?["ref"] as? String) ?? "main"

            let url = (dict["html_url"] as? String) ?? ""
            let createdAtStr = (dict["created_at"] as? String) ?? ""
            let createdAt = isoFormatter.date(from: createdAtStr) ?? Date()

            let rawState = (dict["state"] as? String) ?? "open"
            let mergedAt = dict["merged_at"] as? String

            let state: PullRequestState
            if isDraft {
                state = .draft
            } else if mergedAt != nil {
                state = .merged
            } else if rawState == "closed" {
                state = .closed
            } else {
                state = .open
            }

            let additions = (dict["additions"] as? Int) ?? 0
            let deletions = (dict["deletions"] as? Int) ?? 0
            let changedFiles = (dict["changed_files"] as? Int) ?? 0
            let commentsCount = (dict["comments"] as? Int) ?? 0

            return PullRequest(
                number: number,
                title: title,
                body: body,
                state: state,
                isDraft: isDraft,
                authorName: authorName,
                authorAvatarUrl: authorAvatarUrl,
                headBranch: headBranch,
                baseBranch: baseBranch,
                headSha: headSha,
                url: url,
                createdAt: createdAt,
                commentsCount: commentsCount,
                additions: additions,
                deletions: deletions,
                changedFilesCount: changedFiles,
                reviewVerdict: .pending,
                comments: [],
                ciStatus: "SUCCESS"
            )
        }
    }

    /// All changed files, 100 per page; pages after the first are fetched in parallel (GitHub caps this at 3,000).
    public func fetchPRFiles(owner: String, repo: String, prNumber: Int, expectedCount: Int = 0, token: String?) async throws -> [PRFileChange] {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return [] }
        let base = "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls/\(prNumber)/files?per_page=100"
        guard let url = URL(string: base) else { return [] }
        let first = parseFileChanges(try await executeCachedGET(url: url, token: token).data)
        guard first.count == 100 else { return first }

        let pages = min(30, max(2, Int((Double(expectedCount) / 100).rounded(.up))))
        var rest: [Int: [PRFileChange]] = [:]
        try await withThrowingTaskGroup(of: (Int, [PRFileChange]).self) { group in
            for page in 2...pages {
                group.addTask {
                    guard let url = URL(string: base + "&page=\(page)") else { return (page, []) }
                    return (page, await self.parseFileChanges(try await self.executeCachedGET(url: url, token: token).data))
                }
            }
            for try await (page, files) in group { rest[page] = files }
        }
        var all = first
        for page in 2...pages { all += rest[page] ?? [] }
        // expectedCount can be stale; keep paging sequentially while pages come back full.
        var page = pages
        while (rest[page]?.count ?? 0) == 100 && page < 30 {
            page += 1
            guard let url = URL(string: base + "&page=\(page)") else { break }
            let files = parseFileChanges(try await executeCachedGET(url: url, token: token).data)
            rest[page] = files
            all += files
        }
        return all
    }

    /// Parses a `files` array from the pulls or commits API.
    func parseFileChanges(_ data: Data) -> [PRFileChange] {
        let json = try? JSONSerialization.jsonObject(with: data)
        let jsonArray = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["files"] as? [[String: Any]]) ?? []
        return jsonArray.compactMap { dict -> PRFileChange? in
            guard let filename = dict["filename"] as? String else { return nil }
            let status = (dict["status"] as? String) ?? "modified"
            let additions = (dict["additions"] as? Int) ?? 0
            let deletions = (dict["deletions"] as? Int) ?? 0
            let changes = (dict["changes"] as? Int) ?? (additions + deletions)
            let patch = dict["patch"] as? String
            let previousFilename = dict["previous_filename"] as? String

            return PRFileChange(
                filename: filename,
                status: status,
                additions: additions,
                deletions: deletions,
                changes: changes,
                patch: patch,
                previousFilename: previousFilename
            )
        }
    }

    // MARK: - PR Full Conversation Timeline

    /// Private helper: GET a URL, log it, and return parsed JSON array.
    /// Returns nil for optional endpoints on error; throws for required endpoints.
    /// Every page of a list endpoint, merged into one JSON array. A full page means there may be more (the
    /// `Link` header isn't available for 304 cache hits); capped at 10 pages, 1,000 items.
    private func timelineFetchAllPages(urlStr: String, token: String, required: Bool = false) async throws -> Data? {
        let perPage = 100
        var all: [Any] = []
        for page in 1...10 {
            guard let data = try await timelineFetchData(urlStr: "\(urlStr)?per_page=\(perPage)&page=\(page)", token: token,
                                                         required: required && page == 1),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                if page == 1 { return nil }
                break
            }
            if page == 1 && items.count < perPage { return data }
            all += items
            if items.count < perPage { break }
        }
        return try? JSONSerialization.data(withJSONObject: all)
    }

    private func timelineFetchData(
        urlStr: String,
        token: String,
        required: Bool = false
    ) async throws -> Data? {
        guard let url = URL(string: urlStr) else { return nil }
        let startTime = DispatchTime.now()
        do {
            let result = try await executeCachedGET(url: url, token: token)
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0

            await GitHubAPILogger.shared.record(
                method: "GET",
                urlString: urlStr,
                statusCode: result.httpStatusCode,
                durationMs: durationMs,
                isCached304: result.isFromCache,
                responseSizeBytes: result.data.count
            )

            // Check if error status code
            if result.httpStatusCode >= 400 {
                var message = "HTTP \(result.httpStatusCode)"
                if let errDict = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
                   let errMsg = errDict["message"] as? String {
                    message = errMsg
                }
                if required {
                    throw NSError(domain: "GitHubAPI", code: result.httpStatusCode,
                                  userInfo: [NSLocalizedDescriptionKey: message])
                }
                return nil
            }

            return result.data
        } catch {
            if GitHubHTTP.isCancellation(error) { throw CancellationError() }
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
            await GitHubAPILogger.shared.record(
                method: "GET",
                urlString: urlStr,
                statusCode: 0,
                durationMs: durationMs,
                isCached304: false,
                responseSizeBytes: 0,
                errorDescription: error.localizedDescription
            )
            if required { throw error }
            return nil
        }
    }

    /// Fetches the complete PR conversation: issue comments + review events + inline
    /// code comment threads + commits, merged into a single chronological timeline.
    /// Throws if any core endpoint returns an HTTP error (401, 403, 404, 422, etc.).
    public func fetchPRTimeline(
        owner: String,
        repo: String,
        prNumber: Int,
        token: String?
    ) async throws -> [PRTimelineItem] {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw NSError(domain: "GitHubAPI", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "No GitHub token configured."])
        }

        let iso = ISO8601DateFormatter()
        let base = "\(GitHubHost.api)/repos/\(owner)/\(repo)"

        // --- Concurrent parallel fetching of all 4 timeline sources ---
        async let issueTask = timelineFetchAllPages(urlStr: "\(base)/issues/\(prNumber)/comments", token: token, required: true)
        async let reviewsTask = timelineFetchAllPages(urlStr: "\(base)/pulls/\(prNumber)/reviews", token: token)
        async let prCommentsTask = timelineFetchAllPages(urlStr: "\(base)/pulls/\(prNumber)/comments", token: token)
        async let commitsTask = timelineFetchAllPages(urlStr: "\(base)/pulls/\(prNumber)/commits", token: token)

        let (issueData, reviewsData, allReviewCommentsData, commitsData) = try await (issueTask, reviewsTask, prCommentsTask, commitsTask)

        let issueArray = issueData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        let reviewsArray = reviewsData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        let allReviewCommentsArray = allReviewCommentsData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        let commitsArray = commitsData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }

        // --- 1. Issue comments (general conversation) ---
        var issueComments: [PRComment] = []
        if let array = issueArray {
            for item in array {
                guard let idNum = item["id"],
                      let body = item["body"] as? String,
                      let createdStr = item["created_at"] as? String,
                      let createdAt = iso.date(from: createdStr) else { continue }
                let idStr: String
                if let n = idNum as? Int { idStr = String(n) } else { idStr = "\(idNum)" }
                let userDict = item["user"] as? [String: Any]
                let authorName = (userDict?["login"] as? String) ?? "unknown"
                let avatarUrl = userDict?["avatar_url"] as? String
                var comment = PRComment(
                    id: idStr,
                    authorName: authorName,
                    authorAvatarUrl: avatarUrl,
                    body: body,
                    createdAt: createdAt
                )
                comment.reactions = Self.parseReactionCounts(item["reactions"])
                issueComments.append(comment)
            }
        }

        // --- 2. Reviews ---
        var reviewEvents: [PRReviewEvent] = []
        if let array = reviewsArray {
            for item in array {
                guard let idNum = item["id"],
                      let state = item["state"] as? String,
                      let submittedStr = item["submitted_at"] as? String,
                      let submittedAt = iso.date(from: submittedStr) else { continue }
                let idStr: String
                if let n = idNum as? Int { idStr = String(n) } else { idStr = "\(idNum)" }
                let userDict = item["user"] as? [String: Any]
                let authorName = (userDict?["login"] as? String) ?? "unknown"
                let avatarUrl = userDict?["avatar_url"] as? String
                let body = (item["body"] as? String) ?? ""
                let htmlUrl = item["html_url"] as? String

                let upperState = state.uppercased()
                let shouldInclude = upperState == "APPROVED"
                    || upperState == "CHANGES_REQUESTED"
                    || upperState == "DISMISSED"
                    || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if shouldInclude {
                    reviewEvents.append(PRReviewEvent(
                        id: idStr,
                        authorName: authorName,
                        authorAvatarUrl: avatarUrl,
                        submittedAt: submittedAt,
                        state: upperState,
                        body: body,
                        htmlUrl: htmlUrl
                    ))
                }
            }
        }

        // --- 3. Inline review comments (threading) ---
        let allReviewComments = allReviewCommentsArray ?? []

        // Group into threads
        var threadMap: [String: PRReviewThread] = [:]
        var commentOrder: [String] = []
        var parsedReviewComments: [(comment: PRReviewComment, threadKey: String, isReply: Bool)] = []
        for item in allReviewComments {
            guard let idNum = item["id"],
                  let path = item["path"] as? String,
                  let body = item["body"] as? String,
                  let createdStr = item["created_at"] as? String,
                  let createdAt = iso.date(from: createdStr) else { continue }
            let idStr: String
            if let n = idNum as? Int { idStr = String(n) } else { idStr = "\(idNum)" }
            let userDict = item["user"] as? [String: Any]
            let authorName = (userDict?["login"] as? String) ?? "unknown"
            let avatarUrl = userDict?["avatar_url"] as? String
            let diffHunk = item["diff_hunk"] as? String
            let line = item["line"] as? Int ?? item["original_line"] as? Int
            let originalLine = item["original_line"] as? Int
            let inReplyToIdNum = item["in_reply_to_id"]
            let inReplyToId: String?
            if let n = inReplyToIdNum as? Int { inReplyToId = String(n) } else { inReplyToId = nil }
            let htmlUrl = item["html_url"] as? String
            let updatedStr = item["updated_at"] as? String
            let updatedAt = updatedStr.flatMap { iso.date(from: $0) }

            var comment = PRReviewComment(
                id: idStr,
                authorName: authorName,
                authorAvatarUrl: avatarUrl,
                body: body,
                createdAt: createdAt,
                updatedAt: updatedAt,
                path: path,
                line: line,
                originalLine: originalLine,
                diffHunk: diffHunk,
                inReplyToId: inReplyToId,
                htmlUrl: htmlUrl,
                side: item["side"] as? String
            )
            comment.reactions = Self.parseReactionCounts(item["reactions"])
            let threadKey = inReplyToId ?? idStr
            parsedReviewComments.append((comment: comment, threadKey: threadKey, isReply: inReplyToId != nil))
        }

        for entry in parsedReviewComments where !entry.isReply {
            let c = entry.comment
            threadMap[c.id] = PRReviewThread(
                id: c.id,
                path: c.path ?? "",
                line: c.line,
                diffHunk: c.diffHunk,
                comments: [c],
                isResolved: false
            )
            commentOrder.append(c.id)
        }
        for entry in parsedReviewComments where entry.isReply {
            let c = entry.comment
            if threadMap[entry.threadKey] != nil {
                threadMap[entry.threadKey]!.comments.append(c)
            } else {
                threadMap[c.id] = PRReviewThread(
                    id: c.id,
                    path: c.path ?? "",
                    line: c.line,
                    diffHunk: c.diffHunk,
                    comments: [c],
                    isResolved: false
                )
                commentOrder.append(c.id)
            }
        }

        // --- 4. Commits ---
        var commitEvents: [PRCommitEvent] = []
        if let array = commitsArray {
            for item in array {
                guard let sha = item["sha"] as? String else { continue }
                let commitDict = item["commit"] as? [String: Any]
                let message = (commitDict?["message"] as? String) ?? sha
                let authorDict = commitDict?["author"] as? [String: Any]
                let authorName: String
                if let login = (item["author"] as? [String: Any])?["login"] as? String {
                    authorName = login
                } else {
                    authorName = (authorDict?["name"] as? String) ?? "unknown"
                }
                let dateStr = (authorDict?["date"] as? String) ?? ""
                let authoredAt = iso.date(from: dateStr) ?? Date()
                commitEvents.append(PRCommitEvent(
                    id: sha,
                    sha: sha,
                    message: message,
                    authorName: authorName,
                    authoredAt: authoredAt
                ))
            }
        }

        // --- 5. Assemble ---
        var items: [PRTimelineItem] = []
        for comment in issueComments { items.append(.issueComment(comment)) }
        for review in reviewEvents { items.append(.reviewEvent(review)) }
        for threadId in commentOrder {
            if let thread = threadMap[threadId] { items.append(.reviewThread(thread)) }
        }
        if !commitEvents.isEmpty { items.append(.commitPushed(commitEvents)) }
        return items.sorted { $0.sortDate < $1.sortDate }
    }

    /// REST `reactions` rollup (`{"+1": 2, "heart": 1, …}`) with zero counts dropped.
    static func parseReactionCounts(_ raw: Any?) -> [String: Int]? {
        guard let dict = raw as? [String: Any] else { return nil }
        var counts: [String: Int] = [:]
        for key in PRReaction.allCases.map(\.rawValue) {
            if let n = dict[key] as? Int, n > 0 { counts[key] = n }
        }
        return counts
    }

    /// Adds the viewer's reaction, or removes it if they already reacted with that emoji. Returns true when
    /// the reaction is now present. `kind` is "issue" (conversation comment) or "review" (inline comment).
    public func toggleReaction(owner: String, repo: String, kind: String, commentId: String, content: PRReaction,
                               viewer: String, token: String?) async throws -> Bool {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw NSError(domain: "GitHubAPI", code: 401, userInfo: [NSLocalizedDescriptionKey: "No GitHub token configured."])
        }
        let path = kind == "review" ? "pulls/comments" : "issues/comments"
        let base = "\(GitHubHost.api)/repos/\(owner)/\(repo)/\(path)/\(commentId)/reactions"
        func request(_ url: String, method: String, body: [String: Any]? = nil) async throws -> (Data, Int) {
            guard let url = URL(string: url) else { throw URLError(.badURL) }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("GitXX-macOS-Client", forHTTPHeaderField: "User-Agent")
            if let body {
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await GitHubHTTP.session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 400 {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                throw NSError(domain: "GitHubAPI", code: status, userInfo: [NSLocalizedDescriptionKey: message ?? "HTTP \(status)"])
            }
            return (data, status)
        }
        let encoded = content.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? content.rawValue
        let (listData, _) = try await request("\(base)?content=\(encoded)&per_page=100", method: "GET")
        let existing = (try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]])?.first {
            (($0["user"] as? [String: Any])?["login"] as? String)?.caseInsensitiveCompare(viewer) == .orderedSame
        }
        if let id = existing?["id"] {
            _ = try await request("\(base)/\(id)", method: "DELETE")
            return false
        }
        _ = try await request(base, method: "POST", body: ["content": content.rawValue])
        return true
    }

    public func fetchRequiredCheckContexts(
        owner: String,
        repo: String,
        baseBranch: String,
        token: String?
    ) async -> Set<String> {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return [] }
        var contexts = Set<String>()

        // 1. Try modern repository rulesets endpoint: GET /repos/{owner}/{repo}/rules/branches/{branch}
        if let rulesUrl = URL(string: "\(GitHubHost.api)/repos/\(owner)/\(repo)/rules/branches/\(baseBranch)") {
            if let result = try? await executeCachedGET(url: rulesUrl, token: token),
               let rulesArray = try? JSONSerialization.jsonObject(with: result.data) as? [[String: Any]] {
                for rule in rulesArray {
                    if let type = rule["type"] as? String, type == "required_status_checks",
                       let params = rule["parameters"] as? [String: Any],
                       let reqChecks = params["required_status_checks"] as? [[String: Any]] {
                        for c in reqChecks {
                            if let ctx = c["context"] as? String {
                                contexts.insert(ctx.lowercased())
                            }
                        }
                    }
                }
            }
        }

        // 2. Try classic branch protection: GET /repos/{owner}/{repo}/branches/{branch}/protection/required_status_checks
        if contexts.isEmpty, let protUrl = URL(string: "\(GitHubHost.api)/repos/\(owner)/\(repo)/branches/\(baseBranch)/protection/required_status_checks") {
            if let result = try? await executeCachedGET(url: protUrl, token: token),
               let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
               let list = json["contexts"] as? [String] {
                for c in list {
                    contexts.insert(c.lowercased())
                }
            }
        }

        return contexts
    }

    public func fetchPRChecks(
        owner: String,
        repo: String,
        headSha: String?,
        baseBranch: String? = nil,
        token: String?
    ) async throws -> [PRCheckRun] {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              let sha = headSha, !sha.isEmpty else {
            return []
        }

        // Fetch required check contexts in parallel with checks
        let requiredContexts = await fetchRequiredCheckContexts(owner: owner, repo: repo, baseBranch: baseBranch ?? "main", token: token)

        var results: [PRCheckRun] = []
        let isoFormatter = ISO8601DateFormatter()

        // 1. Fetch GitHub Actions check-runs (Cached with ETag & 304 support)
        var checkRunPages: [[[String: Any]]] = []
        for page in 1...5 {
            guard let url = URL(string: "\(GitHubHost.api)/repos/\(owner)/\(repo)/commits/\(sha)/check-runs?filter=latest&per_page=100\(page > 1 ? "&page=\(page)" : "")"),
                  let result = try? await executeCachedGET(url: url, token: token),
                  let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
                  let runs = json["check_runs"] as? [[String: Any]] else { break }
            checkRunPages.append(runs)
            if runs.count < 100 || ((json["total_count"] as? Int) ?? 0) <= page * 100 { break }
        }
        if !checkRunPages.isEmpty {
            do {
                let checkRuns = checkRunPages.flatMap { $0 }

                for item in checkRuns {
                    let idVal = item["id"]
                    let idStr: String
                    if let num = idVal as? Int { idStr = String(num) }
                    else if let s = idVal as? String { idStr = s }
                    else { idStr = UUID().uuidString }

                    let name = (item["name"] as? String) ?? "Unnamed Check"
                    let status = (item["status"] as? String) ?? "completed"
                    let conclusion = item["conclusion"] as? String
                    let htmlUrl = item["html_url"] as? String

                    var startedDate: Date? = nil
                    if let startStr = item["started_at"] as? String {
                        startedDate = isoFormatter.date(from: startStr)
                    }

                    var completedDate: Date? = nil
                    if let compStr = item["completed_at"] as? String {
                        completedDate = isoFormatter.date(from: compStr)
                    }

                    let lowerName = name.lowercased()
                    let isRequired = requiredContexts.contains(lowerName)
                        || lowerName.contains("(required)")
                        || lowerName.contains("[required]")

                    // A re-run creates a second check run with the same name; keep only the newest.
                    if let existing = results.firstIndex(where: { $0.name == name }) {
                        if (results[existing].startedAt ?? .distantPast) >= (startedDate ?? .distantPast) { continue }
                        results.remove(at: existing)
                    }

                    var run = PRCheckRun(
                        id: idStr,
                        name: name,
                        status: status,
                        conclusion: conclusion,
                        isRequired: isRequired,
                        htmlUrl: htmlUrl,
                        startedAt: startedDate,
                        completedAt: completedDate
                    )
                    run.appName = (item["app"] as? [String: Any])?["name"] as? String
                    if let output = item["output"] as? [String: Any] {
                        run.outputTitle = output["title"] as? String
                        run.outputSummary = output["summary"] as? String
                    }
                    results.append(run)
                }
            }
        }

        // 2. Fetch commit status contexts (Cached with ETag & 304 support)
        if let statusUrl = URL(string: "\(GitHubHost.api)/repos/\(owner)/\(repo)/commits/\(sha)/status") {
            if let result = try? await executeCachedGET(url: statusUrl, token: token),
               let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
               let statuses = json["statuses"] as? [[String: Any]] {

                for st in statuses {
                    let idVal = st["id"]
                    let idStr = idVal != nil ? "\(idVal!)" : UUID().uuidString
                    let context = (st["context"] as? String) ?? (st["description"] as? String) ?? "CI Status"
                    let state = (st["state"] as? String) ?? "pending"
                    let targetUrl = st["target_url"] as? String

                    let conclusion: String
                    switch state {
                    case "success": conclusion = "success"
                    case "failure", "error": conclusion = "failure"
                    default: conclusion = "in_progress"
                    }

                    let lowerContext = context.lowercased()
                    let isRequired = requiredContexts.contains(lowerContext)
                        || lowerContext.contains("(required)")
                        || lowerContext.contains("[required]")

                    if !results.contains(where: { $0.name == context }) {
                        var run = PRCheckRun(
                            id: idStr,
                            name: context,
                            status: state == "pending" ? "in_progress" : "completed",
                            conclusion: conclusion,
                            isRequired: isRequired,
                            htmlUrl: targetUrl,
                            startedAt: (st["created_at"] as? String).flatMap { isoFormatter.date(from: $0) },
                            completedAt: state == "pending" ? nil : (st["updated_at"] as? String).flatMap { isoFormatter.date(from: $0) }
                        )
                        run.appName = ((st["creator"] as? [String: Any])?["login"] as? String).map { "Status · \($0)" } ?? "Commit status"
                        run.outputSummary = st["description"] as? String
                        results.append(run)
                    }
                }
            }
        }

        return results
    }

    /// Commits on a PR's branch, oldest first (GitHub returns at most 250).
    public func fetchPRCommits(owner: String, repo: String, prNumber: Int, token: String?) async throws -> [PRCommit] {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return [] }
        let iso = ISO8601DateFormatter()
        var commits: [PRCommit] = []
        for page in 1...3 {
            guard let url = URL(string: "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls/\(prNumber)/commits?per_page=100&page=\(page)") else { break }
            let data = try await executeCachedGET(url: url, token: token).data
            let items = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            for item in items {
                guard let sha = item["sha"] as? String, let commit = item["commit"] as? [String: Any] else { continue }
                let author = commit["author"] as? [String: Any]
                let user = item["author"] as? [String: Any]
                commits.append(PRCommit(
                    sha: sha,
                    message: (commit["message"] as? String) ?? "",
                    authorLogin: user?["login"] as? String,
                    authorName: (author?["name"] as? String) ?? (user?["login"] as? String) ?? "unknown",
                    authorAvatarUrl: user?["avatar_url"] as? String,
                    date: (author?["date"] as? String).flatMap { iso.date(from: $0) } ?? Date(),
                    htmlUrl: item["html_url"] as? String
                ))
            }
            if items.count < 100 { break }
        }
        return commits
    }

    /// Files changed by a single commit, in the same shape as PR files.
    public func fetchCommitFiles(owner: String, repo: String, sha: String, token: String?) async throws -> [PRFileChange] {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              let url = URL(string: "\(GitHubHost.api)/repos/\(owner)/\(repo)/commits/\(sha)?per_page=300") else { return [] }
        return parseFileChanges(try await executeCachedGET(url: url, token: token).data)
    }

    public struct PRMergeabilityInfo: Sendable {
        public let mergeable: Bool?
        public let mergeableState: String? // "clean", "blocked", "dirty", "unstable", "behind", "draft"
        public let rebaseable: Bool?
        public let isDraft: Bool
        public let headSha: String?
        public let title: String?
        public let body: String?

        public init(mergeable: Bool?, mergeableState: String?, rebaseable: Bool?, isDraft: Bool, headSha: String? = nil, title: String? = nil, body: String? = nil) {
            self.mergeable = mergeable
            self.mergeableState = mergeableState
            self.rebaseable = rebaseable
            self.isDraft = isDraft
            self.headSha = headSha
            self.title = title
            self.body = body
        }
    }

    /// Fetches PR mergeability, draft status, and mergeable_state directly from GitHub API
    public func fetchPRMergeability(
        owner: String,
        repo: String,
        prNumber: Int,
        token: String?
    ) async throws -> PRMergeabilityInfo {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return PRMergeabilityInfo(mergeable: nil, mergeableState: nil, rebaseable: nil, isDraft: false)
        }

        let urlString = "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls/\(prNumber)"
        guard let url = URL(string: urlString) else {
            return PRMergeabilityInfo(mergeable: nil, mergeableState: nil, rebaseable: nil, isDraft: false)
        }

        let result = try await executeCachedGET(url: url, token: token)
        guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            return PRMergeabilityInfo(mergeable: nil, mergeableState: nil, rebaseable: nil, isDraft: false)
        }

        let mergeable = json["mergeable"] as? Bool
        let mergeableState = json["mergeable_state"] as? String
        let rebaseable = json["rebaseable"] as? Bool
        let isDraft = (json["draft"] as? Bool) ?? false

        return PRMergeabilityInfo(
            mergeable: mergeable,
            mergeableState: mergeableState,
            rebaseable: rebaseable,
            isDraft: isDraft,
            headSha: (json["head"] as? [String: Any])?["sha"] as? String,
            title: json["title"] as? String,
            body: json.keys.contains("body") ? (json["body"] as? String ?? "") : nil
        )
    }

    /// Number of commits on `baseBranch` that the PR head doesn't contain yet (`behind_by` of the compare API).
    public func fetchBehindBy(owner: String, repo: String, baseBranch: String, headSha: String, token: String?) async throws -> Int? {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              let base = baseBranch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(GitHubHost.api)/repos/\(owner)/\(repo)/compare/\(base)...\(headSha)?per_page=1") else { return nil }
        let result = try await executeCachedGET(url: url, token: token)
        guard let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any] else { return nil }
        return json["behind_by"] as? Int
    }

    /// Updates PR branch with latest base branch commits (PUT /repos/{owner}/{repo}/pulls/{prNumber}/update-branch)
    public func updateBranch(
        owner: String,
        repo: String,
        prNumber: Int,
        token: String?
    ) async throws {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw NSError(domain: "GitHubAPI", code: 401, userInfo: [NSLocalizedDescriptionKey: "No GitHub token configured."])
        }

        let urlString = "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls/\(prNumber)/update-branch"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitXX-macOS-Client", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await GitHubHTTP.session.data(for: request)
        let httpRes = response as? HTTPURLResponse
        let statusCode = httpRes?.statusCode ?? 500

        guard statusCode == 202 || statusCode == 200 else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msg = (json?["message"] as? String) ?? "HTTP status \(statusCode)"
            throw NSError(domain: "GitHubAPI", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to update branch: \(msg)"])
        }

        await GitHubHTTPCache.shared.remove(for: "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls/\(prNumber)")
    }


    public func submitReview(
        owner: String,
        repo: String,
        prNumber: Int,
        verdict: ReviewVerdict,
        body: String,
        token: String?
    ) async throws {
        let reviewEvent: String
        switch verdict {
        case .approved: reviewEvent = "APPROVE"
        case .changesRequested: reviewEvent = "REQUEST_CHANGES"
        case .commented, .pending: reviewEvent = "COMMENT"
        }
        var payload: [String: Any] = ["event": reviewEvent]
        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["body"] = body
        }
        try await sendREST(
            method: "POST",
            path: "/repos/\(owner)/\(repo)/pulls/\(prNumber)/reviews",
            body: payload,
            token: token,
            actionName: "Submit review"
        )
        await invalidateTimelineCaches(owner: owner, repo: repo, prNumber: prNumber)
    }

    public func updatePullRequestDescription(
        owner: String,
        repo: String,
        prNumber: Int,
        body: String,
        token: String?
    ) async throws {
        guard let token = token, !token.isEmpty else {
            return
        }

        let urlString = "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls/\(prNumber)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitXX-macOS-Client", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = ["body": body]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let startTime = DispatchTime.now()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await GitHubHTTP.session.data(for: request)
        } catch {
            if GitHubHTTP.isCancellation(error) { throw CancellationError() }
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
            await GitHubAPILogger.shared.record(
                method: "PATCH",
                urlString: urlString,
                statusCode: 0,
                durationMs: durationMs,
                isCached304: false,
                responseSizeBytes: 0,
                errorDescription: error.localizedDescription
            )
            throw error
        }

        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
        let httpRes = response as? HTTPURLResponse
        let statusCode = httpRes?.statusCode ?? 200
        let rem = httpRes?.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init)
        let lim = httpRes?.value(forHTTPHeaderField: "x-ratelimit-limit").flatMap(Int.init)
        var resetDate: Date? = nil
        if let resetStr = httpRes?.value(forHTTPHeaderField: "x-ratelimit-reset"),
           let resetEpoch = Double(resetStr) {
            resetDate = Date(timeIntervalSince1970: resetEpoch)
        }

        await GitHubAPILogger.shared.record(
            method: "PATCH",
            urlString: urlString,
            statusCode: statusCode,
            durationMs: durationMs,
            rateLimitRemaining: rem,
            rateLimitLimit: lim,
            rateLimitReset: resetDate,
            isCached304: false,
            responseSizeBytes: data.count,
            errorDescription: statusCode >= 400 ? String(data: data, encoding: .utf8) : nil
        )

        if statusCode >= 400 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw NSError(domain: "GitHubAPI", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to update PR description: \(errorMsg)"])
        }

        // Invalidate cached pulls list and single pull response
        await GitHubHTTPCache.shared.remove(for: "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls?state=all&per_page=50")
        await GitHubHTTPCache.shared.remove(for: urlString)
    }

    public enum MergeMethod: String, Sendable, CaseIterable {
        case merge = "merge"
        case squash = "squash"
        case rebase = "rebase"

        public var displayName: String {
            switch self {
            case .merge: return "Create a merge commit"
            case .squash: return "Squash and merge"
            case .rebase: return "Rebase and merge"
            }
        }

        public var description: String {
            switch self {
            case .merge: return "All commits from this branch will be added to the base branch via a merge commit."
            case .squash: return "The commits will be combined into a single commit in the base branch."
            case .rebase: return "The commits from this branch will be rebased and added to the base branch."
            }
        }
    }

    public struct MergeResult: Sendable {
        public let sha: String
        public let merged: Bool
        public let message: String

        public init(sha: String, merged: Bool, message: String) {
            self.sha = sha
            self.merged = merged
            self.message = message
        }
    }

    /// Merges a pull request using the GitHub REST API (PUT /repos/{owner}/{repo}/pulls/{prNumber}/merge)
    public func mergePullRequest(
        owner: String,
        repo: String,
        prNumber: Int,
        commitTitle: String? = nil,
        commitMessage: String? = nil,
        mergeMethod: MergeMethod = .merge,
        token: String?
    ) async throws -> MergeResult {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw NSError(domain: "GitHubAPI", code: 401, userInfo: [NSLocalizedDescriptionKey: "No GitHub token configured."])
        }

        let urlString = "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls/\(prNumber)/merge"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "GitHubAPI", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid merge URL."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitXX-macOS-Client", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "merge_method": mergeMethod.rawValue
        ]
        if let title = commitTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            payload["commit_title"] = title
        }
        if let msg = commitMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty {
            payload["commit_message"] = msg
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let startTime = DispatchTime.now()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await GitHubHTTP.session.data(for: request)
        } catch {
            if GitHubHTTP.isCancellation(error) { throw CancellationError() }
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
            await GitHubAPILogger.shared.record(
                method: "PUT",
                urlString: urlString,
                statusCode: 0,
                durationMs: durationMs,
                isCached304: false,
                responseSizeBytes: 0,
                errorDescription: error.localizedDescription
            )
            throw error
        }

        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
        let httpRes = response as? HTTPURLResponse
        let statusCode = httpRes?.statusCode ?? 500

        await GitHubAPILogger.shared.record(
            method: "PUT",
            urlString: urlString,
            statusCode: statusCode,
            durationMs: durationMs,
            isCached304: false,
            responseSizeBytes: data.count,
            errorDescription: statusCode >= 400 ? String(data: data, encoding: .utf8) : nil
        )

        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let message = (json["message"] as? String) ?? ""

        guard statusCode == 200 else {
            let errorMsg = message.isEmpty ? "HTTP error \(statusCode)" : message
            throw NSError(domain: "GitHubAPI", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Merge failed: \(errorMsg)"])
        }

        let sha = (json["sha"] as? String) ?? ""
        let merged = (json["merged"] as? Bool) ?? true

        // Invalidate cached PR listings and details
        await GitHubHTTPCache.shared.remove(for: "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls?state=all&per_page=50")
        await GitHubHTTPCache.shared.remove(for: "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls/\(prNumber)")

        return MergeResult(sha: sha, merged: merged, message: message)
    }

    /// Updates PR state to "closed" or "open" (PATCH /repos/{owner}/{repo}/pulls/{prNumber})
    public func updatePullRequestState(
        owner: String,
        repo: String,
        prNumber: Int,
        state: String,
        token: String?
    ) async throws {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw NSError(domain: "GitHubAPI", code: 401, userInfo: [NSLocalizedDescriptionKey: "No GitHub token configured."])
        }

        let urlString = "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls/\(prNumber)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitXX-macOS-Client", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = ["state": state]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let startTime = DispatchTime.now()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await GitHubHTTP.session.data(for: request)
        } catch {
            if GitHubHTTP.isCancellation(error) { throw CancellationError() }
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
            await GitHubAPILogger.shared.record(
                method: "PATCH",
                urlString: urlString,
                statusCode: 0,
                durationMs: durationMs,
                isCached304: false,
                responseSizeBytes: 0,
                errorDescription: error.localizedDescription
            )
            throw error
        }

        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
        let httpRes = response as? HTTPURLResponse
        let statusCode = httpRes?.statusCode ?? 500

        await GitHubAPILogger.shared.record(
            method: "PATCH",
            urlString: urlString,
            statusCode: statusCode,
            durationMs: durationMs,
            isCached304: false,
            responseSizeBytes: data.count,
            errorDescription: statusCode >= 400 ? String(data: data, encoding: .utf8) : nil
        )

        guard statusCode == 200 else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errorMsg = (json?["message"] as? String) ?? "HTTP error \(statusCode)"
            throw NSError(domain: "GitHubAPI", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to \(state) pull request: \(errorMsg)"])
        }

        await GitHubHTTPCache.shared.remove(for: "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls?state=all&per_page=50")
        await GitHubHTTPCache.shared.remove(for: urlString)
    }

    public func createPullRequest(
        owner: String,
        repo: String,
        title: String,
        body: String,
        headBranch: String,
        baseBranch: String,
        isDraft: Bool,
        token: String?
    ) async throws -> PullRequest {
        guard let token = token, !token.isEmpty else {
            // Local simulation response
            return PullRequest(
                number: Int.random(in: 100...999),
                title: title,
                body: body,
                state: isDraft ? .draft : .open,
                isDraft: isDraft,
                authorName: "you",
                headBranch: headBranch,
                baseBranch: baseBranch,
                createdAt: Date(),
                additions: 12,
                deletions: 3,
                changedFilesCount: 2
            )
        }

        let url = URL(string: "\(GitHubHost.api)/repos/\(owner)/\(repo)/pulls")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GitXX-macOS-Client", forHTTPHeaderField: "User-Agent")

        let payload: [String: Any] = [
            "title": title,
            "body": body,
            "head": headBranch,
            "base": baseBranch,
            "draft": isDraft
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let startTime = DispatchTime.now()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await GitHubHTTP.session.data(for: request)
        } catch {
            if GitHubHTTP.isCancellation(error) { throw CancellationError() }
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
            await GitHubAPILogger.shared.record(
                method: "POST",
                urlString: url.absoluteString,
                statusCode: 0,
                durationMs: durationMs,
                isCached304: false,
                responseSizeBytes: 0,
                errorDescription: error.localizedDescription
            )
            throw error
        }

        let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
        let httpRes = response as? HTTPURLResponse
        let statusCode = httpRes?.statusCode ?? 200
        let rem = httpRes?.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init)
        let lim = httpRes?.value(forHTTPHeaderField: "x-ratelimit-limit").flatMap(Int.init)
        var resetDate: Date? = nil
        if let resetStr = httpRes?.value(forHTTPHeaderField: "x-ratelimit-reset"),
           let resetEpoch = Double(resetStr) {
            resetDate = Date(timeIntervalSince1970: resetEpoch)
        }

        await GitHubAPILogger.shared.record(
            method: "POST",
            urlString: url.absoluteString,
            statusCode: statusCode,
            durationMs: durationMs,
            rateLimitRemaining: rem,
            rateLimitLimit: lim,
            rateLimitReset: resetDate,
            isCached304: false,
            responseSizeBytes: data.count,
            errorDescription: statusCode >= 400 ? String(data: data, encoding: .utf8) : nil
        )

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let number = json["number"] as? Int {
            return PullRequest(
                number: number,
                title: title,
                body: body,
                state: isDraft ? .draft : .open,
                isDraft: isDraft,
                authorName: "you",
                headBranch: headBranch,
                baseBranch: baseBranch
            )
        }

        var reasons: [String] = []
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for item in json["errors"] as? [[String: Any]] ?? [] {
                if let message = item["message"] as? String {
                    reasons.append(message)
                } else if let field = item["field"] as? String, let code = item["code"] as? String {
                    reasons.append("\(field) \(code)")
                }
            }
            if reasons.isEmpty, let message = json["message"] as? String { reasons.append(message) }
        }
        let message = reasons.isEmpty ? (String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)") : reasons.joined(separator: "; ")
        throw NSError(domain: "GitHubAPI", code: statusCode >= 400 ? statusCode : 400, userInfo: [NSLocalizedDescriptionKey: message])
    }

    public func demoPullRequests(repo: String = "") -> [PullRequest] {
        return [
            PullRequest(
                number: 142,
                title: "feat(diff): Add Metal-accelerated line rendering and split view",
                body: "This PR introduces a high-performance native diff viewer supporting both side-by-side (split) and unified modes.\n\n### Changes\n- Virtualized line rendering\n- Zero allocations during 60/120fps scrolling\n- Keyboard shortcuts for line jumps",
                state: .open,
                isDraft: false,
                authorName: "octocat",
                headBranch: "feat/fast-diff",
                baseBranch: "main",
                url: "https://github.com/octocat/gitxx/pull/142",
                createdAt: Date().addingTimeInterval(-3600 * 4),
                commentsCount: 6,
                additions: 412,
                deletions: 88,
                changedFilesCount: 5,
                reviewVerdict: .pending,
                comments: [
                    PRComment(authorName: "alex_dev", body: "Could we ensure the line numbers are monospace aligned when additions exceed 10k?", createdAt: Date().addingTimeInterval(-3600 * 3)),
                    PRComment(authorName: "sarah_q", body: "Tested locally on macOS Sequoia, smooth 120fps. LGTM once lint passes!", createdAt: Date().addingTimeInterval(-3600 * 1))
                ],
                ciStatus: "SUCCESS",
                totalChecksCount: 12,
                passedChecksCount: 12
            ),
            PullRequest(
                number: 139,
                title: "perf(graphql): Implement rate-limit aware batch querying",
                body: "Eliminates REST N+1 requests by fetching PR status, checks, and review comments in a single GraphQL query.",
                state: .open,
                isDraft: false,
                authorName: "hubot",
                headBranch: "perf/graphql-batching",
                baseBranch: "main",
                url: "https://github.com/octocat/gitxx/pull/139",
                createdAt: Date().addingTimeInterval(-3600 * 28),
                commentsCount: 3,
                additions: 120,
                deletions: 340,
                changedFilesCount: 3,
                reviewVerdict: .approved,
                comments: [
                    PRComment(authorName: "octocat", body: "Approved! Rate limit cost decreased by 85%.", createdAt: Date().addingTimeInterval(-3600 * 12))
                ],
                ciStatus: "SUCCESS",
                totalChecksCount: 5,
                passedChecksCount: 5
            ),
            PullRequest(
                number: 135,
                title: "fix(keybindings): Fix ⌘Enter shortcut collision in commit box",
                body: "Ensures pressing ⌘Enter inside multi-line commit descriptions triggers commit immediately without inserting a newline.",
                state: .open,
                isDraft: false,
                authorName: "dev_dan",
                headBranch: "fix/keybindings",
                baseBranch: "main",
                url: "https://github.com/octocat/gitxx/pull/135",
                createdAt: Date().addingTimeInterval(-3600 * 48),
                commentsCount: 1,
                additions: 14,
                deletions: 4,
                changedFilesCount: 1,
                reviewVerdict: .changesRequested,
                comments: [
                    PRComment(authorName: "tech_lead", body: "Please add a test verifying the shortcut is disabled when no files are staged.", createdAt: Date().addingTimeInterval(-3600 * 20))
                ],
                ciStatus: "FAILURE",
                totalChecksCount: 3,
                passedChecksCount: 2
            )
        ]
    }
}

public struct CrossRepoPullRequest: Identifiable, Hashable, Codable, Sendable {
    public let repository: String
    public var pr: PullRequest
    public let updatedAt: Date
    public var id: String { "\(repository)#\(pr.number)" }
    public var repoName: String { repository.split(separator: "/").last.map(String.init) ?? repository }
}
