import SwiftUI

public final class PRDateFormatterHelper: @unchecked Sendable {
    public static let shared = PRDateFormatterHelper()
    private let formatter: RelativeDateTimeFormatter
    private let lock = NSLock()

    private init() {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        self.formatter = f
    }

    public func formatRelative(date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

public enum PRDetailTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case overview = "Overview"
    case commits = "Commits"
    case checks = "Checks"
    case filesChanged = "Files Changed"
    public var id: String { rawValue }
}

public enum PullRequestState: String, Codable, Sendable {
    case `open` = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
    case draft = "DRAFT"

    /// Open or draft: the PR can still receive actions (merge, close, comment, label).
    public var isActive: Bool { self == .open || self == .draft }

    public var badgeColor: Color {
        switch self {
        case .open: return Color.green
        case .closed: return Color.red
        case .merged: return Color.purple
        case .draft: return Color.gray
        }
    }

    public var iconName: String {
        switch self {
        case .open: return "arrow.triangle.pull"
        case .closed: return "xmark.circle"
        case .merged: return "arrow.triangle.merge"
        case .draft: return "doc.badge.ellipsis"
        }
    }
}

public enum ReviewVerdict: String, Codable, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case commented = "COMMENTED"
    case pending = "PENDING"

    public var title: String {
        switch self {
        case .approved: return "Approved"
        case .changesRequested: return "Changes Requested"
        case .commented: return "Commented"
        case .pending: return "Review Required"
        }
    }

    public var color: Color {
        switch self {
        case .approved: return .green
        case .changesRequested: return .red
        case .commented: return .blue
        case .pending: return .orange
        }
    }
}

public struct PRComment: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let authorName: String
    public let authorAvatarUrl: String?
    public let body: String
    public let createdAt: Date
    public let path: String?
    public let lineNumber: Int?

    public init(id: String = UUID().uuidString, authorName: String, authorAvatarUrl: String? = nil, body: String, createdAt: Date = Date(), path: String? = nil, lineNumber: Int? = nil) {
        self.id = id
        self.authorName = authorName
        self.authorAvatarUrl = authorAvatarUrl
        self.body = body
        self.createdAt = createdAt
        self.path = path
        self.lineNumber = lineNumber
    }
}

// MARK: - Rich Timeline Models

/// A single inline review comment (reply inside a review thread)
public struct PRReviewComment: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let authorName: String
    public let authorAvatarUrl: String?
    public let body: String
    public let createdAt: Date
    public let updatedAt: Date?
    public let path: String?
    public let line: Int?          // new-file line number
    public let originalLine: Int?  // old-file line number
    public let diffHunk: String?   // the @@ hunk context snippet
    public let inReplyToId: String?
    public let htmlUrl: String?
    /// Diff side the comment is anchored to: "RIGHT" (new file) or "LEFT" (old file).
    public let side: String?

    public init(
        id: String,
        authorName: String,
        authorAvatarUrl: String? = nil,
        body: String,
        createdAt: Date,
        updatedAt: Date? = nil,
        path: String? = nil,
        line: Int? = nil,
        originalLine: Int? = nil,
        diffHunk: String? = nil,
        inReplyToId: String? = nil,
        htmlUrl: String? = nil,
        side: String? = nil
    ) {
        self.id = id
        self.authorName = authorName
        self.authorAvatarUrl = authorAvatarUrl
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.path = path
        self.line = line
        self.originalLine = originalLine
        self.diffHunk = diffHunk
        self.inReplyToId = inReplyToId
        self.htmlUrl = htmlUrl
        self.side = side
    }
}

/// A thread of inline code review comments anchored to a file+line
public struct PRReviewThread: Identifiable, Hashable, Codable, Sendable {
    public let id: String       // derived from first comment id
    public let path: String
    public let line: Int?
    public let diffHunk: String?
    public var comments: [PRReviewComment]
    public var isResolved: Bool
    public var resolvedByName: String?
    /// GraphQL `PullRequestReviewThread` node id. `nil` until resolution metadata has been fetched,
    /// in which case `isResolved` is not authoritative.
    public var nodeId: String?
    public var isOutdated: Bool?

