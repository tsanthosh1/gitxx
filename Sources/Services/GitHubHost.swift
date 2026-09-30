import Foundation

/// The GitHub instance GitXX talks to: github.com, or a GitHub Enterprise Server host set in Settings › GitHub.
public enum GitHubHost {
    public static let enterpriseHostKey = "gitxx_github_enterprise_host"

    /// Bare host name such as `github.com` or `github.corp.com`.
    public static var host: String {
        normalize(UserDefaults.standard.string(forKey: enterpriseHostKey) ?? "") ?? "github.com"
    }

    public static var isEnterprise: Bool { host != "github.com" }

    /// REST base without a trailing slash.
    public static var api: String { isEnterprise ? "https://\(host)/api/v3" : "https://api.github.com" }

    public static var graphQL: URL {
        URL(string: isEnterprise ? "https://\(host)/api/graphql" : "https://api.github.com/graphql")!
    }

    /// Web base without a trailing slash, for links and avatars.
    public static var web: String { "https://\(host)" }

    /// Whether a URL host is the configured GitHub web host (github.com links are always recognised too).
    public static func isWebHost(_ candidate: String) -> Bool {
        let h = candidate.lowercased()
        return h == host || h == "www.\(host)" || h == "github.com" || h == "www.github.com"
    }

    /// Accepts `github.corp.com`, `https://github.corp.com/`, or `https://github.corp.com/api/v3`; empty means github.com.
    public static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let host = URLComponents(string: text)?.host, !host.isEmpty else { return nil }
        if host == "github.com" || host == "www.github.com" || host == "api.github.com" { return nil }
        return host
    }
}
