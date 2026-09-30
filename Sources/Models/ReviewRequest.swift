import SwiftUI

/// Where a PR someone asked you to review (in chat, not on GitHub) stands for you.
public enum ReviewRequestStatus: String, Codable, CaseIterable, Sendable {
    case pending, notApproved, approved, merged, closed, mine, unknown

    var label: String {
        switch self {
        case .pending: return "Needs your review"
        case .notApproved: return "Not approved by you"
        case .approved: return "Approved by you"
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .mine: return "Your PR"
        case .unknown: return "Status unavailable"
        }
    }

    var color: Color {
        switch self {
        case .pending: return .orange
        case .notApproved: return .red
        case .approved: return .green
        case .merged: return .purple
        case .closed, .unknown: return .secondary
        case .mine: return .blue
        }
    }

    var icon: String {
        switch self {
        case .pending: return "clock.badge.exclamationmark"
        case .notApproved: return "xmark.circle"
        case .approved: return "checkmark.seal.fill"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.octagon"
        case .mine: return "person.crop.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

public struct ReviewRequestItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(owner)/\(repo)#\(number)".lowercased() }
    var owner: String
    var repo: String
    var number: Int
    var url: String { "\(GitHubHost.web)/\(owner)/\(repo)/pull/\(number)" }

    // From Slack
    var requestedBy: String?
    var permalink: String?
    var channel: String?
    var postedAt: Date?
    var snippet: String

    // From GitHub
    var title: String?
    var author: String?
    var state: String?
    var isDraft = false
    var myReview: String?
    var myReviewAt: Date?
    var lastCommitAt: Date?
    var updatedAt: Date?
    var additions: Int?
    var deletions: Int?

    var status: ReviewRequestStatus = .unknown
    /// Approved or reviewed earlier, but the author pushed since.
    var changedSinceMyReview = false
}

/// Pulls GitHub PR links, with who posted them and when, out of Slack search results.
enum SlackPRMentionParser {
    struct Mention { var item: ReviewRequestItem; var context: String }

    private static let prPattern = #"https?://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\d+)"#
    private static let permalinkPattern = #"https://[A-Za-z0-9-]+\.slack\.com/archives/[A-Za-z0-9]+/p\d+(?:\?[^\s)>\]"|]*)?"#

    /// Handles both JSON results (message objects with text/permalink/user/ts) and markdown-ish text.
    static func parse(_ text: String, channel: String?) -> [Mention] {
        if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            let found = walk(json, channel: channel)
            if !found.isEmpty { return found }
        }
        return parseText(text, channel: channel)
    }

    private static func walk(_ node: Any, channel: String?) -> [Mention] {
        if let array = node as? [Any] { return array.flatMap { walk($0, channel: channel) } }
        guard let dict = node as? [String: Any] else { return [] }
        let nested = dict.values.flatMap { walk($0, channel: channel) }
        if !nested.isEmpty { return nested }
        let strings = dict.values.compactMap { $0 as? String }
        let body = strings.joined(separator: "\n")
        let prs = prLinks(in: body)
        guard !prs.isEmpty else { return [] }
        func value(_ keys: [String]) -> String? {
            for key in keys { if let v = dict[key] as? String, !v.isEmpty { return v } }
            return nil
        }
        let permalink = value(["permalink", "link", "url"]).flatMap { $0.contains("slack.com") ? $0 : nil } ?? firstMatch(permalinkPattern, in: body)
        let author = value(["user_name", "username", "author_name", "real_name", "display_name", "author", "user", "from"])
        let date = value(["ts", "message_ts", "timestamp", "date", "time", "created"]).flatMap(parseDate)
            ?? (dict["ts"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let chan = value(["channel_name", "channel"]) ?? channel
        let snippet = value(["text", "message", "content"]) ?? body
        return prs.map { pr in
            Mention(item: ReviewRequestItem(owner: pr.owner, repo: pr.repo, number: pr.number, requestedBy: author,
                                            permalink: permalink, channel: chan, postedAt: date, snippet: clean(snippet)),
                    context: body)
        }
    }

    /// Text results: each PR link's surrounding block (between separators or blank-line-delimited headers).
    private static func parseText(_ text: String, channel: String?) -> [Mention] {
        let lines = text.components(separatedBy: .newlines)
        let isSeparator: (String) -> Bool = { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("---") || t.hasPrefix("#") || t.hasPrefix("===")
                || t.range(of: #"^(\*\*)?(Result|Message)\s*\d*"#, options: .regularExpression) != nil
        }
        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines {
            if isSeparator(line), !current.isEmpty { blocks.append(current); current = [] }
            current.append(line)
        }
        if !current.isEmpty { blocks.append(current) }
        // One unseparated blob: fall back to a few lines around each link.
        if blocks.count == 1, lines.count > 12 {
            blocks = lines.indices.filter { lines[$0].range(of: prPattern, options: .regularExpression) != nil }.map { i in
                Array(lines[max(0, i - 5)...min(lines.count - 1, i + 3)])
            }
        }
        var result: [Mention] = []
        for block in blocks {
            let body = block.joined(separator: "\n")
            let prs = prLinks(in: body)
            guard !prs.isEmpty else { continue }
            let author = labeled(["From", "Author", "User", "Sender", "Posted by"], in: block)
            let date = labeled(["Time", "Date", "Timestamp", "Posted", "ts", "Message_ts"], in: block).flatMap(parseDate)
            let chan = labeled(["Channel", "In"], in: block) ?? channel
            let text = labeled(["Text", "Message", "Content"], in: block) ?? block.filter { !$0.contains(":") || $0.contains("github.com") }.joined(separator: " ")
            for pr in prs {
                result.append(Mention(item: ReviewRequestItem(owner: pr.owner, repo: pr.repo, number: pr.number, requestedBy: author,
                                                              permalink: firstMatch(permalinkPattern, in: body), channel: chan,
                                                              postedAt: date, snippet: clean(text)),
                                      context: body))
            }
        }
        return result
    }

    static func nextCursor(_ text: String) -> String? {
        guard let range = text.range(of: #"\"?next_cursor\"?\s*[:=]\s*\"?([A-Za-z0-9=_\-]{4,})"#, options: .regularExpression) else { return nil }
        let match = String(text[range])
        return match.range(of: #"[A-Za-z0-9=_\-]{4,}$"#, options: .regularExpression).map { String(match[$0]) }
    }

    private static func prLinks(in text: String) -> [(owner: String, repo: String, number: Int)] {
        guard let regex = try? NSRegularExpression(pattern: prPattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let owner = ns.substring(with: m.range(at: 1)), repo = ns.substring(with: m.range(at: 2))
            guard let number = Int(ns.substring(with: m.range(at: 3))), seen.insert("\(owner)/\(repo)#\(number)".lowercased()).inserted else { return nil }
            return (owner, repo.hasSuffix(".git") ? String(repo.dropLast(4)) : repo, number)
        }
    }

    /// `Label: value`, or `Label:` followed by lines up to the next label or separator.
    /// Trailing Slack ids like `Priya (U0123)` are dropped.
    private static func labeled(_ labels: [String], in block: [String]) -> String? {
        let normalized = block.map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "- ", with: "", options: .anchored)
        }
        let isLabelLine: (String) -> Bool = { $0.range(of: #"^[A-Za-z_ ]{2,20}:(\s|$)"#, options: .regularExpression) != nil && !$0.hasPrefix("http") }
        for (i, t) in normalized.enumerated() {
            for label in labels where t.lowercased().hasPrefix(label.lowercased() + ":") {
                var value = t.dropFirst(label.count + 1).trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    value = normalized[(i + 1)...].prefix { !isLabelLine($0) && !$0.hasPrefix("---") && !$0.hasPrefix("#") }
                        .joined(separator: " ").trimmingCharacters(in: .whitespaces)
                }
                value = value.replacingOccurrences(of: #"\s*\((?:U|W|C|G|D)[A-Z0-9]{6,}\)$"#, with: "", options: .regularExpression)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
    }

    static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let epoch = Double(s.prefix(while: { $0.isNumber || $0 == "." })), epoch > 1_000_000_000, s.count < 25 {
            return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
        }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "MMM d, yyyy 'at' h:mm a", "MMM d, yyyy"] {
            formatter.dateFormat = format
            if let d = formatter.date(from: s) { return d }
        }
        return nil
    }

    private static func clean(_ text: String) -> String {
        let unlinked = text.replacingOccurrences(of: #"<(https?://[^|>]+)\|([^>]+)>"#, with: "$2", options: .regularExpression)
            .replacingOccurrences(of: #"[<>]"#, with: "", options: .regularExpression)
        return String(unlinked.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(280))
    }
}

