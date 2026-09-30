import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// An application that can open the chosen item.
private struct OpenWithApp: Identifiable, Hashable {
    let url: URL
    var name: String
    var isDefault = false
    var id: String { url.path }

    init?(url: URL, isDefault: Bool = false) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        self.url = url
        self.isDefault = isDefault
        name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private enum OpenWithCatalog {
    static let editors = [
        "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "dev.zed.Zed", "com.exafunction.windsurf", "com.apple.dt.Xcode", "com.sublimetext.4", "com.sublimetext.3",
        "com.panic.Nova", "com.barebones.bbedit", "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
        "com.jetbrains.WebStorm", "com.jetbrains.pycharm", "com.jetbrains.goland", "com.jetbrains.fleet",
        "com.google.android.studio", "com.apple.TextEdit",
    ]
    static let terminals = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty"]

    static let recentKey = "gitxx_open_with_recent_apps"

    static func installed(_ bundleIds: [String]) -> [OpenWithApp] {
        var seen = Set<String>()
        return bundleIds.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), seen.insert(url.path).inserted else { return nil }
            return OpenWithApp(url: url)
        }
    }

    static var recent: [OpenWithApp] {
        (UserDefaults.standard.stringArray(forKey: recentKey) ?? []).compactMap { OpenWithApp(url: URL(fileURLWithPath: $0)) }
    }

    static func remember(_ app: URL) {
        var list = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        list.removeAll { $0 == app.path }
        list.insert(app.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(6)), forKey: recentKey)
    }
}

struct OpenWithPopover: View {
    @ObservedObject var state: AppState
    let targets: [OpenWithTarget]
    @State private var selectedId: String?
    @State private var query = ""
    @State private var sections: [(title: String, apps: [OpenWithApp])] = []

    private var target: OpenWithTarget? { targets.first { $0.id == selectedId } ?? targets.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let target {
                if targets.count > 1 {
                    Picker("", selection: Binding(get: { target.id }, set: { selectedId = $0 })) {
                        ForEach(targets) { Text($0.kind.rawValue).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                dragTile(target)
                searchField
                appList(target)
                Divider()
                footer(target)
            } else {
                Text("Open a repository to open its files or folder in another app.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .padding(12)
        .frame(width: 350)
        .onAppear { reload() }
        .onChange(of: selectedId) { _, _ in reload() }
    }

    // MARK: Pieces

    private func dragTile(_ target: OpenWithTarget) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: icon(for: target))
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(target.subtitle)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            VStack(spacing: 2) {
                Image(systemName: "hand.draw").font(.system(size: 13))
                Text("Drag").font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color.primary.opacity(0.18)))
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: target.url as NSURL) } preview: {
            HStack(spacing: 6) {
                Image(nsImage: icon(for: target)).resizable().frame(width: 28, height: 28)
                Text(target.title).font(.system(size: 12, weight: .medium))
            }
            .padding(6)
        }
        .help("Drag onto any app, Dock icon or window to open it there")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Filter applications", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.hoverPlain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func appList(_ target: OpenWithTarget) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = sections.map { ($0.title, q.isEmpty ? $0.apps : $0.apps.filter { $0.name.lowercased().contains(q) }) }
            .filter { !$0.1.isEmpty }
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if visible.isEmpty {
                    Text(q.isEmpty ? "No applications found." : "No applications match “\(query)”.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(8)
                }
                ForEach(visible, id: \.0) { title, apps in
                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    ForEach(apps) { app in
                        OpenWithAppRow(app: app) { open(target, with: app.url) }
                    }
                }
            }
        }
        .frame(height: 300)
    }

    private func footer(_ target: OpenWithTarget) -> some View {
        HStack(spacing: 6) {
            Button { chooseApplication(for: target) } label: {
                Label("Choose application…", systemImage: "app.badge.checkmark")
            }
            .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
            Spacer()
            if target.kind != .web {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([target.url])
                    state.showOpenWith = false
                } label: { Image(systemName: "folder") }
                    .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                    .help("Reveal in Finder")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(target.kind == .web ? target.url.absoluteString : target.url.path, forType: .string)
                state.showToast(target.kind == .web ? "Copied link" : "Copied path", type: .success)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                .help(target.kind == .web ? "Copy link" : "Copy path")
        }
    }

    // MARK: Behaviour

    private func icon(for target: OpenWithTarget) -> NSImage {
        if target.kind == .web {
            if let browser = NSWorkspace.shared.urlForApplication(toOpen: target.url) { return NSWorkspace.shared.icon(forFile: browser.path) }
            return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: target.url.path)
    }

    private func reload() {
        guard let target else { sections = []; return }
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: target.url)
        let handlers = workspace.urlsForApplications(toOpen: target.url)
        var used = Set<String>()
        func take(_ apps: [OpenWithApp]) -> [OpenWithApp] {
            apps.filter { used.insert($0.url.standardizedFileURL.path).inserted }.map { app in
                var copy = app
                copy.isDefault = app.url.standardizedFileURL == defaultApp?.standardizedFileURL
                return copy
            }
        }
        var result: [(String, [OpenWithApp])] = []
        let recent = OpenWithCatalog.recent.filter { app in
            target.kind != .web || handlers.contains { $0.standardizedFileURL == app.url.standardizedFileURL }
        }
        if let defaultApp, let app = OpenWithApp(url: defaultApp) { result.append(("Default", take([app]))) }
        result.append(("Recent", take(recent)))
        switch target.kind {
        case .web:
            result.append(("Browsers", take(handlers.compactMap { OpenWithApp(url: $0) }.sorted { $0.name < $1.name })))
        case .file, .folder:
            result.append(("Code editors", take(OpenWithCatalog.installed(OpenWithCatalog.editors))))
            if target.kind == .folder { result.append(("Terminals", take(OpenWithCatalog.installed(OpenWithCatalog.terminals)))) }
            let others = handlers.compactMap { OpenWithApp(url: $0) }
                .filter { !$0.url.path.contains("/Library/CoreServices/") || $0.name == "Finder" }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            result.append(("Other applications", take(others)))
        }
        let names = Dictionary(grouping: result.flatMap(\.1), by: \.name).mapValues(\.count)
        sections = result.filter { !$0.1.isEmpty }.map { title, apps in
            (title: title, apps: apps.map { app in
                guard names[app.name, default: 0] > 1 else { return app }
                var copy = app
                copy.name += " — " + (app.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                return copy
            })
        }
    }

    private func open(_ target: OpenWithTarget, with app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let appName = app.deletingPathExtension().lastPathComponent
        let report: @Sendable (String) -> Void = { [weak state] message in
            DispatchQueue.main.async { MainActor.assumeIsolated { state?.showToast(message, type: .error) } }
        }
        // LaunchServices calls back on its own queue, so the handler must not be main-actor isolated.
        NSWorkspace.shared.open([target.url], withApplicationAt: app, configuration: configuration) { @Sendable _, error in
            if let error { report("Couldn't open with \(appName): \(error.localizedDescription)") }
        }
        OpenWithCatalog.remember(app)
        state.showOpenWith = false
    }

    private func chooseApplication(for target: OpenWithTarget) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose an application to open \(target.title)"
        state.showOpenWith = false
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(target, with: app)
    }
}

private struct OpenWithAppRow: View {
    let app: OpenWithApp
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(app.name).font(.system(size: 12.5)).lineLimit(1)
                if app.isDefault {
                    Text("Default")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(hovering ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .onHover { hovering = $0 }
        .help(app.url.path)
    }
}
