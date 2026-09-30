import SwiftUI

public enum AccentTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    // Solid Themes
    case classicGreen = "Classic Green"
    case electricBlue = "Electric Blue"
    case neonCyan = "Neon Cyan"
    case sunsetCoral = "Sunset Coral"
    case royalPurple = "Royal Purple"
    case amberGold = "Amber Gold"
    case roseRed = "Rose"
    case slateNord = "Nord"

    // Gradient Themes
    case gradientCyberpunk = "Cyberpunk (Neon Green ➔ Cyan)"
    case gradientSunset = "Hyper Sunset (Orange ➔ Pink)"
    case gradientOcean = "Deep Ocean (Cyan ➔ Deep Blue)"
    case gradientAurora = "Aurora Borealis (Purple ➔ Emerald)"
    case gradientElectric = "Electric Violet (Indigo ➔ Magenta)"
    case gradientSolar = "Solar Flare (Gold ➔ Crimson)"
    case gradientAubergine = "Aubergine (Plum ➔ Raspberry)"
    case gradientLagoon = "Lagoon (Teal ➔ Indigo)"

    public var id: String { rawValue }

    public var isGradient: Bool {
        switch self {
        case .gradientCyberpunk, .gradientSunset, .gradientOcean, .gradientAurora, .gradientElectric, .gradientSolar,
             .gradientAubergine, .gradientLagoon:
            return true
        default:
            return false
        }
    }

    public var shortName: String {
        switch self {
        case .classicGreen: return "Emerald"
        case .electricBlue: return "Blue"
        case .neonCyan: return "Teal"
        case .sunsetCoral: return "Coral"
        case .royalPurple: return "Violet"
        case .amberGold: return "Amber"
        case .roseRed: return "Rose"
        case .slateNord: return "Nord"
        case .gradientCyberpunk: return "Cyberpunk"
        case .gradientSunset: return "Sunset"
        case .gradientOcean: return "Ocean Deep"
        case .gradientAurora: return "Aurora"
        case .gradientElectric: return "Electric"
        case .gradientSolar: return "Solar Flare"
        case .gradientAubergine: return "Aubergine"
        case .gradientLagoon: return "Lagoon"
        }
    }

    public var gradientDescription: String {
        switch self {
        case .gradientCyberpunk: return "Jade ➔ Cyan"
        case .gradientSunset: return "Tangerine ➔ Pink"
        case .gradientOcean: return "Cyan ➔ Royal Blue"
        case .gradientAurora: return "Violet ➔ Emerald"
        case .gradientElectric: return "Indigo ➔ Fuchsia"
        case .gradientSolar: return "Amber ➔ Crimson"
        case .gradientAubergine: return "Plum ➔ Raspberry"
        case .gradientLagoon: return "Teal ➔ Indigo"
        default: return ""
        }
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// Primary, secondary and tertiary colours. The primary fills buttons under white text, so every primary sits in
    /// the mid-luminance band (about 3:1 against white and 4:1+ against the dark canvas). Secondary and tertiary tint
    /// surfaces and gradients.
    public var palette: [Color] {
        let h = Self.hex
        switch self {
        case .classicGreen: return [h(0x2DA44E), h(0x1A7F72), h(0x3B6FD8)]
        case .electricBlue: return [h(0x3B7DF0), h(0x5B5BD6), h(0x1F8FB0)]
        case .neonCyan: return [h(0x0E9AAE), h(0x2E6FD8), h(0x16A37A)]
        case .sunsetCoral: return [h(0xE8583A), h(0xC2366B), h(0xD08A0A)]
        case .royalPurple: return [h(0x8B5CF6), h(0xB83A9B), h(0x4F52E0)]
        case .amberGold: return [h(0xD6800A), h(0xC2410C), h(0x9A7B12)]
        case .roseRed: return [h(0xE0395E), h(0x9D2A6B), h(0xD9631E)]
        case .slateNord: return [h(0x5E81AC), h(0x4C8C9E), h(0x7B6BA8)]
        case .gradientCyberpunk: return [h(0x0E9F6E), h(0x0891B2), h(0x5B5FE0)]
        case .gradientSunset: return [h(0xEE6A1A), h(0xD6336C), h(0x7C3AED)]
        case .gradientOcean: return [h(0x0891B2), h(0x2563EB), h(0x0D9488)]
        case .gradientAurora: return [h(0x8B5CF6), h(0x059669), h(0x0EA5E9)]
        case .gradientElectric: return [h(0x6366F1), h(0xC026D3), h(0xDB2777)]
        case .gradientSolar: return [h(0xDD8A0B), h(0xDC2626), h(0x9D174D)]
        case .gradientAubergine: return [h(0x9D4EDD), h(0xD9366B), h(0x611F69)]
        case .gradientLagoon: return [h(0x0F9D8F), h(0x4F46E5), h(0x0284C7)]
        }
    }

    public var colors: [Color] {
        isGradient ? Array(palette.prefix(2)) : [palette[0]]
    }

    public var primaryColor: Color { palette[0] }
    public var secondaryColor: Color { palette[1] }
    public var tertiaryColor: Color { palette[2] }

    public var linearGradient: LinearGradient {
        if colors.count > 1 {
            return LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            let base = colors[0]
            return LinearGradient(
                colors: [base, base.opacity(0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    public var horizontalGradient: LinearGradient {
        if colors.count > 1 {
            return LinearGradient(
                colors: colors,
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            let base = colors[0]
            return LinearGradient(
                colors: [base, base],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    public static func from(_ raw: String) -> AccentTheme? {
        if let direct = AccentTheme(rawValue: raw) {
            return direct
        }
        switch raw.lowercased() {
        case "emerald", "emerald green", "classic green", "green":
            return .classicGreen
        case "ocean", "ocean blue", "electric blue", "blue":
            return .electricBlue
        case "cyan", "neon cyan", "teal", "graphite", "graphite slate", "slate":
            return .neonCyan
        case "sunset", "sunset coral", "coral":
            return .sunsetCoral
        case "royal", "royal violet", "royal purple", "purple", "violet":
            return .royalPurple
        case "amber", "amber gold", "gold":
            return .amberGold
        case "rose", "red":
            return .roseRed
        case "nord":
            return .slateNord
        default:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        if let theme = AccentTheme.from(str) {
            self = theme
        } else {
            self = .classicGreen
        }
    }
}
