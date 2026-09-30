import Foundation

/// What is in progress when files are left unmerged.
public enum ConflictOperation: String, Sendable {
    case merge, rebase, cherryPick, revert, stashPop

    public var title: String {
        switch self {
        case .merge: return "Merge"
        case .rebase: return "Rebase"
        case .cherryPick: return "Cherry-pick"
        case .revert: return "Revert"
        case .stashPop: return "Stash apply"
        }
    }

    /// `git <verb> --continue / --abort`; stash conflicts have neither.
    var verb: String? {
        switch self {
        case .merge: return "merge"
        case .rebase: return "rebase"
        case .cherryPick: return "cherry-pick"
        case .revert: return "revert"
        case .stashPop: return nil
        }
    }
}

/// The two sides of a conflict, named the way the operation means them.
public struct ConflictSides: Sendable, Equatable {
    public let operation: ConflictOperation
    /// Stage 2 ("ours"): the checked-out branch, or during a rebase the branch being rebased onto.
    public let oursTitle: String
    public let oursDetail: String
    /// Stage 3 ("theirs"): the branch being merged, or during a rebase your commit being replayed.
    public let theirsTitle: String
    public let theirsDetail: String
}

/// One conflicted file split into shared text and conflicting hunks (git has already merged everything else).
public struct ConflictDocument: Sendable {
    public enum Segment: Sendable {
        case common([String])
        case conflict(id: Int, ours: [String], base: [String], theirs: [String])
    }

    public let path: String
    public let segments: [Segment]
    public let oursMissing: Bool
    public let theirsMissing: Bool
    public let isBinary: Bool
    public let trailingNewline: Bool

    public var conflictCount: Int {
        segments.reduce(0) { if case .conflict = $1 { return $0 + 1 }; return $0 }
    }
}

public enum ConflictMerge {
    private static let git = GitService.shared

    // MARK: Discovery

