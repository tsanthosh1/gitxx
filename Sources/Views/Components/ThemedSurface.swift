import SwiftUI
import AppKit

/// Where a surface sits; decides only a slight neutral lift over the shared window shade.
public enum SurfaceRole {
    case sidebar
    case toolbar
    case titleBar
    case header
    /// Floating panels and dropdowns (pickers, palette, assistant, popovers, sheets).
    case elevated
}

/// User preferences for surface shading, stored in UserDefaults.
public enum SurfaceStyle {
    public static let intensityKey = "gitxx_surface_tint"
    public static let secondaryKey = "gitxx_surface_secondary"
    public static let tertiaryKey = "gitxx_surface_tertiary"

    public enum Intensity: Int, CaseIterable, Identifiable {
        case off = 0, subtle = 1, rich = 2
        public var id: Int { rawValue }
        public var title: String {
            switch self {
            case .off: return "Off"
            case .subtle: return "Subtle"
            case .rich: return "Rich"
            }
        }
    }

    static func color(hex: String) -> Color? {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard clean.count == 6, let value = UInt32(clean, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    static func hex(of color: Color) -> String {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "" }
        return String(format: "%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    /// Near-black window base modelled on Slack's dark theme; system window colour in light mode.
    static let windowBase = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.102, green: 0.106, blue: 0.122, alpha: 1)
            : NSColor.windowBackgroundColor
    })

    /// Solid shade for floating panels, which live outside the window's shade.
    static let elevatedBase = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.137, green: 0.141, blue: 0.160, alpha: 1)
            : NSColor.controlBackgroundColor
    })

    /// Neutral lift per role, so panes stay distinguishable without their own colours.
    static func lift(_ role: SurfaceRole) -> Double {
        switch role {
        case .sidebar, .titleBar: return 0
        case .toolbar: return 0.012
        case .header: return 0.025
        case .elevated: return 0
        }
    }
}

private struct ThemeCanvasKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

public extension EnvironmentValues {
    /// The main window's content rect in global coordinates; surfaces inside it align their shade to it.
    var themeCanvas: CGRect? {
        get { self[ThemeCanvasKey.self] }
        set { self[ThemeCanvasKey.self] = newValue }
    }
}

/// The one shade for the whole window: base plus a wash of the secondary colour from the top-left and the
/// tertiary from the bottom-right.
public struct ThemedWindowWash: View {
    let theme: AccentTheme
    @AppStorage(SurfaceStyle.intensityKey) private var intensity = SurfaceStyle.Intensity.subtle.rawValue
    @AppStorage(SurfaceStyle.secondaryKey) private var secondaryHex = ""
    @AppStorage(SurfaceStyle.tertiaryKey) private var tertiaryHex = ""
    @Environment(\.colorScheme) private var scheme

    public init(theme: AccentTheme) { self.theme = theme }

    public var body: some View {
        let level = SurfaceStyle.Intensity(rawValue: intensity) ?? .subtle
        let k: Double = (level == .off ? 0 : (level == .subtle ? 1 : 1.8)) * (scheme == .dark ? 1 : 0.5)
        let secondary = SurfaceStyle.color(hex: secondaryHex) ?? theme.secondaryColor
        let tertiary = SurfaceStyle.color(hex: tertiaryHex) ?? theme.tertiaryColor
        ZStack {
            SurfaceStyle.windowBase
            if k > 0 {
                RadialGradient(colors: [secondary.opacity(0.20 * k), secondary.opacity(0.06 * k), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 900)
                RadialGradient(colors: [tertiary.opacity(0.13 * k), tertiary.opacity(0.03 * k), .clear],
                               center: .bottomTrailing, startRadius: 0, endRadius: 800)
            }
        }
    }
}

/// A pane's background: the window shade cut out at the pane's position, so neighbouring panes join seamlessly.
public struct ThemedSurfaceBackground: View {
    let theme: AccentTheme
    let role: SurfaceRole
    @Environment(\.themeCanvas) private var canvas

    public init(theme: AccentTheme, role: SurfaceRole) {
        self.theme = theme
        self.role = role
    }

    public var body: some View {
        if role != .elevated, let canvas {
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                ThemedWindowWash(theme: theme)
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(x: canvas.minX - frame.minX, y: canvas.minY - frame.minY)
            }
            .overlay(Color.white.opacity(SurfaceStyle.lift(role)))
            .clipped()
            // The window-sized wash overhangs the pane; clipping hides it but doesn't stop it catching clicks.
            .allowsHitTesting(false)
        } else {
            SurfaceStyle.elevatedBase
        }
    }
}

public extension View {
    /// Pane background aligned to the window's single theme shade.
    func themedSurface(_ theme: AccentTheme, _ role: SurfaceRole) -> some View {
        background(ThemedSurfaceBackground(theme: theme, role: role))
    }
}
