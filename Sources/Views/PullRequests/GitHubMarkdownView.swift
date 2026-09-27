import SwiftUI
import AppKit

// MARK: - GitHub Markdown View

public struct GitHubMarkdownView: View {
    public let markdown: String
    public var onToggleChecklist: ((Int) async throws -> Void)? = nil

    public init(markdown: String, onToggleChecklist: ((Int) async throws -> Void)? = nil) {
        self.markdown = markdown
        self.onToggleChecklist = onToggleChecklist
    }

    public var body: some View {
        let cleanText = Self.sanitizeGitHubMarkdown(markdown)

        VStack(alignment: .leading, spacing: 0) {
            if cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No description provided.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                    .italic()
                    .padding(.vertical, 8)
            } else if cleanText.localizedCaseInsensitiveContains("<details>") {
                // If the markdown contains collapsible <details> tags, render segments
                renderWithDetailsSupport(cleanText)
            } else {
                // Standard markdown: render as a single unified text view for continuous multi-line selection
                UnifiedMarkdownTextView(
                    markdown: cleanText,
                    onToggleChecklist: onToggleChecklist
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Details Tag Support

    @ViewBuilder
    private func renderWithDetailsSupport(_ text: String) -> some View {
        let segments = parseDetailsSegments(text)
        ForEach(segments.indices, id: \.self) { idx in
            let seg = segments[idx]
            switch seg {
            case .standard(let md):
                if !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    UnifiedMarkdownTextView(markdown: md, onToggleChecklist: onToggleChecklist)
                }
            case .details(let summary, let content):
                DisclosureGroup {
                    GitHubMarkdownView(markdown: content, onToggleChecklist: onToggleChecklist)
                        .padding(.top, 4)
                        .padding(.leading, 8)
                } label: {
                    Text(summary)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 88/255, green: 166/255, blue: 255/255))
                }
                .padding(10)
                .background(Color(red: 22/255, green: 27/255, blue: 34/255).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(red: 48/255, green: 54/255, blue: 61/255), lineWidth: 1)
                )
                .padding(.vertical, 4)
            }
        }
    }

    private enum MarkdownSegment {
        case standard(String)
        case details(summary: String, content: String)
    }

    private func parseDetailsSegments(_ text: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        let rawLines = text.components(separatedBy: "\n")
        var currentStandardLines: [String] = []
        var i = 0

        while i < rawLines.count {
            let line = rawLines[i]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.lowercased().hasPrefix("<details>") {
                if !currentStandardLines.isEmpty {
                    segments.append(.standard(currentStandardLines.joined(separator: "\n")))
                    currentStandardLines = []
                }

                var summary = "Details"
                var detailLines: [String] = []
                i += 1
                while i < rawLines.count {
                    let dLine = rawLines[i]
                    let dTrimmed = dLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if dTrimmed.lowercased().hasPrefix("</details>") {
                        i += 1
                        break
                    }
                    if dTrimmed.lowercased().hasPrefix("<summary>") {
                        let clean = dTrimmed
                            .replacingOccurrences(of: "<summary>", with: "", options: .caseInsensitive)
                            .replacingOccurrences(of: "</summary>", with: "", options: .caseInsensitive)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !clean.isEmpty { summary = clean }
                    } else {
                        detailLines.append(dLine)
                    }
                    i += 1
                }
                segments.append(.details(summary: summary, content: detailLines.joined(separator: "\n")))
            } else {
                currentStandardLines.append(line)
                i += 1
            }
        }

        if !currentStandardLines.isEmpty {
            segments.append(.standard(currentStandardLines.joined(separator: "\n")))
        }

        return segments
    }

    // MARK: - Markdown & HTML Preprocessing

    public static func sanitizeGitHubMarkdown(_ input: String) -> String {
        var s = input

        // 1. Strip HTML comments <!-- ... -->
        while let start = s.range(of: "<!--"),
              let end = s.range(of: "-->", range: start.lowerBound..<s.endIndex) {
            s.removeSubrange(start.lowerBound..<end.upperBound)
        }

        // 2. Normalize <br> to newlines
        s = s.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)

        // 3. Transform HTML table structure (DangerJS / bot tables)
        if s.localizedCaseInsensitiveContains("<table") {
            if let emptyRegex = try? NSRegularExpression(pattern: "<t[hd][^>]*>\\s*</t[hd]>", options: [.caseInsensitive]) {
                s = emptyRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: s.utf16.count), withTemplate: "")
            }

            if let thRegex = try? NSRegularExpression(pattern: "<th[^>]*>([^<]+)</th>", options: [.caseInsensitive]) {
                s = thRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: s.utf16.count), withTemplate: "\n### $1\n")
            }

            if let trRegex = try? NSRegularExpression(pattern: "(?s)<tr[^>]*>([\\s\\S]*?)</tr>", options: [.caseInsensitive]) {
                let matches = trRegex.matches(in: s, range: NSRange(location: 0, length: s.utf16.count))
                for m in matches.reversed() {
                    let trContent = (s as NSString).substring(with: m.range(at: 1))
                    if let tdRegex = try? NSRegularExpression(pattern: "(?s)<td[^>]*>([\\s\\S]*?)</td>", options: [.caseInsensitive]) {
                        let tdMatches = tdRegex.matches(in: trContent, range: NSRange(location: 0, length: trContent.utf16.count))
                        let cells = tdMatches.map { (trContent as NSString).substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        if !cells.isEmpty {
                            let rowStr = "\n• " + cells.joined(separator: " ") + "\n"
                            s = (s as NSString).replacingCharacters(in: m.range, with: rowStr)
                        }
                    }
                }
            }

            if let tagRegex = try? NSRegularExpression(pattern: "</?(?:table|thead|tbody|tfoot|tr|td|th|p|div|span)[^>]*>", options: [.caseInsensitive]) {
                s = tagRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: s.utf16.count), withTemplate: "\n")
            }
        }

        // 4. Format markdown tables (e.g. CodeRabbit review summary tables)
        s = formatMarkdownTables(s)

        // 5. Replace common GitHub emoji shortcodes
        let emojis: [(String, String)] = [
            (":no_entry_sign:", "🚫"),
            (":white_check_mark:", "✅"),
            (":warning:", "⚠️"),
            (":book:", "📖"),
            (":tada:", "🎉"),
            (":rocket:", "🚀"),
            (":sparkles:", "✨"),
            (":bulb:", "💡"),
            (":memo:", "📝"),
            (":x:", "❌"),
            (":heavy_check_mark:", "✔️")
        ]
        for (k, v) in emojis {
            s = s.replacingOccurrences(of: k, with: v)
        }

        // 6. Clean up consecutive empty lines
        let rawLines = s.components(separatedBy: "\n")
        var cleanedLines: [String] = []
        var emptyCount = 0
        for l in rawLines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t == "###" { continue }
            if t.isEmpty {
                emptyCount += 1
                if emptyCount <= 1 {
                    cleanedLines.append("")
                }
            } else {
                emptyCount = 0
                cleanedLines.append(l)
            }
        }

        return cleanedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatMarkdownTables(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && i + 1 < lines.count {
                let nextLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if nextLine.hasPrefix("|") && nextLine.contains("---") {
                    i += 2 // skip header and divider
                    result.append("")
                    while i < lines.count {
                        let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                        guard rowLine.hasPrefix("|") && rowLine.hasSuffix("|") else { break }
                        let cells = rowLine.split(separator: "|").map {
                            $0.trimmingCharacters(in: .whitespaces)
                                .replacingOccurrences(of: "<br>", with: " ", options: .caseInsensitive)
                                .replacingOccurrences(of: "<br/>", with: " ", options: .caseInsensitive)
                                .replacingOccurrences(of: "<br />", with: " ", options: .caseInsensitive)
                        }.filter { !$0.isEmpty }

                        if cells.count >= 2 {
                            let col1 = cells[0].trimmingCharacters(in: .whitespaces)
                            let col2 = cells[1].trimmingCharacters(in: .whitespaces)
                            result.append("• **\(col1)**: \(col2)")
                        } else if let only = cells.first {
                            result.append("• \(only)")
                        }
                        i += 1
                    }
                    result.append("")
                    continue
                }
            }
            result.append(line)
            i += 1
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Toggle Checklist Item Helper

    public static func toggleChecklistItem(in markdown: String, at targetIndex: Int) -> String {
        let pattern = #"^(\s*[-*]\s+\[)([ xX])(\]\s+.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return markdown
        }

        let lines = markdown.components(separatedBy: "\n")
        var checklistCount = 0
        var newLines: [String] = []

        for line in lines {
            let range = NSRange(location: 0, length: line.utf16.count)
            if let match = regex.firstMatch(in: line, options: [], range: range) {
                if checklistCount == targetIndex {
                    let stateRange = match.range(at: 2)
                    let currentState = (line as NSString).substring(with: stateRange)
                    let newState = (currentState == " " ? "x" : " ")
                    let prefix = (line as NSString).substring(with: match.range(at: 1))
                    let suffix = (line as NSString).substring(with: match.range(at: 3))
                    newLines.append(prefix + newState + suffix)
                } else {
                    newLines.append(line)
                }
                checklistCount += 1
            } else {
                newLines.append(line)
            }
        }

        return newLines.joined(separator: "\n")
    }
}

