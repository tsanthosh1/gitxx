import SwiftUI

/// Settings for the Slack review-requests integration. Not secret, so UserDefaults.
struct ReviewRequestsSettings: Codable, Equatable {
    var serverID: UUID?
    var searchTool = ""
    var channels: [String] = []
    var lookbackDays = 14
    var identifiers: [String] = []
    var onlyMentions = true
    var queryTemplate = ReviewRequestsSettings.defaultTemplate
    var includeMine = false

    static let defaultTemplate = "in:#{channel} after:{after}"
    private static let key = "gitxx_review_requests_settings"

    static func load() -> ReviewRequestsSettings {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? ReviewRequestsSettings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Finds GitHub PR links posted to Slack channels (via a Slack MCP server's search tool),
/// keeps the ones addressed to you, and classifies them with live GitHub review state.
@MainActor
final class ReviewRequestsStore: ObservableObject {
    static let shared = ReviewRequestsStore()

    @Published var settings = ReviewRequestsSettings.load() { didSet { if settings != oldValue { settings.save() } } }
    @Published private(set) var items: [ReviewRequestItem] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var progress = ""
    @Published var errorMessage: String?
    @Published private(set) var rawOutput = ""
    @Published private(set) var viewerLogin: String?

    /// Supplied by the main window so the integration uses the signed-in GitHub account.
    var githubToken: @MainActor () -> String? = { nil }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GitXX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("review-requests.json")
    }

    private struct Cache: Codable { var items: [ReviewRequestItem]; var refreshed: Date; var viewer: String? }

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            items = cache.items
            lastRefresh = cache.refreshed
            viewerLogin = cache.viewer
        }
    }

    var server: MCPServerConfig? { IntegrationsStore.shared.server(settings.serverID) }

    func counts(_ status: ReviewRequestStatus) -> Int { items.filter { $0.status == status }.count }

    /// The search tool: the configured one, else one named like search/messages taking a query.
    func resolveSearchTool() -> MCPTool? {
        guard let id = settings.serverID else { return nil }
        let tools = IntegrationsStore.shared.tools[id] ?? []
        if !settings.searchTool.isEmpty, let tool = tools.first(where: { $0.name == settings.searchTool }) { return tool }
        let candidates = tools.filter { $0.name.lowercased().contains("search") && Self.queryParameter($0) != nil }
        return candidates.first { $0.name.lowercased().contains("message") }
            ?? candidates.first { !$0.name.lowercased().contains("user") && !$0.name.lowercased().contains("channel") }
            ?? candidates.first
    }

    private static func queryParameter(_ tool: MCPTool) -> String? {
        let names = tool.parameterNames
        return ["query", "q", "search_query", "search", "text", "keywords"].first { names.contains($0) }
    }

    // MARK: Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        guard let server else { errorMessage = "Choose a Slack MCP server in this page's settings."; return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false; progress = "" }

        let store = IntegrationsStore.shared
        if store.status[server.id] != .connected {
            progress = "Connecting to \(server.name)…"
            guard await store.connect(server.id) else {
                errorMessage = store.status[server.id] == .needsSignIn
                    ? "Sign in to \(server.name) first (Integrations → MCP Servers)."
                    : "Couldn't connect to \(server.name): \(store.status[server.id]?.label ?? "")"
                return
            }
        }
        guard let tool = resolveSearchTool(), let queryParam = Self.queryParameter(tool) else {
            errorMessage = "\(server.name) has no search tool that takes a query. Pick one in settings."
            return
        }

