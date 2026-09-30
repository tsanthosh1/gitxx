import SwiftUI
import Foundation

public struct AppShortcutItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var category: String
    public var defaultKey: String
    public var defaultModifiers: [String] // "command", "shift", "option", "control"
    public var currentKey: String
    public var currentModifiers: [String]

    public init(
        id: String,
        title: String,
        category: String,
        defaultKey: String,
        defaultModifiers: [String]
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.defaultKey = defaultKey
        self.defaultModifiers = defaultModifiers
        self.currentKey = defaultKey
        self.currentModifiers = defaultModifiers
    }

    public var displayString: String {
        var str = ""
        if currentModifiers.contains("control") { str += "⌃" }
        if currentModifiers.contains("option") { str += "⌥" }
        if currentModifiers.contains("shift") { str += "⇧" }
        if currentModifiers.contains("command") { str += "⌘" }
        if currentKey == "return" || currentKey == "Enter" {
            str += "↩"
        } else if currentKey == "escape" {
            str += "⎋"
        } else {
            str += currentKey.uppercased()
        }
        return str
    }

    public var isModified: Bool {
        currentKey != defaultKey || currentModifiers != defaultModifiers
    }

    public mutating func resetToDefault() {
        currentKey = defaultKey
        currentModifiers = defaultModifiers
    }

    public static let defaultShortcuts: [AppShortcutItem] = [
        AppShortcutItem(id: "commandPalette", title: "Open Command Palette", category: "General", defaultKey: "K", defaultModifiers: ["command"]),
        AppShortcutItem(id: "preferences", title: "Open Preferences / Settings", category: "General", defaultKey: ",", defaultModifiers: ["command"]),
        AppShortcutItem(id: "help", title: "Open Help & Documentation", category: "General", defaultKey: "/", defaultModifiers: ["command"]),
        AppShortcutItem(id: "aiAssistant", title: "Open / Minimize AI Assistant", category: "General", defaultKey: "I", defaultModifiers: ["command"]),
        AppShortcutItem(id: "newBranch", title: "New Branch (pick name and base)", category: "General", defaultKey: "N", defaultModifiers: ["command", "shift"]),
        AppShortcutItem(id: "aiVoice", title: "Talk to AI Assistant (start dictation)", category: "General", defaultKey: "I", defaultModifiers: ["command", "option"]),
        AppShortcutItem(id: "changesTab", title: "Switch to Changes Tab", category: "Navigation", defaultKey: "1", defaultModifiers: ["command"]),
        AppShortcutItem(id: "historyTab", title: "Switch to History Tab", category: "Navigation", defaultKey: "2", defaultModifiers: ["command"]),
        AppShortcutItem(id: "prsTab", title: "Switch to Pull Requests Tab", category: "Navigation", defaultKey: "3", defaultModifiers: ["command"]),
        AppShortcutItem(id: "actionsTab", title: "Switch to Actions Tab", category: "Navigation", defaultKey: "4", defaultModifiers: ["command"]),
        AppShortcutItem(id: "terminalTab", title: "Switch to Embedded Terminal", category: "Navigation", defaultKey: "5", defaultModifiers: ["command"]),
        AppShortcutItem(id: "openRepo", title: "Switch / Open Repository", category: "Repository", defaultKey: "O", defaultModifiers: ["command"]),
        AppShortcutItem(id: "openWith", title: "Open With… (file, repository or page)", category: "Repository", defaultKey: "O", defaultModifiers: ["command", "option"]),
        AppShortcutItem(id: "openBranch", title: "Switch or Create Branch", category: "Repository", defaultKey: "B", defaultModifiers: ["command"]),
        AppShortcutItem(id: "refreshRepo", title: "Refresh Repository Status", category: "Repository", defaultKey: "R", defaultModifiers: ["command"]),
        AppShortcutItem(id: "fetchOrigin", title: "Fetch from Origin", category: "Remote Sync", defaultKey: "T", defaultModifiers: ["command"]),
        AppShortcutItem(id: "pushOrigin", title: "Push Commits to Origin", category: "Remote Sync", defaultKey: "P", defaultModifiers: ["command"]),
        AppShortcutItem(id: "pullOrigin", title: "Pull Changes from Origin", category: "Remote Sync", defaultKey: "P", defaultModifiers: ["command", "shift"]),
        AppShortcutItem(id: "commitStaged", title: "Commit Staged Changes", category: "Changes", defaultKey: "return", defaultModifiers: ["command"])
    ]
}
