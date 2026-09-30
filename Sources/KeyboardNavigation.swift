import SwiftUI
import AppKit

/// App-wide keyboard behaviour: Tab reaches every control, and ⌘↩ runs the frontmost dialog's primary action.
enum KeyboardNavigation {
    static let fullAccessKey = "gitxx_full_keyboard_navigation"

    static var fullAccessEnabled: Bool {
        UserDefaults.standard.object(forKey: fullAccessKey) as? Bool ?? true
    }

    /// AppKit reads `AppleKeyboardUIMode` through the app's defaults domain first, so setting it here turns on
    /// "Keyboard navigation" (Tab to buttons, toggles, chips…) for GitXX alone. Read at launch.
    static func applyPreference() {
        if fullAccessEnabled {
            UserDefaults.standard.set(2, forKey: "AppleKeyboardUIMode")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleKeyboardUIMode")
        }
    }

    @MainActor private static var commandReturnMonitor: Any?

    /// ⌘↩ first goes to whatever claims it (AI composer, review, merge); otherwise it presses the window's
    /// default (↩) button, so it works even while typing in a multi-line field.
    @MainActor
    static func installCommandReturn() {
        guard commandReturnMonitor == nil else { return }
        commandReturnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 36 || event.keyCode == 76,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == .command,
                  let window = event.window ?? NSApp.keyWindow else { return event }
            if window.performKeyEquivalent(with: event) { return nil }
            guard let plainReturn = NSEvent.keyEvent(
                with: .keyDown, location: event.locationInWindow, modifierFlags: [],
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ) else { return event }
            return window.performKeyEquivalent(with: plainReturn) ? nil : event
        }
    }
}

// MARK: - Explicit tab order for SwiftUI forms


/// Reports the NSWindow a view lives in (so key monitors only act on their own sheet).
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Probe(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let onWindow: (NSWindow?) -> Void
        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { self.onWindow(window) }
        }
    }
}

@MainActor
private final class TabCycleBox<F: Hashable> {
    var order: [F] = []
    var monitor: Any?
    weak var window: NSWindow?
}

/// Tab / ⇧Tab move through `order` regardless of the system "Keyboard navigation" setting,
/// which SwiftUI buttons with custom styles otherwise ignore.
private struct TabCycle<F: Hashable>: ViewModifier {
    let order: [F]
    let focus: FocusState<F?>.Binding
    @State private var box = TabCycleBox<F>()

    func body(content: Content) -> some View {
        box.order = order
        return content
            .background(WindowReader { box.window = $0 }.frame(width: 0, height: 0))
            .onAppear(perform: install)
            .onDisappear {
                if let monitor = box.monitor { NSEvent.removeMonitor(monitor) }
                box.monitor = nil
            }
    }

    private func install() {
        guard box.monitor == nil else { return }
        let box = self.box
        let focus = self.focus
        box.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 48 else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            guard mods.isEmpty else { return event }
            let windowNumber = event.windowNumber
            let back = event.modifierFlags.contains(.shift)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let window = box.window, window.windowNumber == windowNumber, window.attachedSheet == nil,
                      !box.order.isEmpty else { return false }
                let count = box.order.count
                let next: Int
                if let current = focus.wrappedValue, let i = box.order.firstIndex(of: current) {
                    next = (i + (back ? -1 : 1) + count) % count
                } else {
                    next = back ? count - 1 : 0
                }
                focus.wrappedValue = box.order[next]
                return true
            }
            return handled ? nil : event
        }
    }
}

extension View {
    /// Explicit Tab order for a form; pair non-text controls with `keyboardFocusable`.
    func tabCycle<F: Hashable>(_ order: [F], focus: FocusState<F?>.Binding) -> some View {
        modifier(TabCycle(order: order, focus: focus))
    }

    /// Lets Tab land on a button-like control: accent focus ring, Space presses it.
    func keyboardFocusable<F: Hashable>(_ focus: FocusState<F?>.Binding, _ value: F, accent: Color,
                                        cornerRadius: CGFloat = 8, press: @escaping () -> Void) -> some View {
        self
            .focusable()
            .focused(focus, equals: value)
            .focusEffectDisabled()
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                    .stroke(accent, lineWidth: 2)
                    .padding(-3)
                    .opacity(focus.wrappedValue == value ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .onKeyPress(.space) {
                press()
                return .handled
            }
    }
}
