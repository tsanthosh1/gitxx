import SwiftUI
import AppKit

/// Bottom-right assistant: a floating bubble that expands into a fixed chat panel (⌘I).
struct AIChatOverlay: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat = AIChatStore.shared

    private let topInset: CGFloat = 64
    private let edge: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let maxWidth = max(geo.size.width - edge * 2, 320)
            let maxHeight = max(geo.size.height - topInset - edge, 260)
            let size = chat.isExpanded
                ? CGSize(width: min(maxWidth, 1040), height: maxHeight)
                : CGSize(width: min(maxWidth, 420), height: min(maxHeight, 600))
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 0) {
                    Spacer(minLength: 0)
                    if chat.isOpen {
                        AIChatPanel(state: state, chat: chat)
                            .frame(width: size.width, height: size.height)
                            .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
                    } else {
                        HStack(alignment: .center, spacing: 8) {
                            AIVoiceBubble(chat: chat, accent: state.accentTheme.primaryColor)
                            AIChatBubble(chat: chat, accent: state.accentTheme.primaryColor)
                        }
                        .transition(.scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
                    }
                }
            }
            .padding(.top, topInset)
            .padding(.trailing, edge)
            .padding(.bottom, edge)
        }
    }
}

private struct AIChatBubble: View {
    @ObservedObject var chat: AIChatStore
    let accent: Color
    @State private var hovering = false
    @State private var spin = false

    var body: some View {
        Button { chat.toggle() } label: {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [accent, accent.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                if chat.isRunning {
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .padding(3)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                        .onAppear { spin = true }
                        .onDisappear { spin = false }
                }
            }
            .frame(width: 46, height: 46)
            .overlay(alignment: .topTrailing) {
                if chat.hasUnread {
                    Circle().fill(Color.red).frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color(NSColor.windowBackgroundColor), lineWidth: 2))
                }
            }
            .shadow(color: .black.opacity(0.35), radius: hovering ? 12 : 8, y: 3)
            .scaleEffect(hovering ? 1.06 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.hoverPlain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .pointerCursor()
        .help(chat.isRunning ? "Assistant is working… (⌘I)" : "AI Assistant (⌘I)")
    }
}

/// Small mic beside the bubble: opens the assistant already listening.
private struct AIVoiceBubble: View {
    @ObservedObject var chat: AIChatStore
    let accent: Color
    @State private var hovering = false

    var body: some View {
        Button { chat.toggleVoice() } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(hovering ? Color.white : Color.primary.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovering ? accent : SurfaceStyle.elevatedBase))
                .overlay(Circle().stroke(hovering ? Color.clear : Color.primary.opacity(0.14)))
                .shadow(color: .black.opacity(0.3), radius: hovering ? 8 : 5, y: 2)
                .scaleEffect(hovering ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.hoverPlain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .pointerCursor()
        .help("Talk to the assistant (⌥⌘I)")
    }
}

/// Composer mic: a pulsing red stop button while listening.
private struct AIVoiceButton: View {
    @ObservedObject var chat: AIChatStore
    @ObservedObject var voice = AIVoiceInput.shared

    var body: some View {
        Button { AIVoiceInput.shared.toggle(chat: chat) } label: {
            ZStack {
                if voice.isRecording {
                    Circle()
                        .fill(Color.red.opacity(0.28))
                        .scaleEffect(1 + CGFloat(voice.level) * 0.55)
                        .animation(.easeOut(duration: 0.1), value: voice.level)
                    Circle().fill(Color.red)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else if voice.isStarting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "mic")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.hoverPlain)
        .pointerCursor()
        .help(voice.isRecording ? "Stop dictation (⌥⌘I)" : "Dictate (⌥⌘I)")
    }
}

private struct AIChatPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: AIChatStore
    @ObservedObject var voice = AIVoiceInput.shared
    @FocusState private var inputFocused: Bool
    @State private var showHistory = false

