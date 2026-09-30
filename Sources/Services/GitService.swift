import Foundation

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

public actor GitService {
    public static let shared = GitService()

    public init() {}

    // MARK: - SSH identity

    private static let identityLock = NSLock()
    nonisolated(unsafe) private static var _sshIdentityPath: String?

    /// Private key of the active Git profile. When set, commands that talk to a remote authenticate with
    /// only this key; otherwise ssh-agent offers every loaded key and GitHub picks whichever account matches first.
    public nonisolated static var sshIdentityPath: String? {
        get { identityLock.lock(); defer { identityLock.unlock() }; return _sshIdentityPath }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let expanded = trimmed.isEmpty ? nil : NSString(string: trimmed).expandingTildeInPath
            identityLock.lock(); _sshIdentityPath = expanded; identityLock.unlock()
        }
    }

    private static let remoteCommands: Set<String> = ["push", "pull", "fetch", "ls-remote", "clone", "submodule", "remote"]

    /// `GIT_SSH_COMMAND` pinning the profile key, for any process that may run git against an SSH remote.
    /// Nothing is set when the user already configured `GIT_SSH_COMMAND` or the key file is missing.
    public nonisolated static func sshEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        guard base["GIT_SSH_COMMAND"] == nil, let key = sshIdentityPath,
              FileManager.default.fileExists(atPath: key) else { return [:] }
        let quoted = "'" + key.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return ["GIT_SSH_COMMAND": "ssh -i \(quoted) -o IdentitiesOnly=yes"]
    }

    /// First git subcommand, skipping global options such as `-c key=value` and `-C dir`.
    nonisolated static func subcommand(of arguments: [String]) -> String? {
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            if a == "-c" || a == "-C" { i += 2; continue }
            if a.hasPrefix("-") { i += 1; continue }
            return a
        }
        return nil
    }

    /// A repository's own `core.sshCommand` wins over the profile key.
    private nonisolated static func repoHasSSHCommand(in directory: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["config", "--get", "core.sshCommand"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    nonisolated static func remoteEnvironment(arguments: [String], directory: String, base: [String: String]) -> [String: String] {
        guard let cmd = subcommand(of: arguments), remoteCommands.contains(cmd), sshIdentityPath != nil,
              !repoHasSSHCommand(in: directory) else { return [:] }
        return sshEnvironment(base: base)
    }

    // MARK: - Process Runner

    public struct GitResult: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public var isSuccess: Bool { exitCode == 0 }
    }

    /// Nonisolated and run on a background queue: `waitUntilExit()` must not block the actor,
    /// otherwise every git call (diff, status, log) is serialized behind the slowest one.
    public nonisolated func execute(arguments: [String], in directory: String, extraEnvironment: [String: String] = [:]) async throws -> GitResult {
        return try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)

            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["LC_ALL"] = "en_US.UTF-8"
            // Read-only commands (status, diff) otherwise refresh .git/index and hold index.lock,
            // which blocks git in the user's terminal and retriggers the file watcher.
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            environment.merge(GitService.remoteEnvironment(arguments: arguments, directory: directory, base: environment)) { _, new in new }
            environment.merge(extraEnvironment) { _, new in new }
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            let stdoutBox = DataBox()
            let stderrBox = DataBox()

            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stdoutBox.data = stdoutHandle.readDataToEndOfFile()
                group.leave()
            }

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stderrBox.data = stderrHandle.readDataToEndOfFile()
                group.leave()
            }

            do {
                try process.run()
                process.waitUntilExit()
                group.wait()

                let stdout = String(data: stdoutBox.data, encoding: .utf8) ?? ""
                let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""

                continuation.resume(returning: GitResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: process.terminationStatus
                ))
            } catch {
                continuation.resume(throwing: error)
            }
          }
        }
    }

    public nonisolated func executeShell(command: String, in directory: String, shell: TerminalShell = .bash) async throws -> GitResult {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell.executablePath)
            process.arguments = ["-l", "-c", shell.wrapperScript]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)

            var environment = ProcessInfo.processInfo.environment
            environment["GITXX_CMD"] = command
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["LC_ALL"] = "en_US.UTF-8"
            environment["LANG"] = "en_US.UTF-8"
            let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:" + existingPath
            if !GitService.repoHasSSHCommand(in: directory) {
                environment.merge(GitService.sshEnvironment(base: environment)) { _, new in new }
            }
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            let stdoutBox = DataBox()
            let stderrBox = DataBox()

            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stdoutBox.data = stdoutHandle.readDataToEndOfFile()
                group.leave()
            }

            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stderrBox.data = stderrHandle.readDataToEndOfFile()
                group.leave()
            }

            do {
                try process.run()
                process.waitUntilExit()
                group.wait()

                let stdout = String(data: stdoutBox.data, encoding: .utf8) ?? ""
                let stderr = String(data: stderrBox.data, encoding: .utf8) ?? ""

                continuation.resume(returning: GitResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: process.terminationStatus
                ))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Status & Inspection

    public func isGitRepository(at path: String) async -> Bool {
        let res = try? await execute(arguments: ["rev-parse", "--is-inside-work-tree"], in: path)
        return res?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func getRepoName(at path: String) -> String {
        return URL(fileURLWithPath: path).lastPathComponent
    }

    public func getRemoteUrl(at path: String) async -> String? {
        let res = try? await execute(arguments: ["config", "--get", "remote.origin.url"], in: path)
        let url = res?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (url?.isEmpty ?? true) ? nil : url
    }

    public struct RepoStatus: Sendable {
        public let branch: String
        public let files: [GitFileStatus]
        public let commitsAhead: Int
        public let commitsBehind: Int
        public let remoteUrl: String?
    }

    public func getStatus(at path: String) async throws -> RepoStatus {
        let statusRes = try await execute(arguments: ["status", "--porcelain=v1", "-b", "-uall"], in: path)
        let lines = statusRes.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }

        var currentBranch = "main"
        var commitsAhead = 0
        var commitsBehind = 0
        var files: [GitFileStatus] = []

        for line in lines {
            if line.hasPrefix("## ") {
                let header = String(line.dropFirst(3))
                // Formats:
                // ## main
                // ## main...origin/main
                // ## main...origin/main [ahead 1, behind 2]
                let parts = header.components(separatedBy: "...")
                let branchNameWithTags = parts.first ?? "main"
                currentBranch = branchNameWithTags.components(separatedBy: " ").first ?? "main"

                if line.contains("ahead ") {
                    if let match = line.range(of: #"ahead (\d+)"#, options: .regularExpression) {
                        let substr = String(line[match]).replacingOccurrences(of: "ahead ", with: "")
                        commitsAhead = Int(substr) ?? 0
                    }
                }
                if line.contains("behind ") {
                    if let match = line.range(of: #"behind (\d+)"#, options: .regularExpression) {
                        let substr = String(line[match]).replacingOccurrences(of: "behind ", with: "")
                        commitsBehind = Int(substr) ?? 0
                    }
                }
            } else if line.count >= 4 {
                let indexStatus = line[line.startIndex]
                let workTreeStatus = line[line.index(line.startIndex, offsetBy: 1)]
                let filePath = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)

                if indexStatus == "?" || workTreeStatus == "?" {
                    files.append(GitFileStatus(path: filePath, changeKind: .untracked))
                    continue
                }
                if indexStatus == "U" || workTreeStatus == "U" || (indexStatus == workTreeStatus && indexStatus != " " && "AD".contains(indexStatus)) {
                    files.append(GitFileStatus(path: filePath, changeKind: .unmerged))
                    continue
                }
                if indexStatus != " " {
                    files.append(GitFileStatus(path: filePath, changeKind: GitFileChangeKind(rawValue: String(indexStatus)) ?? .modified, isStaged: true))
                }
                if workTreeStatus != " " {
                    files.append(GitFileStatus(path: filePath, changeKind: GitFileChangeKind(rawValue: String(workTreeStatus)) ?? .modified, isStaged: false))
                }
            }
        }

        let remoteUrl = await getRemoteUrl(at: path)
        return RepoStatus(
            branch: currentBranch,
            files: files,
            commitsAhead: commitsAhead,
            commitsBehind: commitsBehind,
            remoteUrl: remoteUrl
        )
    }

    // MARK: - Diff Operations

    public func getDiff(at path: String, for filePath: String?, staged: Bool) async throws -> FileDiff {
        var args = ["diff", "--no-color"]
        if staged {
            args.append("--cached")
        }
        if let filePath = filePath, !filePath.isEmpty {
            args.append("--")
            args.append(filePath)
        }

        let res = try await execute(arguments: args, in: path)
        if res.stdout.isEmpty, !staged, let filePath = filePath, !filePath.isEmpty {
            // For untracked files, run git diff --no-index /dev/null <file>
            let fallbackRes = try? await execute(arguments: ["diff", "--no-color", "--no-index", "/dev/null", filePath], in: path)
            if let output = fallbackRes?.stdout, !output.isEmpty {
                return parseUnifiedDiff(diffOutput: output, targetPath: filePath)
            }
        }
        return parseUnifiedDiff(diffOutput: res.stdout, targetPath: filePath ?? "All Changes")
    }

    public nonisolated func parseUnifiedDiff(diffOutput: String, targetPath: String) -> FileDiff {
        let lines = diffOutput.components(separatedBy: "\n")
        var hunks: [DiffHunk] = []
        var currentHunkLines: [DiffLine] = []
        var currentHeader = ""
        var oldLineNum = 1
        var newLineNum = 1
        var totalAdditions = 0
        var totalDeletions = 0
        var patchHeader: [String] = []
        var noNewlineAfter: Set<Int> = []

        for line in lines {
            if hunks.isEmpty && currentHunkLines.isEmpty && !line.hasPrefix("@@") {
                if !line.isEmpty { patchHeader.append(line) }
                continue
            }
            if line.hasPrefix("\\") {
                if !currentHunkLines.isEmpty { noNewlineAfter.insert(currentHunkLines.count - 1) }
                continue
            }
            if line.hasPrefix("@@") {
                if !currentHunkLines.isEmpty {
                    hunks.append(DiffHunk(header: currentHeader, lines: currentHunkLines, noNewlineAfter: noNewlineAfter))
                    currentHunkLines = []
                    noNewlineAfter = []
                }
                currentHeader = line
                // Parse @@ -1,5 +1,6 @@
                let components = line.components(separatedBy: " ")
                if components.count >= 3 {
                    let oldChunk = components[1].replacingOccurrences(of: "-", with: "")
                    let newChunk = components[2].replacingOccurrences(of: "+", with: "")
                    let oldStart = oldChunk.components(separatedBy: ",").first ?? "1"
                    let newStart = newChunk.components(separatedBy: ",").first ?? "1"
                    oldLineNum = Int(oldStart) ?? 1
                    newLineNum = Int(newStart) ?? 1
                }
                currentHunkLines.append(DiffLine(type: .hunkHeader, content: line))
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                totalAdditions += 1
                let content = String(line.dropFirst())
                currentHunkLines.append(DiffLine(type: .addition, content: content, oldLineNumber: nil, newLineNumber: newLineNum))
                newLineNum += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                totalDeletions += 1
                let content = String(line.dropFirst())
                currentHunkLines.append(DiffLine(type: .deletion, content: content, oldLineNumber: oldLineNum, newLineNumber: nil))
                oldLineNum += 1
            } else if line.hasPrefix(" ") {
                let content = String(line.dropFirst())
                currentHunkLines.append(DiffLine(type: .context, content: content, oldLineNumber: oldLineNum, newLineNumber: newLineNum))
                oldLineNum += 1
                newLineNum += 1
            }
        }

        if !currentHunkLines.isEmpty {
            hunks.append(DiffHunk(header: currentHeader, lines: currentHunkLines, noNewlineAfter: noNewlineAfter))
        }

        let lower = targetPath.lowercased()
        let isKnownBinary = lower.hasSuffix(".ds_store") || lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".pyc") || lower.hasSuffix(".zip") || lower.hasSuffix(".pdf") || diffOutput.contains("Binary files differ") || diffOutput.contains("GIT binary patch")

        var result = FileDiff(
            path: targetPath,
            hunks: hunks,
            additions: totalAdditions,
            deletions: totalDeletions,
            isBinary: isKnownBinary
        )
        result.patchHeader = patchHeader
        return result
    }

    // MARK: - Staging & Commits

    public func stage(at path: String, files: [String]) async throws {
        try await run(["add", "--"] + files, in: path)
    }

    public func unstage(at path: String, files: [String]) async throws {
        try await run(["reset", "HEAD", "--"] + files, in: path)
    }

    public func stageAll(at path: String) async throws {
        try await run(["add", "-A"], in: path)
    }

    public func unstageAll(at path: String) async throws {
        try await run(["reset", "HEAD"], in: path)
    }

    public func commit(at path: String, summary: String, description: String = "", skipHooks: Bool = false) async throws {
        var message = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty {
            message += "\n\n" + desc
        }
        let res = try await execute(arguments: ["commit", "-m", message] + (skipHooks ? ["--no-verify"] : []), in: path)
        guard res.isSuccess else {
            // A rejecting hook's findings are usually on stdout, git's own message on stderr.
            let text = [res.stdout, res.stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            throw NSError(domain: "GitService", code: Int(res.exitCode), userInfo: [
                NSLocalizedDescriptionKey: text.isEmpty ? "git commit failed (exit \(res.exitCode))" : text
            ])
        }
    }

    /// Applies a patch to the index (`cached`) or the working tree. Throws with git's stderr when it doesn't apply.
    public func applyPatch(at path: String, patch: String, cached: Bool, reverse: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitxx-\(UUID().uuidString).patch")
        try patch.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        var args = ["apply", "--recount", "--whitespace=nowarn"]
        if cached { args.append("--cached") }
        if reverse { args.append("-R") }
        args.append(url.path)
        let res = try await execute(arguments: args, in: path)
        guard res.isSuccess else {
            throw NSError(domain: "GitService", code: Int(res.exitCode), userInfo: [
                NSLocalizedDescriptionKey: res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            ])
        }
    }

    /// A file's HEAD→working-tree diff plus which of its `+`/`-` rows are currently staged (GitHub Desktop model).
    /// Returns nil when there is no HEAD to diff against.
    public func workingDiff(at repo: String, path file: String, untracked: Bool) async throws -> (diff: FileDiff, staged: Set<DiffLineKey>)? {
        if untracked {
            let res = try await execute(arguments: ["diff", "--no-color", "--no-index", "--", "/dev/null", file], in: repo)
            return (parseUnifiedDiff(diffOutput: res.stdout, targetPath: file), [])
        }
        async let fullRes = execute(arguments: ["diff", "--no-color", "HEAD", "--", file], in: repo)
        async let cachedRes = execute(arguments: ["diff", "--no-color", "--cached", "--", file], in: repo)
        async let unstagedRes = execute(arguments: ["diff", "--no-color", "--", file], in: repo)
        let (full, cached, unstaged) = try await (fullRes, cachedRes, unstagedRes)
        guard full.isSuccess else { return nil }

        let diff = parseUnifiedDiff(diffOutput: full.stdout, targetPath: file)
        var stagedDeletions = Set<Int>()
        for hunk in parseUnifiedDiff(diffOutput: cached.stdout, targetPath: file).hunks {
            for line in hunk.lines where line.type == .deletion { if let n = line.oldLineNumber { stagedDeletions.insert(n) } }
        }
        var unstagedAdditions = Set<Int>()
        for hunk in parseUnifiedDiff(diffOutput: unstaged.stdout, targetPath: file).hunks {
            for line in hunk.lines where line.type == .addition { if let n = line.newLineNumber { unstagedAdditions.insert(n) } }
        }
        var staged = Set<DiffLineKey>()
        for (h, hunk) in diff.hunks.enumerated() {
            for (i, line) in hunk.lines.enumerated() {
                switch line.type {
                case .deletion where line.oldLineNumber.map(stagedDeletions.contains) == true:
                    staged.insert(DiffLineKey(hunk: h, line: i))
                case .addition where line.newLineNumber.map { !unstagedAdditions.contains($0) } == true:
                    staged.insert(DiffLineKey(hunk: h, line: i))
                default:
                    break
                }
            }
        }
        return (diff, staged)
    }

    /// Rewrites the index entry of `file` to HEAD plus exactly the `included` rows of its HEAD→working-tree `diff`.
    /// The previous entry is restored if the patch doesn't apply.
    public func setStagedLines(at repo: String, path file: String, diff: FileDiff, included: Set<DiffLineKey>) async throws {
        let all = PartialPatch.changedLines(in: diff)
        if included.isSuperset(of: all) {
            try await run(["add", "-A", "--", file], in: repo)
            return
        }
        var patch: String?
        if !included.isEmpty {
            patch = PartialPatch.build(diff: diff, included: included, direction: .forward)
            guard patch != nil else {
                throw NSError(domain: "GitService", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "These lines change the missing newline at the end of the file; stage them together."])
            }
        }
        let previous = try await execute(arguments: ["ls-files", "-s", "--", file], in: repo).stdout
            .split(separator: "\n").first.map(String.init)
        try await run(["reset", "-q", "HEAD", "--", file], in: repo)
        guard let patch else { return }
        do {
            try await applyPatch(at: repo, patch: patch, cached: true, reverse: false)
        } catch {
            if let previous, let tab = previous.firstIndex(of: "\t") {
                let fields = previous[..<tab].split(separator: " ")
                if fields.count >= 2 {
                    _ = try? await execute(arguments: ["update-index", "--add", "--cacheinfo", "\(fields[0]),\(fields[1]),\(file)"], in: repo)
                }
            }
            throw error
        }
    }

    /// Reverts `lines` of the HEAD→working-tree `diff` in the working copy only.
    public func discardLines(at repo: String, diff: FileDiff, lines: Set<DiffLineKey>) async throws {
        guard let patch = PartialPatch.build(diff: diff, included: lines, direction: .reverse) else { return }
        try await applyPatch(at: repo, patch: patch, cached: false, reverse: true)
    }

    public func discardChanges(at path: String, files: [String]) async throws {
        // `restore` fails for untracked paths; `clean` then removes them.
        _ = try await execute(arguments: ["restore", "--staged", "--worktree", "--"] + files, in: path)
        try await run(["clean", "-fd", "--"] + files, in: path)
    }

    // MARK: - History & Commits

    public func getLog(at path: String, maxCount: Int = 100, ref: String? = nil) async throws -> [GitCommit] {
        let delimiter = "%x1f"
        let recordDelimiter = "%x1e"
        let format = "%H\(delimiter)%s\(delimiter)%b\(delimiter)%an\(delimiter)%ae\(delimiter)%aI\(delimiter)%P\(delimiter)%D\(recordDelimiter)"
        var args = ["log", "-n", "\(maxCount)", "--format=\(format)"]
        if let ref, !ref.isEmpty { args += [ref, "--"] }
        let res = try await execute(arguments: args, in: path)

        let records = res.stdout.components(separatedBy: "\u{1e}").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var commits: [GitCommit] = []

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        for record in records {
            let fields = record.components(separatedBy: "\u{1f}")
            if fields.count >= 6 {
                let sha = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = fields[1]
                let body = fields[2]
                let authorName = fields[3]
                let authorEmail = fields[4]
                let dateStr = fields[5].trimmingCharacters(in: .whitespacesAndNewlines)
                let parentShas = fields.count > 6 ? fields[6].components(separatedBy: " ").filter { !$0.isEmpty } : []
                let date = isoFormatter.date(from: dateStr) ?? Date()
                let refs = fields.count > 7
                    ? fields[7].trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ", ").filter { !$0.isEmpty }
                    : []

                var commit = GitCommit(
                    sha: sha,
                    summary: summary,
                    body: body,
                    authorName: authorName,
                    authorEmail: authorEmail,
                    authorDate: date,
                    parentShas: parentShas,
                    touchedFilesCount: 1
                )
                commit.refs = refs
                commits.append(commit)
            }
        }
        return commits
    }

    public func getCommitDiff(at path: String, sha: String) async throws -> FileDiff {
        let res = try await execute(arguments: ["show", "--no-color", sha], in: path)
        return parseUnifiedDiff(diffOutput: res.stdout, targetPath: "Commit \(String(sha.prefix(7)))")
    }

    // MARK: - Branches

    public func getBranches(at path: String) async throws -> [GitBranch] {
        let res = try await execute(arguments: ["branch", "-a", "--no-color"], in: path)
        let lines = res.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }

        var branches: [GitBranch] = []
        for line in lines {
            let isCurrent = line.hasPrefix("*")
            let cleaned = line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
            guard !cleaned.contains("->") else { continue } // Skip HEAD symrefs

            let isRemote = cleaned.hasPrefix("remotes/")
            let branchName = isRemote ? cleaned.replacingOccurrences(of: "remotes/", with: "") : cleaned

            branches.append(GitBranch(
                name: branchName,
                isCurrent: isCurrent,
                isRemote: isRemote
            ))
        }
        return branches
    }

    public func checkout(at path: String, branch: String) async throws {
        try await run(["checkout", branch], in: path)
    }

    /// `base` is the start point (a local or remote branch); nil starts from HEAD. A remote base is not tracked,
    /// so the new branch pushes to its own name rather than to the base.
    public func createBranch(at path: String, name: String, base: String? = nil, baseIsRemote: Bool = false, checkout: Bool = true) async throws {
        var args = checkout ? ["checkout", "-b", name] : ["branch", name]
        if let base, !base.isEmpty {
            if baseIsRemote { args.append("--no-track") }
            args.append(base)
        }
        try await run(args, in: path)
    }

    // MARK: - Remote Synchronization

    public func fetch(at path: String) async throws {
        try await run(["fetch", "--all", "--prune"], in: path)
    }

    public func pull(at path: String) async throws {
        try await run(["pull"], in: path)
    }

    public func push(at path: String, setUpstream: Bool = false, branch: String? = nil) async throws {
        var args = ["push"]
        if setUpstream, let branch = branch {
            args += ["-u", "origin", branch]
        }
        try await run(args, in: path)
    }

    // MARK: - Stash

    public func stash(at path: String, message: String? = nil) async throws {
        var args = ["stash", "push"]
        if let message = message, !message.isEmpty {
            args += ["-m", message]
        }
        try await run(args, in: path)
    }

    public func stashPop(at path: String) async throws {
        try await run(["stash", "pop"], in: path)
    }

    public func listStashes(at path: String) async throws -> [GitStash] {
        let res = try await run(["stash", "list", "--format=%gd%x1f%gs%x1f%cI"], in: path)
        let iso = ISO8601DateFormatter()
        return res.stdout.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count >= 3 else { return nil }
            return GitStash(ref: f[0], subject: f[1], date: iso.date(from: f[2]) ?? Date())
        }
    }

    public func stashPush(at path: String, message: String, includeUntracked: Bool, keepIndex: Bool, paths: [String] = []) async throws {
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if keepIndex { args.append("--keep-index") }
        if !message.isEmpty { args += ["-m", message] }
        if !paths.isEmpty { args += ["--"] + paths }
        try await run(args, in: path)
    }

    public func stashApply(at path: String, ref: String, pop: Bool) async throws {
        if (try? await run(["stash", pop ? "pop" : "apply", "--index", ref], in: path)) != nil { return }
        try await run(["stash", pop ? "pop" : "apply", ref], in: path)
    }

    public func stashDrop(at path: String, ref: String) async throws {
        try await run(["stash", "drop", ref], in: path)
    }

    public func stashDiff(at path: String, ref: String) async throws -> [FileDiff] {
        var res = try await execute(arguments: ["stash", "show", "-p", "--no-color", "--include-untracked", ref], in: path)
        if !res.isSuccess {
            res = try await run(["stash", "show", "-p", "--no-color", ref], in: path)
        }
        return parseMultiFileDiff(res.stdout)
    }

    // MARK: - Commit Operations

    public func cherryPick(at path: String, sha: String, noCommit: Bool = false) async throws {
        var args = ["cherry-pick"]
        if noCommit { args.append("--no-commit") }
        args.append(sha)
        do {
            try await run(args, in: path)
        } catch {
            _ = try? await execute(arguments: ["cherry-pick", "--abort"], in: path)
            throw Self.abortedError("Cherry-pick", error)
        }
    }

    public func createTag(at path: String, name: String, sha: String, message: String?) async throws {
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await run(["tag", "-a", name, sha, "-m", message], in: path)
        } else {
            try await run(["tag", name, sha], in: path)
        }
    }

    public func pushTag(at path: String, name: String, remote: String = "origin") async throws {
        try await run(["push", remote, "refs/tags/\(name)"], in: path)
    }

    public func tags(at path: String, pointingAt sha: String) async -> [String] {
        let res = try? await execute(arguments: ["tag", "--points-at", sha], in: path)
        return res?.stdout.split(separator: "\n").map(String.init) ?? []
    }

    /// Commits reachable from `ref` but not from HEAD (candidates for cherry-pick).
    public func commitsNotInHead(at path: String, ref: String, limit: Int = 500) async -> Set<String> {
        let res = try? await execute(arguments: ["rev-list", "-n", "\(limit)", "HEAD..\(ref)", "--"], in: path)
        return Set(res?.stdout.split(separator: "\n").map(String.init) ?? [])
    }

    public func revertCommit(at path: String, sha: String) async throws {
        do {
            try await run(["revert", "--no-edit", sha], in: path)
        } catch {
            _ = try? await execute(arguments: ["revert", "--abort"], in: path)
            throw Self.abortedError("Revert", error)
        }
    }

    /// Remote branches that already contain `sha`; non-empty means rewriting it requires a force-push.
    public func remoteBranchesContaining(at path: String, sha: String) async -> [String] {
        let res = try? await execute(arguments: ["branch", "-r", "--contains", sha, "--format=%(refname:short)"], in: path)
        return res?.stdout.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") } ?? []
    }

    public struct RebaseStep: Sendable, Hashable {
        public enum Action: String, CaseIterable, Sendable { case pick, reword, squash, fixup, drop }
        public var sha: String
        public var action: Action
        /// New message for `.reword`.
        public var message: String?

        public init(sha: String, action: Action, message: String? = nil) {
            self.sha = sha
            self.action = action
            self.message = message
        }
    }

    /// Non-interactive `git rebase -i`: the todo list is generated from `steps` (oldest first) and editors are
    /// bypassed. Rewords run as `exec git commit --amend -F`. Aborts and rethrows if the rebase stops.
    public func interactiveRebase(at path: String, onto base: String?, steps: [RebaseStep]) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitxx-rebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var todo: [String] = []
        for (i, step) in steps.enumerated() {
            switch step.action {
            case .pick: todo.append("pick \(step.sha)")
            case .squash: todo.append("squash \(step.sha)")
            case .fixup: todo.append("fixup \(step.sha)")
            case .drop: todo.append("drop \(step.sha)")
            case .reword:
                let file = dir.appendingPathComponent("msg-\(i).txt")
                try (step.message ?? "").write(to: file, atomically: true, encoding: .utf8)
                todo.append("pick \(step.sha)")
                todo.append("exec git commit --amend --allow-empty --no-verify -F \(shellQuote(file.path))")
            }
        }
        let todoFile = dir.appendingPathComponent("todo")
        try (todo.joined(separator: "\n") + "\n").write(to: todoFile, atomically: true, encoding: .utf8)

        var args = ["rebase", "-i", "--autostash"]
        args.append(base ?? "--root")
        do {
            try await run(args, in: path, environment: [
                "GIT_SEQUENCE_EDITOR": "cp \(shellQuote(todoFile.path))",
                "GIT_EDITOR": "true",
            ])
        } catch {
            _ = try? await execute(arguments: ["rebase", "--abort"], in: path)
            throw Self.abortedError("Rebase", error)
        }
    }

    /// Condenses git's multi-line conflict output (hints etc.) into one sentence for a toast.
    private static func abortedError(_ operation: String, _ error: Error) -> Error {
        let text = error.localizedDescription
        let line = text.components(separatedBy: "\n").first { $0.contains("could not apply") || $0.hasPrefix("error:") || $0.hasPrefix("CONFLICT") }
        let detail = (line ?? text.components(separatedBy: "\n").first ?? text)
            .replacingOccurrences(of: "error: ", with: "")
            .replacingOccurrences(of: #"Rebasing \(\d+/\d+\)"#, with: "", options: .regularExpression)
        let conflict = text.contains("could not apply") || text.contains("CONFLICT")
        return NSError(domain: "GitService", code: 1, userInfo: [NSLocalizedDescriptionKey: conflict
            ? "\(operation) hit a conflict (\(detail.trimmingCharacters(in: .whitespaces))). Nothing was changed."
            : "\(operation) failed: \(detail.trimmingCharacters(in: .whitespaces))"])
    }

    private nonisolated func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs git and throws with its stderr when it exits non-zero.
    @discardableResult
    public nonisolated func run(_ arguments: [String], in directory: String, environment: [String: String] = [:]) async throws -> GitResult {
        let res = try await execute(arguments: arguments, in: directory, extraEnvironment: environment)
        guard res.isSuccess else {
            let message = [res.stderr, res.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            throw NSError(domain: "GitService", code: Int(res.exitCode), userInfo: [
                NSLocalizedDescriptionKey: message ?? "git \(arguments.first ?? "") failed (exit \(res.exitCode))"
            ])
        }
        return res
    }

    /// Splits `git diff`/`git show` output covering several files into one `FileDiff` per file.
    public nonisolated func parseMultiFileDiff(_ output: String) -> [FileDiff] {
        var chunks: [[String]] = []
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") { chunks.append([line]) } else if !chunks.isEmpty { chunks[chunks.count - 1].append(line) }
        }
        return chunks.map { lines in
            let plus = lines.first { $0.hasPrefix("+++ ") }.map { String($0.dropFirst(4)) }
            let minus = lines.first { $0.hasPrefix("--- ") }.map { String($0.dropFirst(4)) }
            var name = (plus == "/dev/null" ? minus : plus) ?? lines[0].components(separatedBy: " b/").last ?? "file"
            if name.hasPrefix("a/") || name.hasPrefix("b/") { name = String(name.dropFirst(2)) }
            return parseUnifiedDiff(diffOutput: lines.joined(separator: "\n"), targetPath: name)
        }
    }

    // MARK: - Git User & Identity Management

    public func setGitUser(name: String, email: String, in path: String?, global: Bool = false) async throws {
        if let path = path, !path.isEmpty {
            try await run(["config", "user.name", name], in: path)
            try await run(["config", "user.email", email], in: path)
        }
        if global {
            let workingDir = path ?? FileManager.default.currentDirectoryPath
            try await run(["config", "--global", "user.name", name], in: workingDir)
            try await run(["config", "--global", "user.email", email], in: workingDir)
        }
    }

    public func getCurrentGitUser(in path: String?) async -> (name: String, email: String) {
        let repoPath = path ?? FileManager.default.currentDirectoryPath
        let nameRes = try? await execute(arguments: ["config", "user.name"], in: repoPath)
        let emailRes = try? await execute(arguments: ["config", "user.email"], in: repoPath)
        let name = nameRes?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let email = emailRes?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (name, email)
    }

    public func addSSHKey(path: String) async -> (success: Bool, message: String) {
        let expanded = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return (false, "SSH key file not found at \(path)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        process.arguments = [expanded]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let ok = process.terminationStatus == 0
            return (ok, ok ? (out.isEmpty ? "Identity added: \(expanded)" : out) : "ssh-add failed (\(process.terminationStatus)): \(out)")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