    public init(
        id: String,
        path: String,
        line: Int? = nil,
        diffHunk: String? = nil,
        comments: [PRReviewComment] = [],
        isResolved: Bool = false,
        resolvedByName: String? = nil,
        nodeId: String? = nil,
        isOutdated: Bool? = nil
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.diffHunk = diffHunk
        self.comments = comments
        self.isResolved = isResolved
        self.resolvedByName = resolvedByName
        self.nodeId = nodeId
        self.isOutdated = isOutdated
    }

    public var isResolutionKnown: Bool { nodeId != nil }

    public var fileDisplayName: String {
        (path as NSString).lastPathComponent
    }

    public var directoryPath: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }

    public var firstComment: PRReviewComment? { comments.first }
    public var replyCount: Int { max(0, comments.count - 1) }
}

/// A formal review submission (APPROVED / CHANGES_REQUESTED / COMMENTED)
public struct PRReviewEvent: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let authorName: String
    public let authorAvatarUrl: String?
    public let submittedAt: Date
    public let state: String       // "APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED"
    public let body: String
    public let htmlUrl: String?

    public init(
        id: String,
        authorName: String,
        authorAvatarUrl: String? = nil,
        submittedAt: Date,
        state: String,
        body: String,
        htmlUrl: String? = nil
    ) {
        self.id = id
        self.authorName = authorName
        self.authorAvatarUrl = authorAvatarUrl
        self.submittedAt = submittedAt
        self.state = state
        self.body = body
        self.htmlUrl = htmlUrl
    }

    public var verdict: ReviewVerdict {
        switch state.uppercased() {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        default: return .commented
        }
    }

    public var displayLabel: String {
        switch state.uppercased() {
        case "APPROVED": return "approved these changes"
        case "CHANGES_REQUESTED": return "requested changes"
        case "DISMISSED": return "dismissed their review"
        default: return body.isEmpty ? "reviewed this pull request" : "commented"
        }
    }

    public var badgeColor: Color {
        switch state.uppercased() {
        case "APPROVED": return .green
        case "CHANGES_REQUESTED": return .red
        case "DISMISSED": return .secondary
        default: return .blue
        }
    }

    public var badgeIcon: String {
        switch state.uppercased() {
        case "APPROVED": return "checkmark.circle.fill"
        case "CHANGES_REQUESTED": return "exclamationmark.circle.fill"
        case "DISMISSED": return "minus.circle"
        default: return "bubble.left.fill"
        }
    }
}

/// A commit pushed to the PR branch
public struct PRCommitEvent: Identifiable, Hashable, Codable, Sendable {
    public let id: String      // SHA
    public let sha: String
    public let message: String
    public let authorName: String
    public let authoredAt: Date

    public init(id: String, sha: String, message: String, authorName: String, authoredAt: Date) {
        self.id = id
        self.sha = sha
        self.message = message
        self.authorName = authorName
        self.authoredAt = authoredAt
    }

    public var shortSha: String { String(sha.prefix(7)) }
    public var firstLine: String { message.components(separatedBy: "\n").first ?? message }
}

/// The unified timeline — every event type in chronological order.
public enum PRTimelineItem: Identifiable, Hashable, Codable, Sendable {
    case issueComment(PRComment)
    case reviewEvent(PRReviewEvent)
    case reviewThread(PRReviewThread)
    case commitPushed([PRCommitEvent])  // group of commits pushed together
    case merged(authorName: String, mergedAt: Date, sha: String)
    case closed(authorName: String, closedAt: Date)
    case reopened(authorName: String, reopenedAt: Date)
    case labeled(name: String, color: String, addedAt: Date, actorName: String)
    case readyForReview(authorName: String, at: Date)

    public var id: String {
        switch self {
        case .issueComment(let c): return "ic-\(c.id)"
        case .reviewEvent(let r): return "re-\(r.id)"
        case .reviewThread(let t): return "rt-\(t.id)"
        case .commitPushed(let commits): return "cp-\(commits.first?.id ?? UUID().uuidString)"
        case .merged(_, let at, let sha): return "merged-\(sha)-\(at.timeIntervalSince1970)"
        case .closed(_, let at): return "closed-\(at.timeIntervalSince1970)"
        case .reopened(_, let at): return "reopened-\(at.timeIntervalSince1970)"
        case .labeled(let name, _, let at, _): return "label-\(name)-\(at.timeIntervalSince1970)"
        case .readyForReview(_, let at): return "rfr-\(at.timeIntervalSince1970)"
        }
    }

