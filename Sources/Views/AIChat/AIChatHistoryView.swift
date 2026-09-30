import SwiftUI

/// Saved assistant conversations grouped by day; picking one continues it in the chat panel.
struct AIChatHistoryList: View {
    @ObservedObject var chat: AIChatStore
    /// Popover style: tighter rows without the last-message preview.
    var compact = false
    var onOpen: () -> Void = {}
    @State private var query = ""

    private var filtered: [AIChatThreadSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return chat.threads }
        return chat.threads.filter {
            $0.title.lowercased().contains(q) || $0.context.lowercased().contains(q) || $0.preview.lowercased().contains(q)
        }
    }

    private var sections: [(String, [AIChatThreadSummary])] {
        let calendar = Calendar.current
        let now = Date()
        func bucket(_ date: Date) -> String {
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { return "Previous 7 days" }
            if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 30 { return "Previous 30 days" }
            return "Older"
        }
        var order: [String] = []
        var groups: [String: [AIChatThreadSummary]] = [:]
        for thread in filtered {
            let key = bucket(thread.updatedAt)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(thread)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search conversations", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.hoverPlain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08)))
            .padding(compact ? 8 : 0)
            .padding(.bottom, compact ? 0 : 10)

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text(chat.threads.isEmpty ? "No conversations yet" : "No conversations match “\(query)”")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections, id: \.0) { title, threads in
                            Section {
                                ForEach(threads) { thread in
                                    AIChatHistoryRow(chat: chat, thread: thread, compact: compact) {
                                        chat.openThread(thread.id)
                                        onOpen()
                                    }
                                }
                            } header: {
                                Text(title)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 8)
                                    .padding(.bottom, 3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(compact ? Color.clear : Color(NSColor.windowBackgroundColor))
                            }
                        }
                    }
                    .padding(compact ? 6 : 0)
                }
            }
        }
    }
}

private struct AIChatHistoryRow: View {
    @ObservedObject var chat: AIChatStore
    let thread: AIChatThreadSummary
    let compact: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let isCurrent = thread.id == chat.currentThreadId
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isCurrent ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title.isEmpty ? "Untitled" : thread.title)
                    .font(.system(size: compact ? 12.5 : 13, weight: .medium))
                    .lineLimit(compact ? 1 : 2)
                Text("\(thread.context) · \(thread.messageCount) message\(thread.messageCount == 1 ? "" : "s") · \(thread.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !compact, !thread.preview.isEmpty {
                    Text(thread.preview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if hovering {
                Button { chat.deleteThread(thread.id) } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverPlain)
                .help("Delete conversation")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 6 : 9)
        .background(isCurrent ? Color.primary.opacity(0.1) : (hovering ? Color.primary.opacity(0.05) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Continue conversation", action: open)
            Button("Delete conversation", role: .destructive) { chat.deleteThread(thread.id) }
        }
        .help(thread.title)
    }
}

/// Home tab listing every saved assistant conversation.
struct HomeConversationsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat = AIChatStore.shared
    @State private var confirmDeleteAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI conversations").font(.system(size: 16, weight: .semibold))
                    Text("\(chat.threads.count) saved · click one to continue it in the assistant (⌘I)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    chat.newChat()
                    if !chat.isOpen { chat.toggle() }
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                Menu {
                    Button("Delete all conversations…", role: .destructive) { confirmDeleteAll = true }
                        .disabled(chat.threads.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .iconHover(size: 24)
            }
            AIChatHistoryList(chat: chat)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog("Delete all \(chat.threads.count) conversations?", isPresented: $confirmDeleteAll) {
            Button("Delete all", role: .destructive) { chat.deleteAllThreads() }
        } message: {
            Text("This can't be undone.")
        }
    }
}
