import SwiftUI
import AppKit

public struct CommitPaneResizeDivider: View {
    @ObservedObject var state: AppState
    let maxAllowedHeight: CGFloat

    @State private var isHovered: Bool = false
    @State private var isDragging: Bool = false

    public var body: some View {
        ZStack {
            // Visual hairline divider line
            Rectangle()
                .fill(isHovered || isDragging ? Color.white.opacity(0.55) : Color.primary.opacity(0.12))
                .frame(height: 1)

            // Centered tactile grip handle
            Capsule()
                .fill(
                    isDragging
                        ? Color.white
                        : (isHovered ? Color.white.opacity(0.9) : Color.secondary.opacity(0.42))
                )
                .frame(width: 38, height: 3.5)
                .shadow(
                    color: (isHovered || isDragging) ? Color.white.opacity(0.4) : Color.clear,
                    radius: 2.5,
                    x: 0,
                    y: 0
                )

            // Native AppKit mouse event & cursor handle (14pt hit area)
            NativeResizeHandleRepresentable(
                height: Binding(
                    get: { state.commitPaneHeight },
                    set: { state.commitPaneHeight = $0 }
                ),
                minHeight: 140,
                maxHeight: maxAllowedHeight,
                isHovered: $isHovered,
                isDragging: $isDragging,
                onDoubleClick: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        if state.commitPaneHeight >= 250 {
                            state.commitPaneHeight = 185
                        } else {
                            state.commitPaneHeight = min(320, maxAllowedHeight)
                        }
                    }
                }
            )
        }
        .frame(height: 14)
        .frame(maxWidth: .infinity)
        .help("Drag to resize commit pane. Double-click to toggle default height.")
    }
}

// MARK: - Native AppKit Mouse Tracking & Drag Capture

struct NativeResizeHandleRepresentable: NSViewRepresentable {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    @Binding var isHovered: Bool
    @Binding var isDragging: Bool
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NativeResizeHandleView {
        let view = NativeResizeHandleView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NativeResizeHandleView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NativeResizeHandleView) {
        view.onHeightChange = { newHeight in
            self.height = newHeight
        }
        view.onHoverChange = { hovered in
            self.isHovered = hovered
        }
        view.onDragChange = { dragging in
            self.isDragging = dragging
        }
        view.onDoubleClick = onDoubleClick
        view.minHeight = minHeight
        view.maxHeight = maxHeight
        view.currentHeight = height
    }
}

final class NativeResizeHandleView: NSView {
    var onHeightChange: ((CGFloat) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onDragChange: ((Bool) -> Void)?
    var onDoubleClick: (() -> Void)?

    var minHeight: CGFloat = 140
    var maxHeight: CGFloat = 500
    var currentHeight: CGFloat = 185

    private var initialY: CGFloat = 0
    private var initialHeight: CGFloat = 185
    private var trackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool {
        return false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeUpDown.set()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        initialY = event.locationInWindow.y
        initialHeight = currentHeight
        onDragChange?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.resizeUpDown.set()
        let currentY = event.locationInWindow.y
        let delta = currentY - initialY
        let targetHeight = initialHeight + delta
        let clamped = min(max(targetHeight, minHeight), maxHeight)
        onHeightChange?(clamped)
    }

    override func mouseUp(with event: NSEvent) {
        onDragChange?(false)
        window?.invalidateCursorRects(for: self)
    }
}