    public var sortDate: Date {
        switch self {
        case .issueComment(let c): return c.createdAt
        case .reviewEvent(let r): return r.submittedAt
        case .reviewThread(let t): return t.firstComment?.createdAt ?? Date.distantPast
        case .commitPushed(let cs): return cs.last?.authoredAt ?? Date.distantPast
        case .merged(_, let at, _): return at
        case .closed(_, let at): return at
        case .reopened(_, let at): return at
        case .labeled(_, _, let at, _): return at
        case .readyForReview(_, let at): return at
        }
    }
}

public struct PullRequest: Identifiable, Hashable, Codable, Sendable {
    public var id: Int { number }
    public let number: Int
    public var title: String
    public var body: String
    public var state: PullRequestState
    public var isDraft: Bool
    public let authorName: String
    public let authorAvatarUrl: String?
    public let headBranch: String
    public let baseBranch: String
    public var headSha: String?
    public let url: String
    public let createdAt: Date
    public var commentsCount: Int
    public var additions: Int
    public var deletions: Int
    public var changedFilesCount: Int
    public var reviewVerdict: ReviewVerdict
    public var comments: [PRComment]
    public var ciStatus: String // "SUCCESS", "FAILURE", "PENDING"
    public var totalChecksCount: Int // e.g. 27 total checks
    public var passedChecksCount: Int // e.g. 24 passed checks
    public var mergeable: Bool?
    public var mergeableState: String? // "clean", "blocked", "dirty", "unstable", "behind", "draft"
    public var rebaseable: Bool?

    public var checksSummary: String? {
        guard totalChecksCount > 0 else { return nil }
        return "\(passedChecksCount)/\(totalChecksCount)"
    }

    public var hasConflicts: Bool {
        if let m = mergeable, !m { return true }
        if mergeableState == "dirty" { return true }
        return false
    }

    public var isBehind: Bool {
        return mergeableState == "behind"
    }

    public var isBlocked: Bool {
        return mergeableState == "blocked"
    }

    public var isClean: Bool {
        return mergeableState == "clean" || (mergeable == true && mergeableState != "blocked" && mergeableState != "dirty")
    }

    public var relativeDateString: String {
        PRDateFormatterHelper.shared.formatRelative(date: createdAt)
    }

    public init(
        number: Int,
        title: String,
        body: String = "",
        state: PullRequestState = .open,
        isDraft: Bool = false,
        authorName: String,
        authorAvatarUrl: String? = nil,
        headBranch: String,
        baseBranch: String = "main",
        headSha: String? = nil,
        url: String = "",
        createdAt: Date = Date(),
        commentsCount: Int = 0,
        additions: Int = 0,
        deletions: Int = 0,
        changedFilesCount: Int = 0,
        reviewVerdict: ReviewVerdict = .pending,
        comments: [PRComment] = [],
        ciStatus: String = "SUCCESS",
        totalChecksCount: Int = 0,
        passedChecksCount: Int = 0,
        mergeable: Bool? = nil,
        mergeableState: String? = nil,
        rebaseable: Bool? = nil
    ) {
        self.number = number
        self.title = title
        self.body = body
        self.state = isDraft ? .draft : state
        self.isDraft = isDraft
        self.authorName = authorName
        self.authorAvatarUrl = authorAvatarUrl
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.headSha = headSha
        self.url = url
        self.createdAt = createdAt
        self.commentsCount = commentsCount
        self.additions = additions
        self.deletions = deletions
        self.changedFilesCount = changedFilesCount
        self.reviewVerdict = reviewVerdict
        self.comments = comments
        self.ciStatus = ciStatus
        self.totalChecksCount = totalChecksCount
        self.passedChecksCount = passedChecksCount
        self.mergeable = mergeable
        self.mergeableState = mergeableState
        self.rebaseable = rebaseable
    }
}

public struct PRFileChange: Identifiable, Hashable, Codable, Sendable {
    public var id: String { filename }
    public let filename: String
    public let status: String // "modified", "added", "removed", "renamed"
    public let additions: Int
    public let deletions: Int
    public let changes: Int
    public let patch: String?
    public let previousFilename: String?

    public init(
        filename: String,
        status: String = "modified",
        additions: Int = 0,
        deletions: Int = 0,
        changes: Int = 0,
        patch: String? = nil,
        previousFilename: String? = nil
    ) {
        self.filename = filename
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.changes = changes
        self.patch = patch
        self.previousFilename = previousFilename
    }

