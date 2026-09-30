import Foundation
import SwiftUI

// MARK: - GitHub Actions models

public struct ActionsWorkflow: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let path: String
    /// active, disabled_manually, disabled_inactivity, deleted, disabled_fork
    public let state: String
    public let htmlUrl: String?

    public var isActive: Bool { state == "active" }
    public var fileName: String { (path as NSString).lastPathComponent }
}

/// Shared status vocabulary for runs, jobs and steps.
public enum ActionsStatus: Int, Sendable, Comparable {
    case failure, running, queued, waiting, success, cancelled, skipped, neutral

    public static func < (a: ActionsStatus, b: ActionsStatus) -> Bool { a.rawValue < b.rawValue }

    public init(status: String, conclusion: String?) {
        switch status {
        case "completed":
            switch conclusion ?? "" {
            case "success": self = .success
            case "failure", "timed_out", "startup_failure": self = .failure
            case "cancelled": self = .cancelled
            case "skipped": self = .skipped
            case "action_required": self = .waiting
            default: self = .neutral
            }
        case "in_progress": self = .running
        case "waiting", "action_required", "pending", "requested": self = .waiting
        default: self = .queued
        }
    }

    public var isActive: Bool { self == .running || self == .queued || self == .waiting }

    public var color: Color {
        switch self {
        case .failure: return .red
        case .running, .queued, .waiting: return .yellow
        case .success: return .green
        case .cancelled, .skipped, .neutral: return .secondary
        }
    }

    public var iconName: String {
        switch self {
        case .failure: return "xmark.circle.fill"
        case .running: return "circle.dotted.circle"
        case .queued: return "clock"
        case .waiting: return "pause.circle"
        case .success: return "checkmark.circle.fill"
        case .cancelled: return "slash.circle"
        case .skipped: return "minus.circle"
        case .neutral: return "circle"
        }
    }

    public var label: String {
        switch self {
        case .failure: return "Failed"
        case .running: return "In progress"
        case .queued: return "Queued"
        case .waiting: return "Waiting"
        case .success: return "Success"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        case .neutral: return "Neutral"
        }
    }
}

public struct ActionsRun: Identifiable, Hashable, Sendable {
    public let id: Int
    public let workflowId: Int
    public let workflowName: String
    public let displayTitle: String
    public let runNumber: Int
    public let runAttempt: Int
    public let event: String
    public let status: String
    public let conclusion: String?
    public let headBranch: String
    public let headSha: String
    public let actorLogin: String
    public let actorAvatarUrl: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let runStartedAt: Date?
    public let htmlUrl: String
    public let workflowPath: String
    /// Same-repository PRs GitHub associated with this run (empty for fork PRs).
    public let pullRequestNumbers: [Int]

    public var actionsStatus: ActionsStatus { ActionsStatus(status: status, conclusion: conclusion) }
    public var shortSha: String { String(headSha.prefix(7)) }

    public var duration: TimeInterval {
        let start = runStartedAt ?? createdAt
        let end = actionsStatus.isActive ? Date() : updatedAt
        return max(0, end.timeIntervalSince(start))
    }

    public var eventLabel: String {
        switch event {
        case "pull_request", "pull_request_target": return "Pull request"
        case "push": return "Push"
        case "workflow_dispatch": return "Manual"
        case "schedule": return "Schedule"
        case "merge_group": return "Merge queue"
        case "release": return "Release"
        case "workflow_run": return "Workflow run"
        case "repository_dispatch": return "Repository dispatch"
        default: return event.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

public struct ActionsStep: Identifiable, Hashable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let name: String
    public let status: String
    public let conclusion: String?
    public let startedAt: Date?
    public let completedAt: Date?

    public var actionsStatus: ActionsStatus { ActionsStatus(status: status, conclusion: conclusion) }
    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (completedAt ?? Date()).timeIntervalSince(startedAt))
    }
}

public struct ActionsJob: Identifiable, Hashable, Sendable {
    public let id: Int
    public let runId: Int
    public let name: String
    public let status: String
    public let conclusion: String?
    public let startedAt: Date?
    public let completedAt: Date?
    public let htmlUrl: String?
    public let runnerName: String?
    public let labels: [String]
    public let steps: [ActionsStep]

