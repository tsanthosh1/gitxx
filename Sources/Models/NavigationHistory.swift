import Foundation

/// Represents a distinct visited page or view location in GitXX
public struct NavigationLocation: Equatable, Hashable, Identifiable {
    public enum PageType: Equatable, Hashable {
        case changes
        case history(commitSha: String?)
        case pullRequestsIndex(filter: PRFilter)
        case pullRequestDetail(prNumber: Int, subTab: PRDetailTab)
        case actions(runId: Int?)
        case terminal
        case home
    }

    public let id: UUID
    public let page: PageType
    public let repoPath: String?
    public let repoName: String?
    public let title: String
    public var timestamp: Date

    public init(id: UUID = UUID(), page: PageType, repoPath: String?, repoName: String? = nil, title: String, timestamp: Date = Date()) {
        self.id = id
        self.page = page
        self.repoPath = repoPath
        self.repoName = repoName ?? (repoPath.map { URL(fileURLWithPath: $0).lastPathComponent })
        self.title = title
        self.timestamp = timestamp
    }

    public static func == (lhs: NavigationLocation, rhs: NavigationLocation) -> Bool {
        return lhs.page == rhs.page && lhs.repoPath == rhs.repoPath
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(page)
        hasher.combine(repoPath)
    }

    public var iconName: String {
        switch page {
        case .changes:
            return "tray.full.fill"
        case .history:
            return "clock.arrow.circlepath"
        case .pullRequestsIndex:
            return "arrow.triangle.pull"
        case .pullRequestDetail:
            return "arrow.triangle.pull"
        case .actions:
            return "play.circle"
        case .terminal:
            return "terminal.fill"
        case .home:
            return "house.fill"
        }
    }

    public var displayRepoName: String {
        if let name = repoName, !name.isEmpty {
            return name
        }
        if let path = repoPath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "Repository"
    }

    public var subtitle: String {
        let repo = displayRepoName
        switch page {
        case .changes:
            return repo
        case .history(let sha):
            if let sha = sha {
                return "\(repo) · Commit \(String(sha.prefix(7)))"
            }
            return "\(repo) · Commits"
        case .pullRequestsIndex(let filter):
            return "\(repo) · \(filter.rawValue)"
        case .pullRequestDetail(let prNumber, let subTab):
            return "\(repo) · PR #\(prNumber) · \(subTab.rawValue)"
        case .actions(let runId):
            return runId.map { "\(repo) · Actions run \($0)" } ?? "\(repo) · Actions"
        case .terminal:
            return "\(repo) · Terminal"
        case .home:
            return "Recent repositories & your pull requests"
        }
    }

    public var timeAgo: String {
        let elapsed = Int(Date().timeIntervalSince(timestamp))
        if elapsed < 10 {
            return "Just now"
        } else if elapsed < 60 {
            return "\(elapsed)s ago"
        } else if elapsed < 3600 {
            return "\(elapsed / 60)m ago"
        } else {
            return "\(elapsed / 3600)h ago"
        }
    }
}