        var found: [String: ReviewRequestItem] = [:]
        var raw: [String] = []
        let channels = settings.queryTemplate.contains("{channel}") ? settings.channels : [""]
        guard !channels.isEmpty else { errorMessage = "Add at least one Slack channel in settings."; return }
        for channel in channels {
            let query = buildQuery(channel: channel)
            progress = "Searching Slack: \(query)"
            var cursor: String?
            for _ in 0..<5 {
                var args: [String: Any] = [queryParam: query]
                if let (name, value) = Self.limitArgument(tool) { args[name] = value }
                if let cursor, let name = ["cursor", "next_cursor", "page_cursor"].first(where: tool.parameterNames.contains) { args[name] = cursor }
                let result: MCPCallResult
                do {
                    result = try await store.call(server: server.id, tool: tool.name, arguments: args)
                } catch {
                    errorMessage = "Slack search failed: \(error.localizedDescription)"
                    rawOutput = raw.joined(separator: "\n\n---\n\n")
                    return
                }
                raw.append("# \(tool.name) \(query)\n" + result.text)
                if result.isError { errorMessage = "Slack search returned an error: \(result.text.prefix(300))"; break }
                for mention in SlackPRMentionParser.parse(result.text, channel: channel.isEmpty ? nil : channel) {
                    guard !settings.onlyMentions || settings.identifiers.isEmpty || mentionsMe(mention.context) else { continue }
                    let existing = found[mention.item.id]
                    // Keep the newest request for a PR.
                    if existing == nil || (mention.item.postedAt ?? .distantPast) > (existing?.postedAt ?? .distantPast) {
                        found[mention.item.id] = mention.item
                    }
                }
                cursor = SlackPRMentionParser.nextCursor(result.text)
                if cursor == nil || !tool.parameterNames.contains(where: { $0.contains("cursor") }) { break }
            }
        }
        rawOutput = raw.joined(separator: "\n\n---\n\n")

        progress = "Checking \(found.count) pull request\(found.count == 1 ? "" : "s") on GitHub…"
        var list = Array(found.values)
        if let token = githubToken() ?? GitHubAPIService.getGitHubCLIToken() {
            do {
                let (viewer, statuses) = try await PRReviewStatusFetcher.fetch(list, token: token)
                viewerLogin = viewer
                list = statuses
            } catch {
                errorMessage = "Found \(list.count) PRs, but GitHub status failed: \(error.localizedDescription)"
            }
        } else {
            errorMessage = "Sign in to GitHub in GitXX to see each PR's status."
        }
        items = list.sorted { ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast) }
        lastRefresh = Date()
        if let data = try? JSONEncoder().encode(Cache(items: items, refreshed: Date(), viewer: viewerLogin)) {
            try? data.write(to: Self.cacheURL)
        }
    }

    func buildQuery(channel: String) -> String {
        let after = Calendar.current.date(byAdding: .day, value: -max(1, settings.lookbackDays), to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = channel.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        return settings.queryTemplate
            .replacingOccurrences(of: "{channel}", with: name)
            .replacingOccurrences(of: "{after}", with: formatter.string(from: after))
            .replacingOccurrences(of: "{me}", with: settings.identifiers.first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func mentionsMe(_ text: String) -> Bool {
        let lower = text.lowercased()
        return settings.identifiers.contains { id in
            let needle = id.trimmingCharacters(in: .whitespaces).lowercased()
            guard !needle.isEmpty else { return false }
            return lower.contains(needle) || lower.contains("@" + needle.trimmingCharacters(in: CharacterSet(charactersIn: "@")))
        }
    }

    private static func limitArgument(_ tool: MCPTool) -> (String, Int)? {
        guard let name = ["limit", "count", "max_results", "page_size", "per_page"].first(where: tool.parameterNames.contains) else { return nil }
        let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8))) as? [String: Any]
        let maximum = ((schema?["properties"] as? [String: Any])?[name] as? [String: Any])?["maximum"] as? Int
        return (name, min(100, maximum ?? 50))
    }

    /// Asks the server's profile/auth tool who you are and adds the Slack user id and handle it reports.
    func detectIdentity() async -> String {
        guard let server, let tools = IntegrationsStore.shared.tools[server.id] else { return "Connect the server first." }
        let tool = tools.first { t in
            let n = t.name.lowercased()
            return (n.contains("profile") || n.contains("whoami") || n.contains("auth_test") || n.contains("current_user") || n.hasSuffix("_me"))
                && t.parameterNames.allSatisfy { !Self.isRequired($0, in: t) }
        }
        guard let tool else { return "\(server.name) has no profile tool; add your Slack user ID (e.g. U0123ABCD) and @handle manually." }
        do {
            let result = try await IntegrationsStore.shared.call(server: server.id, tool: tool.name, arguments: [:])
            var found: [String] = []
            if let range = result.text.range(of: #"\bU[A-Z0-9]{8,11}\b"#, options: .regularExpression) { found.append(String(result.text[range])) }
            for key in ["display_name", "real_name", "name", "username", "handle"] {
                let pattern = "\"?\(key)\"?\\s*[:=]\\s*\"?([^\",\\n}]+)"
                if let match = result.text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                    let value = String(result.text[match]).replacingOccurrences(of: #"^\"?\w+\"?\s*[:=]\s*\"?"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty, value.count < 40 { found.append(value) }
                    break
                }
            }
            let added = found.filter { f in !settings.identifiers.contains { $0.caseInsensitiveCompare(f) == .orderedSame } }
            settings.identifiers += added
            return added.isEmpty ? "No new identifiers found in \(tool.name)'s reply." : "Added " + added.joined(separator: ", ")
        } catch {
            return "\(tool.name) failed: \(error.localizedDescription)"
        }
    }

    private static func isRequired(_ name: String, in tool: MCPTool) -> Bool {
        let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8))) as? [String: Any]
        return (schema?["required"] as? [String] ?? []).contains(name)
    }
}

