import Foundation
import SwiftUI

public enum DiffLineType: String, Codable, Sendable {
    case context
    case addition
    case deletion
    case hunkHeader

    public var backgroundColor: Color {
        switch self {
        case .context:
            return Color.clear
        case .addition:
            return Color.green.opacity(0.15)
        case .deletion:
            return Color.red.opacity(0.15)
        case .hunkHeader:
            return Color.accentColor.opacity(0.12)
        }
    }

    public var textColor: Color {
        switch self {
        case .context:
            return Color.primary
        case .addition:
            return Color.green
        case .deletion:
            return Color.red
        case .hunkHeader:
            return Color.accentColor
        }
    }

    public var prefixSymbol: String {
        switch self {
        case .context: return " "
        case .addition: return "+"
        case .deletion: return "-"
        case .hunkHeader: return "@"
        }
    }
}

public struct DiffLine: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(oldLineNumber ?? -1):\(newLineNumber ?? -1):\(content.prefix(20))" }
    public let type: DiffLineType
    public let content: String
    public let oldLineNumber: Int?
    public let newLineNumber: Int?

    public init(type: DiffLineType, content: String, oldLineNumber: Int? = nil, newLineNumber: Int? = nil) {
        self.type = type
        self.content = content
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

public struct DiffHunk: Identifiable, Hashable, Codable, Sendable {
    public var id: String { header }
    public let header: String
    public let lines: [DiffLine]
    /// Indices into `lines` that were followed by a `\ No newline at end of file` marker.
    public var noNewlineAfter: Set<Int> = []

    public init(header: String, lines: [DiffLine], noNewlineAfter: Set<Int> = []) {
        self.header = header
        self.lines = lines
        self.noNewlineAfter = noNewlineAfter
    }
}

public struct FileDiff: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public let path: String
    public let oldPath: String?
    public let hunks: [DiffHunk]
    public let additions: Int
    public let deletions: Int
    public let isBinary: Bool
    /// Raw `diff --git` / `---` / `+++` lines preceding the first hunk; needed to rebuild partial patches.
    public var patchHeader: [String] = []

    public var allLines: [DiffLine] {
        hunks.flatMap { $0.lines }
    }

    public init(
        path: String,
        oldPath: String? = nil,
        hunks: [DiffHunk] = [],
        additions: Int = 0,
        deletions: Int = 0,
        isBinary: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.hunks = hunks
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
    }
}
