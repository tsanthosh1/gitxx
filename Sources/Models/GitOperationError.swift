import Foundation

/// A failed git (or GitHub) operation shown in a dialog with an explanation and one-click fixes.
public struct GitOperationError: Identifiable {
    public let id = UUID()
    public let title: String
    /// Plain-language explanation of what went wrong.
    public let summary: String
    /// Raw git / API output.
    public let details: String
    /// Files named in the error (e.g. local changes that block a pull).
    public let files: [String]
    public let actions: [GitFixAction]
}

public struct GitFixAction: Identifiable {
    public enum Role { case primary, normal, destructive }

    public let id = UUID()
    public let title: String
    public let systemImage: String
    public let role: Role
    /// Destructive actions ask for confirmation with this text first.
    public let confirmation: String?
    public let perform: @MainActor () async -> Void

    public init(_ title: String, systemImage: String, role: Role = .normal, confirmation: String? = nil,
                perform: @escaping @MainActor () async -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.confirmation = confirmation
        self.perform = perform
    }
}

/// Recognises common git failures from their output.
public enum GitErrorKind: Equatable {
    case localChangesOverwritten(files: [String])
    case untrackedOverwritten(files: [String])
    case indexLocked(lockPath: String?)
    case pushRejected
    case divergentBranches
    case conflicts
    case noUpstream
    case unknownRef
    case network
    case authentication
    case other

    public static func classify(_ output: String) -> GitErrorKind {
        let lower = output.lowercased()
        if lower.contains("your local changes to the following files would be overwritten") {
            return .localChangesOverwritten(files: indentedFiles(after: "would be overwritten", in: output))
        }
        if lower.contains("untracked working tree files would be overwritten") || lower.contains("untracked working tree files would be removed") {
            return .untrackedOverwritten(files: indentedFiles(after: "untracked working tree files would be", in: output))
        }
        if lower.contains("index.lock") && (lower.contains("file exists") || lower.contains("unable to create")) {
            let path = output.range(of: #"'[^']*index\.lock'"#, options: .regularExpression)
                .map { String(output[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            return .indexLocked(lockPath: path)
        }
        if lower.contains("[rejected]") || lower.contains("non-fast-forward") || lower.contains("updates were rejected")
            || lower.contains("fetch first") {
            return .pushRejected
        }
        if lower.contains("divergent branches") || lower.contains("not possible to fast-forward") {
            return .divergentBranches
        }
        if lower.contains("conflict") || lower.contains("automatic merge failed") || lower.contains("fix conflicts")
            || lower.contains("you have unmerged paths") || lower.contains("needs merge") {
            return .conflicts
        }
        if lower.contains("has no upstream branch") || lower.contains("no tracking information") {
            return .noUpstream
        }
        if lower.contains("did not match any file(s) known to git") || lower.contains("invalid reference")
            || lower.contains("couldn't find remote ref") || lower.contains("unknown revision") {
            return .unknownRef
        }
        if lower.contains("could not resolve host") || lower.contains("connection timed out")
            || lower.contains("unable to access") || lower.contains("network is unreachable") {
            return .network
        }
        if lower.contains("permission denied (publickey)") || lower.contains("authentication failed")
            || lower.contains("could not read username") || lower.contains("repository not found") {
            return .authentication
        }
        return .other
    }

    /// Tab-indented paths that git lists after a header line, up to the next non-indented line.
    static func indentedFiles(after marker: String, in output: String) -> [String] {
        let lines = output.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.lowercased().contains(marker) }) else { return [] }
        var files: [String] = []
        for line in lines[(start + 1)...] {
            guard line.hasPrefix("\t") || line.hasPrefix("    ") else { break }
            let path = line.trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { files.append(path) }
        }
        return files
    }
}
