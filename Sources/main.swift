import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        KeyboardLayoutAdapter.shared.install()
        MenuBarController.shared.start()
        KeyboardNavigation.installCommandReturn()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.tabbingMode = .disallowed
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = false
            }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(handleSnapshot), name: NSNotification.Name("SnapshotWindow"), object: nil)

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let win = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }) {
                    win.setContentSize(NSSize(width: 1200, height: 780))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-reduced"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let win = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }) {
                    win.setContentSize(NSSize(width: 900, height: 720))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-wide"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let win = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }) {
                    win.setContentSize(NSSize(width: 1280, height: 800))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-branch"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("OpenBranchModal"), object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-palette"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("ToggleCommandPalette"), object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-git-cmd"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("ToggleCommandPalette"), object: "git status -s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-terminal"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("SwitchTabTerminal"), object: nil)
                // Execute a command so terminal has realistic output
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(name: NSNotification.Name("RunDemoTerminalCommand"), object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.captureWindow(to: targetPath)
                    }
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-terminal-empty"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("SwitchTabTerminal"), object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.captureWindow(to: targetPath)
                }
            }
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-preferences"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsAction"), object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.captureWindow(to: targetPath)
                }
            }
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-preferences-users"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsAction"), object: "Git Users & Profiles")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.captureWindow(to: targetPath)
                }
            }
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-preferences-ai"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsAction"), object: "AI & Copilot")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-preferences-github"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsAction"), object: "GitHub Accounts & API")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-preferences-ai-bottom"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsAction"), object: "AI & Copilot")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NotificationCenter.default.post(name: NSNotification.Name("ScrollAIToBottom"), object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.captureWindow(to: targetPath)
                    }
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--open"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: NSNotification.Name("OpenRepoPathFromCLI"), object: targetPath)
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-toast"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("ShowDemoToast"), object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-confirm"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let win = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }) {
                    win.setContentSize(NSSize(width: 1200, height: 780))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NotificationCenter.default.post(name: NSNotification.Name("ShowDemoFirstTimeConfirm"), object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.captureWindow(to: targetPath)
                    }
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-help"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("ShowHelpModalAction"), object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-cli-success"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("ShowCLIModalAction"), object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-preferences-shortcuts"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsAction"), object: "Shortcuts & Keybindings")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-preferences-cli"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsAction"), object: "Command Line Tool (CLI)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-page-history"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Visit history, then PRs, then changes to populate history
                NotificationCenter.default.post(name: NSNotification.Name("SwitchTabHistory"), object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: NSNotification.Name("SwitchTabPRs"), object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(name: NSNotification.Name("SwitchTabChanges"), object: nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NotificationCenter.default.post(name: NSNotification.Name("TogglePageHistoryAction"), object: nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                self.captureWindow(to: targetPath)
                            }
                        }
                    }
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-pr"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NotificationCenter.default.post(name: NSNotification.Name("SwitchTabPRs"), object: nil)
                NotificationCenter.default.post(name: NSNotification.Name("SwitchPRSubTab"), object: "overview")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-pr-select"), idx + 2 < CommandLine.arguments.count {
            let prNum = Int(CommandLine.arguments[idx + 1]) ?? 50
            let targetPath = CommandLine.arguments[idx + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                NotificationCenter.default.post(name: NSNotification.Name("SwitchTabPRs"), object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    NotificationCenter.default.post(name: NSNotification.Name("SelectPRNumber"), object: prNum)
                    NotificationCenter.default.post(name: NSNotification.Name("SwitchPRSubTab"), object: "overview")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.captureWindow(to: targetPath)
                    }
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-scene"), idx + 2 < CommandLine.arguments.count {
            let scene = CommandLine.arguments[idx + 1], targetPath = CommandLine.arguments[idx + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if let win = WindowAccessor.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }) {
                    win.setContentSize(NSSize(width: 1400, height: 860))
                }
                NotificationCenter.default.post(name: NSNotification.Name("DevScene"), object: scene)
                let delay = CommandLine.arguments.firstIndex(of: "--snapshot-delay")
                    .flatMap { $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 3.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-pr-diff"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NotificationCenter.default.post(name: NSNotification.Name("SwitchTabPRs"), object: nil)
                NotificationCenter.default.post(name: NSNotification.Name("SwitchPRSubTab"), object: "filesChanged")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.captureWindow(to: targetPath)
                }
            }
        }

        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-pr-checks"), idx + 1 < CommandLine.arguments.count {
            let targetPath = CommandLine.arguments[idx + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NotificationCenter.default.post(name: NSNotification.Name("SwitchTabPRs"), object: nil)
                NotificationCenter.default.post(name: NSNotification.Name("SwitchPRSubTab"), object: "checks")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.captureWindow(to: targetPath)
                }
            }
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            NotificationCenter.default.post(name: NSNotification.Name("OpenRepoPathFromCLI"), object: filename)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        NotificationCenter.default.post(name: NSNotification.Name("OpenRepoPathFromCLI"), object: filename)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "gitxx", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                if let path = components.queryItems?.first(where: { $0.name == "path" })?.value {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenRepoPathFromCLI"), object: path)
                }
            } else if url.isFileURL {
                NotificationCenter.default.post(name: NSNotification.Name("OpenRepoPathFromCLI"), object: url.path)
            }
        }
    }

    @objc func handleSnapshot(_ notification: Notification) {
        let path = (notification.object as? String) ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("gitxx_window.png")
        captureWindow(to: path)
    }

    func captureWindow(to path: String) {
        for w in NSApp.windows {
            w.orderFrontRegardless()
        }
        print("DEBUG: captureWindow windows = \(NSApp.windows.count): \(NSApp.windows.map { "\($0.title) (vis: \($0.isVisible), cv: \($0.contentView != nil))" })")

        // If a sheet window is open (e.g. Preferences), capture that sheet or key window
        let targetWindow = NSApp.windows.first(where: { $0.isSheet && $0.isVisible && $0.contentView != nil })
            ?? WindowAccessor.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
            ?? NSApp.windows.first(where: { $0.contentView != nil })
            ?? NSApp.windows.first

        guard let window = targetWindow,
              let view = window.contentView?.superview ?? window.contentView else {
            print("ERROR: No visible window found to snapshot, retrying in 1.0s...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.captureWindow(to: path)
            }
            return
        }
        window.makeKeyAndOrderFront(nil)

        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            print("ERROR: Failed to allocate bitmap image rep")
            return
        }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            do {
                try data.write(to: URL(fileURLWithPath: path))
                print("SNAPSHOT_SAVED: \(path)")
                if CommandLine.arguments.contains(where: { $0.hasPrefix("--snapshot") }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        exit(0)
                    }
                }
            } catch {
                print("ERROR: Failed to write PNG: \(error)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

struct GitXXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("GitXX", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsAction"), object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // Native macOS Menu Bar Shortcuts
            CommandGroup(replacing: .newItem) {
                Button("Open Repository...") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenRepoModal"), object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open With…") {
                    NotificationCenter.default.post(name: NSNotification.Name("ShowOpenWith"), object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .option])

                Button("Switch Branch…") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenBranchModal"), object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
            }

            CommandMenu("Navigation") {
                Button("Home") {
                    NotificationCenter.default.post(name: NSNotification.Name("GoHomeAction"), object: nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Button("Back") {
                    NotificationCenter.default.post(name: NSNotification.Name("NavigateBackAction"), object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Forward") {
                    NotificationCenter.default.post(name: NSNotification.Name("NavigateForwardAction"), object: nil)
                }
                .keyboardShortcut("]", modifiers: .command)

                Button("Page History...") {
                    NotificationCenter.default.post(name: NSNotification.Name("TogglePageHistoryAction"), object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)

                Divider()

                Button("Changes") {
                    NotificationCenter.default.post(name: NSNotification.Name("SwitchTabChanges"), object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("History") {
                    NotificationCenter.default.post(name: NSNotification.Name("SwitchTabHistory"), object: nil)
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Pull Requests") {
                    NotificationCenter.default.post(name: NSNotification.Name("SwitchTabPRs"), object: nil)
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Actions") {
                    NotificationCenter.default.post(name: NSNotification.Name("SwitchTabActions"), object: nil)
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Terminal") {
                    NotificationCenter.default.post(name: NSNotification.Name("SwitchTabTerminal"), object: nil)
                }
                .keyboardShortcut("5", modifiers: .command)

                Divider()

                Button("Command Palette...") {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleCommandPalette"), object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("AI Assistant") {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleAIChat"), object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Talk to AI Assistant") {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleAIVoice"), object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }

            CommandMenu("Repository") {
                Button("New Branch…") {
                    NotificationCenter.default.post(name: NSNotification.Name("NewBranchAction"), object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button("Fetch Origin") {
                    NotificationCenter.default.post(name: NSNotification.Name("FetchOriginAction"), object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Pull from Origin") {
                    NotificationCenter.default.post(name: NSNotification.Name("PullOriginAction"), object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Push to Origin") {
                    NotificationCenter.default.post(name: NSNotification.Name("PushOriginAction"), object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)

                Divider()

                Button("Refresh Status") {
                    NotificationCenter.default.post(name: NSNotification.Name("RefreshAction"), object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

// Tooltips (`.help`) appear after ~0.25s instead of AppKit's ~1s default, so icon-only buttons are easy to identify.
UserDefaults.standard.set(250, forKey: "NSInitialToolTipDelay")
KeyboardNavigation.applyPreference()
DevFixtures.runIfRequested()
GitXXApp.main()
