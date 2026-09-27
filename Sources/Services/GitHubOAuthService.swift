import Foundation
import AppKit

public struct GitHubDeviceCodeResponse: Codable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationUri: String
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

public actor GitHubOAuthService {
    public static let shared = GitHubOAuthService()

    // Official GitHub Client ID with Device Authorization Grant enabled
    public static let defaultClientId = "178c6fc778ccc68e1d6a"
    public static let defaultScopes = "repo,read:org,read:user,workflow"

    private var pollingTask: Task<String, Error>?

    public init() {}

    // MARK: - Device Code Request

    public func requestDeviceCode(
        clientId: String = defaultClientId,
        scopes: String = defaultScopes
    ) async throws -> GitHubDeviceCodeResponse {
        guard let url = URL(string: "https://github.com/login/device/code") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyString = "client_id=\(clientId)&scope=\(scopes)"
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown server response"
            throw NSError(
                domain: "GitHubOAuth",
                code: (response as? HTTPURLResponse)?.statusCode ?? 500,
                userInfo: [NSLocalizedDescriptionKey: "Failed to request device authorization code: \(errorText)"]
            )
        }

        let decoder = JSONDecoder()
        return try decoder.decode(GitHubDeviceCodeResponse.self, from: data)
    }

    // MARK: - Polling for Access Token

    public func pollForAccessToken(
        deviceCode: String,
        clientId: String = defaultClientId,
        interval: Int = 5,
        timeoutSeconds: Int = 900
    ) async throws -> String {
        guard let url = URL(string: "https://github.com/login/oauth/access_token") else {
            throw URLError(.badURL)
        }

        let startTime = Date()
        var currentInterval = max(interval, 5)

        while Date().timeIntervalSince(startTime) < TimeInterval(timeoutSeconds) {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(currentInterval) * 1_000_000_000)
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let bodyString = "client_id=\(clientId)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code"
            request.httpBody = bodyString.data(using: .utf8)

            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let accessToken = json["access_token"] as? String, !accessToken.isEmpty {
                    return accessToken
                }

                if let error = json["error"] as? String {
                    if error == "authorization_pending" {
                        continue
                    } else if error == "slow_down" {
                        currentInterval += 5
                        continue
                    } else if error == "expired_token" {
                        throw NSError(
                            domain: "GitHubOAuth",
                            code: 400,
                            userInfo: [NSLocalizedDescriptionKey: "The authorization code has expired. Please request a new one."]
                        )
                    } else if error == "access_denied" {
                        throw NSError(
                            domain: "GitHubOAuth",
                            code: 403,
                            userInfo: [NSLocalizedDescriptionKey: "Authorization was cancelled by the user."]
                        )
                    } else {
                        throw NSError(
                            domain: "GitHubOAuth",
                            code: 400,
                            userInfo: [NSLocalizedDescriptionKey: "GitHub authorization error: \(error)"]
                        )
                    }
                }
            }
        }

        throw NSError(
            domain: "GitHubOAuth",
            code: 408,
            userInfo: [NSLocalizedDescriptionKey: "Authorization timed out. Please try again."]
        )
    }

    public func cancel() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