// MARK: - Unified Markdown Text View (NSViewRepresentable)

public struct UnifiedMarkdownTextView: NSViewRepresentable {
    public let markdown: String
    public var onToggleChecklist: ((Int) async throws -> Void)?

    public init(markdown: String, onToggleChecklist: ((Int) async throws -> Void)? = nil) {
        self.markdown = markdown
        self.onToggleChecklist = onToggleChecklist
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onToggleChecklist: onToggleChecklist)
    }

    public func makeNSView(context: Context) -> UnifiedNSTextView {
        let textView = UnifiedNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = true
        textView.importsGraphics = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)

        // Enable hardware GPU CALayer acceleration for butter-smooth 120 FPS scrolling
        textView.wantsLayer = true
        textView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        textView.canDrawSubviewsIntoLayer = true

        context.coordinator.textView = textView
        textView.coordinator = context.coordinator

        applyMarkdown(markdown, to: textView)
        return textView
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: UnifiedNSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0 else {
            return CGSize(width: NSView.noIntrinsicMetric, height: max(24, nsView.cachedHeight))
        }
        let h = nsView.heightForWidth(width)
        return CGSize(width: width, height: h)
    }

    public func updateNSView(_ nsView: UnifiedNSTextView, context: Context) {
        context.coordinator.onToggleChecklist = onToggleChecklist
        nsView.coordinator = context.coordinator

        // Only rebuild attributed string if the text actually changed,
        // avoiding resetting active user mouse drags or selections.
        if nsView.cachedMarkdown != markdown {
            applyMarkdown(markdown, to: nsView)
        }
    }

    private func applyMarkdown(_ md: String, to textView: UnifiedNSTextView) {
        textView.cachedMarkdown = md
        let builder = MarkdownAttributedStringBuilder()
        let attributedString = builder.build(from: md)

        textView.textStorage?.setAttributedString(attributedString)
        textView.invalidateCalculatedHeight()
    }

    @MainActor
    public class Coordinator {
        public var onToggleChecklist: ((Int) async throws -> Void)?
        public weak var textView: UnifiedNSTextView?

        public init(onToggleChecklist: ((Int) async throws -> Void)? = nil) {
            self.onToggleChecklist = onToggleChecklist
        }

        public func toggleChecklist(at index: Int) {
            guard let action = onToggleChecklist else { return }
            Task { @MainActor in
                try? await action(index)
            }
        }
    }
}