    public var statusBadgeColor: Color {
        switch status.lowercased() {
        case "added": return .green
        case "removed", "deleted": return .red
        case "modified": return .orange
        case "renamed": return .blue
        default: return .secondary
        }
    }

    public var statusLetter: String {
        switch status.lowercased() {
        case "added": return "A"
        case "removed", "deleted": return "D"
        case "modified": return "M"
        case "renamed": return "R"
        default: return "M"
        }
    }

    public var fileDisplayName: String {
        (filename as NSString).lastPathComponent
    }

    public var directoryPath: String {
        let dir = (filename as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

public struct PRCheckRun: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public let name: String
    public let status: String // "queued", "in_progress", "completed"
    public let conclusion: String? // "success", "failure", "neutral", "cancelled", "skipped", "timed_out", "action_required"
    public var isRequired: Bool
    public let htmlUrl: String?
    public let startedAt: Date?
    public let completedAt: Date?
    /// GitHub App that reported the check ("GitHub Actions", "SonarCloud", …) or the status context creator.
    public var appName: String?
    /// Check-run `output.title` / `output.summary` (markdown), or a commit status's description.
    public var outputTitle: String?
    public var outputSummary: String?

    public init(
        id: String,
        name: String,
        status: String,
        conclusion: String? = nil,
        isRequired: Bool = false,
        htmlUrl: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.isRequired = isRequired
        self.htmlUrl = htmlUrl
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public enum Group: Int, CaseIterable, Sendable {
        case failing, running, passing, skipped

        public var title: String {
            switch self {
            case .failing: return "Failing"
            case .running: return "In progress"
            case .passing: return "Successful"
            case .skipped: return "Skipped"
            }
        }
    }

    private var normalizedConclusion: String { conclusion?.lowercased() ?? "" }

    public var isPending: Bool {
        status.lowercased() != "completed" || conclusion == nil
    }

    public var isSuccess: Bool {
        !isPending && normalizedConclusion == "success"
    }

    public var isSkipped: Bool {
        !isPending && ["skipped", "neutral", "stale"].contains(normalizedConclusion)
    }

    /// GitHub treats cancelled and startup failures of required checks as failing.
    public var isFailure: Bool {
        !isPending && !isSuccess && !isSkipped
    }

    public var group: Group {
        if isPending { return .running }
        if isFailure { return .failing }
        if isSkipped { return .skipped }
        return .passing
    }

    public var statusColor: Color {
        switch group {
        case .running: return .yellow
        case .passing: return .green
        case .skipped: return .secondary
        case .failing: return .red
        }
    }

    public var iconName: String {
        switch group {
        case .running: return "clock.fill"
        case .passing: return "checkmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        case .failing: return "xmark.circle.fill"
        }
    }

    public var displayConclusion: String {
        if isPending { return "Running" }
        return conclusion?.capitalized.replacingOccurrences(of: "_", with: " ") ?? "Completed"
    }

    /// GitHub Actions run / job ids parsed from `.../actions/runs/{run}/job/{job}` URLs.
    public var actionsRunId: String? { isActionsURL ? Self.pathComponent(after: "runs", in: htmlUrl) : nil }
    public var actionsJobId: String? { isActionsURL ? Self.pathComponent(after: "job", in: htmlUrl) : nil }
    /// Only `/actions/runs/...` links are Actions runs; `/runs/{id}` is a plain check-run page (e.g. SonarCloud).
    private var isActionsURL: Bool { htmlUrl?.contains("/actions/runs/") == true }

    public var isRerunnable: Bool {
        isFailure && actionsJobId != nil
    }

    public var durationText: String? {
        guard let start = startedAt else { return nil }
        let end = completedAt ?? Date()
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    /// Blocker priority: failed required, failed optional, pending required, pending optional,
    /// passed required, passed optional, then skipped.
    public var blockerPriority: Int {
        group.rawValue * 2 + (isRequired ? 0 : 1)
    }

    public static func sortedByBlockerPriority(_ checks: [PRCheckRun]) -> [PRCheckRun] {
        checks.sorted { a, b in
            if a.blockerPriority != b.blockerPriority { return a.blockerPriority < b.blockerPriority }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private static func pathComponent(after marker: String, in urlString: String?) -> String? {
        guard let urlString, let url = URL(string: urlString), url.host?.contains("github") == true else { return nil }
        let parts = url.pathComponents
        guard let idx = parts.firstIndex(of: marker), idx + 1 < parts.count else { return nil }
        let value = parts[idx + 1]
        return value.allSatisfy(\.isNumber) ? value : nil
    }
}

// MARK: - Labels, Reviewers & Detail Metadata

public struct PRLabel: Identifiable, Hashable, Codable, Sendable {
    public var id: String { name }
    public let name: String
    public let color: String   // hex without '#'
    public let description: String?

    public init(name: String, color: String, description: String? = nil) {
        self.name = name
        self.color = color
        self.description = description
    }

    public var swiftUIColor: Color {
        let hex = color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return .gray }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

public struct PRReviewerStatus: Identifiable, Hashable, Codable, Sendable {
    public var id: String { login }
    public let login: String
    public let avatarUrl: String?
    public let isTeam: Bool
    /// "APPROVED", "CHANGES_REQUESTED", "COMMENTED", "DISMISSED", or "REQUESTED" (awaiting review)
    public let state: String

    public init(login: String, avatarUrl: String?, isTeam: Bool = false, state: String) {
        self.login = login
        self.avatarUrl = avatarUrl
        self.isTeam = isTeam
        self.state = state
    }

    public var stateTitle: String {
        switch state {
        case "APPROVED": return "Approved"
        case "CHANGES_REQUESTED": return "Changes requested"
        case "COMMENTED": return "Commented"
        case "DISMISSED": return "Dismissed"
        default: return "Awaiting review"
        }
    }

    public var stateColor: Color {
        switch state {
        case "APPROVED": return .green
        case "CHANGES_REQUESTED": return .red
        case "COMMENTED": return .blue
        default: return .orange
        }
    }

    public var stateIcon: String {
        switch state {
        case "APPROVED": return "checkmark.circle.fill"
        case "CHANGES_REQUESTED": return "exclamationmark.circle.fill"
        case "COMMENTED": return "bubble.left.fill"
        case "DISMISSED": return "minus.circle"
        default: return "clock"
        }
    }
}

public struct PRThreadMeta: Hashable, Codable, Sendable {
    public let nodeId: String
    public let isResolved: Bool
    public let isOutdated: Bool
    public let resolvedBy: String?
    public let firstCommentDatabaseId: String
}

/// Extra per-PR metadata fetched via GraphQL: labels, reviewers, thread resolution and repo merge settings.
public struct PRDetailMeta: Hashable, Codable, Sendable {
    public let prNumber: Int
    public let nodeId: String
    public var labels: [PRLabel]
    public var reviewers: [PRReviewerStatus]
    public var threads: [PRThreadMeta]
    public var assignees: [PRReviewerStatus]? = nil
    public var participants: [PRReviewerStatus]? = nil
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or nil when reviews are not required.
    public var reviewDecision: String? = nil
    /// GraphQL `mergeStateStatus`: CLEAN, BLOCKED, BEHIND, DIRTY, UNSTABLE, HAS_HOOKS, DRAFT, UNKNOWN.
    public var mergeStateStatus: String? = nil
    /// `baseRef.refUpdateRule.viewerCanPush`; false means branch protection restricts who can merge.
    public var viewerCanPushToBase: Bool? = nil
    public var requiredApprovingReviewCount: Int? = nil
    public let viewerLogin: String?
    public let viewerPermission: String?   // ADMIN, MAINTAIN, WRITE, TRIAGE, READ
    public let viewerDidAuthor: Bool
    public let mergeCommitAllowed: Bool
    public let squashMergeAllowed: Bool
    public let rebaseMergeAllowed: Bool
    public let deleteBranchOnMerge: Bool

    public var canTriage: Bool {
        guard let p = viewerPermission else { return true }
        return ["ADMIN", "MAINTAIN", "WRITE", "TRIAGE"].contains(p)
    }

    public var canWrite: Bool {
        guard let p = viewerPermission else { return true }
        return ["ADMIN", "MAINTAIN", "WRITE"].contains(p)
    }

    public var allowedMergeMethods: [String] {
        var methods: [String] = []
        if squashMergeAllowed { methods.append("squash") }
        if mergeCommitAllowed { methods.append("merge") }
        if rebaseMergeAllowed { methods.append("rebase") }
        return methods.isEmpty ? ["merge"] : methods
    }

    /// Applies authoritative resolution status and thread node ids onto REST-derived timeline threads.
    public func applyingThreadState(to timeline: [PRTimelineItem]) -> [PRTimelineItem] {
        guard !threads.isEmpty else { return timeline }
        let byComment = Dictionary(threads.map { ($0.firstCommentDatabaseId, $0) }, uniquingKeysWith: { a, _ in a })
        return timeline.map { item in
            guard case .reviewThread(var thread) = item,
                  let meta = thread.comments.lazy.compactMap({ byComment[$0.id] }).first else { return item }
            thread.nodeId = meta.nodeId
            thread.isResolved = meta.isResolved
            thread.isOutdated = meta.isOutdated
            thread.resolvedByName = meta.resolvedBy
            return .reviewThread(thread)
        }
    }
}

// MARK: - Merge Readiness Engine

public struct PRMergeReadiness: Sendable {
    public enum Status: Sendable { case ready, blocked, pending, merged, closed }

    public let status: Status
    public let blockers: [String]
    public let failedRequired: Int
    public let failedOptional: Int
    public let pendingRequired: Int
    public let pendingOptional: Int
    public let passed: Int
    public let requiredTotal: Int
    public let unresolvedThreads: Int
    public let totalThreads: Int
    public let resolutionKnown: Bool
    public let isReviewBlocked: Bool
    public var isPushRestricted: Bool = false
    public var reviewVerdict: ReviewVerdict = .pending

    public var isMergeBlocked: Bool { status == .blocked || status == .pending }

    public var headline: String {
        switch status {
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .ready: return "Ready to merge"
        case .pending: return "Waiting on checks"
        case .blocked: return "Merging blocked"
        }
    }

    public static func evaluate(
        pr: PullRequest,
        checks: [PRCheckRun],
        timeline: [PRTimelineItem],
        meta: PRDetailMeta? = nil
    ) -> PRMergeReadiness {
        let failedRequired = checks.filter { $0.isFailure && $0.isRequired }.count
        let failedOptional = checks.filter { $0.isFailure && !$0.isRequired }.count
        let pendingRequired = checks.filter { $0.isPending && $0.isRequired }.count
        let pendingOptional = checks.filter { $0.isPending && !$0.isRequired }.count
        let passed = checks.filter(\.isSuccess).count
        let requiredTotal = checks.filter(\.isRequired).count

        let threads = timeline.compactMap { item -> PRReviewThread? in
            if case .reviewThread(let t) = item { return t }
            return nil
        }
        let resolutionKnown = threads.allSatisfy(\.isResolutionKnown)
        let unresolved = resolutionKnown ? threads.filter { !$0.isResolved }.count : 0
        let meta = meta?.prNumber == pr.number ? meta : nil
        let verdict = effectiveReviewVerdict(pr: pr, meta: meta)
        let isReviewBlocked: Bool
        switch meta?.reviewDecision {
        case "APPROVED": isReviewBlocked = false
        case "CHANGES_REQUESTED", "REVIEW_REQUIRED": isReviewBlocked = true
        default: isReviewBlocked = verdict == .changesRequested || (pr.isBlocked && verdict == .pending)
        }
        let pushRestricted = meta?.viewerCanPushToBase == false

        var blockers: [String] = []
        if pr.isDraft { blockers.append("Draft") }
        if pr.hasConflicts { blockers.append("Merge conflicts") }
        if failedRequired > 0 { blockers.append("\(failedRequired) required check\(failedRequired == 1 ? "" : "s") failing") }
        if verdict == .changesRequested {
            blockers.append("Changes requested")
        } else if isReviewBlocked {
            blockers.append("Approval required")
        }
        if unresolved > 0 { blockers.append("\(unresolved) unresolved conversation\(unresolved == 1 ? "" : "s")") }
        if pr.isBehind { blockers.append("Behind base branch") }
        if pushRestricted { blockers.append("You're not authorized to push to this branch") }
        let stateBlocked = meta?.mergeStateStatus.map { $0 == "BLOCKED" } ?? pr.isBlocked
        if blockers.isEmpty && stateBlocked && pendingRequired == 0 { blockers.append("Branch protection requirements unmet") }

        let status: Status
        switch pr.state {
        case .merged: status = .merged
        case .closed: status = .closed
        default:
            if !blockers.isEmpty { status = .blocked }
            else if pendingRequired > 0 { status = .pending }
            else { status = .ready }
        }

        return PRMergeReadiness(
            status: status,
            blockers: blockers,
            failedRequired: failedRequired,
            failedOptional: failedOptional,
            pendingRequired: pendingRequired,
            pendingOptional: pendingOptional,
            passed: passed,
            requiredTotal: requiredTotal,
            unresolvedThreads: unresolved,
            totalThreads: threads.count,
            resolutionKnown: resolutionKnown,
            isReviewBlocked: isReviewBlocked,
            isPushRestricted: pushRestricted,
            reviewVerdict: verdict
        )
    }

    /// GitHub's `reviewDecision` wins over the list row's cached verdict, which can lag behind new reviews.
    public static func effectiveReviewVerdict(pr: PullRequest, meta: PRDetailMeta?) -> ReviewVerdict {
        guard let meta, meta.prNumber == pr.number else { return pr.reviewVerdict }
        switch meta.reviewDecision {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .pending
        default:
            if meta.reviewers.contains(where: { $0.state == "CHANGES_REQUESTED" }) { return .changesRequested }
            if meta.reviewers.contains(where: { $0.state == "APPROVED" }) { return .approved }
            return pr.reviewVerdict
        }
    }
}

public enum PRDiffHelper {
    public static func parsePatch(patch: String, filename: String, additions: Int, deletions: Int) -> FileDiff {
        var hunks: [DiffHunk] = []
        var currentHeader = "@@ Changes @@"
        var currentLines: [DiffLine] = []
        var oldLine = 1
        var newLine = 1

        let lines = patch.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("@@") {
                if !currentLines.isEmpty {
                    hunks.append(DiffHunk(header: currentHeader, lines: currentLines))
                    currentLines.removeAll()
                }
                currentHeader = line
                let components = line.components(separatedBy: " ")
                if components.count >= 3 {
                    let oldPart = components[1].replacingOccurrences(of: "-", with: "")
                    let newPart = components[2].replacingOccurrences(of: "+", with: "")
                    oldLine = Int(oldPart.components(separatedBy: ",")[0]) ?? 1
                    newLine = Int(newPart.components(separatedBy: ",")[0]) ?? 1
                }
            } else if line.hasPrefix("+") {
                currentLines.append(DiffLine(type: .addition, content: line, oldLineNumber: nil, newLineNumber: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                currentLines.append(DiffLine(type: .deletion, content: line, oldLineNumber: oldLine, newLineNumber: nil))
                oldLine += 1
            } else if line.hasPrefix("\\") {
                continue
            } else {
                currentLines.append(DiffLine(type: .context, content: line, oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }

        if !currentLines.isEmpty {
            hunks.append(DiffHunk(header: currentHeader, lines: currentLines))
        }

        return FileDiff(path: filename, hunks: hunks, additions: additions, deletions: deletions)
    }
}

public struct GitHubRateLimitInfo: Codable, Sendable {
    public let remaining: Int
    public let limit: Int
    public let resetAt: Date
    public let cost: Int

    public var percentRemaining: Double {
        guard limit > 0 else { return 1.0 }
        return Double(remaining) / Double(limit)
    }

    public init(remaining: Int = 5000, limit: Int = 5000, resetAt: Date = Date().addingTimeInterval(3600), cost: Int = 1) {
        self.remaining = remaining
        self.limit = limit
        self.resetAt = resetAt
        self.cost = cost
    }
}

/// A commit on a pull request's branch (`GET /pulls/{n}/commits`).
public struct PRCommit: Identifiable, Hashable, Codable, Sendable {
    public var id: String { sha }
    public let sha: String
    public let message: String
    public let authorLogin: String?
    public let authorName: String
    public let authorAvatarUrl: String?
    public let date: Date
    public let htmlUrl: String?

    public init(sha: String, message: String, authorLogin: String?, authorName: String, authorAvatarUrl: String?, date: Date, htmlUrl: String?) {
        self.sha = sha
        self.message = message
        self.authorLogin = authorLogin
        self.authorName = authorName
        self.authorAvatarUrl = authorAvatarUrl
        self.date = date
        self.htmlUrl = htmlUrl
    }

    public var shortSha: String { String(sha.prefix(7)) }
    public var summary: String { message.components(separatedBy: "\n").first ?? message }
    public var body: String {
        let parts = message.components(separatedBy: "\n")
        return parts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
