import Foundation

/// Turns a raw GitHub Actions job log into something readable inline: timestamps and workflow commands are
/// stripped, and the excerpt focuses on the error lines (with context) or falls back to the log's tail.
public struct CILogExcerpt: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable { case normal, error, warning, group, gap }
        public let id: Int
        public let text: String
        public let kind: Kind
    }

    public let lines: [Line]
    public let totalLines: Int
    public let errorCount: Int
    /// `true` when `lines` is a focused subset of the log rather than all of it.
    public let isExcerpt: Bool

    public static let contextBefore = 30
    public static let contextAfter = 8
    public static let tailLines = 200

    public static func parse(_ raw: String, full: Bool = false) -> CILogExcerpt {
        let cleaned: [(String, Line.Kind)] = raw.split(separator: "\n", omittingEmptySubsequences: false).map { sub in
            var text = String(sub)
            if text.hasSuffix("\r") { text.removeLast() }
            text = stripTimestamp(text)
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            if let rest = text.dropPrefix("##[error]") { return ("Error: " + rest, .error) }
            if let rest = text.dropPrefix("##[warning]") { return ("Warning: " + rest, .warning) }
            if let rest = text.dropPrefix("##[group]") { return ("▸ " + rest, .group) }
            if text.hasPrefix("##[endgroup]") { return ("", .gap) }
            if let rest = text.dropPrefix("##[") , let close = rest.firstIndex(of: "]") {
                return (String(rest[rest.index(after: close)...]), .normal)
            }
            return (text, .normal)
        }.filter { $0.1 != .gap }

        let errorIndices = cleaned.indices.filter { cleaned[$0].1 == .error }
        if full || cleaned.count <= tailLines {
            return CILogExcerpt(
                lines: cleaned.enumerated().map { Line(id: $0.offset, text: $0.element.0, kind: $0.element.1) },
                totalLines: cleaned.count, errorCount: errorIndices.count, isExcerpt: false
            )
        }

        var keep = IndexSet()
        for i in errorIndices {
            keep.insert(integersIn: max(0, i - contextBefore)...min(cleaned.count - 1, i + contextAfter))
        }
        if keep.isEmpty {
            keep.insert(integersIn: (cleaned.count - tailLines)..<cleaned.count)
        }

        var lines: [Line] = []
        var previous: Int?
        for i in keep {
            if let previous, i > previous + 1 {
                lines.append(Line(id: -i, text: "⋯ \(i - previous - 1) lines hidden", kind: .gap))
            } else if previous == nil, i > 0 {
                lines.append(Line(id: -i, text: "⋯ \(i) earlier lines hidden", kind: .gap))
            }
            lines.append(Line(id: i, text: cleaned[i].0, kind: cleaned[i].1))
            previous = i
        }
        return CILogExcerpt(lines: lines, totalLines: cleaned.count, errorCount: errorIndices.count, isExcerpt: true)
    }

    /// Actions prefixes every line with an ISO-8601 timestamp like `2024-05-01T10:20:30.1234567Z `.
    static func stripTimestamp(_ line: String) -> String {
        let utf8 = Array(line.utf8.prefix(40))
        guard utf8.count > 20, utf8[4] == UInt8(ascii: "-"), utf8[10] == UInt8(ascii: "T"),
              let z = utf8.firstIndex(of: UInt8(ascii: "Z")), z < 36, z + 1 < utf8.count, utf8[z + 1] == UInt8(ascii: " ") else {
            return line
        }
        return String(line.utf8.dropFirst(z + 2)) ?? line
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? self[index(startIndex, offsetBy: prefix.count)...] : nil
    }
}

public enum PRJobLogState: Sendable, Equatable {
    case loading
    case loaded(raw: String, excerpt: CILogExcerpt)
    case failed(String)

    var isLoadedOrLoading: Bool {
        if case .failed = self { return false }
        return true
    }
}