// MARK: - Unified AppKit Text View with Continuous Multi-line Selection

public class UnifiedNSTextView: NSTextView {
    public var cachedMarkdown: String = ""
    public weak var coordinator: UnifiedMarkdownTextView.Coordinator?
    public var lastKnownWidth: CGFloat = -1
    public var cachedHeight: CGFloat = -1
    public var cachedCheckboxRects: [(index: Int, rect: NSRect)] = []

    public func invalidateCalculatedHeight() {
        cachedHeight = -1
        lastKnownWidth = -1
        cachedCheckboxRects.removeAll()
        invalidateIntrinsicContentSize()
    }

    public func heightForWidth(_ width: CGFloat) -> CGFloat {
        if cachedHeight > 0 && abs(width - lastKnownWidth) <= 1.0 {
            return cachedHeight
        }
        guard let layoutManager = layoutManager, let textContainer = textContainer else {
            return cachedHeight > 0 ? cachedHeight : 24
        }
        lastKnownWidth = width
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let h = max(18, ceil(used.height))
        cachedHeight = h
        recomputeCheckboxRects()
        return h
    }

    public override var intrinsicContentSize: NSSize {
        if cachedHeight > 0 {
            return NSSize(width: NSView.noIntrinsicMetric, height: cachedHeight)
        }
        let fallbackWidth = bounds.width > 0 ? bounds.width : 600
        return NSSize(width: NSView.noIntrinsicMetric, height: heightForWidth(fallbackWidth))
    }

