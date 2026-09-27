import SwiftUI
import AppKit

public struct WindowAccessor: NSViewRepresentable {
    public static var mainWindow: NSWindow? = nil

    public init() {}

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                WindowAccessor.mainWindow = window
                configureWindow(window)
            }
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            WindowAccessor.mainWindow = window
            configureWindow(window)
        }
    }

    private func configureWindow(_ window: NSWindow) {
        WindowAccessor.mainWindow = window
        NSWindow.allowsAutomaticWindowTabbing = false
        window.tabbingMode = .disallowed
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Disable movable by window background so dragging splitters or content never moves the window
        window.isMovableByWindowBackground = false
    }
}

// MARK: - Dedicated Window Drag Area for Titlebar / Topbar

public struct WindowDragArea: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> WindowDragNSView {
        WindowDragNSView()
    }

    public func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

public final class WindowDragNSView: NSView {
    public override var mouseDownCanMoveWindow: Bool { true }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
            return
        }
        window?.performDrag(with: event)
    }
}
