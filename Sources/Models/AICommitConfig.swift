import Foundation

public enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case githubCopilot = "GitHub Copilot"
    case githubModels = "GitHub Models (Free)"
    case ollama = "Local Ollama"
    case customOpenAI = "Custom OpenAI / BYOK"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .githubCopilot: return "sparkles"
        case .githubModels: return "network"
        case .ollama: return "desktopcomputer"
        case .customOpenAI: return "key.fill"
        }
    }

    public var description: String {
        switch self {
        case .githubCopilot:
            return "Uses your GitHub Copilot subscription. No separate API key required."
        case .githubModels:
            return "Free cloud models (GPT-4o, Claude) using your standard GitHub account."
        case .ollama:
            return "100% private, runs offline on your Mac (e.g. Llama 3.2, Mistral)."
        case .customOpenAI:
            return "OpenAI, Anthropic Claude, or any OpenAI-compatible API endpoint."
        }
    }
}

public enum CommitStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case conventional = "Conventional Commits"
    case gitmoji = "Gitmoji + Conventional"
    case concise = "Concise & Plain"
    case detailed = "Detailed with Bullets"

    public var id: String { rawValue }

    public var exampleText: String {
        switch self {
        case .conventional:
            return "feat(auth): add GitHub Copilot commit generator"
        case .gitmoji:
            return "✨ feat(auth): add GitHub Copilot commit generator"
        case .concise:
            return "Add GitHub Copilot commit generator"
        case .detailed:
            return "feat(auth): add Copilot commit generator\n\n• Integrate device code flow\n• Add liquid glass commit button"
        }
    }
}

public enum CopilotModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case gpt4o = "gpt-4o"
    case claude35Sonnet = "claude-3.5-sonnet"
    case gpt4oMini = "gpt-4o-mini"
    case o1Mini = "o1-mini"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gpt4o: return "GPT-4o (Recommended)"
        case .claude35Sonnet: return "Claude 3.5 Sonnet"
        case .gpt4oMini: return "GPT-4o mini (Fastest)"
        case .o1Mini: return "o1-mini (Reasoning)"
        }
    }
}

public struct DeviceCodeResponse: Codable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationUri: String
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

public struct CopilotQuotaInfo: Codable, Sendable, Equatable {
    public let sku: String
    public let chatQuotaLimit: Int?
    public let completionsQuotaLimit: Int?
    public let resetDate: Date?
    public let isUnlimited: Bool

    public init(
        sku: String,
        chatQuotaLimit: Int?,
        completionsQuotaLimit: Int?,
        resetDate: Date?,
        isUnlimited: Bool
    ) {
        self.sku = sku
        self.chatQuotaLimit = chatQuotaLimit
        self.completionsQuotaLimit = completionsQuotaLimit
        self.resetDate = resetDate
        self.isUnlimited = isUnlimited
    }

    public var planDisplayName: String {
        let lower = sku.lowercased()
        if lower.contains("free") {
            return "Copilot Free"
        } else if lower.contains("individual") {
            return "Copilot Individual"
        } else if lower.contains("business") {
            return "Copilot Business"
        } else if lower.contains("enterprise") {
            return "Copilot Enterprise"
        } else if sku.isEmpty {
            return "Copilot Active"
        }
        return sku.replacingOccurrences(of: "_", with: " ").capitalized
    }
}


/// Premium-request balance from `copilot_internal/user`.
public struct CopilotPremiumUsage: Sendable, Equatable {
    public let plan: String?
    public let entitlement: Double?
    public let remaining: Double?
    public let unlimited: Bool
    /// `YYYY-MM-DD`
    public let resetDate: String?
}
