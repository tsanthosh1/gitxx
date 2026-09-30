import SwiftUI

/// MCP servers the user connected, their live connections and tools. Integrations (Slack review requests…)
/// and the assistant both call tools through here.
@MainActor
public final class IntegrationsStore: ObservableObject {
    public static let shared = IntegrationsStore()

    public enum Status: Equatable {
        case idle, connecting, connected, needsSignIn, failed(String)

        var label: String {
            switch self {
            case .idle: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .needsSignIn: return "Sign-in required"
            case .failed(let message): return message
            }
        }
    }

    @Published public private(set) var servers: [MCPServerConfig] = []
    @Published public private(set) var status: [UUID: Status] = [:]
    @Published public private(set) var tools: [UUID: [MCPTool]] = [:]
    @Published public private(set) var signingIn: UUID?

    private var clients: [UUID: MCPClient] = [:]
    private var resourceMetadata: [UUID: String] = [:]
    private static let account = "servers"

    private init() {
        if let data = MCPSecretStore.load(account: Self.account),
           let list = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            servers = list
        }
    }

    // MARK: Configuration

    public func server(_ id: UUID?) -> MCPServerConfig? { servers.first { $0.id == id } }

    public func upsert(_ config: MCPServerConfig) {
        if let i = servers.firstIndex(where: { $0.id == config.id }) {
            servers[i] = config
        } else {
            servers.append(config)
        }
        persist()
        disconnect(config.id)
    }

    public func remove(_ id: UUID) {
        disconnect(id)
        servers.removeAll { $0.id == id }
        MCPOAuthTokens.delete(id)
        status[id] = nil
        tools[id] = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) { MCPSecretStore.save(data, account: Self.account) }
    }

    /// Adds servers from Cursor's `~/.cursor/mcp.json` that aren't configured yet. Returns how many were added.
    @discardableResult
    public func importFromCursor() -> Int {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cursor/mcp.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["mcpServers"] as? [String: Any] else { return 0 }
        var added = 0
        for (name, raw) in entries.sorted(by: { $0.key < $1.key }) {
            guard let entry = raw as? [String: Any],
                  !servers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            var config = MCPServerConfig(name: name)
            if let command = entry["command"] as? String, entry["type"] as? String != "http" {
                config.kind = .stdio
                config.command = command
                config.args = entry["args"] as? [String] ?? []
                config.env = entry["env"] as? [String: String] ?? [:]
            } else if let url = entry["url"] as? String {
                config.kind = .http
                config.url = url
                config.headers = entry["headers"] as? [String: String] ?? [:]
                // Cursor keeps OAuth tokens itself; remote servers without a header sign in again here.
                config.auth = config.headers.keys.contains { $0.lowercased() == "authorization" } ? .none : .oauth
            } else { continue }
            config.enabled = false
            servers.append(config)
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    // MARK: Connections

    public func connectEnabled() {
        for server in servers where server.enabled && status[server.id] != .connected {
            Task { await connect(server.id) }
        }
    }

    public func disconnect(_ id: UUID) {
        if let client = clients.removeValue(forKey: id) { Task { await client.close() } }
        status[id] = .idle
    }

    @discardableResult
    public func connect(_ id: UUID) async -> Bool {
        guard let config = server(id) else { return false }
        status[id] = .connecting
        do {
            let client = try await readyClient(config)
            tools[id] = try await client.listTools()
            status[id] = .connected
            return true
        } catch MCPError.unauthorized(let metadata) {
            resourceMetadata[id] = metadata
            clients[id] = nil
            status[id] = config.auth == .bearer ? .failed("The token was rejected.") : .needsSignIn
        } catch {
            clients[id] = nil
            status[id] = .failed(error.localizedDescription)
        }
        return false
    }

    /// Browser sign-in (OAuth), then connects.
    public func signIn(_ id: UUID) async {
        guard let config = server(id) else { return }
        signingIn = id
        defer { signingIn = nil }
        do {
            let tokens = try await MCPOAuth.authorize(config: config, resourceMetadata: resourceMetadata[id])
            tokens.save(id)
            if config.auth != .oauth {
                var updated = config
                updated.auth = .oauth
                upsert(updated)
            }
            disconnect(id)
            await connect(id)
        } catch {
            status[id] = .failed(error.localizedDescription)
        }
    }

    public func signOut(_ id: UUID) {
        MCPOAuthTokens.delete(id)
        disconnect(id)
        status[id] = .needsSignIn
    }

    public func hasOAuthSession(_ id: UUID) -> Bool { MCPOAuthTokens.load(id) != nil }

    private func bearer(for config: MCPServerConfig) async throws -> String? {
        switch config.auth {
        case .none: return nil
        case .bearer: return config.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        case .oauth:
            guard var tokens = MCPOAuthTokens.load(config.id) else { throw MCPError.unauthorized(resourceMetadata: resourceMetadata[config.id]) }
            if tokens.isExpired, tokens.refreshToken != nil {
                tokens = try await MCPOAuth.refresh(tokens)
                tokens.save(config.id)
            }
            return tokens.accessToken
        }
    }

    private func readyClient(_ config: MCPServerConfig) async throws -> MCPClient {
        if let client = clients[config.id], await client.isInitialized { return client }
        let client = MCPClient(config: config, bearer: try await bearer(for: config))
        clients[config.id] = client
        try await client.initialize()
        return client
    }

    /// Calls a tool, connecting (and refreshing an expired OAuth token once) as needed.
    public func call(server id: UUID, tool: String, arguments: [String: Any]) async throws -> MCPCallResult {
        guard let config = server(id) else { throw MCPError.transport("That integration was removed.") }
        let data = try JSONSerialization.data(withJSONObject: arguments)
        do {
            let client = try await readyClient(config)
            if status[id] != .connected {
                status[id] = .connected
                if tools[id] == nil { tools[id] = try? await client.listTools() }
            }
            return try await client.callTool(tool, argumentsJSON: data)
        } catch MCPError.unauthorized(let metadata) {
            resourceMetadata[id] = metadata
            if config.auth == .oauth, var tokens = MCPOAuthTokens.load(id), tokens.refreshToken != nil {
                tokens = try await MCPOAuth.refresh(tokens)
                tokens.save(id)
                clients[id] = nil
                let client = try await readyClient(config)
                return try await client.callTool(tool, argumentsJSON: data)
            }
            clients[id] = nil
            status[id] = .needsSignIn
            throw MCPError.unauthorized(resourceMetadata: metadata)
        } catch {
            clients[id] = nil
            status[id] = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: Assistant

    /// Tools of connected servers the user shares with the assistant, named `mcp_<server>__<tool>`.
    public var assistantToolSpecs: [AIToolSpec] {
        servers.filter { $0.exposeToAssistant && status[$0.id] == .connected }.flatMap { server in
            (tools[server.id] ?? []).map { tool in
                AIToolSpec(name: Self.assistantName(server, tool),
                           description: "[\(server.name) via MCP] " + (tool.description.isEmpty ? tool.name : String(tool.description.prefix(900))),
                           parametersJSON: tool.inputSchemaJSON)
            }
        }
    }

    public func assistantRoute(_ name: String) -> (server: MCPServerConfig, tool: MCPTool)? {
        for server in servers where server.exposeToAssistant {
            if let tool = tools[server.id]?.first(where: { Self.assistantName(server, $0) == name }) { return (server, tool) }
        }
        return nil
    }

    private static func assistantName(_ server: MCPServerConfig, _ tool: MCPTool) -> String {
        let safe = String(tool.name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        return String("mcp_\(server.slug)__\(safe)".prefix(64))
    }

    /// Short description of connected integrations for the assistant's system prompt.
    public var assistantSummary: String? {
        let connected = servers.filter { $0.exposeToAssistant && status[$0.id] == .connected }
        guard !connected.isEmpty else { return nil }
        return "## Integrations\nThe user connected these MCP servers; their tools are prefixed `mcp_<server>__`: "
            + connected.map { "\($0.name) (\(tools[$0.id]?.count ?? 0) tools)" }.joined(separator: ", ")
            + ". Use them when the user asks about those services (e.g. Slack messages, review requests in a channel). "
            + "Tools not marked read-only ask the user before running."
    }
}
