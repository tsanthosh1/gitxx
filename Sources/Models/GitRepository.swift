import Foundation

public struct GitRepository: Identifiable, Hashable, Codable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public var currentBranch: String
    public var remoteUrl: String?
    public var lastFetched: Date?
    public var commitsAhead: Int
    public var commitsBehind: Int

    public init(
        name: String,
        path: String,
        currentBranch: String = "main",
        remoteUrl: String? = nil,
        lastFetched: Date? = nil,
        commitsAhead: Int = 0,
        commitsBehind: Int = 0
    ) {
        self.name = name
        self.path = path
        self.currentBranch = currentBranch
        self.remoteUrl = remoteUrl
        self.lastFetched = lastFetched
        self.commitsAhead = commitsAhead
        self.commitsBehind = commitsBehind
    }
}
