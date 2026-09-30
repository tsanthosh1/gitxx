import AppKit

/// Optional GitXX icon in the macOS menu bar: recent repositories and quick actions (Settings › Appearance).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()
    static let enabledKey = "gitxx_menubar_icon"

    private var statusItem: NSStatusItem?
    private var defaultsObserver: NSObjectProtocol?

    func start() {
        sync()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarController.shared.sync() }
        }
    }

    private func sync() {
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if enabled, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let icon = (NSApp.applicationIconImage.copy() as? NSImage) ?? NSImage()
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
                button.toolTip = "GitXX"
            }
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !enabled, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Show GitXX", key: "", action: #selector(showApp)))
        menu.addItem(.separator())

        let recents = Self.recentRepos().prefix(8)
        if !recents.isEmpty {
            let header = NSMenuItem(title: "Recent Repositories", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for repo in recents {
                let entry = item(repo.name, key: "", action: #selector(openRepo(_:)))
                entry.representedObject = repo.path
                entry.toolTip = repo.path
                entry.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
                menu.addItem(entry)
            }
            menu.addItem(.separator())
        }

        menu.addItem(item("Command Palette", key: "k", action: #selector(post(_:)), note: "ToggleCommandPalette", symbol: "command"))
        menu.addItem(item("New Branch…", key: "N", action: #selector(post(_:)), note: "NewBranchAction", symbol: "arrow.triangle.branch"))
        menu.addItem(item("Fetch Origin", key: "t", action: #selector(post(_:)), note: "FetchOriginAction", symbol: "arrow.clockwise"))
        menu.addItem(item("Pull", key: "P", action: #selector(post(_:)), note: "PullOriginAction", symbol: "arrow.down"))
        menu.addItem(item("Push", key: "p", action: #selector(post(_:)), note: "PushOriginAction", symbol: "arrow.up"))
        menu.addItem(.separator())
        menu.addItem(item("AI Assistant", key: "i", action: #selector(post(_:)), note: "ToggleAIChat", symbol: "sparkles"))
        let voice = item("Talk to AI Assistant", key: "i", action: #selector(post(_:)), note: "ToggleAIVoice", symbol: "mic")
        voice.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(voice)
        menu.addItem(item("Slack Review Requests", key: "", action: #selector(showReviewRequests), symbol: "person.2.badge.gearshape"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", key: ",", action: #selector(post(_:)), note: "OpenSettingsAction", symbol: "gearshape"))
        menu.addItem(item("Hide Menu Bar Icon", key: "", action: #selector(hideIcon)))
        menu.addItem(item("Quit GitXX", key: "q", action: #selector(quit)))
    }

    private func item(_ title: String, key: String, action: Selector, note: String? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = note
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private static func recentRepos() -> [(name: String, path: String)] {
        struct Stored: Decodable { let name: String; let path: String }
        guard let data = UserDefaults.standard.data(forKey: "gitxxRecentRepos"),
              let repos = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return repos.map { ($0.name, $0.path) }
    }

    @objc private func showApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = WindowAccessor.mainWindow ?? NSApp.windows.first(where: { !$0.isSheet && $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openRepo(_ sender: NSMenuItem) {
        showApp()
        guard let path = sender.representedObject as? String else { return }
        NotificationCenter.default.post(name: NSNotification.Name("OpenRepoPathFromCLI"), object: path)
    }

    @objc private func post(_ sender: NSMenuItem) {
        showApp()
        guard let name = sender.representedObject as? String else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name(name), object: nil)
        }
    }

    @objc private func showReviewRequests() {
        IntegrationsWindowController.shared.show(.reviewRequests)
    }

    @objc private func hideIcon() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
