import Foundation

public struct TerminalEntry: Identifiable, Sendable {
    public let id = UUID()
    public let command: String
    public let directoryName: String
    public let fullPath: String
    public let branchName: String
    public let isDirty: Bool
    public let commitsAhead: Int
    public let commitsBehind: Int
    public let shellName: String
    public let timestamp: Date
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let duration: TimeInterval
    public var isSuccess: Bool { exitCode == 0 }

    public init(
        command: String,
        directoryName: String,
        fullPath: String,
        branchName: String,
        isDirty: Bool,
        commitsAhead: Int,
        commitsBehind: Int,
        shellName: String = "bash",
        timestamp: Date,
        stdout: String,
        stderr: String,
        exitCode: Int32,
        duration: TimeInterval
    ) {
        self.command = command
        self.directoryName = directoryName
        self.fullPath = fullPath
        self.branchName = branchName
        self.isDirty = isDirty
        self.commitsAhead = commitsAhead
        self.commitsBehind = commitsBehind
        self.shellName = shellName
        self.timestamp = timestamp
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.duration = duration
    }
}
