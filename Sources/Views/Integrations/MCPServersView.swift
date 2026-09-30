import SwiftUI

struct MCPServersView: View {
    @ObservedObject private var store = IntegrationsStore.shared
    @State private var selection: UUID?
    @State private var importMessage = ""

    static func slackPreset() -> MCPServerConfig {
        var config = MCPServerConfig(name: "Slack")
        config.kind = .http
        config.url = "https://mcp.slack.com/mcp"
        config.auth = .oauth
        config.oauthScopes = "search:read.public search:read.private search:read.im search:read.mpim channels:history groups:history users:read"
        return config
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("MCP Servers").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Menu {
                        Button("Slack") { add(Self.slackPreset()) }
                        Divider()
                        Button("Remote server (URL)…") { add(MCPServerConfig(name: "New server")) }
                        Button("Local command (stdio)…") {
                            var config = MCPServerConfig(name: "New command")
                            config.kind = .stdio
                            add(config)
                        }
                        Divider()
                        Button("Import from Cursor (~/.cursor/mcp.json)") {
                            let n = store.importFromCursor()
                            importMessage = n == 0 ? "Nothing new to import." : "Imported \(n) server\(n == 1 ? "" : "s") (disabled until you connect them)."
                        }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Add a server")
                }
                .padding(.horizontal, 14).padding(.top, 34).padding(.bottom, 10)
                if !importMessage.isEmpty {
                    Text(importMessage).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 6)
                }
                if store.servers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No servers yet. Add Slack, any remote MCP URL or a local command, or import the servers you use in Cursor.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Add Slack") { add(Self.slackPreset()) }
                    }
                    .font(.system(size: 12))
                    .padding(14)
                }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.servers) { server in
                            Button { selection = server.id } label: {
                                HStack(spacing: 8) {
                                    statusDot(store.status[server.id] ?? .idle)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(server.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                        Text(server.kind == .http ? server.url : server.command)
                                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if let n = store.tools[server.id]?.count { Text("\(n)").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 7).fill(selection == server.id ? Color.accentColor.opacity(0.18) : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .frame(width: 270)
            Divider()
            if let id = selection, let server = store.server(id) {
                MCPServerDetail(server: server, removed: { selection = nil })
                    .id(id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("Select a server, or add one with +.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = store.servers.first?.id } }
    }

    private func add(_ config: MCPServerConfig) {
        store.upsert(config)
        selection = config.id
    }
}

private struct MCPServerDetail: View {
    @ObservedObject private var store = IntegrationsStore.shared
    @State private var draft: MCPServerConfig
    @State private var headersText: String
    @State private var envText: String
    @State private var argsText: String
    @State private var toolFilter = ""
    @State private var confirmRemove = false
    let removed: () -> Void

    init(server: MCPServerConfig, removed: @escaping () -> Void) {
        _draft = State(initialValue: server)
        _headersText = State(initialValue: server.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
        _envText = State(initialValue: server.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        _argsText = State(initialValue: server.args.joined(separator: "\n"))
        self.removed = removed
    }

    private var status: IntegrationsStore.Status { store.status[draft.id] ?? .idle }
    private var saved: MCPServerConfig? { store.server(draft.id) }
    private var isDirty: Bool { saved != composed }

    private var composed: MCPServerConfig {
        var c = draft
        c.headers = Self.pairs(headersText, separator: ":")
        c.env = Self.pairs(envText, separator: "=")
        c.args = argsText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return c
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    TextField("Name", text: $draft.name).textFieldStyle(.plain).font(.system(size: 18, weight: .semibold))
                    Spacer()
                    statusDot(status)
                    Text(status.label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 320, alignment: .trailing)
                }
                .padding(.top, 34)

                actions

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Transport", selection: $draft.kind) {
                            Text("Remote (Streamable HTTP)").tag(MCPServerConfig.Kind.http)
                            Text("Local command (stdio)").tag(MCPServerConfig.Kind.stdio)
                        }
                        .pickerStyle(.segmented).frame(maxWidth: 420)
                        if draft.kind == .http {
                            field("URL") { TextField("https://example.com/mcp", text: $draft.url).textFieldStyle(.roundedBorder) }
                            field("Headers") { editor($headersText, placeholder: "Header-Name: value (one per line)") }
                        } else {
                            field("Command") { TextField("npx", text: $draft.command).textFieldStyle(.roundedBorder) }
                            field("Arguments") { editor($argsText, placeholder: "one per line") }
                            field("Environment") { editor($envText, placeholder: "KEY=value (one per line)") }
                        }
                    }
                    .padding(6)
                }

                if draft.kind == .http {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Authentication", selection: $draft.auth) {
                                Text("None").tag(MCPServerConfig.Auth.none)
                                Text("Bearer token").tag(MCPServerConfig.Auth.bearer)
                                Text("OAuth (browser sign-in)").tag(MCPServerConfig.Auth.oauth)
                            }
                            .frame(maxWidth: 360)
                            switch draft.auth {
                            case .none:
                                EmptyView()
                            case .bearer:
                                field("Token") { SecureField("Paste a token (e.g. a Slack xoxp- user token)", text: $draft.bearerToken).textFieldStyle(.roundedBorder) }
                            case .oauth:
                                field("Client ID") { TextField("Leave empty if the server registers clients automatically", text: $draft.oauthClientID).textFieldStyle(.roundedBorder) }
                                field("Client secret") { SecureField("Optional", text: $draft.oauthClientSecret).textFieldStyle(.roundedBorder) }
                                field("Scopes") { TextField("Space-separated; empty uses what the server advertises", text: $draft.oauthScopes).textFieldStyle(.roundedBorder) }
                                Text("Redirect URL for your OAuth app: \(MCPOAuth.redirectURI)")
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                                if draft.url.contains("slack.com") {
                                    Text("Slack doesn't register clients automatically. Create a Slack app (api.slack.com/apps) with MCP enabled, add the redirect URL and the user scopes above, then paste its Client ID and Secret. Or use a Bearer user token (xoxp-…) instead.")
                                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(6)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Connect automatically when Integrations opens", isOn: $draft.enabled)
                        Toggle("Let the AI assistant use this server's tools", isOn: $draft.exposeToAssistant)
                        Text("Tools the server marks read-only run straight away; anything else asks you first (unless auto-approve is on).")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                toolsList
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 20).padding(.bottom, 20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .alert("Remove \(draft.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                store.remove(draft.id)
                removed()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its settings and sign-in are deleted from this Mac.") }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(isDirty ? "Save & Connect" : (status == .connected ? "Reconnect" : "Connect")) {
                let config = composed
                if isDirty { store.upsert(config) }
                Task { await store.connect(config.id) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(status == .connecting)
            if isDirty {
                Button("Save") { store.upsert(composed) }
            }
            if composed.auth == .oauth {
                if store.signingIn == draft.id {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else {
                    Button(store.hasOAuthSession(draft.id) ? "Sign in again" : "Sign in…") {
                        let config = composed
                        if isDirty { store.upsert(config) }
                        Task { await store.signIn(config.id) }
                    }
                    if store.hasOAuthSession(draft.id) {
                        Button("Sign out") { store.signOut(draft.id) }
                    }
                }
            }
            if status == .connected {
                Button("Disconnect") { store.disconnect(draft.id) }
            }
            Spacer()
            Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }
                .help("Remove this server")
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var toolsList: some View {
        let tools = (store.tools[draft.id] ?? []).filter { toolFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(toolFilter) || $0.description.localizedCaseInsensitiveContains(toolFilter) }
        if !(store.tools[draft.id] ?? []).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tools (\(store.tools[draft.id]?.count ?? 0))").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    TextField("Filter tools", text: $toolFilter).textFieldStyle(.roundedBorder).frame(width: 180)
                }
                ForEach(tools) { tool in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(tool.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                            if tool.readOnly {
                                Text("read-only").font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
                                    .padding(.horizontal, 5).background(Capsule().fill(Color.green.opacity(0.12)))
                            }
                        }
                        if !tool.description.isEmpty {
                            Text(tool.description).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            content()
        }
    }

    private func editor(_ text: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(height: 64)
            if text.wrappedValue.isEmpty {
                Text(placeholder).font(.system(size: 12)).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private static func pairs(_ text: String, separator: Character) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let i = line.firstIndex(of: separator) else { continue }
            let key = line[..<i].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
