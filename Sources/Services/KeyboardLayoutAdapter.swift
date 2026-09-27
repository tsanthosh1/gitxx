import AppKit
import Carbon

/// Layouts whose users can keep QWERTY shortcut positions.
public enum ShortcutLayout: String, CaseIterable, Identifiable, Sendable {
    case off
    case dvorak
    case programmerDvorak

    public var id: String { rawValue }

    public static let defaultsKey = "gitxx_shortcut_layout"

    public var title: String {
        switch self {
        case .off: return "Off"
        case .dvorak: return "Dvorak"
        case .programmerDvorak: return "Programmer Dvorak"
        }
    }

    /// Whether a macOS input source (by localized name / ID) is this layout.
    /// "Dvorak - QWERTY ⌘" already keeps QWERTY shortcuts, so it never matches.
    func matches(inputSourceName name: String, id: String) -> Bool {
        let haystack = (name + " " + id).lowercased()
        guard haystack.contains("dvorak"), !haystack.contains("qwerty") else { return false }
        let isProgrammer = haystack.contains("programmer")
        switch self {
        case .off: return false
        case .dvorak: return !isProgrammer
        case .programmerDvorak: return isProgrammer
        }
    }
}

/// Rewrites ⌘/⌃ key presses to the character the same physical key types on QWERTY, so menu shortcuts,
/// custom shortcuts and editing commands (⌘C, ⌘V…) stay on their QWERTY positions under Dvorak layouts.
public final class KeyboardLayoutAdapter: @unchecked Sendable {
    public static let shared = KeyboardLayoutAdapter()

    private var monitor: Any?

    /// ANSI key code → (unshifted, shifted) QWERTY characters.
    private static let qwerty: [UInt16: (String, String)] = [
        0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 4: ("h", "H"), 5: ("g", "G"),
        6: ("z", "Z"), 7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"), 11: ("b", "B"), 12: ("q", "Q"),
        13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"), 16: ("y", "Y"), 17: ("t", "T"),
        18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"), 22: ("6", "^"), 23: ("5", "%"),
        24: ("=", "+"), 25: ("9", "("), 26: ("7", "&"), 27: ("-", "_"), 28: ("8", "*"), 29: ("0", ")"),
        30: ("]", "}"), 31: ("o", "O"), 32: ("u", "U"), 33: ("[", "{"), 34: ("i", "I"), 35: ("p", "P"),
        37: ("l", "L"), 38: ("j", "J"), 39: ("'", "\""), 40: ("k", "K"), 41: (";", ":"), 42: ("\\", "|"),
        43: (",", "<"), 44: ("/", "?"), 45: ("n", "N"), 46: ("m", "M"), 47: (".", ">"), 50: ("`", "~"),
    ]

    public var selectedLayout: ShortcutLayout {
        ShortcutLayout(rawValue: UserDefaults.standard.string(forKey: ShortcutLayout.defaultsKey) ?? "") ?? .off
    }

    /// Localized name and ID of the active keyboard layout.
    public static func currentInputSource() -> (name: String, id: String) {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return ("", "") }
        func property(_ key: CFString) -> String {
            guard let raw = TISGetInputSourceProperty(source, key) else { return "" }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        return (property(kTISPropertyLocalizedName), property(kTISPropertyInputSourceID))
    }

    /// Cached so key presses never query the input source; refreshed when the layout or setting changes.
    public private(set) var isTranslating = false
    private var lastLayout: ShortcutLayout?

    private func refresh(force: Bool = false) {
        let layout = selectedLayout
        guard force || layout != lastLayout else { return }
        lastLayout = layout
        guard layout != .off else { isTranslating = false; return }
        let source = Self.currentInputSource()
        isTranslating = layout.matches(inputSourceName: source.name, id: source.id)
    }

    @MainActor
    public func install() {
        guard monitor == nil else { return }
        refresh(force: true)
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { _ in KeyboardLayoutAdapter.shared.refresh(force: true) }
        NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
        ) { _ in KeyboardLayoutAdapter.shared.refresh(force: true) }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in KeyboardLayoutAdapter.shared.refresh() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            KeyboardLayoutAdapter.shared.translate(event)
        }
    }

    private func translate(_ event: NSEvent) -> NSEvent {
        let flags = event.modifierFlags
        guard flags.contains(.command) || flags.contains(.control),
              isTranslating, let (lower, upper) = Self.qwerty[event.keyCode] else { return event }
        let char = flags.contains(.shift) ? upper : lower
        guard event.charactersIgnoringModifiers != char else { return event }
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: flags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: char,
            charactersIgnoringModifiers: char,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }
}
