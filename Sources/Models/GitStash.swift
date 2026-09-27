import Foundation

public struct GitStash: Identifiable, Hashable, Sendable {
    public var id: String { ref }
    /// `stash@{N}`
    public let ref: String
    /// Reflog subject, e.g. "On main: wip parser" or "WIP on main: 1a2b3c4 Fix build".
    public let subject: String
    public let date: Date

    public init(ref: String, subject: String, date: Date) {
        self.ref = ref
        self.subject = subject
        self.date = date
    }

    public var branch: String? {
        guard let on = subject.range(of: "on ", options: .caseInsensitive), let colon = subject.range(of: ":", range: on.upperBound..<subject.endIndex) else { return nil }
        return String(subject[on.upperBound..<colon.lowerBound])
    }

    /// Message without the "On branch:" prefix.
    public var message: String {
        guard let colon = subject.firstIndex(of: ":") else { return subject }
        return subject[subject.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
}
