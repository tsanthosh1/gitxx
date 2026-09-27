import SwiftUI

public enum AccentTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    // Solid Themes
    case classicGreen = "Classic Green"
    case electricBlue = "Electric Blue"
    case neonCyan = "Neon Cyan"
    case sunsetCoral = "Sunset Coral"
    case royalPurple = "Royal Purple"
    case amberGold = "Amber Gold"

    // Gradient Themes
    case gradientCyberpunk = "Cyberpunk (Neon Green ➔ Cyan)"
    case gradientSunset = "Hyper Sunset (Orange ➔ Pink)"
    case gradientOcean = "Deep Ocean (Cyan ➔ Deep Blue)"
    case gradientAurora = "Aurora Borealis (Purple ➔ Emerald)"
    case gradientElectric = "Electric Violet (Indigo ➔ Magenta)"
    case gradientSolar = "Solar Flare (Gold ➔ Crimson)"

    public var id: String { rawValue }

    public var isGradient: Bool {
        switch self {
        case .gradientCyberpunk, .gradientSunset, .gradientOcean, .gradientAurora, .gradientElectric, .gradientSolar:
            return true
        default:
            return false
        }
    }

    public var shortName: String {
        switch self {
        case .classicGreen: return "Green"
        case .electricBlue: return "Blue"
        case .neonCyan: return "Cyan"
        case .sunsetCoral: return "Coral"
        case .royalPurple: return "Purple"
        case .amberGold: return "Amber"
        case .gradientCyberpunk: return "Cyberpunk"
        case .gradientSunset: return "Sunset"
        case .gradientOcean: return "Ocean Deep"
        case .gradientAurora: return "Aurora"
        case .gradientElectric: return "Electric"
        case .gradientSolar: return "Solar Flare"
        }
    }

    public var gradientDescription: String {
        switch self {
        case .gradientCyberpunk: return "Neon Green ➔ Cyan"
        case .gradientSunset: return "Orange ➔ Hot Pink"
        case .gradientOcean: return "Cyan ➔ Deep Blue"
        case .gradientAurora: return "Purple ➔ Emerald"
        case .gradientElectric: return "Indigo ➔ Magenta"
        case .gradientSolar: return "Gold ➔ Crimson"
        default: return ""
        }
    }

    public var colors: [Color] {
        switch self {
        case .classicGreen:
            // Native Apple system green (#30D158) - luminous, vibrant, punchy
            return [Color.green]
        case .electricBlue:
            // High-luminance macOS system blue (#0A84FF)
            return [Color(red: 0.08, green: 0.52, blue: 1.00)]
        case .neonCyan:
            // High-contrast modern terminal neon cyan (#00E5FF)
            return [Color(red: 0.00, green: 0.86, blue: 0.98)]
        case .sunsetCoral:
            // Radiant warm fiery coral (#FF5E3A)
            return [Color(red: 1.00, green: 0.38, blue: 0.24)]
        case .royalPurple:
            // Electric macOS purple (#BF5AF2)
            return [Color(red: 0.72, green: 0.36, blue: 0.98)]
        case .amberGold:
            // Luminous warm amber gold (#FFB800)
            return [Color(red: 1.00, green: 0.73, blue: 0.06)]

        case .gradientCyberpunk:
            return [Color(red: 0.05, green: 0.92, blue: 0.55), Color(red: 0.00, green: 0.76, blue: 0.98)]
        case .gradientSunset:
            return [Color(red: 1.00, green: 0.44, blue: 0.22), Color(red: 0.95, green: 0.22, blue: 0.58)]
        case .gradientOcean:
            return [Color(red: 0.00, green: 0.82, blue: 0.96), Color(red: 0.22, green: 0.42, blue: 0.98)]
        case .gradientAurora:
            return [Color(red: 0.68, green: 0.28, blue: 0.96), Color(red: 0.12, green: 0.86, blue: 0.55)]
        case .gradientElectric:
            return [Color(red: 0.42, green: 0.25, blue: 0.98), Color(red: 0.94, green: 0.24, blue: 0.78)]
        case .gradientSolar:
            return [Color(red: 1.00, green: 0.70, blue: 0.10), Color(red: 0.95, green: 0.24, blue: 0.28)]
        }
    }

    public var primaryColor: Color {
        colors.first ?? Color.green
    }

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
        case "cyan", "neon cyan", "graphite", "graphite slate", "slate":
            return .neonCyan
        case "sunset", "sunset coral", "coral":
            return .sunsetCoral
        case "royal", "royal violet", "royal purple", "purple", "violet":
            return .royalPurple
        case "amber", "amber gold", "gold":
            return .amberGold
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
