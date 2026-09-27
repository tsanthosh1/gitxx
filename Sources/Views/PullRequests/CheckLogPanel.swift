import SwiftUI
import AppKit

/// Inline GitHub Actions job log shown under a check row: an error-focused excerpt by default, the full log on demand.
struct CheckLogPanel: View {
    @ObservedObject var state: AppState
    let check: PRCheckRun
    let jobId: String
    var fillsHeight = false

    @State private var showFull = false
    @State private var fullExcerpt: CILogExcerpt?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider().opacity(0.6)
            content
        }
        .background(Color(red: 13/255, green: 17/255, blue: 23/255))
        .onAppear { state.loadJobLog(jobId: jobId) }
    }

    private var logState: PRJobLogState? { state.prJobLogs[jobId] }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if case .loaded(_, let excerpt) = logState {
                Text(summary(excerpt))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Job log")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .loaded(let raw, let excerpt) = logState {
                if excerpt.isExcerpt {
                    Button(showFull ? "Show errors only" : "Show full log") {
                        if !showFull && fullExcerpt == nil { fullExcerpt = CILogExcerpt.parse(raw, full: true) }
                        showFull.toggle()
                    }
                    .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(raw, forType: .string)
                    state.showToast("Copied job log", type: .success)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                .help("Copy the full raw log")
            }
            Button {
                fullExcerpt = nil
                state.loadJobLog(jobId: jobId, force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
            .help("Reload log")
            if let urlString = check.htmlUrl, let url = URL(string: urlString) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                .help("Open this job on GitHub")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    @ViewBuilder
    private var content: some View {
        switch logState {
        case .none, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading job log…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        case .failed(let message):
            Text(message.contains("404") || message.contains("410")
                 ? "The log isn't available (it may have expired, or the job hasn't produced one yet)."
                 : message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .loaded(_, let excerpt):
            let shown = showFull ? (fullExcerpt ?? excerpt) : excerpt
            if fillsHeight {
                LogTextView(excerpt: shown, scrollToFirstError: !showFull)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LogTextView(excerpt: shown, scrollToFirstError: !showFull)
                    .frame(height: min(420, max(120, CGFloat(shown.lines.count) * 16 + 16)))
            }
        }
    }

    private func summary(_ excerpt: CILogExcerpt) -> String {
        var parts = ["\(excerpt.totalLines) lines"]
        if excerpt.errorCount > 0 { parts.append("\(excerpt.errorCount) error\(excerpt.errorCount == 1 ? "" : "s")") }
        if excerpt.isExcerpt && !showFull {
            parts.append(excerpt.errorCount > 0 ? "showing error context" : "showing last \(CILogExcerpt.tailLines) lines")
        }
        return parts.joined(separator: " · ")
    }
}

/// Read-only, selectable monospaced log view; AppKit text layout keeps very long logs smooth.
struct LogTextView: NSViewRepresentable {
    let excerpt: CILogExcerpt
    var scrollToFirstError: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = false
            text.textContainerInset = NSSize(width: 10, height: 8)
            text.isAutomaticLinkDetectionEnabled = false
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.shown != excerpt, let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.shown = excerpt
        let (attributed, firstError) = Self.render(excerpt)
        text.textStorage?.setAttributedString(attributed)
        if scrollToFirstError, let firstError {
            text.scrollRangeToVisible(NSRange(location: firstError, length: 0))
        } else {
            text.scrollToEndOfDocument(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: CILogExcerpt?
    }

    private static func render(_ excerpt: CILogExcerpt) -> (NSAttributedString, Int?) {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        let out = NSMutableAttributedString()
        var firstError: Int?
        for line in excerpt.lines {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.82, alpha: 1)]
            switch line.kind {
            case .error:
                attrs[.foregroundColor] = NSColor(red: 1, green: 0.48, blue: 0.45, alpha: 1)
                attrs[.backgroundColor] = NSColor(red: 0.97, green: 0.32, blue: 0.29, alpha: 0.12)
                attrs[.font] = bold
                if firstError == nil { firstError = out.length }
            case .warning:
                attrs[.foregroundColor] = NSColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1)
            case .group:
                attrs[.foregroundColor] = NSColor(white: 0.95, alpha: 1)
                attrs[.font] = bold
            case .gap:
                attrs[.foregroundColor] = NSColor(white: 0.5, alpha: 1)
            case .normal:
                break
            }
            out.append(NSAttributedString(string: line.text + "\n", attributes: attrs))
        }
        return (out, firstError)
    }
}