    public override func layout() {
        super.layout()
        if bounds.width > 10 && lastKnownWidth > 0 && abs(bounds.width - lastKnownWidth) > 2.0 {
            _ = heightForWidth(bounds.width)
            invalidateIntrinsicContentSize()
        }
    }

    private func recomputeCheckboxRects() {
        guard let layoutManager = layoutManager, let textContainer = textContainer, let textStorage = textStorage else { return }
        var rects: [(index: Int, rect: NSRect)] = []
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(NSAttributedString.Key("ChecklistIndex"), in: fullRange) { value, range, _ in
            if let index = value as? Int {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rects.append((index: index, rect: rect))
            }
        }
        self.cachedCheckboxRects = rects
    }

    // MARK: - Cursor Management

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
        for item in cachedCheckboxRects {
            addCursorRect(item.rect.insetBy(dx: -4, dy: -4), cursor: .pointingHand)
        }
    }

    // MARK: - Mouse Click & Selection

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check if the click hit an interactive checkbox
        if let (index, _) = findChecklistIndex(at: point) {
            coordinator?.toggleChecklist(at: index)
            return
        }

        // Standard multi-line continuous text selection
        super.mouseDown(with: event)
    }

    private func findChecklistIndex(at point: NSPoint) -> (Int, NSRect)? {
        for item in cachedCheckboxRects {
            if item.rect.insetBy(dx: -5, dy: -5).contains(point) {
                return (item.index, item.rect)
            }
        }
        return nil
    }

    // MARK: - Link Click Handling

    public override func clicked(onLink link: Any, at charIndex: Int) {
        if let url = link as? URL {
            NSWorkspace.shared.open(url)
        } else if let str = link as? String, let url = URL(string: str) {
            NSWorkspace.shared.open(url)
        } else {
            super.clicked(onLink: link, at: charIndex)
        }
    }

    // MARK: - Enhanced Copy to Clipboard

    public override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let textStorage = textStorage else {
            super.copy(sender)
            return
        }

        super.copy(sender)

        // Replace attachment characters (\u{FFFC}) with clean [ ] / [x] in the plain-text pasteboard string
        let subAttr = textStorage.attributedSubstring(from: range)
        var plain = ""
        subAttr.enumerateAttributes(in: NSRange(location: 0, length: subAttr.length)) { attrs, r, _ in
            let chunk = (subAttr.string as NSString).substring(with: r)
            if chunk == "\u{FFFC}" {
                if let isChecked = attrs[NSAttributedString.Key("ChecklistChecked")] as? Bool {
                    plain += isChecked ? "[x] " : "[ ] "
                } else {
                    plain += "• "
                }
            } else {
                plain += chunk
            }
        }

        NSPasteboard.general.setString(plain, forType: .string)
    }
}

// MARK: - Markdown AttributedString Builder

