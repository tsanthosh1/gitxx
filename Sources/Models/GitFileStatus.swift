import Foundation
import SwiftUI

public enum GitFileChangeKind: String, Codable, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case untracked = "?"
    case copied = "C"
    case unmerged = "U"

    public var badgeLabel: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "U"
        case .copied: return "C"
        case .unmerged: return "!"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .modified: return Color.orange
        case .added, .untracked: return Color.green
        case .deleted: return Color.red
        case .renamed, .copied: return Color.blue
        case .unmerged: return Color.purple
        }
    }
}

public struct GitFileStatus: Identifiable, Hashable, Codable, Sendable {
    /// A partially staged file appears twice (index and working tree), so the id includes the side.
    public var id: String { (isStaged ? "index:" : "worktree:") + path }
    public let path: String
    public let filename: String
    public let directory: String
    public var changeKind: GitFileChangeKind
    public var isStaged: Bool
    public var additions: Int
    public var deletions: Int

    public init(
        path: String,
        changeKind: GitFileChangeKind,
        isStaged: Bool = false,
        additions: Int = 0,
        deletions: Int = 0
    ) {
        self.path = path
        let nsPath = path as NSString
        self.filename = nsPath.lastPathComponent
        let dir = nsPath.deletingLastPathComponent
        self.directory = (dir.isEmpty || dir == ".") ? "" : dir
        self.changeKind = changeKind
        self.isStaged = isStaged
        self.additions = additions
        self.deletions = deletions
    }
}

/// One changed path in the Changes list, combining its index (staged) and working-tree (unstaged) entries.
public struct WorkingChange: Identifiable, Hashable, Sendable, FileTreeItem {
    public enum StageState: Sendable { case none, partial, all }

    public var id: String { path }
    public let path: String
    public let index: GitFileStatus?
    public let worktree: GitFileStatus?

    public var treePath: String { path }
    public var filename: String { (index ?? worktree)?.filename ?? path }
    public var directory: String { (index ?? worktree)?.directory ?? "" }

    /// What the file's change is relative to HEAD (a staged add stays "added" even with later edits).
    public var changeKind: GitFileChangeKind {
        if let index, index.changeKind == .added || index.changeKind == .renamed || index.changeKind == .copied {
            return index.changeKind
        }
        return (worktree ?? index)?.changeKind ?? .modified
    }

    public var stageState: StageState {
        switch (index != nil, worktree != nil) {
        case (true, true): return .partial
        case (true, false): return .all
        default: return .none
        }
    }

    /// The entry the diff and actions default to.
    public var primary: GitFileStatus { worktree ?? index! }

    public static func group(_ files: [GitFileStatus]) -> [WorkingChange] {
        var order: [String] = []
        var index: [String: GitFileStatus] = [:]
        var worktree: [String: GitFileStatus] = [:]
        for file in files {
            if index[file.path] == nil && worktree[file.path] == nil { order.append(file.path) }
            if file.isStaged { index[file.path] = file } else { worktree[file.path] = file }
        }
        return order.map { WorkingChange(path: $0, index: index[$0], worktree: worktree[$0]) }
    }
}

/// A `+`/`-` row of a diff: hunk index plus the row's index within `DiffHunk.lines`.
public struct DiffLineKey: Hashable, Sendable, Comparable {
    public let hunk: Int
    public let line: Int
    public init(hunk: Int, line: Int) { self.hunk = hunk; self.line = line }
    public static func < (a: DiffLineKey, b: DiffLineKey) -> Bool { (a.hunk, a.line) < (b.hunk, b.line) }
}
