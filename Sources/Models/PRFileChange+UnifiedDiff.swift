import Foundation

extension PRFileChange {
    /// Splits local `git diff` / `git show` output into per-file changes shaped like the GitHub files API.
    public static func fromUnifiedDiff(_ text: String) -> [PRFileChange] {
        var chunks: [[String]] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") { chunks.append([line]) } else if !chunks.isEmpty { chunks[chunks.count - 1].append(line) }
        }
        return chunks.compactMap { lines -> PRFileChange? in
            guard let header = lines.first else { return nil }
            let renameFrom = lines.first { $0.hasPrefix("rename from ") }.map { String($0.dropFirst("rename from ".count)) }
            let renameTo = lines.first { $0.hasPrefix("rename to ") }.map { String($0.dropFirst("rename to ".count)) }
            let name = renameTo ?? header.components(separatedBy: " b/").last ?? header
            let status: String
            if lines.contains(where: { $0.hasPrefix("new file") }) { status = "added" }
            else if lines.contains(where: { $0.hasPrefix("deleted file") }) { status = "removed" }
            else if renameTo != nil { status = "renamed" }
            else { status = "modified" }
            guard let first = lines.firstIndex(where: { $0.hasPrefix("@@") }) else {
                return PRFileChange(filename: name, status: status, previousFilename: renameFrom)
            }
            var patchLines = Array(lines[first...])
            while patchLines.last?.isEmpty == true { patchLines.removeLast() }
            let adds = patchLines.filter { $0.hasPrefix("+") }.count
            let dels = patchLines.filter { $0.hasPrefix("-") }.count
            return PRFileChange(filename: name, status: status, additions: adds, deletions: dels,
                                changes: adds + dels, patch: patchLines.joined(separator: "\n"), previousFilename: renameFrom)
        }
    }
}