    public var actionsStatus: ActionsStatus { ActionsStatus(status: status, conclusion: conclusion) }
    public var duration: TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (completedAt ?? Date()).timeIntervalSince(startedAt))
    }
    /// Matrix jobs are named "build (ubuntu, 18)"; the prefix groups them.
    public var groupName: String {
        guard let paren = name.firstIndex(of: "(") else { return name }
        return name[..<paren].trimmingCharacters(in: .whitespaces)
    }
}

public struct ActionsArtifact: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let sizeInBytes: Int
    public let expired: Bool
    public let expiresAt: Date?
    public let archiveDownloadUrl: String
}

public struct ActionsAnnotation: Identifiable, Hashable, Sendable {
    public var id: String { "\(jobId)-\(path)-\(startLine)-\(message.hashValue)" }
    public let jobId: Int
    public let jobName: String
    /// failure, warning, notice
    public let level: String
    public let title: String?
    public let message: String
    public let path: String
    public let startLine: Int

    public var color: Color { level == "failure" ? .red : (level == "warning" ? .orange : .blue) }
    public var iconName: String {
        level == "failure" ? "xmark.octagon.fill" : (level == "warning" ? "exclamationmark.triangle.fill" : "info.circle.fill")
    }
}

/// One `workflow_dispatch` input, parsed from the workflow file.
public struct ActionsDispatchInput: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public var description: String?
    public var type: String = "string"
    public var required: Bool = false
    public var defaultValue: String?
    public var options: [String] = []
}

public struct ActionsRunFilter: Equatable, Sendable {
    public var workflowId: Int?
    public var branch: String?
    public var event: String?
    /// Server-side `status` query value (success, failure, in_progress, queued, cancelled, …).
    public var status: String?
    public var actor: String?

    public var isEmpty: Bool { workflowId == nil && branch == nil && event == nil && status == nil && actor == nil }
}

