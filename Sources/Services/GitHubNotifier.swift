import Foundation
import AppKit
import UserNotifications

/// Posts macOS notifications when someone requests your review, or when CI fails on the latest commit of one of
/// your open pull requests. Polls GitHub search every few minutes; the first pass only records what's already there.
@MainActor
final class GitHubNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = GitHubNotifier()
    static let enabledKey = "gitxx_system_notifications"

    private static let seenReviewsKey = "gitxx_notify_seen_reviews"
    private static let failedKey = "gitxx_notify_failed_commits"
    private static let interval: UInt64 = 180

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil || UserDefaults.standard.bool(forKey: enabledKey)
    }

    private var token: (@MainActor () -> String?)?
    private var loop: Task<Void, Never>?
    private var authorized = false

    /// Notifications need a real app bundle; `swift run` builds have none.
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func start(token: @escaping @MainActor () -> String?) {
        self.token = token
        guard loop == nil, available else { return }
        UNUserNotificationCenter.current().delegate = self
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: Self.interval * 1_000_000_000)
            }
        }
    }

    private func check() async {
        guard Self.isEnabled, let token = token?(), !token.isEmpty else { return }
        if !authorized {
            authorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            guard authorized else { return }
        }
        await checkReviewRequests(token: token)
        await checkFailedChecks(token: token)
    }

    private func checkReviewRequests(token: String) async {
        let query = """
        query { r: search(query: "is:open is:pr review-requested:@me archived:false", type: ISSUE, first: 30) {
          nodes { ... on PullRequest { number title url repository { nameWithOwner } author { login } } } } }
        """
        guard let current = try? await GitHubAPIService.shared.notificationSearch(query: query, token: token,
                                                                                    actionName: "Notifications: review requests") else { return }
        let defaults = UserDefaults.standard
        let primed = defaults.array(forKey: Self.seenReviewsKey) != nil
        let seen = Set(defaults.stringArray(forKey: Self.seenReviewsKey) ?? [])
        defaults.set(current.map(\.key), forKey: Self.seenReviewsKey)
        guard primed else { return }
        for item in current where !seen.contains(item.key) {
            post(id: "review-\(item.key)", title: "Review requested: \(item.repo) #\(item.number)",
                 body: "\(item.author) asked for your review on “\(item.title)”", url: item.url)
        }
    }

    private func checkFailedChecks(token: String) async {
        let query = """
        query { m: search(query: "is:open is:pr author:@me archived:false", type: ISSUE, first: 20) {
          nodes { ... on PullRequest { number title url repository { nameWithOwner } author { login }
            commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } } } } } }
        """
        guard let prs = try? await GitHubAPIService.shared.notificationSearch(query: query, token: token,
                                                                                actionName: "Notifications: my PR checks") else { return }
        let defaults = UserDefaults.standard
        let primed = defaults.array(forKey: Self.failedKey) != nil
        var known = defaults.stringArray(forKey: Self.failedKey) ?? []
        var fresh: [NotificationPR] = []
        for item in prs {
            guard let oid = item.headOid, item.rollupState == "FAILURE" || item.rollupState == "ERROR" else { continue }
            let key = "\(item.key)@\(oid)"
            guard !known.contains(key) else { continue }
            known.append(key)
            fresh.append(item)
        }
        defaults.set(Array(known.suffix(300)), forKey: Self.failedKey)
        guard primed else { return }
        for item in fresh {
            post(id: "checks-\(item.key)", title: "Checks failed: \(item.repo) #\(item.number)",
                 body: "“\(item.title)” has failing checks on its latest commit", url: item.url)
        }
    }

    private func post(id: String, title: String, body: String, url: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["url": url]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: raw) else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: NSNotification.Name("OpenGitHubLinkInApp"), object: url)
        }
    }
}

struct NotificationPR: Sendable {
    let repo: String
    let number: Int
    let title: String
    let url: String
    let author: String
    let headOid: String?
    let rollupState: String?
    var key: String { "\(repo)#\(number)" }
}

extension GitHubAPIService {
    /// Runs a query whose only field is a PR `search`, returning its pull requests.
    func notificationSearch(query: String, token: String, actionName: String) async throws -> [NotificationPR] {
        let data = try await sendGraphQL(query: query, variables: [:], token: token, actionName: actionName)
        let search = data.values.first as? [String: Any]
        let nodes = (search?["nodes"] as? [[String: Any]]) ?? []
        return nodes.compactMap { node in
            guard let number = node["number"] as? Int, let url = node["url"] as? String,
                  let repo = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String else { return nil }
            let commit = ((((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first)?["commit"] as? [String: Any])
            return NotificationPR(repo: repo, number: number, title: (node["title"] as? String) ?? "", url: url,
                                  author: ((node["author"] as? [String: Any])?["login"] as? String) ?? "someone",
                                  headOid: commit?["oid"] as? String,
                                  rollupState: (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String)
        }
    }
}
