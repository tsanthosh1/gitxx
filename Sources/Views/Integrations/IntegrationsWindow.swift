import SwiftUI
import AppKit

/// The Integrations window: kept apart from the repository window on purpose.
@MainActor
final class IntegrationsWindowController {
    static let shared = IntegrationsWindowController()
    private var window: NSWindow?

    enum Page: String, CaseIterable, Identifiable {
        case reviewRequests, servers
        var id: String { rawValue }
        var title: String { self == .reviewRequests ? "Slack Review Requests" : "MCP Servers" }
        var icon: String { self == .reviewRequests ? "person.2.badge.gearshape" : "point.3.connected.trianglepath.dotted" }
    }

    func show(_ page: Page? = nil) {
        if let page { UserDefaults.standard.set(page.rawValue, forKey: IntegrationsView.pageKey) }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Integrations"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.minSize = NSSize(width: 820, height: 480)
            window.contentView = NSHostingView(rootView: IntegrationsView())
            window.center()
            window.setFrameAutosaveName("GitXXIntegrations")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        IntegrationsStore.shared.connectEnabled()
    }

    /// Brings the repository window forward (for "Open in GitXX" and assistant hand-offs).
    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let main = WindowAccessor.mainWindow ?? NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
        if main?.isMiniaturized == true { main?.deminiaturize(nil) }
        main?.makeKeyAndOrderFront(nil)
    }
}

struct IntegrationsView: View {
    static let pageKey = "gitxx_integrations_page"
    @AppStorage(IntegrationsView.pageKey) private var pageRaw = IntegrationsWindowController.Page.reviewRequests.rawValue
    @ObservedObject private var store = IntegrationsStore.shared
    @ObservedObject private var reviews = ReviewRequestsStore.shared

    private var page: IntegrationsWindowController.Page { .init(rawValue: pageRaw) ?? .reviewRequests }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch page {
                case .reviewRequests: ReviewRequestsView(openServers: { pageRaw = IntegrationsWindowController.Page.servers.rawValue })
                case .servers: MCPServersView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SurfaceStyle.windowBase)
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.openURL, OpenURLAction { url in
            LinkRouter.open(url)
            return .handled
        })
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("INTEGRATIONS")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 40).padding(.bottom, 6)
            ForEach(IntegrationsWindowController.Page.allCases) { item in
                Button { pageRaw = item.rawValue } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon).frame(width: 18)
                        Text(item.title).lineLimit(1)
                        Spacer(minLength: 0)
                        if item == .reviewRequests, reviews.counts(.pending) > 0 {
                            countBadge(reviews.counts(.pending), .orange)
                        } else if item == .servers {
                            countBadge(store.servers.filter { store.status[$0.id] == .connected }.count, .green)
                        }
                    }
                    .font(.system(size: 12.5, weight: page == item ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7).fill(page == item ? Color.accentColor.opacity(0.18) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Connect MCP servers to bring outside tools into GitXX and the assistant.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(10)
        }
        .padding(.horizontal, 8)
        .frame(width: 220)
        .background(Color.white.opacity(0.02))
    }

    private func countBadge(_ n: Int, _ color: Color) -> some View {
        Group {
            if n > 0 {
                Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(color.opacity(0.16)))
            }
        }
    }
}

// MARK: - Review requests

private enum ReviewFilter: String, CaseIterable, Identifiable {
    case open, pending, notApproved, approved, done, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: return "Open"
        case .pending: return "Needs your review"
        case .notApproved: return "Not approved"
        case .approved: return "Approved"
        case .done: return "Merged / closed"
        case .all: return "All"
        }
    }

    func matches(_ status: ReviewRequestStatus) -> Bool {
        switch self {
        case .open: return [.pending, .notApproved, .approved, .unknown].contains(status)
        case .pending: return status == .pending
        case .notApproved: return status == .notApproved
        case .approved: return status == .approved
        case .done: return status == .merged || status == .closed
        case .all: return true
        }
    }
}

