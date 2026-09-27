import Foundation

/// Builds `git apply`-able patches from a subset of a diff's lines (git-gui style line staging).
public enum PartialPatch {
    public enum Direction: Sendable {
        /// Patch applied as-is (`git apply --cached`): stage selected lines of an unstaged diff.
        case forward
        /// Patch applied with `-R`: unstage (staged diff) or discard (unstaged diff) selected lines.
        case reverse
    }

    /// `lines` are indices into `hunk.lines` (index 0 is the `@@` header row). `nil` selects the whole hunk.
    public static func build(diff: FileDiff, hunkIndex: Int, lines selected: Set<Int>?, direction: Direction) -> String? {
        guard diff.hunks.indices.contains(hunkIndex), !diff.patchHeader.isEmpty else { return nil }
        let hunk = diff.hunks[hunkIndex]
        guard let (oldStart, newStart) = parseStarts(hunk.header) else { return nil }

        var body: [String] = []
        var oldCount = 0, newCount = 0, changed = 0
        for (index, line) in hunk.lines.enumerated() where line.type != .hunkHeader {
            let isSelected = selected?.contains(index) ?? true
            var emitted: String?
            switch line.type {
            case .context:
                emitted = " " + line.content
                oldCount += 1; newCount += 1
            case .addition:
                if isSelected {
                    emitted = "+" + line.content; newCount += 1; changed += 1
                } else if direction == .reverse {
                    // Present on the side the reversed patch starts from, so it stays as context.
                    emitted = " " + line.content; oldCount += 1; newCount += 1
                }
            case .deletion:
                if isSelected {
                    emitted = "-" + line.content; oldCount += 1; changed += 1
                } else if direction == .forward {
                    emitted = " " + line.content; oldCount += 1; newCount += 1
                }
            case .hunkHeader:
                break
            }
            if let emitted {
                body.append(emitted)
                if hunk.noNewlineAfter.contains(index) { body.append("\\ No newline at end of file") }
            }
        }
        guard changed > 0 else { return nil }

        let header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        return (diff.patchHeader + [header] + body).joined(separator: "\n") + "\n"
    }

    /// Every `+`/`-` row of the diff.
    public static func changedLines(in diff: FileDiff) -> Set<DiffLineKey> {
        var keys = Set<DiffLineKey>()
        for (h, hunk) in diff.hunks.enumerated() {
            for i in selectableIndices(in: hunk) { keys.insert(DiffLineKey(hunk: h, line: i)) }
        }
        return keys
    }

    /// Multi-hunk variant of `build`: a patch containing only `included` rows of `diff`.
    /// Forward patches of a whole-file deletion that keep some lines are rewritten as modifications.
    public static func build(diff: FileDiff, included: Set<DiffLineKey>, direction: Direction) -> String? {
        guard !diff.patchHeader.isEmpty else { return nil }
        var hunksOut: [String] = []
        var delta = 0
        var keptOldLines = false
        for (h, hunk) in diff.hunks.enumerated() {
            guard let (oldStart, _) = parseStarts(hunk.header) else { return nil }
            var body: [String] = []
            var oldCount = 0, newCount = 0, changed = 0
            var oldEnded = false, newEnded = false
            for (index, line) in hunk.lines.enumerated() where line.type != .hunkHeader {
                let isIncluded = included.contains(DiffLineKey(hunk: h, line: index))
                var emitted: String?
                switch line.type {
                case .context:
                    emitted = " " + line.content; oldCount += 1; newCount += 1
                case .addition:
                    if isIncluded {
                        emitted = "+" + line.content; newCount += 1; changed += 1
                    } else if direction == .reverse {
                        emitted = " " + line.content; oldCount += 1; newCount += 1
                    }
                case .deletion:
                    if isIncluded {
                        emitted = "-" + line.content; oldCount += 1; changed += 1
                    } else if direction == .forward {
                        emitted = " " + line.content; oldCount += 1; newCount += 1; keptOldLines = true
                    }
                case .hunkHeader:
                    break
                }
                if let emitted {
                    // A line without a trailing newline ends its side; anything after it there would be glued on.
                    let onOld = !emitted.hasPrefix("+"), onNew = !emitted.hasPrefix("-")
                    if (onOld && oldEnded) || (onNew && newEnded) { return nil }
                    body.append(emitted)
                    if hunk.noNewlineAfter.contains(index) {
                        body.append("\\ No newline at end of file")
                        oldEnded = oldEnded || onOld
                        newEnded = newEnded || onNew
                    }
                }
            }
            guard changed > 0 else { continue }
            let start = oldCount == 0 ? oldStart : max(oldStart, 1)
            let newStart = newCount == 0 ? start + delta : (oldCount == 0 ? start + delta + 1 : start + delta)
            hunksOut.append("@@ -\(start),\(oldCount) +\(newStart),\(newCount) @@")
            hunksOut.append(contentsOf: body)
            delta += newCount - oldCount
        }
        guard !hunksOut.isEmpty else { return nil }

        var header = diff.patchHeader.filter { !$0.hasPrefix("index ") }
        if direction == .forward, keptOldLines, header.contains(where: { $0.hasPrefix("deleted file mode") }) {
            header.removeAll { $0.hasPrefix("deleted file mode") }
            if let minus = header.firstIndex(where: { $0.hasPrefix("--- a/") }),
               let plus = header.firstIndex(where: { $0.hasPrefix("+++ ") }) {
                header[plus] = "+++ b/" + header[minus].dropFirst("--- a/".count)
            }
        }
        return (header + hunksOut).joined(separator: "\n") + "\n"
    }

    /// Indices of `+`/`-` rows in a hunk, i.e. the rows that can be selected.
    public static func selectableIndices(in hunk: DiffHunk) -> [Int] {
        hunk.lines.indices.filter { hunk.lines[$0].type == .addition || hunk.lines[$0].type == .deletion }
    }

    private static func parseStarts(_ header: String) -> (Int, Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        let old = parts[1].dropFirst().split(separator: ",").first.flatMap { Int($0) }
        let new = parts[2].dropFirst().split(separator: ",").first.flatMap { Int($0) }
        guard let old, let new else { return nil }
        return (old, new)
    }
}
