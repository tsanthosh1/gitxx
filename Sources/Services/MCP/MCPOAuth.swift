import Foundation
import CryptoKit
import Network
import AppKit
import Security

/// Keychain-only storage (never mirrored to UserDefaults) for MCP server configs and tokens.
enum MCPSecretStore {
    private static let service = "com.gitxx.macos.mcp"

    static func save(_ data: Data, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

struct MCPOAuthTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenEndpoint: String
    var clientID: String
    var clientSecret: String?
    var resource: String?

    var isExpired: Bool { expiresAt.map { $0 < Date().addingTimeInterval(60) } ?? false }

    static func load(_ serverID: UUID) -> MCPOAuthTokens? {
        MCPSecretStore.load(account: "oauth-\(serverID.uuidString)").flatMap { try? JSONDecoder().decode(MCPOAuthTokens.self, from: $0) }
    }

    func save(_ serverID: UUID) {
        if let data = try? JSONEncoder().encode(self) { MCPSecretStore.save(data, account: "oauth-\(serverID.uuidString)") }
    }

    static func delete(_ serverID: UUID) { MCPSecretStore.delete(account: "oauth-\(serverID.uuidString)") }
}

/// OAuth 2.1 for MCP servers: protected-resource → authorization-server discovery, dynamic client
/// registration when offered (otherwise the configured client id/secret), PKCE, and a loopback redirect.
enum MCPOAuth {
    static let redirectPort: UInt16 = 33418
    static var redirectURI: String { "http://localhost:\(redirectPort)/callback" }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func authorize(config: MCPServerConfig, resourceMetadata: String?) async throws -> MCPOAuthTokens {
        guard let serverURL = URL(string: config.url), let origin = originURL(serverURL) else { throw Failure(message: "Invalid server URL.") }

        // 1. Discover the authorization server.
        let resourceURL = resourceMetadata.flatMap(URL.init(string:)) ?? origin.appendingPathComponent(".well-known/oauth-protected-resource")
        let resource = try? await fetchJSON(resourceURL)
        let issuer = (resource?["authorization_servers"] as? [String])?.first.flatMap(URL.init(string:)) ?? origin
        var metadata = try? await fetchJSON(issuer.appendingPathComponent(".well-known/oauth-authorization-server"))
        if metadata == nil { metadata = try? await fetchJSON(issuer.appendingPathComponent(".well-known/openid-configuration")) }
        guard let metadata,
              let authorizeEndpoint = (metadata["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let tokenEndpoint = metadata["token_endpoint"] as? String else {
            throw Failure(message: "Couldn't discover the server's OAuth endpoints.")
        }
        let resourceID = resource?["resource"] as? String ?? config.url

        // 2. A client id: configured, or registered on the fly.
        var clientID = config.oauthClientID.trimmingCharacters(in: .whitespaces)
        var clientSecret: String? = config.oauthClientSecret.isEmpty ? nil : config.oauthClientSecret
        if clientID.isEmpty {
            guard let registration = (metadata["registration_endpoint"] as? String).flatMap(URL.init(string:)) else {
                throw Failure(message: "This server doesn't support automatic client registration. Create an OAuth app with the provider, add \(redirectURI) as its redirect URL, and enter its client ID and secret in the server's settings — or use a Bearer token instead.")
            }
            let body: [String: Any] = [
                "client_name": "GitXX", "redirect_uris": [redirectURI],
                "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                "token_endpoint_auth_method": "none",
            ]
            let reg = try await postJSON(registration, body: body)
            guard let id = reg["client_id"] as? String else { throw Failure(message: "Client registration failed.") }
            clientID = id
            clientSecret = reg["client_secret"] as? String
        }

        // 3. Browser authorization with PKCE, answered on the loopback listener.
        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = randomString(24)
        let scopes = config.oauthScopes.trimmingCharacters(in: .whitespaces).isEmpty
            ? ((resource?["scopes_supported"] as? [String]) ?? (metadata["scopes_supported"] as? [String]) ?? []).joined(separator: " ")
            : config.oauthScopes
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resourceID),
        ]
        if !scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: scopes)) }
        components.queryItems = items
        guard let authorizeURL = components.url else { throw Failure(message: "Couldn't build the sign-in URL.") }

        let listener = try LoopbackListener(port: redirectPort)
        defer { listener.stop() }
        await MainActor.run { LinkRouter.open(authorizeURL) }
        let callback = try await listener.waitForCallback(timeout: 300)
        guard callback["state"] == state else { throw Failure(message: "Sign-in was rejected (state mismatch).") }
        if let error = callback["error"] { throw Failure(message: "Sign-in failed: \(callback["error_description"] ?? error)") }
        guard let code = callback["code"] else { throw Failure(message: "Sign-in returned no code.") }

        // 4. Code → tokens.
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
                    "client_id": clientID, "code_verifier": verifier, "resource": resourceID]
        if let clientSecret { form["client_secret"] = clientSecret }
        let reply = try await postForm(URL(string: tokenEndpoint)!, form: form)
        return try tokens(from: reply, tokenEndpoint: tokenEndpoint, clientID: clientID, clientSecret: clientSecret, resource: resourceID, previous: nil)
    }

    static func refresh(_ current: MCPOAuthTokens) async throws -> MCPOAuthTokens {
        guard let refresh = current.refreshToken, let url = URL(string: current.tokenEndpoint) else {
            throw Failure(message: "The session expired; sign in again.")
        }
        var form = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": current.clientID]
        if let secret = current.clientSecret { form["client_secret"] = secret }
        if let resource = current.resource { form["resource"] = resource }
        let reply = try await postForm(url, form: form)
        return try tokens(from: reply, tokenEndpoint: current.tokenEndpoint, clientID: current.clientID,
                          clientSecret: current.clientSecret, resource: current.resource, previous: current)
    }

    private static func tokens(from reply: [String: Any], tokenEndpoint: String, clientID: String, clientSecret: String?,
                               resource: String?, previous: MCPOAuthTokens?) throws -> MCPOAuthTokens {
        // Slack nests user tokens under `authed_user` and reports failures as `ok: false`.
        let body = reply["authed_user"] as? [String: Any] ?? reply
        guard let access = body["access_token"] as? String ?? reply["access_token"] as? String else {
            let reason = reply["error_description"] as? String ?? reply["error"] as? String ?? "no access token"
            throw Failure(message: "Token exchange failed: \(reason)")
        }
        let expires = (body["expires_in"] as? Double ?? reply["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        return MCPOAuthTokens(accessToken: access,
                              refreshToken: body["refresh_token"] as? String ?? reply["refresh_token"] as? String ?? previous?.refreshToken,
                              expiresAt: expires, tokenEndpoint: tokenEndpoint, clientID: clientID,
                              clientSecret: clientSecret, resource: resource)
    }

    // MARK: HTTP helpers

    private static func originURL(_ url: URL) -> URL? {
        var c = URLComponents()
        c.scheme = url.scheme; c.host = url.host; c.port = url.port
        return c.url
    }

    private static func fetchJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure(message: "No metadata at \(url)") }
        return json
    }

    private static func postJSON(_ url: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func postForm(_ url: URL, form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func randomString(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URLEncoded.prefix(length).description
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Receives the OAuth redirect on `http://localhost:<port>/callback` and returns its query parameters.
private final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw MCPOAuth.Failure(message: "Port \(port) is busy; close whatever is using it and try again.")
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() { listener.cancel() }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(MCPOAuth.Failure(message: "Sign-in timed out.")))
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let comps = URLComponents(string: "http://localhost" + target)
            guard comps?.path == "/callback" else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            var params: [String: String] = [:]
            for item in comps?.queryItems ?? [] { params[item.name] = item.value ?? "" }
            let ok = params["code"] != nil
            let page = """
            <html><body style="font-family:-apple-system;background:#0d1117;color:#e6edf3;display:flex;align-items:center;justify-content:center;height:90vh">
            <div style="text-align:center"><h2>\(ok ? "Signed in to GitXX" : "Sign-in failed")</h2><p>You can close this tab and return to GitXX.</p></div></body></html>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            self?.finish(.success(params))
        }
    }
}