    public static func operation(repo: String) async -> ConflictOperation {
        guard let gitDir = try? await git.execute(arguments: ["rev-parse", "--absolute-git-dir"], in: repo),
              gitDir.isSuccess else { return .merge }
        return inProgress(gitDir: gitDir.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .stashPop
    }

    /// The merge, rebase, cherry-pick or revert waiting to be concluded, if any.
    public static func inProgress(repo: String) async -> ConflictOperation? {
        guard let gitDir = try? await git.execute(arguments: ["rev-parse", "--absolute-git-dir"], in: repo),
              gitDir.isSuccess else { return nil }
        return inProgress(gitDir: gitDir.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func inProgress(gitDir dir: String) -> ConflictOperation? {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir + "/rebase-merge") || fm.fileExists(atPath: dir + "/rebase-apply") { return .rebase }
        if fm.fileExists(atPath: dir + "/CHERRY_PICK_HEAD") { return .cherryPick }
        if fm.fileExists(atPath: dir + "/REVERT_HEAD") { return .revert }
        if fm.fileExists(atPath: dir + "/MERGE_HEAD") { return .merge }
        return nil
    }

    public static func sides(repo: String) async -> ConflictSides {
        let op = await operation(repo: repo)
        func run(_ args: [String]) async -> String {
            guard let res = try? await git.execute(arguments: args, in: repo), res.isSuccess else { return "" }
            return res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let head = await run(["rev-parse", "--abbrev-ref", "HEAD"])
        let headSubject = await run(["log", "-1", "--format=%h %s", "HEAD"])
        switch op {
        case .rebase:
            let onto = await run(["log", "-1", "--format=%h %s", "REBASE_HEAD"])
            return ConflictSides(operation: op, oursTitle: "Upstream", oursDetail: "Already rebased: \(headSubject)",
                                 theirsTitle: "Your commit", theirsDetail: onto.isEmpty ? "Commit being replayed" : onto)
        case .cherryPick, .revert:
            let ref = op == .cherryPick ? "CHERRY_PICK_HEAD" : "REVERT_HEAD"
            let subject = await run(["log", "-1", "--format=%h %s", ref])
            return ConflictSides(operation: op, oursTitle: "Yours", oursDetail: head,
                                 theirsTitle: op == .cherryPick ? "Cherry-picked" : "Reverted", theirsDetail: subject)
        case .merge:
            var incoming = await run(["name-rev", "--name-only", "--exclude=tags/*", "MERGE_HEAD"])
            if incoming.isEmpty || incoming == "undefined" { incoming = await run(["log", "-1", "--format=%h", "MERGE_HEAD"]) }
            return ConflictSides(operation: op, oursTitle: "Yours", oursDetail: head, theirsTitle: "Theirs", theirsDetail: incoming)
        case .stashPop:
            return ConflictSides(operation: op, oursTitle: "Yours", oursDetail: head, theirsTitle: "Stashed", theirsDetail: "stash")
        }
    }

    // MARK: Loading

    public static func load(repo: String, path: String) async throws -> ConflictDocument {
        async let base = blob(repo: repo, stage: 1, path: path)
        async let ours = blob(repo: repo, stage: 2, path: path)
        async let theirs = blob(repo: repo, stage: 3, path: path)
        let (b, o, t) = await (base, ours, theirs)

        let isBinary = [b, o, t].contains { $0?.contains("\u{0}") == true }
        if o == nil || t == nil || isBinary {
            return ConflictDocument(path: path, segments: [], oursMissing: o == nil, theirsMissing: t == nil,
                                    isBinary: isBinary, trailingNewline: true)
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gitxx-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let files = ["ours", "base", "theirs"].map { tmp.appendingPathComponent($0) }
        try (o ?? "").write(to: files[0], atomically: true, encoding: .utf8)
        try (b ?? "").write(to: files[1], atomically: true, encoding: .utf8)
        try (t ?? "").write(to: files[2], atomically: true, encoding: .utf8)
        let res = try await git.execute(arguments: ["merge-file", "-p", "--diff3", "-L", "ours", "-L", "base", "-L", "theirs"]
                                        + files.map(\.path), in: repo)
        guard res.exitCode >= 0 else { throw NSError(domain: "ConflictMerge", code: 1, userInfo: [NSLocalizedDescriptionKey: res.stderr]) }
        let merged = res.stdout
        return ConflictDocument(path: path, segments: parse(merged), oursMissing: false, theirsMissing: false,
                                isBinary: false, trailingNewline: merged.hasSuffix("\n") || merged.isEmpty)
    }

    private static func blob(repo: String, stage: Int, path: String) async -> String? {
        guard let res = try? await git.execute(arguments: ["show", ":\(stage):\(path)"], in: repo), res.isSuccess else { return nil }
        return res.stdout
    }

    /// Splits `git merge-file --diff3` output into shared runs and conflict hunks.
    static func parse(_ text: String) -> [ConflictDocument.Segment] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var segments: [ConflictDocument.Segment] = []
        var common: [String] = []
        var ours: [String] = [], base: [String] = [], theirs: [String] = []
        enum Mode { case common, ours, base, theirs }
        var mode = Mode.common
        var nextId = 0

        for line in lines {
            switch mode {
            case .common:
                if line.hasPrefix("<<<<<<< ") || line == "<<<<<<<" {
                    if !common.isEmpty { segments.append(.common(common)); common = [] }
                    mode = .ours
                } else {
                    common.append(line)
                }
            case .ours:
                if line.hasPrefix("||||||| ") || line == "|||||||" { mode = .base }
                else if line == "=======" { mode = .theirs }
                else { ours.append(line) }
            case .base:
                if line == "=======" { mode = .theirs } else { base.append(line) }
            case .theirs:
                if line.hasPrefix(">>>>>>> ") || line == ">>>>>>>" {
                    segments.append(.conflict(id: nextId, ours: ours, base: base, theirs: theirs))
                    nextId += 1
                    ours = []; base = []; theirs = []
                    mode = .common
                } else {
                    theirs.append(line)
                }
            }
        }
        if !common.isEmpty { segments.append(.common(common)) }
        return segments
    }

    // MARK: Resolving

    /// Writes the merged text and marks the file resolved.
    public static func apply(repo: String, path: String, text: String) async throws {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(path)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try await run(["add", "--", path], repo: repo)
    }

    /// Takes one whole side, including a deletion on that side.
    public static func accept(repo: String, path: String, ours: Bool) async throws {
        let stage = ours ? 2 : 3
        if await blob(repo: repo, stage: stage, path: path) == nil {
            try await run(["rm", "--quiet", "--", path], repo: repo)
        } else {
            try await run(["checkout", ours ? "--ours" : "--theirs", "--", path], repo: repo)
            try await run(["add", "--", path], repo: repo)
        }
    }

    public static func abort(repo: String, operation: ConflictOperation) async throws {
        guard let verb = operation.verb else {
            try await run(["reset", "--merge"], repo: repo)
            return
        }
        try await run([verb, "--abort"], repo: repo)
    }

    /// Continues with git's default message (no editor).
    /// `skipHooks` points `core.hooksPath` at an empty location, which is the only way to bypass
    /// pre-commit / commit-msg hooks for `--continue` (it takes no `--no-verify`).
    public static func continueOperation(repo: String, operation: ConflictOperation, skipHooks: Bool = false) async throws {
        guard let verb = operation.verb else { return }
        let hooks = skipHooks ? ["-c", "core.hooksPath=/dev/null"] : []
        let res = try await git.execute(arguments: hooks + ["-c", "core.editor=true", verb, "--continue"], in: repo,
                                        extraEnvironment: ["GIT_EDITOR": "true"])
        guard res.isSuccess else { throw failure(res) }
    }

    private static func run(_ args: [String], repo: String) async throws {
        let res = try await git.execute(arguments: args, in: repo)
        guard res.isSuccess else { throw failure(res) }
    }

    private static func failure(_ res: GitService.GitResult) -> NSError {
        // Hooks print their findings on stdout, git its verdict on stderr; both are needed to explain a rejection.
        let text = [res.stdout, res.stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        return NSError(domain: "ConflictMerge", code: Int(res.exitCode), userInfo: [NSLocalizedDescriptionKey: text])
    }
}
