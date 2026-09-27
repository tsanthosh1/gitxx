import SwiftUI
import AppKit

/// Pointing-hand cursor for link-like content (list rows, chips, navigation targets).
/// Standard push buttons keep the arrow cursor, per macOS conventions.
private struct PointerCursorModifier: ViewModifier {
    @State private var isPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !isPushed {
                    NSCursor.pointingHand.push()
                    isPushed = true
                } else if !inside, isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
            .onDisappear {
                if isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
    }
}

extension View {
    func pointerCursor() -> some View {
        modifier(PointerCursorModifier())
    }
}