@MainActor
final class MarkdownAttributedStringBuilder {
    private let textColor = NSColor(red: 230/255, green: 237/255, blue: 243/255, alpha: 1)
    private let mutedColor = NSColor(red: 125/255, green: 133/255, blue: 144/255, alpha: 1)
    private let linkColor = NSColor(red: 88/255, green: 166/255, blue: 255/255, alpha: 1)
    private let codeBgColor = NSColor(red: 22/255, green: 27/255, blue: 34/255, alpha: 1)
    private let dividerColor = NSColor(red: 48/255, green: 54/255, blue: 61/255, alpha: 1)

    // Cached checkbox images
    private static let uncheckedImage: NSImage = MarkdownAttributedStringBuilder.makeCheckboxImage(checked: false)
    private static let checkedImage: NSImage = MarkdownAttributedStringBuilder.makeCheckboxImage(checked: true)
    private static let dividerImage: NSImage = MarkdownAttributedStringBuilder.makeDividerImage()
    private static let parsedCache = NSCache<NSString, NSAttributedString>()

    func build(from markdown: String) -> NSMutableAttributedString {
        if let cached = Self.parsedCache.object(forKey: markdown as NSString) {
            return cached.mutableCopy() as! NSMutableAttributedString
        }
        let result = NSMutableAttributedString()
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.components(separatedBy: "\n")

        var i = 0
        var checklistIndex = 0

        while i < rawLines.count {
            let line = rawLines[i]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Blank line
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Code block ```
            if trimmed.hasPrefix("```") {
                var codeLines: [String] = []
                i += 1
                while i < rawLines.count && !rawLines[i].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                    codeLines.append(rawLines[i])
                    i += 1
                }
                if i < rawLines.count { i += 1 } // consume closing ```
                appendCodeBlock(codeLines, to: result)
                continue
            }

            // Headers
            if trimmed.hasPrefix("#### ") {
                appendHeader(String(trimmed.dropFirst(5)), level: 4, to: result)
                i += 1
                continue
            } else if trimmed.hasPrefix("### ") {
                appendHeader(String(trimmed.dropFirst(4)), level: 3, to: result)
                i += 1
                continue
            } else if trimmed.hasPrefix("## ") {
                appendHeader(String(trimmed.dropFirst(3)), level: 2, to: result)
                i += 1
                continue
            } else if trimmed.hasPrefix("# ") {
                appendHeader(String(trimmed.dropFirst(2)), level: 1, to: result)
                i += 1
                continue
            }