// MARK: - GitHub status

enum PRReviewStatusFetcher {
    private struct Failure: LocalizedError { let errorDescription: String? }

    static func fetch(_ items: [ReviewRequestItem], token: String) async throws -> (String?, [ReviewRequestItem]) {
        let viewer = try await viewerLogin(token: token)
        var output: [ReviewRequestItem] = []
        for chunk in stride(from: 0, to: items.count, by: 25).map({ Array(items[$0..<min($0 + 25, items.count)]) }) {
            var query = "query {\n"
            for (i, item) in chunk.enumerated() {
                query += """
                p\(i): repository(owner: "\(item.owner)", name: "\(item.repo)") { pullRequest(number: \(item.number)) {
                  title state isDraft updatedAt additions deletions author { login }
                  reviews(last: 30, author: "\(viewer)") { nodes { state submittedAt } }
                  commits(last: 1) { nodes { commit { committedDate } } }
                } }

                """
            }
            query += "}"
            let data = try await post(["query": query], token: token)
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let results = root?["data"] as? [String: Any] ?? [:]
            for (i, var item) in chunk.enumerated() {
                if let pr = (results["p\(i)"] as? [String: Any])?["pullRequest"] as? [String: Any] {
                    apply(pr, to: &item, viewer: viewer)
                } else {
                    item.status = .unknown
                }
                output.append(item)
            }
        }
        return (viewer, output)
    }

    private static func apply(_ pr: [String: Any], to item: inout ReviewRequestItem, viewer: String) {
        let iso = ISO8601DateFormatter()
        item.title = pr["title"] as? String
        item.state = pr["state"] as? String
        item.isDraft = pr["isDraft"] as? Bool ?? false
        item.updatedAt = (pr["updatedAt"] as? String).flatMap(iso.date)
        item.additions = pr["additions"] as? Int
        item.deletions = pr["deletions"] as? Int
        item.author = (pr["author"] as? [String: Any])?["login"] as? String
        let commits = ((pr["commits"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        item.lastCommitAt = ((commits.last?["commit"] as? [String: Any])?["committedDate"] as? String).flatMap(iso.date)

        let reviews = ((pr["reviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let submitted = reviews.filter { ($0["state"] as? String) != "PENDING" }
        // A verdict (approve / request changes / dismissed) outranks later plain comments.
        let verdict = submitted.last { ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains($0["state"] as? String ?? "") } ?? submitted.last
        item.myReview = verdict?["state"] as? String
        item.myReviewAt = (submitted.last?["submittedAt"] as? String).flatMap(iso.date)
        item.changedSinceMyReview = item.myReviewAt.map { reviewed in (item.lastCommitAt ?? .distantPast) > reviewed } ?? false

        if item.state == "MERGED" {
            item.status = .merged
        } else if item.state == "CLOSED" {
            item.status = .closed
        } else if item.author?.caseInsensitiveCompare(viewer) == .orderedSame {
            item.status = .mine
        } else {
            switch item.myReview {
            case "APPROVED": item.status = .approved
            case "CHANGES_REQUESTED", "COMMENTED": item.status = item.changedSinceMyReview ? .pending : .notApproved
            default: item.status = .pending
            }
        }
    }

    private static func viewerLogin(token: String) async throws -> String {
        let data = try await post(["query": "query { viewer { login } }"], token: token)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let login = ((root["data"] as? [String: Any])?["viewer"] as? [String: Any])?["login"] as? String else {
            throw Failure(errorDescription: "GitHub didn't return your login.")
        }
        return login
    }

    private static func post(_ body: [String: Any], token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!, timeoutInterval: 40)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("GitXX-macOS-Client", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure(errorDescription: "GitHub HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }
}
