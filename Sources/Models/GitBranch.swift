import Foundation

public struct GitBranch: Identifiable, Hashable, Codable, Sendable {
    public var id: String { name }
    public let name: String
    public let isCurrent: Bool
    public let isRemote: Bool
    public let upstreamBranch: String?
    public let commitsAhead: Int
    public let commitsBehind: Int

    public var displayName: String {
        if isRemote, name.hasPrefix("origin/") {
            return String(name.dropFirst("origin/".count))
        }
        return name
    }

    public init(
        name: String,
        isCurrent: Bool = false,
        isRemote: Bool = false,
        upstreamBranch: String? = nil,
        commitsAhead: Int = 0,
        commitsBehind: Int = 0
    ) {
        self.name = name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
        self.upstreamBranch = upstreamBranch
        self.commitsAhead = commitsAhead
        self.commitsBehind = commitsBehind
    }
}