            // Horizontal Rules
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                appendDivider(to: result)
                i += 1
                continue
            }

            // Checklists
            if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("* [ ] ") {
                let content = String(trimmed.dropFirst(6))
                appendChecklistItem(content, checked: false, index: checklistIndex, to: result)
                checklistIndex += 1
                i += 1
                continue
            } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("* [x] ") || trimmed.hasPrefix("- [X] ") || trimmed.hasPrefix("* [X] ") {
                let content = String(trimmed.dropFirst(6))
                appendChecklistItem(content, checked: true, index: checklistIndex, to: result)
                checklistIndex += 1
                i += 1
                continue
            }

            // Blockquotes
            if trimmed.hasPrefix("> ") || trimmed.hasPrefix(">") {
                let quote = trimmed.hasPrefix("> ") ? String(trimmed.dropFirst(2)) : String(trimmed.dropFirst(1))
                appendBlockquote(quote, to: result)
                i += 1
                continue
            }

            // Subscript note <sub>...</sub>
            if trimmed.contains("<sub>") {
                let clean = trimmed
                    .replacingOccurrences(of: "<sub>", with: "")
                    .replacingOccurrences(of: "</sub>", with: "")
                appendSubscript(clean, to: result)
                i += 1
                continue
            }

            // Sub-bullets (indented)
            if line.hasPrefix("  * ") || line.hasPrefix("    * ") || line.hasPrefix("  - ") || line.hasPrefix("    - ") {
                let item = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                appendBulletItem(String(item), level: 2, to: result)
                i += 1
                continue
            } else if trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") {
                let item = String(trimmed.dropFirst(2))
                appendBulletItem(item, level: 1, to: result)
                i += 1
                continue
            }

            // Numbered items (e.g. "1. ")
            if let match = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let prefix = String(trimmed[..<match.upperBound])
                let item = String(trimmed[match.upperBound...])
                appendNumberedItem(prefix: prefix, content: item, to: result)
                i += 1
                continue
            }

            // Regular paragraph: gather consecutive lines that belong together
            var paraLines: [String] = [trimmed]
            i += 1
            while i < rawLines.count {
                let nextLine = rawLines[i]
                let nextTrimmed = nextLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if nextTrimmed.isEmpty || isSpecialStart(nextTrimmed, rawLine: nextLine) {
                    break
                }
                paraLines.append(nextTrimmed)
                i += 1
            }
            appendParagraph(paraLines.joined(separator: " "), to: result)
        }

        Self.parsedCache.setObject(result.copy() as! NSAttributedString, forKey: markdown as NSString)
        return result
    }

    private func isSpecialStart(_ trimmed: String, rawLine: String) -> Bool {
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("```") || trimmed.hasPrefix(">") { return true }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" { return true }
        if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("* [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("* [x] ") { return true }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || rawLine.hasPrefix("  - ") || rawLine.hasPrefix("  * ") { return true }
        if trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: - Element Appenders

    private func appendHeader(_ text: String, level: Int, to result: NSMutableAttributedString) {
        let size: CGFloat
        let topSpace: CGFloat
        let bottomSpace: CGFloat
        switch level {
        case 1: size = 16.5; topSpace = 12; bottomSpace = 6
        case 2: size = 14.5; topSpace = 10; bottomSpace = 6
        case 3: size = 13.5; topSpace = 8; bottomSpace = 4
        default: size = 12.5; topSpace = 6; bottomSpace = 3
        }

        let pStyle = NSMutableParagraphStyle()
        pStyle.paragraphSpacingBefore = result.length == 0 ? 0 : topSpace
        pStyle.paragraphSpacing = (level <= 2) ? 4 : bottomSpace

        let baseFont = NSFont.boldSystemFont(ofSize: size)
        let headerAttr = parseInlineFormatting(text, baseFont: baseFont, baseColor: textColor)
        headerAttr.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: headerAttr.length))
        result.append(headerAttr)
        result.append(NSAttributedString(string: "\n"))

        // Add subtle divider line under H1 and H2
        if level <= 2 {
            appendDivider(to: result)
        }
    }

    private func appendParagraph(_ text: String, to result: NSMutableAttributedString) {
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineSpacing = 3.5
        pStyle.paragraphSpacing = 8
        pStyle.paragraphSpacingBefore = 2

        let baseFont = NSFont.systemFont(ofSize: 13.5)
        let attr = parseInlineFormatting(text, baseFont: baseFont, baseColor: textColor)
        attr.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: attr.length))
        result.append(attr)
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendBulletItem(_ text: String, level: Int, to result: NSMutableAttributedString) {
        let pStyle = NSMutableParagraphStyle()
        let prefix: String
        let baseFont: NSFont

        if level == 1 {
            pStyle.firstLineHeadIndent = 2
            pStyle.headIndent = 16
            prefix = "•  "
            baseFont = NSFont.systemFont(ofSize: 13.5)
        } else {
            pStyle.firstLineHeadIndent = 18
            pStyle.headIndent = 34
            prefix = "◦  "
            baseFont = NSFont.systemFont(ofSize: 13)
        }
        pStyle.lineSpacing = 2.5
        pStyle.paragraphSpacing = 3

        let bulletAttr = NSMutableAttributedString(string: prefix, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: mutedColor,
            .paragraphStyle: pStyle
        ])

        let contentAttr = parseInlineFormatting(text, baseFont: baseFont, baseColor: textColor)
        contentAttr.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: contentAttr.length))

        bulletAttr.append(contentAttr)
        result.append(bulletAttr)
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendNumberedItem(prefix: String, content: String, to result: NSMutableAttributedString) {
        let pStyle = NSMutableParagraphStyle()
        pStyle.firstLineHeadIndent = 2
        pStyle.headIndent = 22
        pStyle.lineSpacing = 2.5
        pStyle.paragraphSpacing = 3

        let numAttr = NSMutableAttributedString(string: prefix, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: mutedColor,
            .paragraphStyle: pStyle
        ])

        let contentAttr = parseInlineFormatting(content, baseFont: .systemFont(ofSize: 13.5), baseColor: textColor)
        contentAttr.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: contentAttr.length))

        numAttr.append(contentAttr)
        result.append(numAttr)
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendChecklistItem(_ text: String, checked: Bool, index: Int, to result: NSMutableAttributedString) {
        let pStyle = NSMutableParagraphStyle()
        pStyle.firstLineHeadIndent = 0
        pStyle.headIndent = 22
        pStyle.lineSpacing = 2.5
        pStyle.paragraphSpacing = 4

        // Checkbox image attachment
        let attachment = NSTextAttachment()
        attachment.image = checked ? Self.checkedImage : Self.uncheckedImage
        attachment.bounds = CGRect(x: 0, y: -2.5, width: 14, height: 14)

        let attachAttr = NSMutableAttributedString(attachment: attachment)
        attachAttr.addAttribute(NSAttributedString.Key("ChecklistIndex"), value: index, range: NSRange(location: 0, length: attachAttr.length))
        attachAttr.addAttribute(NSAttributedString.Key("ChecklistChecked"), value: checked, range: NSRange(location: 0, length: attachAttr.length))
        attachAttr.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: attachAttr.length))

        let spaceAttr = NSAttributedString(string: "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 13.5),
            .paragraphStyle: pStyle
        ])

        let contentAttr = parseInlineFormatting(text, baseFont: .systemFont(ofSize: 13.5), baseColor: textColor)
        contentAttr.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: contentAttr.length))

        let line = NSMutableAttributedString()
        line.append(attachAttr)
        line.append(spaceAttr)
        line.append(contentAttr)

        result.append(line)
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendCodeBlock(_ lines: [String], to result: NSMutableAttributedString) {
        let pStyle = NSMutableParagraphStyle()
        pStyle.firstLineHeadIndent = 12
        pStyle.headIndent = 12
        pStyle.lineSpacing = 2.5
        pStyle.paragraphSpacing = 1
        pStyle.paragraphSpacingBefore = 4

        let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let blockText = lines.joined(separator: "\n") + "\n"

        let codeAttr = NSMutableAttributedString(string: blockText, attributes: [
            .font: codeFont,
            .foregroundColor: textColor,
            .backgroundColor: codeBgColor,
            .paragraphStyle: pStyle
        ])

        result.append(codeAttr)
    }

    private func appendBlockquote(_ text: String, to result: NSMutableAttributedString) {
        let pStyle = NSMutableParagraphStyle()
        pStyle.firstLineHeadIndent = 4
        pStyle.headIndent = 16
        pStyle.lineSpacing = 2.5
        pStyle.paragraphSpacing = 6

        let barAttr = NSMutableAttributedString(string: "▎ ", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(red: 48/255, green: 54/255, blue: 61/255, alpha: 1),
            .paragraphStyle: pStyle
        ])

        let quoteAttr = parseInlineFormatting(text, baseFont: NSFont.systemFont(ofSize: 13), baseColor: mutedColor)
        quoteAttr.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: quoteAttr.length))

        barAttr.append(quoteAttr)
        result.append(barAttr)
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendDivider(to result: NSMutableAttributedString) {
        let pStyle = NSMutableParagraphStyle()
        pStyle.paragraphSpacing = 6
        pStyle.paragraphSpacingBefore = 4

        let attachment = NSTextAttachment()
        attachment.image = Self.dividerImage
        attachment.bounds = CGRect(x: 0, y: 1, width: 800, height: 2)

        let divAttr = NSMutableAttributedString(attachment: attachment)
        divAttr.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: divAttr.length))
        result.append(divAttr)
        result.append(NSAttributedString(string: "\n"))
    }

    private func appendSubscript(_ text: String, to result: NSMutableAttributedString) {
        let pStyle = NSMutableParagraphStyle()
        pStyle.paragraphSpacing = 4

        let font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)
        let attr = parseInlineFormatting(text, baseFont: font, baseColor: mutedColor)
        attr.addAttribute(.paragraphStyle, value: pStyle, range: NSRange(location: 0, length: attr.length))
        result.append(attr)
        result.append(NSAttributedString(string: "\n"))
    }

    // MARK: - Inline Formatting Helper

    private func parseInlineFormatting(_ text: String, baseFont: NSFont, baseColor: NSColor) -> NSMutableAttributedString {
        let attributed: NSMutableAttributedString
        if let foundationAttr = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            attributed = NSMutableAttributedString(foundationAttr)
        } else {
            attributed = NSMutableAttributedString(string: text)
        }

        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.foregroundColor, value: baseColor, range: fullRange)
        attributed.addAttribute(.font, value: baseFont, range: fullRange)

        attributed.enumerateAttributes(in: fullRange) { attrs, range, _ in
            if let intent = attrs[NSAttributedString.Key("NSInlinePresentationIntent")] as? Int {
                if intent & 2 != 0 {
                    // Bold
                    attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: baseFont.pointSize), range: range)
                } else if intent & 1 != 0 {
                    // Italic
                    let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                    attributed.addAttribute(.font, value: italicFont, range: range)
                } else if intent & 4 != 0 {
                    // Inline Code
                    attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 0.5, weight: .medium), range: range)
                    attributed.addAttribute(.backgroundColor, value: NSColor(red: 48/255, green: 54/255, blue: 61/255, alpha: 0.6), range: range)
                }
            }
            if attrs[.link] != nil {
                attributed.addAttribute(.foregroundColor, value: linkColor, range: range)
                attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }

        return attributed
    }

    // MARK: - Checkbox & Divider Drawing

    private static func makeCheckboxImage(checked: Bool) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(x: 0.5, y: 0.5, width: 13, height: 13)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)

        if checked {
            NSColor(red: 35/255, green: 134/255, blue: 54/255, alpha: 1).setFill()
            path.fill()

            let checkPath = NSBezierPath()
            checkPath.lineWidth = 1.7
            checkPath.lineCapStyle = .round
            checkPath.lineJoinStyle = .round
            NSColor.white.setStroke()
            checkPath.move(to: NSPoint(x: 3.5, y: 7.0))
            checkPath.line(to: NSPoint(x: 5.5, y: 4.5))
            checkPath.line(to: NSPoint(x: 10.5, y: 9.5))
            checkPath.stroke()
        } else {
            NSColor(red: 22/255, green: 27/255, blue: 34/255, alpha: 1).setFill()
            path.fill()

            NSColor(red: 88/255, green: 96/255, blue: 105/255, alpha: 1).setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }

        image.unlockFocus()
        return image
    }

    private static func makeDividerImage() -> NSImage {
        let size = NSSize(width: 800, height: 2)
        let image = NSImage(size: size)
        image.lockFocus()

        let lineRect = NSRect(x: 0, y: 0.5, width: 800, height: 1)
        NSColor(red: 48/255, green: 54/255, blue: 61/255, alpha: 1).setFill()
        lineRect.fill()

        image.unlockFocus()
        return image
    }
}

// MARK: - Legacy Checkbox Views (for preview or standalone use)

public struct InteractiveGitHubCheckbox: View {
    public let checked: Bool
    public var onToggle: (() -> Void)? = nil

    @State private var isHovered = false

    public var body: some View {
        Button {
            onToggle?()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(checked ? Color(red: 35/255, green: 134/255, blue: 54/255) : Color(red: 22/255, green: 27/255, blue: 34/255))
                    .frame(width: 14, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(
                                isHovered ? Color(red: 88/255, green: 166/255, blue: 255/255) : (checked ? Color.clear : Color(red: 72/255, green: 79/255, blue: 88/255)),
                                lineWidth: isHovered ? 1.5 : 1
                            )
                    )

                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

public struct GitHubCheckbox: View {
    public let checked: Bool

    public init(checked: Bool) {
        self.checked = checked
    }

    public var body: some View {
        InteractiveGitHubCheckbox(checked: checked)
    }
}
