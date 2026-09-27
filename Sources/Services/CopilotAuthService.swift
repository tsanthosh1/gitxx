import Foundation

public actor CopilotAuthService {
    public static let shared = CopilotAuthService()

    // Verified GitHub Copilot App Client ID
    private let clientId = "Iv23ctfURkiMfJ4xr5mv"
    private let keychainAccount = "copilot_oauth_token"
    private let usernameAccount = "copilot_username"

    // In-memory cache for short-lived Copilot session token
    private var cachedCopilotToken: String?
    private var cachedEndpoint: String = "https://api.githubcopilot.com"
    private var tokenExpiry: Date?
    private var cachedQuotaInfo: CopilotQuotaInfo?

    public init() {}

    // MARK: - Device Authorization Flow

    public func requestDeviceCode() async throws -> DeviceCodeResponse {
        guard let url = URL(string: "https://github.com/login/device/code") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyString = "client_id=\(clientId)&scope=read:user"
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown server response"
            throw NSError(domain: "CopilotAuth", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "Device code request failed: \(errorText)"])
        }

        let decoder = JSONDecoder()
        return try decoder.decode(DeviceCodeResponse.self, from: data)
    }

    public func pollForAccessToken(deviceCode: String, interval: Int = 5, timeoutSeconds: Int = 300) async throws -> (token: String, username: String?) {
        guard let url = URL(string: "https://github.com/login/oauth/access_token") else {
            throw URLError(.badURL)
        }

        let startTime = Date()
        var currentInterval = max(interval, 5)

        while Date().timeIntervalSince(startTime) < TimeInterval(timeoutSeconds) {
            try await Task.sleep(nanoseconds: UInt64(currentInterval) * 1_000_000_000)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let bodyString = "client_id=\(clientId)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code"
            request.httpBody = bodyString.data(using: .utf8)

            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let accessToken = json["access_token"] as? String {
                    // Success! Store in keychain
                    _ = KeychainHelper.saveToken(accessToken, forAccount: keychainAccount)

                    // Fetch username
                    let username = await fetchUsername(token: accessToken)
                    if let username = username {
                        _ = KeychainHelper.saveToken(username, forAccount: usernameAccount)
                    }

                    return (token: accessToken, username: username)
                }

                if let error = json["error"] as? String {
                    if error == "authorization_pending" {
                        continue
                    } else if error == "slow_down" {
                        currentInterval += 5
                        continue
                    } else if error == "expired_token" {
                        throw NSError(domain: "CopilotAuth", code: 400, userInfo: [NSLocalizedDescriptionKey: "The authorization code has expired. Please try again."])
                    } else if error == "access_denied" {
                        throw NSError(domain: "CopilotAuth", code: 403, userInfo: [NSLocalizedDescriptionKey: "Authorization was cancelled by user."])
                    } else {
                        throw NSError(domain: "CopilotAuth", code: 400, userInfo: [NSLocalizedDescriptionKey: "Authorization error: \(error)"])
                    }
                }
            }
        }

        throw NSError(domain: "CopilotAuth", code: 408, userInfo: [NSLocalizedDescriptionKey: "Authorization timed out. Please try again."])
    }

    // MARK: - Auto-Detection & Storage

    public func getStoredOAuthToken() -> String? {
        return KeychainHelper.getToken(forAccount: keychainAccount)
    }

    public func getStoredUsername() -> String? {
        return KeychainHelper.getToken(forAccount: usernameAccount)
    }

    public func disconnect() {
        KeychainHelper.deleteToken(forAccount: keychainAccount)
        KeychainHelper.deleteToken(forAccount: usernameAccount)
        cachedCopilotToken = nil
        cachedQuotaInfo = nil
        tokenExpiry = nil
    }

    public func autoDetectToken() async -> (token: String, username: String)? {
        // 1. Check Keychain first
        if let stored = getStoredOAuthToken(), !stored.isEmpty {
            var user = getStoredUsername()
            if user == nil {
                user = await fetchUsername(token: stored)
            }
            return (token: stored, username: user ?? "Copilot User")
        }

        // 2. Check ~/.config/github-copilot/apps.json (VS Code / JetBrains Copilot auth)
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let appsJsonPath = homeDir.appendingPathComponent(".config/github-copilot/apps.json")

        if let data = try? Data(contentsOf: appsJsonPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (_, appData) in json {
                if let token = appData["oauth_token"] as? String, !token.isEmpty {
                    let user = (appData["user"] as? String) ?? "Copilot User"
                    _ = KeychainHelper.saveToken(token, forAccount: keychainAccount)
                    _ = KeychainHelper.saveToken(user, forAccount: usernameAccount)
                    return (token: token, username: user)
                }
            }
        }

        // 3. Check ~/.config/github-copilot/hosts.json
        let hostsJsonPath = homeDir.appendingPathComponent(".config/github-copilot/hosts.json")
        if let data = try? Data(contentsOf: hostsJsonPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (_, hostData) in json {
                if let token = hostData["oauth_token"] as? String, !token.isEmpty {
                    let user = (hostData["user"] as? String) ?? "Copilot User"
                    _ = KeychainHelper.saveToken(token, forAccount: keychainAccount)
                    _ = KeychainHelper.saveToken(user, forAccount: usernameAccount)
                    return (token: token, username: user)
                }
            }
        }

        return nil
    }

    // MARK: - Copilot API Token Exchange

    public func getCopilotSessionToken() async throws -> (token: String, endpoint: String) {
        if let token = cachedCopilotToken,
           let expiry = tokenExpiry,
           Date().addingTimeInterval(120) < expiry {
            return (token: token, endpoint: cachedEndpoint)
        }

        var oauthToken = getStoredOAuthToken()
        if oauthToken == nil {
            // Attempt auto-detection
            if let detected = await autoDetectToken() {
                oauthToken = detected.token
            }
        }

        guard let validOAuthToken = oauthToken, !validOAuthToken.isEmpty else {
            throw NSError(domain: "CopilotAuth", code: 401, userInfo: [NSLocalizedDescriptionKey: "No GitHub Copilot account connected. Please connect your GitHub Copilot account."])
        }

        guard let url = URL(string: "https://api.github.com/copilot_internal/v2/token") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("token \(validOAuthToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GithubCopilot/1.155.0", forHTTPHeaderField: "User-Agent")
        request.setValue("vscode/1.90.0", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot/1.155.0", forHTTPHeaderField: "Editor-Plugin-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Copilot token exchange failed"
            throw NSError(domain: "CopilotAuth", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: "Failed to exchange Copilot token: \(errorText)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionToken = json["token"] as? String else {
            throw NSError(domain: "CopilotAuth", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid token response format from GitHub Copilot."])
        }

        let endpoints = json["endpoints"] as? [String: Any]
        let apiEndpoint = (endpoints?["api"] as? String) ?? "https://api.githubcopilot.com"

        let expiresAtTimestamp = json["expires_at"] as? TimeInterval ?? (Date().timeIntervalSince1970 + 1800)
        self.cachedCopilotToken = sessionToken
        self.cachedEndpoint = apiEndpoint
        self.tokenExpiry = Date(timeIntervalSince1970: expiresAtTimestamp)

        parseAndCacheQuota(from: json)

        return (token: sessionToken, endpoint: apiEndpoint)
    }

    public func getQuotaInfo(forceRefresh: Bool = false) async throws -> CopilotQuotaInfo? {
        if !forceRefresh, let cached = cachedQuotaInfo {
            return cached
        }
        _ = try await getCopilotSessionToken()
        return cachedQuotaInfo
    }

    /// Live premium-request balance for the connected account (the endpoint Copilot's editor clients use).
    public func fetchPremiumUsage() async -> CopilotPremiumUsage? {
        guard let oauth = getStoredOAuthToken(), !oauth.isEmpty,
              let url = URL(string: "https://api.github.com/copilot_internal/user") else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("token \(oauth)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GithubCopilot/1.155.0", forHTTPHeaderField: "User-Agent")
        request.setValue("vscode/1.90.0", forHTTPHeaderField: "Editor-Version")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let snapshots = json["quota_snapshots"] as? [String: Any]
        let premium = (snapshots?["premium_interactions"] ?? snapshots?["chat"]) as? [String: Any]
        func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        return CopilotPremiumUsage(
            plan: json["copilot_plan"] as? String,
            entitlement: number(premium?["entitlement"]),
            remaining: number(premium?["remaining"]),
            unlimited: (premium?["unlimited"] as? Bool) ?? (premium == nil),
            resetDate: json["quota_reset_date"] as? String
        )
    }

    private func parseAndCacheQuota(from json: [String: Any]) {
        let sku = json["sku"] as? String ?? ""
        let quotas = json["limited_user_quotas"] as? [String: Any]
        let chatLimit = quotas?["chat"] as? Int
        let completionsLimit = quotas?["completions"] as? Int

        let resetTimestamp = json["limited_user_reset_date"] as? TimeInterval
        let resetDate = resetTimestamp.map { Date(timeIntervalSince1970: $0) }

        // If limited_user_quotas is not present or chat limit is nil, it's unlimited tier (e.g. Pro/Business/Enterprise)
        let isUnlimited = (quotas == nil || chatLimit == nil)

        self.cachedQuotaInfo = CopilotQuotaInfo(
            sku: sku,
            chatQuotaLimit: chatLimit,
            completionsQuotaLimit: completionsLimit,
            resetDate: resetDate,
            isUnlimited: isUnlimited
        )
    }

    private func fetchUsername(token: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/user") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GitXX-App", forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String else {
            return nil
        }
        return login
    }
}