struct ReviewRequestsView: View {
    let openServers: () -> Void
    @ObservedObject private var reviews = ReviewRequestsStore.shared
    @ObservedObject private var store = IntegrationsStore.shared
    @State private var filter = ReviewFilter.open
    @State private var search = ""
    @State private var showSettings = false
    @State private var question = ""

    private var visible: [ReviewRequestItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return reviews.items.filter { item in
            (reviews.settings.includeMine || item.status != .mine || filter == .all)
                && filter.matches(item.status)
                && (q.isEmpty || [item.title, item.author, item.requestedBy, "\(item.owner)/\(item.repo)#\(item.number)", item.snippet]
                    .compactMap { $0?.lowercased() }.contains { $0.contains(q) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if reviews.server == nil || showSettings {
                ScrollView { ReviewRequestsSettingsForm(openServers: openServers, done: { showSettings = false }).padding(20) }
            } else {
                filters
                if let error = reviews.errorMessage {
                    banner(error, color: .orange, icon: "exclamationmark.triangle.fill")
                }
                if reviews.items.isEmpty {
                    emptyState
                } else {
                    list
                }
                askBar
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Slack Review Requests").font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if reviews.isRefreshing {
                ProgressView().controlSize(.small)
                Text(reviews.progress).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 280, alignment: .trailing)
            }
            Button { Task { await reviews.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(reviews.isRefreshing || reviews.server == nil)
                .keyboardShortcut("r", modifiers: .command)
            Button { showSettings.toggle() } label: { Image(systemName: showSettings ? "xmark" : "slider.horizontal.3") }
                .help(showSettings ? "Close settings" : "Channels, identity and search settings")
        }
        .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 12)
    }

    private var subtitle: String {
        let channels = reviews.settings.channels.map { "#" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }.joined(separator: ", ")
        var parts = [channels.isEmpty ? "No channels yet" : channels]
        if let login = reviews.viewerLogin { parts.append("GitHub: @\(login)") }
        if let date = reviews.lastRefresh { parts.append("updated \(date.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }

    private var filters: some View {
        HStack(spacing: 6) {
            ForEach(ReviewFilter.allCases) { f in
                let count = reviews.items.filter { f.matches($0.status) && (reviews.settings.includeMine || $0.status != .mine || f == .all) }.count
                Button { filter = f } label: {
                    HStack(spacing: 5) {
                        Text(f.title)
                        Text("\(count)").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11.5, weight: filter == f ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(filter == f ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter", text: $search).textFieldStyle(.plain).frame(width: 150)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(visible) { item in ReviewRequestRow(item: item) }
                if visible.isEmpty {
                    Text("Nothing in “\(filter.title)”.").foregroundStyle(.secondary).padding(40)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.secondary)
            if let server = reviews.server, store.status[server.id] == .needsSignIn {
                Text("Sign in to \(server.name) to search Slack.").font(.system(size: 14, weight: .medium))
                Button("Open MCP Servers", action: openServers)
            } else if reviews.lastRefresh == nil {
                Text("Search Slack for PRs people asked you to review.").font(.system(size: 14, weight: .medium))
                Button("Refresh now") { Task { await reviews.refresh() } }.buttonStyle(.borderedProminent)
            } else {
                Text("No review requests found.").font(.system(size: 14, weight: .medium))
                Text("Check the channels, look-back window and your identifiers in settings. The raw Slack output is at the bottom of settings.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var askBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            TextField("Ask the assistant about these review requests…", text: $question)
                .textFieldStyle(.plain)
                .onSubmit(ask)
            Button("Ask", action: ask).disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            Menu {
                Button("Which should I review first?") { question = "Which of these should I review first, and why?"; ask() }
                Button("Summarise what's waiting on me") { question = "Summarise what is waiting on me, grouped by repository."; ask() }
                Button("Draft a Slack status update") { question = "Draft a short Slack message telling the channel which of these I've reviewed and which I'll pick up next."; ask() }
            } label: { Image(systemName: "wand.and.stars") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 20).padding(.bottom, 14).padding(.top, 4)
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let lines = reviews.items.prefix(60).map { i in
            "- \(i.owner)/\(i.repo)#\(i.number) “\(i.title ?? "?")” by @\(i.author ?? "?") — \(i.status.label)"
                + (i.changedSinceMyReview ? " (new commits since my review)" : "")
                + (i.requestedBy.map { "; asked by \($0)" } ?? "")
                + (i.postedAt.map { " on \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
        }
        let prompt = "My PR review requests from Slack:\n" + lines.joined(separator: "\n") + "\n\n" + q
        question = ""
        IntegrationsWindowController.showMainWindow()
        NotificationCenter.default.post(name: NSNotification.Name("AIChatSendPrompt"), object: prompt)
    }

    private func banner(_ text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 12)).textSelection(.enabled)
            Spacer()
            Button { reviews.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
        .padding(.horizontal, 20).padding(.bottom, 8)
    }
}

private struct ReviewRequestRow: View {
    let item: ReviewRequestItem
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.status.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item.status.color)
                .frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.title ?? "\(item.repo) #\(item.number)")
                        .font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if item.isDraft { tag("Draft", .secondary) }
                    tag(item.status.label, item.status.color)
                    if item.changedSinceMyReview && item.status != .merged && item.status != .closed {
                        tag("New commits since your review", .yellow)
                    }
                }
                HStack(spacing: 10) {
                    Text("\(item.owner)/\(item.repo) #\(item.number)").font(.system(size: 11.5, design: .monospaced))
                    if let author = item.author { Label("@\(author)", systemImage: "person").labelStyle(.titleAndIcon) }
                    if let added = item.additions, let removed = item.deletions {
                        HStack(spacing: 3) {
                            Text("+\(added)").foregroundStyle(.green)
                            Text("−\(removed)").foregroundStyle(.red)
                        }
                    }
                    if let requester = item.requestedBy {
                        Label("asked by \(requester)", systemImage: "bubble.left").lineLimit(1)
                    }
                    if let date = item.postedAt {
                        Text(date.formatted(.relative(presentation: .named)))
                    }
                    if let channel = item.channel, !channel.isEmpty {
                        Text(channel.hasPrefix("#") ? channel : "#" + channel).lineLimit(1)
                    }
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                if !item.snippet.isEmpty {
                    Text(item.snippet).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button {
                    IntegrationsWindowController.showMainWindow()
                    if let url = URL(string: item.url) {
                        NotificationCenter.default.post(name: NSNotification.Name("OpenGitHubLinkInApp"), object: url)
                    }
                } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                    .help("Open in GitXX when the repository is on this Mac, otherwise on GitHub")
                Button { if let url = URL(string: item.url) { LinkRouter.open(url) } } label: { Image(systemName: "safari") }
                    .help("Open on GitHub")
                if let link = item.permalink, let url = URL(string: link) {
                    Button { LinkRouter.open(url) } label: { Image(systemName: "bubble.left.and.bubble.right") }
                        .help("Open the Slack message")
                }
            }
            .controlSize(.small)
            .opacity(hovering ? 1 : 0.75)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(item.status == .pending ? Color.orange.opacity(0.35) : Color.primary.opacity(0.06)))
        .onHover { hovering = $0 }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }
}

private struct ReviewRequestsSettingsForm: View {
    let openServers: () -> Void
    let done: () -> Void
    @ObservedObject private var reviews = ReviewRequestsStore.shared
    @ObservedObject private var store = IntegrationsStore.shared
    @State private var channelsText = ""
    @State private var identifiersText = ""
    @State private var detectMessage = ""
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Find PRs people post in Slack channels for you to review. GitXX searches Slack through an MCP server, keeps the messages that mention you, and checks each PR's state on GitHub.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)

            section("Slack server") {
                if store.servers.isEmpty {
                    HStack {
                        Text("No MCP servers yet.").foregroundStyle(.secondary)
                        Button("Add Slack…") {
                            let config = MCPServersView.slackPreset()
                            store.upsert(config)
                            reviews.settings.serverID = config.id
                            openServers()
                        }
                    }
                } else {
                    Picker("Server", selection: $reviews.settings.serverID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(store.servers) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .frame(maxWidth: 360)
                    if let server = reviews.server {
                        HStack(spacing: 8) {
                            statusDot(store.status[server.id] ?? .idle)
                            Text(store.status[server.id]?.label ?? "Not connected").font(.system(size: 12)).foregroundStyle(.secondary)
                            if store.status[server.id] != .connected {
                                Button("Connect") { Task { await store.connect(server.id) } }
                            }
                            Button("Server settings…", action: openServers)
                        }
                        let tools = store.tools[server.id] ?? []
                        Picker("Search tool", selection: $reviews.settings.searchTool) {
                            Text("Automatic (\(reviews.resolveSearchTool()?.name ?? "none found"))").tag("")
                            ForEach(tools) { Text($0.name).tag($0.name) }
                        }
                        .frame(maxWidth: 460)
                        .disabled(tools.isEmpty)
                    }
                }
            }

            section("Channels") {
                TextField("e.g. pr-reviews, team-backend", text: $channelsText)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 460)
                    .onSubmit(commit)
                Stepper("Look back \(reviews.settings.lookbackDays) days", value: $reviews.settings.lookbackDays, in: 1...90)
                    .frame(maxWidth: 260, alignment: .leading)
            }

            section("You") {
                TextField("Slack user ID (U0123ABCD), @handle, first name…", text: $identifiersText)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 460)
                    .onSubmit(commit)
                HStack {
                    Button("Detect from Slack") {
                        commit()
                        Task {
                            detectMessage = await reviews.detectIdentity()
                            identifiersText = reviews.settings.identifiers.joined(separator: ", ")
                        }
                    }
                    .disabled(reviews.server.map { store.status[$0.id] != .connected } ?? true)
                    if !detectMessage.isEmpty { Text(detectMessage).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                }
                Toggle("Only messages that mention me (turn off to list every PR posted in the channels)", isOn: $reviews.settings.onlyMentions)
                Toggle("Include my own PRs", isOn: $reviews.settings.includeMine)
            }

            section("Slack search query") {
                TextField(ReviewRequestsSettings.defaultTemplate, text: $reviews.settings.queryTemplate)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(maxWidth: 460)
                Text("Placeholders: {channel}, {after} (start date), {me} (first identifier). Example: `in:#{channel} {me} after:{after}`. Preview: \(reviews.buildQuery(channel: reviews.settings.channels.first ?? "channel"))")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
            }

            HStack {
                Button("Save & refresh") {
                    commit()
                    done()
                    Task { await reviews.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(reviews.server == nil)
                Button("Done") { commit(); done() }.disabled(reviews.server == nil)
            }

            if !reviews.rawOutput.isEmpty {
                DisclosureGroup("Raw Slack search output (for troubleshooting)", isExpanded: $showRaw) {
                    ScrollView {
                        Text(reviews.rawOutput).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 260)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.2)))
                }
                .font(.system(size: 12))
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .onAppear {
            channelsText = reviews.settings.channels.joined(separator: ", ")
            identifiersText = reviews.settings.identifiers.joined(separator: ", ")
            if reviews.settings.serverID == nil, let slack = store.servers.first(where: { $0.url.contains("slack") || $0.name.lowercased().contains("slack") }) {
                reviews.settings.serverID = slack.id
            }
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        func split(_ s: String) -> [String] {
            s.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        reviews.settings.channels = split(channelsText).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
        reviews.settings.identifiers = split(identifiersText)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .font(.system(size: 12.5))
    }
}

func statusDot(_ status: IntegrationsStore.Status) -> some View {
    let color: Color
    switch status {
    case .connected: color = .green
    case .connecting: color = .yellow
    case .needsSignIn: color = .orange
    case .failed: color = .red
    case .idle: color = .secondary
    }
    return Circle().fill(color).frame(width: 8, height: 8)
}
