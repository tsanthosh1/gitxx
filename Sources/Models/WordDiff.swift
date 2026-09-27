import Foundation

/// Intra-line diff for a deleted/added line pair: which tokens changed on each side.
public enum WordDiff {
    public struct Segment: Equatable, Sendable {
        public let text: String
        public let changed: Bool
    }

    /// Returns `nil` when the lines are too different (or too long) for word highlighting to help.
    public static func diff(old: String, new: String) -> (old: [Segment], new: [Segment])? {
        guard old != new, old.utf8.count <= 1000, new.utf8.count <= 1000 else { return nil }
        let a = tokenize(old), b = tokenize(new)
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 60_000 else { return nil }

        // LCS table over tokens.
        let n = a.count, m = b.count
        var table = [Int](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * (m + 1) + j] = a[i] == b[j]
                    ? table[(i + 1) * (m + 1) + j + 1] + 1
                    : max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1])
            }
        }
        var keepA = [Bool](repeating: false, count: n), keepB = [Bool](repeating: false, count: m)
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                keepA[i] = true; keepB[j] = true; i += 1; j += 1
            } else if table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }

        let common = a.indices.filter { keepA[$0] && !isSpace(a[$0]) }.reduce(0) { $0 + a[$1].count }
        let longest = max(old.count, new.count)
        guard longest > 0, Double(common) / Double(longest) >= 0.35 else { return nil }
        return (segments(a, keepA), segments(b, keepB))
    }

    private static func segments(_ tokens: [String], _ keep: [Bool]) -> [Segment] {
        var out: [Segment] = []
        for (idx, token) in tokens.enumerated() {
            // Whitespace between two changed tokens reads as part of the change.
            let changed = !keep[idx]
            if let last = out.last, last.changed == changed {
                out[out.count - 1] = Segment(text: last.text + token, changed: changed)
            } else {
                out.append(Segment(text: token, changed: changed))
            }
        }
        return out
    }

    private static func isSpace(_ token: String) -> Bool {
        token.first.map { $0 == " " || $0 == "\t" } ?? false
    }

    /// Word characters group together, whitespace runs group together, every other character stands alone.
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentKind = 0 // 1 word, 2 space
        for ch in s {
            let kind = (ch.isLetter || ch.isNumber || ch == "_") ? 1 : ((ch == " " || ch == "\t") ? 2 : 0)
            if kind != 0 && kind == currentKind {
                current.append(ch)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(ch)
                currentKind = kind
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
