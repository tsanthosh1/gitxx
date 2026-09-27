import Foundation

/// GitHub-style search text for the PR list: the active tab and author as qualifiers
/// (`is:open author:@me`), followed by free text that filters the loaded list.
enum PRSearchQuery {
    static func qualifiers(filter: PRFilter, author: String?) -> [String] {
        var tokens: [String]
        switch filter {
        case .myOpen: tokens = ["is:open", "author:@me"]
        case .myClosed: tokens = ["is:closed", "author:@me"]
        case .open: tokens = ["is:open"]
        case .closed: tokens = ["is:closed"]
        case .reviewNeeded: tokens = ["is:open", "review-requested:@me"]
        case .all: tokens = ["is:pr"]
        }
        if let author, !author.isEmpty, filter != .myOpen, filter != .myClosed {
            tokens.append("author:\(author)")
        }
        return tokens
    }

    /// Tokens owned by the tab / author controls rather than the free-text filter.
    static func isScopeToken(_ token: String) -> Bool {
        let t = token.lowercased()
        return t == "is:pr" || t == "is:open" || t == "is:closed" || t.hasPrefix("author:") || t.hasPrefix("review-requested:")
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func freeText(_ text: String) -> String {
        tokens(text).filter { !isScopeToken($0) }.joined(separator: " ")
    }

    static func compose(filter: PRFilter, author: String?, freeText: String) -> String {
        let scope = qualifiers(filter: filter, author: author).joined(separator: " ")
        return freeText.isEmpty ? scope + " " : scope + " " + freeText
    }

    /// Tab and author implied by typed qualifiers (applied when the user presses Return).
    static func scope(of text: String) -> (filter: PRFilter, author: String?) {
        let lower = tokens(text).map { $0.lowercased() }
        let author = tokens(text).first { $0.lowercased().hasPrefix("author:") }.map { String($0.dropFirst("author:".count)) }
        let isMe = author?.lowercased() == "@me"
        let closed = lower.contains("is:closed")
        let open = lower.contains("is:open")
        if lower.contains("review-requested:@me") { return (.reviewNeeded, nil) }
        if isMe { return (closed ? .myClosed : .myOpen, nil) }
        let filter: PRFilter = closed ? .closed : (open ? .open : .all)
        return (filter, author)
    }
}
