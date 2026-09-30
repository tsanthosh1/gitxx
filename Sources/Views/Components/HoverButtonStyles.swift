import SwiftUI

/// Icon-only buttons: a square hit area of at least `size`, a rounded fill on hover and a stronger one while pressed.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var cornerRadius: CGFloat = 6
    /// Keeps the fill on, for toggles that are switched on.
    var isActive = false
    /// Fill shown when idle, for chip-like icon buttons that always show their shape.
    var restingFill: Double = 0

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, cornerRadius: cornerRadius, isActive: isActive, restingFill: restingFill)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let cornerRadius: CGFloat
    let isActive: Bool
    let restingFill: Double
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .frame(minWidth: size, minHeight: size)
            .background(shape.fill(Color.primary.opacity(fill)))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
            .pointerCursor()
    }

    private var fill: Double {
        let idle = max(restingFill, isActive ? 0.1 : 0)
        guard isEnabled else { return idle }
        if configuration.isPressed { return idle + 0.12 }
        if hovering { return idle + 0.07 }
        return idle
    }
}

/// Default for borderless buttons (rows, chips, links, cards): the label brightens on hover and dims while
/// pressed, with a pointing-hand cursor, so every clickable thing responds without changing its shape.
struct HoverPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverPlainBody(configuration: configuration)
    }
}

private struct HoverPlainBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .brightness(isEnabled && hovering && !configuration.isPressed ? 0.08 : 0)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
            .pointerCursor()
    }
}

/// The icon-button hover for things that can't take a button style, such as `Menu`.
private struct IconHoverModifier: ViewModifier {
    let size: CGFloat
    let cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .frame(minWidth: size, minHeight: size)
            .background(shape.fill(Color.primary.opacity(hovering ? 0.1 : 0)))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
            .pointerCursor()
    }
}

extension View {
    func iconHover(size: CGFloat = 26, cornerRadius: CGFloat = 6) -> some View {
        modifier(IconHoverModifier(size: size, cornerRadius: cornerRadius))
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
    static func icon(size: CGFloat = 26, cornerRadius: CGFloat = 6, active: Bool = false, resting: Double = 0) -> IconButtonStyle {
        IconButtonStyle(size: size, cornerRadius: cornerRadius, isActive: active, restingFill: resting)
    }
}

extension ButtonStyle where Self == HoverPlainButtonStyle {
    static var hoverPlain: HoverPlainButtonStyle { HoverPlainButtonStyle() }
}
