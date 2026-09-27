import Foundation

public struct GitCommit: Identifiable, Hashable, Codable, Sendable {
    public var id: String { sha }
    public let sha: String
    public var shortSha: String { String(sha.prefix(7)) }
    public let summary: String
    public let body: String
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let parentShas: [String]
    public var touchedFilesCount: Int
    /// Ref decorations (`git log %D`), e.g. `HEAD -> main`, `origin/main`, `tag: v1.2`.
    public var refs: [String] = []

    public var tagNames: [String] {
        refs.compactMap { $0.hasPrefix("tag: ") ? String($0.dropFirst(5)) : nil }
    }

    public var branchNames: [String] {
        refs.compactMap { ref in
            if ref.hasPrefix("tag: ") || ref == "HEAD" { return nil }
            return ref.hasPrefix("HEAD -> ") ? String(ref.dropFirst(8)) : ref
        }
    }

    public var isMerge: Bool { parentShas.count > 1 }

    public var relativeDateString: String {
        PRDateFormatterHelper.shared.formatRelative(date: authorDate)
    }

    public init(
        sha: String,
        summary: String,
        body: String = "",
        authorName: String,
        authorEmail: String = "",
        authorDate: Date = Date(),
        parentShas: [String] = [],
        touchedFilesCount: Int = 0
    ) {
        self.sha = sha
        self.summary = summary
        self.body = body
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.parentShas = parentShas
        self.touchedFilesCount = touchedFilesCount
    }
}
