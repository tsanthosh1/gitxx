import SwiftUI
import AppKit

/// Selectable, wrapping text backed by `NSTextView`, measured in `sizeThatFits`.
/// SwiftUI's `.textSelection(.enabled)` inside a scrolling stack can spin forever re-laying out its
/// selection overlay, which froze the app while scrolling the chat.
struct SelectableText: NSViewRepresentable {
    let text: NSAttributedString
    /// Report the width the text actually needs (for bubbles) instead of the full proposed width.
    var hugsWidth = false

    func makeNSView(context: Context) -> NSTextView {
        let view = SizedTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        view.textStorage?.setAttributedString(text)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if view.textStorage?.isEqual(to: text) == false {
            view.textStorage?.setAttributedString(text)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 100_000
        let width = max(proposed, 1)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let fitted = (hugsWidth || proposal.width == nil || proposed == 100_000) ? min(width, ceil(used.width) + 1) : width
        return CGSize(width: fitted, height: ceil(used.height))
    }
}

private final class SizedTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let container = textContainer, abs(container.containerSize.width - newSize.width) > 0.5 {
            container.containerSize = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
        }
    }
}

/// Builds the attributed strings shown in the chat; parsed once per distinct text.
@MainActor
enum ChatText {
    private static var cache: [String: NSAttributedString] = [:]

    private static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        return p
    }()

    static func plain(_ s: String, size: CGFloat, monospaced: Bool = false, color: NSColor = .labelColor) -> NSAttributedString {
        let key = "p|\(size)|\(monospaced)|\(color.hashValue)|" + s
        if let hit = cache[key] { return hit }
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        let out = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        store(key, out)
        return out
    }

    /// Inline Markdown (bold, italic, code, links, strikethrough). Headings become bold lines, `-`/`*` bullets become `•`.
    static func markdown(_ s: String, size: CGFloat) -> NSAttributedString {
        let key = "m|\(size)|" + s
        if let hit = cache[key] { return hit }
        let cleaned = s.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.hasPrefix("#") { l.removeFirst() }
            if l.count != line.count { return "**" + l.trimmingCharacters(in: .whitespaces) + "**" }
            let indent = l.prefix(while: { $0 == " " })
            let rest = l.dropFirst(indent.count)
            if rest.hasPrefix("- ") || rest.hasPrefix("* ") { return indent + "• " + rest.dropFirst(2) }
            return l
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(s)

        let base = NSFont.systemFont(ofSize: size)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var font = base
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
                    attrs[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.09)
                }
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attrs[.link] = link }
            attrs[.font] = font
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        store(key, out)
        return out
    }

    private static func store(_ key: String, _ value: NSAttributedString) {
        if cache.count > 600 { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
    }
}
