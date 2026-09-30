import Foundation

/// One Model Context Protocol server the user connected: remote (Streamable HTTP) or a local command (stdio).
public struct MCPServerConfig: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case http, stdio }
    public enum Auth: String, Codable, Sendable, CaseIterable { case none, bearer, oauth }

    public var id = UUID()
    public var name: String
    public var kind: Kind = .http
    public var url: String = ""
    public var headers: [String: String] = [:]
    public var command: String = ""
    public var args: [String] = []
    public var env: [String: String] = [:]
    public var auth: Auth = .none
    public var bearerToken: String = ""
    /// Only needed when the authorization server has no dynamic client registration (e.g. Slack).
    public var oauthClientID: String = ""
    public var oauthClientSecret: String = ""
    /// Space-separated; empty asks for what the server advertises.
    public var oauthScopes: String = ""
    public var enabled = true
    public var exposeToAssistant = true

    public init(name: String) { self.name = name }

    /// A name usable in tool identifiers (`[a-z0-9_]`).
    public var slug: String {
        let mapped = String(name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        let slug = String(mapped.split(separator: "_").joined(separator: "_").prefix(24))
        return slug.isEmpty ? "server" : slug
    }
}

public struct MCPTool: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let title: String?
    public let description: String
    public let inputSchemaJSON: String
    /// From the tool's `readOnlyHint` annotation; read-only tools run without asking.
    public let readOnly: Bool

    /// Names of the input schema's properties, to fill arguments by convention (query, limit…).
    public var parameterNames: [String] {
        guard let schema = (try? JSONSerialization.jsonObject(with: Data(inputSchemaJSON.utf8))) as? [String: Any],
              let props = schema["properties"] as? [String: Any] else { return [] }
        return Array(props.keys)
    }
}

public struct MCPCallResult: Sendable {
    public let text: String
    public let isError: Bool
}

public enum MCPError: LocalizedError, Sendable {
    case unauthorized(resourceMetadata: String?)
    case http(Int, String)
    case rpc(Int, String)
    case transport(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "The server needs you to sign in."
        case .http(let code, let body): return "HTTP \(code)" + (body.isEmpty ? "" : ": \(body.prefix(300))")
        case .rpc(_, let message): return message
        case .transport(let message): return message
        case .timeout(let what): return "Timed out waiting for \(what)."
        }
    }
}