    private var liveContext: AIPageContext { AIPageContext.capture(from: state) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            composer
        }
        .themedSurface(state.accentTheme, .elevated)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        .onAppear { DispatchQueue.main.async { inputFocused = true } }
        .onKeyPress(.escape) {
            if voice.isRecording || voice.isStarting { voice.stop() } else if chat.isRunning { chat.stop() } else { chat.toggle() }
            return .handled
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(state.accentTheme.primaryColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Assistant")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(state.aiProvider.rawValue) · \(state.copilotModel.rawValue)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            AIUsageChip(usage: chat.usage, isCopilot: state.aiProvider == .githubCopilot)
            Menu {
                Button { chat.newChat() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .disabled(chat.items.isEmpty)
                Toggle("Run changing commands without asking", isOn: $chat.autoApprove)
                Divider()
                Button {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsAction"), object: PreferenceCategory.aiCopilot.rawValue)
                } label: { Label("AI Settings…", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .iconHover()
            .help("Chat options")

            Button { showHistory.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.icon(active: showHistory))
            .help("Previous conversations")
            .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                AIChatHistoryList(chat: chat, compact: true) { showHistory = false }
                    .frame(width: 360, height: 440)
            }

            Button { chat.newChat() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.icon)
            .disabled(chat.items.isEmpty)
            .help("New chat")

            Button { chat.toggleExpanded() } label: {
                Image(systemName: chat.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.icon)
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .help(chat.isExpanded ? "Restore size (⇧⌘I)" : "Enlarge (⇧⌘I)")

            Button { chat.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.icon)
            .help("Minimize (⌘I)")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { chat.toggleExpanded() }
    }

    /// Wide panels read better with a centred column than with full-width lines.
    private var columnWidth: CGFloat? { chat.isExpanded ? 780 : nil }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if chat.items.isEmpty {
                        emptyState
                    }
                    ForEach(chat.items) { item in
                        AIChatItemView(item: item, chat: chat, accent: state.accentTheme.primaryColor)
                            .id(item.id)
                    }
                    if chat.isRunning && chat.pendingApprovalID == nil {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button { chat.stop() } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                            .fixedSize()
                            .help("Stop the assistant and kill the command it's running (Esc)")
                        }
                        .padding(.leading, 4)
                        .id("working")
                    } else if !chat.isRunning, let choices = chat.quickReplies {
                        quickReplyRow(choices)
                            .id("choices")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
                .frame(maxWidth: columnWidth)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: chat.items.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.isRunning) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func quickReplyRow(_ choices: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                Button { chat.send(choice, state: state) } label: {
                    HStack(spacing: 5) {
                        Text(choice)
                            .lineLimit(1)
                        if index < 9 {
                            Text("⌘\(index + 1)")
                                .font(.system(size: 9.5, weight: .semibold))
                                .opacity(0.6)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(PRActionButtonStyle(index == 0 ? .primary(state.accentTheme.primaryColor) : .secondary, size: .compact))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .fixedSize()
                .pointerCursor()
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }

    private var suggestions: [String] {
        let label = liveContext.label
        if label.hasSuffix("Changes") {
            return ["Summarize my uncommitted changes", "Write a commit message for the staged changes", "Is anything risky in these changes?"]
        }
        if label.contains("PR #") {
            return ["Summarize this pull request", "Why are the checks failing?", "What's blocking the merge?"]
        }
        if label.hasSuffix("Pull requests") {
            return ["Which PRs are waiting on my review?", "List my open PRs and their status", "Which PRs have failing checks?"]
        }
        if label.hasSuffix("History") {
            return ["What changed in the last week?", "Explain the selected commit", "Who contributed most recently?"]
        }
        return ["What's the status of my repository?", "List my open pull requests", "What should I work on next?"]
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about your repository, changes or pull requests. I can run git, gh and GitHub API calls; anything that changes things waits for your OK.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(suggestions, id: \.self) { text in
                Button {
                    chat.send(text, state: state)
                } label: {
                    HStack {
                        Text(text)
                            .font(.system(size: 12.5))
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .pointerCursor()
            }
        }
        .padding(.top, 4)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "scope")
                    .font(.system(size: 9.5))
                Text(liveContext.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
            .help("Sent with your message so the assistant knows what you're looking at")

            if let problem = voice.problem {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "mic.slash")
                        .foregroundStyle(.orange)
                    Text(problem)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { voice.problem = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.hoverPlain)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(voice.isRecording ? "Listening… speak now  (↩ send)" : chat.isRunning ? "Working… you can type the next message" : "Ask anything  (↩ send, ⌥↩ new line)", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit { chat.send(state: state) }
                    .padding(.vertical, 6)

                AIVoiceButton(chat: chat)

                if chat.isRunning {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.secondary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.hoverPlain)
                    .help("Stop")
                } else {
                    let empty = chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button { chat.send(state: state) } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(empty ? Color.secondary.opacity(0.4) : state.accentTheme.primaryColor)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.hoverPlain)
                    .disabled(empty)
                    .help("Send (↩)")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 5)
            .padding(.vertical, 3)
            .background(Color(NSColor.textBackgroundColor).opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(voice.isRecording ? Color.red.opacity(0.6) : Color.primary.opacity(inputFocused ? 0.2 : 0.1)))
        }
        .padding(10)
        .frame(maxWidth: columnWidth.map { $0 + 4 })
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Items

private struct AIChatItemView: View {
    let item: AIChatItem
    @ObservedObject var chat: AIChatStore
    let accent: Color

    var body: some View {
        switch item.kind {
        case .user(let text, let context):
            VStack(alignment: .trailing, spacing: 3) {
                SelectableText(text: ChatText.plain(text, size: 13), hugsWidth: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(accent.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(context.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        case .assistant(let text):
            AIMarkdownText(text: AIQuickReplies.stripMarker(text))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(_, let summary, let status, let output):
            AIToolRunView(id: item.id, summary: summary, status: status, output: output, chat: chat, accent: accent)
        case .error(let message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                SelectableText(text: ChatText.plain(message, size: 12))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct AIToolRunView: View {
    let id: UUID
    let summary: String
    let status: AIChatItem.ToolStatus
    let output: String
    @ObservedObject var chat: AIChatStore
    let accent: Color
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if !output.isEmpty { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    statusIcon
                        .frame(width: 14)
                    Text(summary)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(expanded ? nil : 1)
                        .truncationMode(.middle)
                        .foregroundStyle(status == .denied ? .secondary : .primary)
                    Spacer(minLength: 4)
                    if status == .denied {
                        Text("Skipped").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    if !output.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 9)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)

            if status == .awaitingApproval {
                VStack(alignment: .leading, spacing: 8) {
                    if summary.count > 90 || summary.contains("\n") {
                        ScrollView {
                            SelectableText(text: ChatText.plain(summary, size: 11, monospaced: true))
                                .padding(8)
                        }
                        .frame(maxHeight: 260)
                        .background(Color.black.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text("This command can change your repository or GitHub. Run it?")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Run") { chat.resolveApproval(true) }
                            .buttonStyle(PRActionButtonStyle(.primary(accent), size: .compact))
                            .keyboardShortcut(.return, modifiers: [.command])
                        Button("Skip") { chat.resolveApproval(false) }
                            .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                        Spacer()
                        Text("⌘↩ to run")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 9)
            }

            if expanded && !output.isEmpty {
                ScrollView {
                    SelectableText(text: ChatText.plain(output, size: 11, monospaced: true))
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(Color.black.opacity(0.25))
            }
        }
        .background(Color.primary.opacity(status == .awaitingApproval ? 0.08 : 0.045))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(status == .awaitingApproval ? accent.opacity(0.6) : Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .awaitingApproval:
            Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(.orange)
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.red)
        case .denied:
            Image(systemName: "minus.circle").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Lightweight Markdown: inline styles via `AttributedString`, fenced code blocks as monospaced cards.
struct AIMarkdownText: View {
    let text: String

    private enum Segment: Hashable {
        case prose(String)
        case code(String)
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        var buffer: [String] = []
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                let chunk = buffer.joined(separator: "\n")
                if inCode { out.append(.code(chunk)) } else if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.prose(chunk)) }
                buffer = []
                inCode.toggle()
            } else {
                buffer.append(line)
            }
        }
        let rest = buffer.joined(separator: "\n")
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(inCode ? .code(rest) : .prose(rest)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let s):
                    SelectableText(text: ChatText.markdown(s, size: 13))
                case .code(let s):
                    SelectableText(text: ChatText.plain(s, size: 11.5, monospaced: true))
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }
}

/// Header chip: what this conversation has used, with the Copilot premium balance on click.
private struct AIUsageChip: View {
    let usage: AIChatUsage
    let isCopilot: Bool
    @State private var showDetails = false

    private var label: String? {
        if isCopilot, let used = usage.premiumUsed {
            return "\(Self.format(used)) premium"
        }
        guard usage.totalTokens > 0 else { return nil }
        return Self.tokens(usage.totalTokens) + " tokens"
    }

    var body: some View {
        if let label {
            Button { showDetails.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 9.5))
                    Text(label)
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Color.primary.opacity(0.07))
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.hoverPlain)
            .help("Usage in this chat")
            .popover(isPresented: $showDetails, arrowEdge: .bottom) { details }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This chat").font(.system(size: 12, weight: .semibold))
            if isCopilot {
                row("Premium requests", usage.premiumUsed.map { Self.format($0) } ?? "–")
                if usage.premiumUnlimited {
                    row("Monthly allowance", "Unlimited")
                } else if let remaining = usage.premiumNow {
                    let total = usage.premiumEntitlement.map { " of \(Self.format($0))" } ?? ""
                    row("Left this month", Self.format(remaining) + total)
                }
                if let reset = usage.resetDate { row("Resets", reset) }
            }
            row("Your messages", "\(usage.userTurns)")
            row("Model calls", "\(usage.modelCalls)")
            row("Tokens", "\(Self.tokens(usage.promptTokens)) in · \(Self.tokens(usage.completionTokens)) out")
            if isCopilot {
                Text("Copilot charges one premium request per message you send (times the model's multiplier); the assistant's tool follow-ups aren't charged. Measured from your account balance, so other Copilot use at the same time is included.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11.5))
    }

    private static func format(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }

    private static func tokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}
