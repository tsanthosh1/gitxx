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
    /// Runs the failed operation again as-is, for after the user fixed things by hand.
    public var retry: GitFixAction? = nil
    /// The raw output is the explanation (e.g. a hook's findings), so it starts expanded.
    public var showOutput: Bool = false
    /// The few output lines that say what actually failed, shown above the full output.
    public var highlights: [String] = []
}

/// Digest of a rejecting hook's output (husky, lint-staged, pre-commit, secret scanners): which hook and task
/// failed, the lines that explain why, and the output without colour codes and per-file timing noise.
public struct HookFailure: Equatable {
    /// "husky pre-commit", "Detect hardcoded secrets"…
    public var hook: String?
    /// lint-staged / pre-commit tasks that failed ("prettier --write").
    public var tasks: [String] = []
    public var problems: [String] = []
    /// Absolute or repo-relative paths named in the problem lines.
    public var paths: [String] = []
    public var cleanedOutput: String = ""

    private static let ansi = try! NSRegularExpression(pattern: #"\u001B?\[[0-9;]*[mK]"#)
    private static let timing = try! NSRegularExpression(pattern: #"^\S+\s+\d+ms$"#)
    private static let huskyHook = try! NSRegularExpression(pattern: #"husky - (\S+) (?:hook|script) (?:exited|failed)"#)
    private static let preCommitFailed = try! NSRegularExpression(pattern: #"^(.+?)\.{3,}\s*Failed$"#)
    private static let lintStagedTask = try! NSRegularExpression(pattern: #"^✖\s+(.+?):?$"#)
    private static let path = try! NSRegularExpression(pattern: #"(?:/[\w.@+-]+)+|[\w.@+-]+(?:/[\w.@+-]+)*\.[A-Za-z0-9]{1,8}\b"#)

    public static func stripANSI(_ text: String) -> String {
        ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    public init(output raw: String) {
        let text = Self.stripANSI(raw)
        var kept: [String] = []
        var hiddenTimings = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if Self.matches(Self.timing, trimmed) { hiddenTimings += 1; continue }
            kept.append(line)
            if let name = Self.capture(Self.huskyHook, trimmed) { hook = "husky \(name)" }
            if let name = Self.capture(Self.preCommitFailed, trimmed) {
                if hook == nil { hook = name }
                tasks.append(name)
                problems.append(trimmed)
            }
            if let task = Self.capture(Self.lintStagedTask, trimmed), !trimmed.contains("[FAILED]") {
                tasks.append(task)
            }
            let lower = trimmed.lowercased()
            let isProblem = trimmed.hasPrefix("✖") || lower.hasPrefix("[error]") || lower.hasPrefix("error")
                || lower.hasPrefix("fatal:") || lower.contains(" error ") || lower.contains("leak")
                || lower.contains("secret") && !lower.hasSuffix("passed")
                || lower.contains("exited with code")
            if isProblem, !trimmed.contains("[STARTED]"), !trimmed.contains("[COMPLETED]"), !problems.contains(trimmed) {
                problems.append(trimmed)
            }
        }
        if hiddenTimings > 0 {
            kept.append("(\(hiddenTimings) lines of per-file timings hidden)")
        }
        cleanedOutput = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        tasks = tasks.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        for problem in problems {
            let range = NSRange(problem.startIndex..., in: problem)
            for match in Self.path.matches(in: problem, range: range) {
                guard let r = Range(match.range, in: problem) else { continue }
                let candidate = String(problem[r])
                if !paths.contains(candidate) { paths.append(candidate) }
            }
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func capture(_ regex: NSRegularExpression, _ text: String) -> String? {
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
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
    /// A pre-commit / commit-msg / pre-push hook (lint, secret scanner…) refused the operation.
    case hookRejected
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
        // Before `.conflicts` and `.pushRejected`: hook output routinely lists checks like "check for merge conflicts".
        if isHookOutput(lower) {
            return .hookRejected
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

    private static let hookMarkers = [
        "pre-commit", "commit-msg", "pre-push", "pre-merge-commit", "prepare-commit-msg", "hook declined", "hook failed",
        "husky", "lint-staged", "gitleaks", "talisman", "detect-secrets", "ggshield", "trufflehog", "git-secrets",
        "secret detected", "secrets detected", "potential secret", "leaks found", "leak found",
    ]

    static func isHookOutput(_ lower: String) -> Bool {
        hookMarkers.contains { lower.contains($0) }
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