/// Minimal MCP client: `initialize`, `tools/list` and `tools/call` over Streamable HTTP or stdio.
public actor MCPClient {
    public nonisolated let serverID: UUID
    private let config: MCPServerConfig
    private var bearer: String?
    private var sessionID: String?
    private var nextID = 1
    public private(set) var isInitialized = false
    public private(set) var serverName: String?

    // stdio
    private var process: Process?
    private var stdin: FileHandle?
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private let stderrTail = OutputTail()

    public init(config: MCPServerConfig, bearer: String?) {
        self.serverID = config.id
        self.config = config
        self.bearer = bearer
    }

    public func setBearer(_ token: String?) { bearer = token }

    // MARK: Protocol

    public func initialize() async throws {
        if config.kind == .stdio && process == nil { try startProcess() }
        let params: [String: Any] = [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "GitXX", "version": "1.0"],
        ]
        let result = try await request("initialize", params: params, timeout: 60)
        serverName = (result["serverInfo"] as? [String: Any])?["name"] as? String
        try await notify("notifications/initialized")
        isInitialized = true
    }

    public func listTools() async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var cursor: String?
        repeat {
            let result = try await request("tools/list", params: cursor.map { ["cursor": $0] } ?? [:], timeout: 60)
            for raw in result["tools"] as? [[String: Any]] ?? [] {
                guard let name = raw["name"] as? String else { continue }
                let schema = raw["inputSchema"] ?? ["type": "object", "properties": [String: Any]()]
                let schemaJSON = (try? JSONSerialization.data(withJSONObject: schema)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let annotations = raw["annotations"] as? [String: Any]
                tools.append(MCPTool(name: name, title: raw["title"] as? String ?? annotations?["title"] as? String,
                                     description: raw["description"] as? String ?? "",
                                     inputSchemaJSON: schemaJSON, readOnly: annotations?["readOnlyHint"] as? Bool ?? false))
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil && tools.count < 1000
        return tools
    }

    public func callTool(_ name: String, argumentsJSON: Data) async throws -> MCPCallResult {
        let arguments = (try? JSONSerialization.jsonObject(with: argumentsJSON)) as? [String: Any] ?? [:]
        let result = try await request("tools/call", params: ["name": name, "arguments": arguments], timeout: 180)
        var parts: [String] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text": if let text = item["text"] as? String { parts.append(text) }
            case "resource":
                if let res = item["resource"] as? [String: Any], let text = res["text"] as? String { parts.append(text) }
            case "resource_link":
                parts.append("[\(item["name"] as? String ?? "resource")](\(item["uri"] as? String ?? ""))")
            case let other?: parts.append("[\(other) content omitted]")
            default: break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted]) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        return MCPCallResult(text: parts.joined(separator: "\n\n"), isError: result["isError"] as? Bool ?? false)
    }

    public func close() {
        for (_, continuation) in pending { continuation.resume(throwing: MCPError.transport("Disconnected.")) }
        pending = [:]
        if let process, process.isRunning { process.terminate() }
        process = nil
        stdin = nil
        isInitialized = false
        sessionID = nil
    }

    // MARK: JSON-RPC

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let reply: Data
        switch config.kind {
        case .http: reply = try await postHTTP(body, id: id, timeout: timeout) ?? Data()
        case .stdio: reply = try await sendStdio(body, id: id, timeout: timeout, what: method)
        }
        guard let message = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else {
            throw MCPError.transport("The server sent an unreadable reply to \(method).")
        }
        if let error = message["error"] as? [String: Any] {
            throw MCPError.rpc(error["code"] as? Int ?? -1, error["message"] as? String ?? "Error from server")
        }
        return message["result"] as? [String: Any] ?? [:]
    }

    private func notify(_ method: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method])
        switch config.kind {
        case .http: _ = try await postHTTP(body, id: nil, timeout: 30)
        case .stdio: try writeLine(body)
        }
    }

    // MARK: Streamable HTTP

    private func postHTTP(_ body: Data, id: Int?, timeout: TimeInterval) async throws -> Data? {
        guard let url = URL(string: config.url) else { throw MCPError.transport("Invalid server URL.") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        for (key, value) in config.headers where !key.isEmpty { request.setValue(value, forHTTPHeaderField: key) }
        if let bearer, !bearer.isEmpty { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.transport("No HTTP response.") }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
        if http.statusCode == 401 || http.statusCode == 403 {
            let header = http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
            let metadata = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression)
                .map { String(header[$0]).replacingOccurrences(of: "resource_metadata=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            throw MCPError.unauthorized(resourceMetadata: metadata)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(http.statusCode, String(decoding: data.prefix(500), as: UTF8.self))
        }
        guard let id else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard type.contains("text/event-stream") else { return data }
        // One SSE response per request: find the event carrying our id.
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        for event in text.components(separatedBy: "\n\n") {
            let payload = event.split(separator: "\n")
                .filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
            guard let json = payload.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
                  (message["id"] as? Int) == id else { continue }
            return json
        }
        throw MCPError.transport("The server's event stream ended without a reply.")
    }

    // MARK: stdio

    private func startProcess() throws {
        guard !config.command.isEmpty else { throw MCPError.transport("No command configured.") }
        let process = Process()
        var env = ProcessInfo.processInfo.environment
        // The login shell's PATH (nvm, Homebrew, asdf) so `npx`, `uvx`, `docker` resolve.
        env["PATH"] = LoginShellPath.value
        env.merge(config.env) { _, new in new }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [config.command] + config.args
        process.environment = env
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let lines = LineSplitter()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            guard let client = self else { return }
            let received = lines.feed(chunk)
            Task { for line in received { await client.handleLine(line) } }
        }
        let tail = stderrTail
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { tail.append(chunk) }
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            guard let client = self else { return }
            Task { await client.processEnded(status: status) }
        }
        try process.run()
        self.process = process
        self.stdin = input.fileHandleForWriting
    }

    private func writeLine(_ data: Data) throws {
        guard let stdin, process?.isRunning == true else {
            throw MCPError.transport("The server process isn't running." + stderrTail.suffixDescription)
        }
        try stdin.write(contentsOf: data + Data("\n".utf8))
    }

    private func sendStdio(_ body: Data, id: Int, timeout: TimeInterval, what: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try writeLine(body) } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(id, what: what)
            }
        }
    }

    private func expire(_ id: Int, what: String) {
        pending.removeValue(forKey: id)?.resume(throwing: MCPError.timeout(what))
    }

    private func handleLine(_ line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        if let method = message["method"] as? String {
            // Server → client requests: answer the few a tool-only client can.
            guard let id = message["id"] else { return }
            let reply: [String: Any]
            switch method {
            case "ping": reply = ["jsonrpc": "2.0", "id": id, "result": [String: Any]()]
            case "roots/list": reply = ["jsonrpc": "2.0", "id": id, "result": ["roots": [Any]()]]
            default: reply = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported by GitXX"]]
            }
            if let data = try? JSONSerialization.data(withJSONObject: reply) { try? writeLine(data) }
            return
        }
        guard let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(returning: line)
    }

    private func processEnded(status: Int32) {
        let reason = MCPError.transport("The server process exited (code \(status))." + stderrTail.suffixDescription)
        for (_, continuation) in pending { continuation.resume(throwing: reason) }
        pending = [:]
        process = nil
        stdin = nil
        isInitialized = false
    }
}

/// PATH as the user's login shell sets it. Read once; startup-file noise is skipped via a marker.
enum LoginShellPath {
    static let value: String = {
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "print -r -- \"__GITXX_PATH__$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return fallback }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("__GITXX_PATH__") }) else { return fallback }
        let path = String(line.dropFirst("__GITXX_PATH__".count))
        return path.isEmpty ? fallback : path + ":" + fallback
    }()
}

/// Splits a byte stream into newline-terminated messages.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func feed(_ chunk: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { lines.append(Data(line)) }
        }
        return lines
    }
}

/// Last few KB of a server's stderr, for error messages when it dies.
final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > 4096 { data = data.suffix(4096) }
    }

    var suffixDescription: String {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : "\n" + String(text.suffix(800))
    }
}
