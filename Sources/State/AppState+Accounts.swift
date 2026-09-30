import Foundation

/// A GitHub sign-in GitXX remembers so you can switch between work and personal accounts.
/// The list lives in UserDefaults without tokens; each token is stored in the Keychain only.
public struct GitHubAccount: Codable, Identifiable, Equatable, Sendable {
    public var id: String { "\(host)/\(login.lowercased())" }
    public var login: String
    public var host: String
    public var method: GitHubAuthMethod

    static let listKey = "gitxx_github_accounts"

    var keychainAccount: String { "gitxx_github_account_\(id)" }

    static func loadAll() -> [GitHubAccount] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let accounts = try? JSONDecoder().decode([GitHubAccount].self, from: data) else { return [] }
        return accounts
    }

    static func saveAll(_ accounts: [GitHubAccount]) {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: listKey) }
    }
}

extension AppState {
    /// The saved account matching the signed-in login on the current host.
    public var activeGitHubAccount: GitHubAccount? {
        guard let login = gitHubViewerLogin else { return nil }
        return gitHubAccounts.first { $0.host == GitHubHost.host && $0.login.caseInsensitiveCompare(login) == .orderedSame }
    }

    func rememberGitHubAccount(login: String, token: String, method: GitHubAuthMethod) {
        let account = GitHubAccount(login: login, host: GitHubHost.host, method: method)
        guard KeychainHelper.saveSecret(token, forAccount: account.keychainAccount) else { return }
        var accounts = gitHubAccounts.filter { $0.id != account.id }
        accounts.append(account)
        accounts.sort { ($0.host, $0.login.lowercased()) < ($1.host, $1.login.lowercased()) }
        gitHubAccounts = accounts
        GitHubAccount.saveAll(accounts)
    }

    public func switchGitHubAccount(_ account: GitHubAccount) {
        guard let token = KeychainHelper.getSecret(forAccount: account.keychainAccount) else {
            showToast("The token for @\(account.login) is missing. Sign in again to re-add it.", type: .error)
            return
        }
        if account.host == "github.com" {
            UserDefaults.standard.removeObject(forKey: GitHubHost.enterpriseHostKey)
        } else {
            UserDefaults.standard.set(account.host, forKey: GitHubHost.enterpriseHostKey)
        }
        gitHubViewerLogin = account.login
        UserDefaults.standard.set(account.login, forKey: "gitxx_github_viewer_login")
        resetRepoScopedPRState()
        pullRequests = []
        saveGitHubToken(token, method: account.method)
    }

    public func removeGitHubAccount(_ account: GitHubAccount) {
        KeychainHelper.deleteToken(forAccount: account.keychainAccount)
        gitHubAccounts.removeAll { $0.id == account.id }
        GitHubAccount.saveAll(gitHubAccounts)
    }
}
