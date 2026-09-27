import SwiftUI

/// Comfortable, easily clickable button style for pull request actions.
/// Native `.small` bordered buttons are ~20pt tall; this renders at 30pt (or 34pt when `.large`).
public struct PRActionButtonStyle: ButtonStyle {
    public enum Kind {
        case primary(Color)
        case secondary
        /// Neutral "on" state for toggles, filters and tabs; accent colors are reserved for primary actions.
        case selected
        case destructive
        case subtle
    }

    public enum Size {
        case compact, regular, large

        var height: CGFloat {
            switch self {
            case .compact: return 26
            case .regular: return 30
            case .large: return 36
            }
        }
        var fontSize: CGFloat {
            switch self {
            case .compact: return 12
            case .regular: return 13
            case .large: return 14
            }
        }
        var hPadding: CGFloat {
            switch self {
            case .compact: return 10
            case .regular: return 14
            case .large: return 18
            }
        }
    }

    let kind: Kind
    let size: Size

    public init(_ kind: Kind = .secondary, size: Size = .regular) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        PRActionButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

private struct PRActionButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: PRActionButtonStyle.Kind
    let size: PRActionButtonStyle.Size

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: size.fontSize, weight: .semibold))
            .labelStyle(PRActionLabelStyle())
            .lineLimit(1)
            .padding(.horizontal, size.hPadding)
            .frame(minHeight: size.height)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .destructive: return Color(red: 248/255, green: 81/255, blue: 73/255)
        case .secondary, .subtle, .selected: return .primary
        }
    }

    private var background: Color {
        let boost = (isHovering && isEnabled) ? 1.0 : 0.0
        switch kind {
        case .primary(let color):
            return color.opacity(configuration.isPressed ? 0.75 : 0.9 + boost * 0.1)
        case .destructive:
            return Color.red.opacity(0.10 + boost * 0.08)
        case .secondary:
            return Color.white.opacity(0.07 + boost * 0.06)
        case .selected:
            return Color.white.opacity(0.20 + boost * 0.04)
        case .subtle:
            return Color.white.opacity(boost * 0.07)
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return Color.white.opacity(0.12)
        case .destructive: return Color.red.opacity(0.35)
        case .secondary: return Color.white.opacity(isHovering ? 0.22 : 0.12)
        case .selected: return Color.white.opacity(0.30)
        case .subtle: return .clear
        }
    }
}

private struct PRActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// Button label that swaps its icon for a spinner while an action runs.
public struct PRActionLabel: View {
    let title: String
    let systemImage: String
    let isRunning: Bool

    public init(_ title: String, systemImage: String, isRunning: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.isRunning = isRunning
    }

    public var body: some View {
        HStack(spacing: 6) {
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: systemImage)
            }
            if !title.isEmpty {
                Text(title)
            }
        }
    }
}