public enum ActionsFormat {
    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    public static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    nonisolated(unsafe) private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    @MainActor public static func relativeDate(_ date: Date) -> String {
        relative.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Step log slicing

public enum ActionsStepLog {
    /// Splits a raw job log into per-step chunks. Steps run in order, so lines are walked once and the current step
    /// only advances once it has finished and the next one has started. Step times have one-second precision and
    /// several steps often share a second, so the `##[group]Run …` / "Post job cleanup." line that opens each step
    /// decides the exact boundary.
    public static func split(raw: String, steps: [ActionsStep]) -> [Int: String] {
        let ordered = steps
            .filter { $0.startedAt != nil && $0.actionsStatus != .skipped }
            .sorted { $0.number < $1.number }
        guard !ordered.isEmpty else { return [:] }
        var buckets: [Int: [Substring]] = [:]
        var index = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if let ts = timestamp(line) {
                let second = ts.timeIntervalSince1970.rounded(.down)
                let body = line.drop(while: { $0 != " " }).dropFirst()
                let opensStep = body.hasPrefix("##[group]Run ") || body.hasPrefix("Post job cleanup.")
                    || body.hasPrefix("Cleaning up orphan processes")
                while index + 1 < ordered.count {
                    let current = ordered[index], next = ordered[index + 1]
                    let nextStart = next.startedAt!.timeIntervalSince1970
                    let currentEnd = current.completedAt?.timeIntervalSince1970 ?? .infinity
                    guard nextStart <= second, currentEnd <= second else { break }
                    if opensStep {
                        index += 1
                        break
                    }
                    // Steps without an opening marker: advance once the line is clearly past the next step's start.
                    guard second > nextStart + 1 else { break }
                    index += 1
                }
            }
            buckets[ordered[index].number, default: []].append(line)
        }
        return buckets.mapValues { $0.joined(separator: "\n") }
    }

    nonisolated(unsafe) private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func timestamp(_ line: Substring) -> Date? {
        guard line.count > 28, line.utf8.dropFirst(4).first == UInt8(ascii: "-"),
              let space = line.firstIndex(of: " "), line.distance(from: line.startIndex, to: space) <= 36 else { return nil }
        var stamp = String(line[..<space])
        // Actions uses 7 fractional digits; ISO8601DateFormatter accepts at most 3.
        if let dot = stamp.firstIndex(of: "."), let z = stamp.lastIndex(of: "Z") {
            let fraction = stamp[stamp.index(after: dot)..<z]
            stamp = String(stamp[..<dot]) + "." + String(fraction.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + "Z"
        }
        return parser.date(from: stamp)
    }
}

// MARK: - Job tree

/// Jobs arranged the way their names are structured: "caller / reusable / job" segments become nested groups,
/// and matrix legs such as "build (ubuntu)" / "build (macos)" are grouped under "build".
public struct ActionsJobNode: Identifiable, Sendable {
    public let id: String
    public var title: String
    public var job: ActionsJob?
    public var children: [ActionsJobNode] = []

    public var isGroup: Bool { job == nil }
    public var leaves: [ActionsJob] { job.map { [$0] } ?? children.flatMap(\.leaves) }

    public var status: ActionsStatus {
        if let job { return job.actionsStatus }
        let all = leaves.map(\.actionsStatus)
        if all.contains(.failure) { return .failure }
        if all.contains(.running) { return .running }
        if all.contains(where: \.isActive) { return all.contains(.waiting) ? .waiting : .queued }
        if all.allSatisfy({ $0 == .skipped }) { return .skipped }
        if all.contains(.cancelled) { return .cancelled }
        return all.contains(.success) ? .success : .neutral
    }

    /// Wall-clock time from the first job starting to the last one finishing.
    public var duration: TimeInterval? {
        if let job { return job.duration }
        let jobs = leaves
        guard let start = jobs.compactMap(\.startedAt).min() else { return nil }
        let end = jobs.contains { $0.actionsStatus.isActive } ? Date() : (jobs.compactMap(\.completedAt).max() ?? Date())
        return max(0, end.timeIntervalSince(start))
    }

    public static func tree(_ jobs: [ActionsJob]) -> [ActionsJobNode] {
        var roots: [ActionsJobNode] = []
        let ordered = jobs.sorted { ($0.startedAt ?? .distantFuture, $0.id) < ($1.startedAt ?? .distantFuture, $1.id) }
        for job in ordered {
            let parts = job.name.components(separatedBy: " / ").map { $0.trimmingCharacters(in: .whitespaces) }
            insert(job, path: parts[...], prefix: "", into: &roots)
        }
        return roots.map(normalize)
    }

    private static func insert(_ job: ActionsJob, path: ArraySlice<String>, prefix: String, into nodes: inout [ActionsJobNode]) {
        guard path.count > 1, let head = path.first else {
            nodes.append(ActionsJobNode(id: "job-\(job.id)", title: path.first ?? job.name, job: job))
            return
        }
        let groupId = prefix + "/" + head
        if let i = nodes.firstIndex(where: { $0.id == groupId }) {
            insert(job, path: path.dropFirst(), prefix: groupId, into: &nodes[i].children)
        } else {
            var group = ActionsJobNode(id: groupId, title: head)
            insert(job, path: path.dropFirst(), prefix: groupId, into: &group.children)
            nodes.append(group)
        }
    }

    /// Groups matrix legs, then folds groups that hold a single entry back into one row.
    private static func normalize(_ node: ActionsJobNode) -> ActionsJobNode {
        guard node.isGroup else { return node }
        var copy = node
        copy.children = groupMatrix(node.children.map(normalize), parentId: node.id)
        if copy.children.count == 1, let only = copy.children.first {
            var merged = only
            merged.title = node.title + " / " + only.title
            return merged
        }
        return copy
    }

    private static func groupMatrix(_ nodes: [ActionsJobNode], parentId: String) -> [ActionsJobNode] {
        func split(_ title: String) -> (base: String, leg: String)? {
            guard title.hasSuffix(")"), let open = title.lastIndex(of: "("), open > title.startIndex else { return nil }
            let base = title[..<open].trimmingCharacters(in: .whitespaces)
            let leg = String(title[title.index(after: open)..<title.index(before: title.endIndex)])
            return base.isEmpty ? nil : (base, leg)
        }
        var counts: [String: Int] = [:]
        for node in nodes where !node.isGroup { if let base = split(node.title)?.base { counts[base, default: 0] += 1 } }
        var result: [ActionsJobNode] = []
        for node in nodes {
            guard !node.isGroup, let parts = split(node.title), counts[parts.base, default: 0] > 1 else {
                result.append(node)
                continue
            }
            var leg = node
            leg.title = parts.leg
            let groupId = parentId + "/matrix:" + parts.base
            if let i = result.firstIndex(where: { $0.id == groupId }) {
                result[i].children.append(leg)
            } else {
                result.append(ActionsJobNode(id: groupId, title: parts.base, children: [leg]))
            }
        }
        return result
    }
}

public struct ActionsFullScreenLog: Equatable, Sendable {
    public let jobId: Int
    public var expanded: Set<Int>
    public var query: String
}
