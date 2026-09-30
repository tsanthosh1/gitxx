import SwiftUI
import AppKit

public enum PreferenceCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance & Themes"
    case shortcuts = "Shortcuts & Keybindings"
    case gitUsers = "Git Users & Profiles"
    case github = "GitHub Accounts & API"
    case network = "API Usage & Network"
    case aiCopilot = "AI & Copilot"
    case aiWriting = "AI Commits & Assistant"
    case terminal = "Terminal & Shell"
    case cli = "Command Line Tool (CLI)"
    case about = "About GitXX"

    public var id: String { rawValue }

    /// One-line sidebar label; `rawValue` stays the full name used to open a category.
    public var shortTitle: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .gitUsers: return "Git Profiles"
        case .github: return "GitHub Account"
        case .network: return "API Usage"
        case .aiCopilot: return "AI Provider"
        case .aiWriting: return "Commits & Assistant"
        case .terminal: return "Terminal"
        case .cli: return "Command Line Tool"
        case .about: return "About GitXX"
        }
    }

    /// Sidebar group heading.
    public var group: String {
        switch self {
        case .general, .appearance, .shortcuts: return "App"
        case .gitUsers, .github, .network: return "Git & GitHub"
        case .aiCopilot, .aiWriting: return "AI"
        case .terminal, .cli: return "Tools"
        case .about: return ""
        }
    }

    public var iconName: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette.fill"
        case .shortcuts: return "command"
        case .gitUsers: return "person.crop.circle.badge.checkmark"
        case .github: return "key.horizontal.fill"
        case .network: return "chart.bar.xaxis"
        case .aiCopilot: return "sparkles"
        case .aiWriting: return "text.bubble"
        case .terminal: return "terminal.fill"
        case .cli: return "apple.terminal"
        case .about: return "info.circle.fill"
        }
    }
}

public struct SettingsSheet: View {
    @AppStorage(MenuBarController.enabledKey) private var menuBarIcon = false
    @AppStorage(KeyboardNavigation.fullAccessKey) private var fullKeyboardNavigation = true
    @State private var fullKeyboardNavigationAtLaunch = KeyboardNavigation.fullAccessEnabled
    @AppStorage(SurfaceStyle.intensityKey) private var surfaceIntensity = SurfaceStyle.Intensity.subtle.rawValue
    @AppStorage(SurfaceStyle.secondaryKey) private var surfaceSecondaryHex = ""
    @AppStorage(SurfaceStyle.tertiaryKey) private var surfaceTertiaryHex = ""
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: PreferenceCategory = .general
    @State private var hoveredCategory: PreferenceCategory? = nil
    @State private var tokenInput: String = ""
    @State private var showPATSection: Bool = false
    @State private var testCommandInput: String = "gs"
    @State private var testCommandResult: String = ""
    @State private var isRunningTestCommand: Bool = false
    @State private var editingProfile: GitUserProfile? = nil
    @State private var isCreatingProfile: Bool = false
    @State private var formLabel: String = ""
    @State private var formName: String = ""
    @State private var formEmail: String = ""
    @State private var formGithub: String = ""
    @State private var formSSH: String = ""
    @State private var testAIResult: String = ""
    @State private var isTestingAI: Bool = false
    @State private var shortcutSearch: String = ""
    @State private var editingShortcutId: String? = nil
    @AppStorage(ShortcutLayout.defaultsKey) private var shortcutLayoutRaw = ShortcutLayout.off.rawValue
    @AppStorage(AIChatStore.customInstructionsKey) private var assistantInstructions = ""
    @State private var currentInputSourceName = ""
    @State private var tempKey: String = ""
    @State private var tempModifiers: [String] = []
    @State private var hasCopiedPathExport: Bool = false
    @State private var apiLogFilter: String = "all"
    @State private var apiLogSearch: String = ""
    @State private var expandedLogId: String? = nil

    public var body: some View {
        VStack(spacing: 0) {
            // Window Header Bar
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    Text("Preferences")
                        .font(.system(size: 14, weight: .bold))
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(state.accentTheme.primaryColor)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .themedSurface(state.accentTheme, .header)

            Divider()

            // Main Content: Sidebar + Detail Content
            HStack(spacing: 0) {
                // Left Navigation Sidebar
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(PreferenceCategory.allCases) { category in
                        if category.group != (PreferenceCategory.allCases.firstIndex(of: category).flatMap { $0 > 0 ? PreferenceCategory.allCases[$0 - 1].group : nil } ?? "-") {
                            if category.group.isEmpty {
                                Divider().padding(.vertical, 6)
                            } else {
                                Text(category.group.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(0.5)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, category == PreferenceCategory.allCases.first ? 0 : 10)
                                    .padding(.bottom, 2)
                            }
                        }
                        let isSelected = selectedCategory == category
                        let isHovered = hoveredCategory == category
                        Button {
                            selectedCategory = category
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: category.iconName)
                                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                    .frame(width: 18)
                                    .foregroundStyle(isSelected ? Color.white : (isHovered ? Color.primary : Color.secondary))

                                Text(category.shortTitle)
                                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                    .lineLimit(1)
                                    .foregroundStyle(isSelected ? Color.white : (isHovered ? Color.primary : Color.secondary))

                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .background(
                                Group {
                                    if isSelected {
                                        ZStack {
                                            // Transparent light glass fill
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .fill(Color.white.opacity(0.14))

                                            // Specular light glass highlight stroke
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .strokeBorder(
                                                    LinearGradient(
                                                        colors: [
                                                            Color.white.opacity(0.35),
                                                            Color.white.opacity(0.10)
                                                        ],
                                                        startPoint: .top,
                                                        endPoint: .bottom
                                                    ),
                                                    lineWidth: 1
                                                )
                                        }
                                        .shadow(color: Color.black.opacity(0.25), radius: 3, x: 0, y: 1.5)
                                    } else if isHovered {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(Color.white.opacity(0.06))
                                    } else {
                                        Color.clear
                                    }
                                }
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.hoverPlain)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.1)) {
                                hoveredCategory = hovering ? category : nil
                            }
                        }
                    }

                    Spacer()
                }
                .padding(12)
                .frame(width: 230)
                .frame(maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.6))

                Divider()

                // Right Category Detail Pane
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            switch selectedCategory {
                            case .general:
                                generalSettingsView
                            case .network:
                                networkSettingsView
                            case .aiWriting:
                                aiWritingSettingsView
                            case .appearance:
                                appearanceSettingsView
                            case .gitUsers:
                                gitUsersSettingsView
                            case .aiCopilot:
                                aiCopilotSettingsView
                            case .terminal:
                                terminalSettingsView
                            case .shortcuts:
                                shortcutsSettingsView
                            case .cli:
                                cliSettingsView
                            case .github:
                                githubSettingsView
                            case .about:
                                aboutSettingsView
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                    .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ScrollAIToBottom"))) { _ in
                        selectedCategory = .aiWriting
                        withAnimation(.easeOut(duration: 0.2)) {
                            scrollProxy.scrollTo("commitStyleSection", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(width: 900, height: 630)
        .onAppear {
            if let existing = state.githubToken {
                tokenInput = existing
            }
            if let initial = state.initialPreferencesCategory,
               let match = PreferenceCategory.allCases.first(where: { $0.rawValue == initial }) {
                selectedCategory = match
                state.initialPreferencesCategory = nil
            }
        }
        .sheet(isPresented: $state.showOAuthModal) {
            GitHubOAuthModalView(state: state)
        }
    }

    // MARK: - 1. Appearance & Themes

    private var appearanceSettingsView: some View {
        VStack(alignment: .leading, spacing: 22) {
            headerSection(
                title: "Theme & Accent Colors",
                subtitle: "Customize the primary accent color and gradient highlights across the application"
            )

            // Section A: Gradients
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Vibrant Gradients")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Recommended")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Capsule())
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(AccentTheme.allCases.filter { $0.isGradient }) { theme in
                        let isSelected = state.accentTheme == theme
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                state.accentTheme = theme
                            }
                        } label: {
                            HStack(spacing: 10) {
                                // Gradient Preview Pill
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(LinearGradient(colors: [theme.primaryColor, theme.secondaryColor, theme.tertiaryColor],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 32, height: 20)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                                    )

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(theme.shortName)
                                        .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                                        .foregroundStyle(.primary)
                                    Text(theme.gradientDescription)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(theme.primaryColor)
                                        .font(.system(size: 14))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color.white.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(isSelected ? theme.primaryColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
                            )
                        }
                        .buttonStyle(.hoverPlain)
                    }
                }
            }

            // Section B: Solid Colors
            VStack(alignment: .leading, spacing: 10) {
                Text("Solid Accent Colors")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(AccentTheme.allCases.filter { !$0.isGradient }) { theme in
                        let isSelected = state.accentTheme == theme
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                state.accentTheme = theme
                            }
                        } label: {
                            HStack(spacing: 8) {
                                ZStack {
                                    Circle().fill(theme.tertiaryColor).frame(width: 11, height: 11).offset(x: 9)
                                    Circle().fill(theme.secondaryColor).frame(width: 11, height: 11).offset(x: 4.5)
                                    Circle().fill(theme.primaryColor).frame(width: 16, height: 16)
                                        .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                                }
                                .frame(width: 26, alignment: .leading)

                                Text(theme.shortName)
                                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                                    .foregroundStyle(.primary)

                                Spacer()

                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(theme.primaryColor)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(isSelected ? Color.white.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(isSelected ? theme.primaryColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
                            )
                        }
                        .buttonStyle(.hoverPlain)
                    }
                }
            }

            surfaceShadingSection

            // Section C: Live Interactive Component Preview
            VStack(alignment: .leading, spacing: 10) {
                Text("Live Theme Preview")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    // Preview Button
                    Button {} label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.circle.fill")
                            Text("Push (6)")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(state.accentTheme.linearGradient)
                        .foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: state.accentTheme.primaryColor.opacity(0.3), radius: 4, y: 2)
                    }
                    .buttonStyle(.hoverPlain)

                    // Preview Badge
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 11))
                        Text("feature/auth")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(state.accentTheme.primaryColor.opacity(0.15))
                    .foregroundStyle(state.accentTheme.primaryColor)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(state.accentTheme.primaryColor.opacity(0.3), lineWidth: 1)
                    )

                    // Preview Prompt Symbol
                    HStack(spacing: 6) {
                        Text("❯")
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundStyle(state.accentTheme.linearGradient)
                        Text("git commit -m \"feat: new look\"")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    // MARK: - 2. Git Users & Profiles

    private var gitUsersSettingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                headerSection(
                    title: "Git Identities & User Profiles",
                    subtitle: "Configure multiple Git author identities (personal, work, client) with avatars and SSH keys"
                )
                Spacer()

                if !isCreatingProfile && editingProfile == nil {
                    Button {
                        startCreatingProfile()
                    } label: {
                        Label("Add Profile", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Inline Form if creating or editing
            if isCreatingProfile || editingProfile != nil {
                profileEditorForm
            }

            // Profiles list
            VStack(spacing: 12) {
                ForEach(state.gitProfiles) { profile in
                    ProfileRowCardView(
                        profile: profile,
                        isActive: state.activeProfileId == profile.id,
                        state: state,
                        onEdit: { startEditingProfile($0) }
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var profileEditorForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingProfile != nil ? "Edit Git Identity" : "Create New Git Identity")
                .font(.system(size: 13, weight: .bold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Label:")
                        .font(.caption.weight(.medium))
                        .frame(width: 85, alignment: .trailing)
                    TextField("e.g. Work, Personal, OpenSource", text: $formLabel)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Git Name:")
                        .font(.caption.weight(.medium))
                        .frame(width: 85, alignment: .trailing)
                    TextField("e.g. Mona Lisa Octocat", text: $formName)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Git Email:")
                        .font(.caption.weight(.medium))
                        .frame(width: 85, alignment: .trailing)
                    TextField("e.g. mona@example.com", text: $formEmail)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("GitHub:")
                        .font(.caption.weight(.medium))
                        .frame(width: 85, alignment: .trailing)
                    TextField("e.g. octocat (fetches avatar icon)", text: $formGithub)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("SSH Key:")
                        .font(.caption.weight(.medium))
                        .frame(width: 85, alignment: .trailing)
                    TextField("e.g. ~/.ssh/bk1 or ~/.ssh/id_ed25519", text: $formSSH)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    cancelProfileEditing()
                }
                .buttonStyle(.hoverPlain)
                .foregroundStyle(.secondary)

                Button("Save Profile") {
                    saveProfileForm()
                }
                .buttonStyle(.borderedProminent)
                .tint(state.accentTheme.primaryColor)
                .disabled(formName.trimmingCharacters(in: .whitespaces).isEmpty || formEmail.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    private func startCreatingProfile() {
        formLabel = ""
        formName = state.activeProfile.name
        formEmail = ""
        formGithub = state.activeProfile.githubUsername
        formSSH = ""
        editingProfile = nil
        isCreatingProfile = true
    }

    private func startEditingProfile(_ profile: GitUserProfile) {
        editingProfile = profile
        isCreatingProfile = false
        formLabel = profile.label
        formName = profile.name
        formEmail = profile.email
        formGithub = profile.githubUsername
        formSSH = profile.sshKeyPath
    }

    private func cancelProfileEditing() {
        editingProfile = nil
        isCreatingProfile = false
    }

    private func saveProfileForm() {
        let label = formLabel.trimmingCharacters(in: .whitespaces).isEmpty ? "Profile" : formLabel.trimmingCharacters(in: .whitespaces)
        let name = formName.trimmingCharacters(in: .whitespaces)
        let email = formEmail.trimmingCharacters(in: .whitespaces)
        let github = formGithub.trimmingCharacters(in: .whitespaces)
        let ssh = formSSH.trimmingCharacters(in: .whitespaces)

        if let existing = editingProfile {
            var updated = existing
            updated.label = label
            updated.name = name
            updated.email = email
            updated.githubUsername = github
            updated.sshKeyPath = ssh
            state.updateProfile(updated)
        } else {
            let newProfile = GitUserProfile(
                label: label,
                name: name,
                email: email,
                githubUsername: github,
                sshKeyPath: ssh
            )
            state.addProfile(newProfile)
        }
        cancelProfileEditing()
    }

    // MARK: - 2.5 AI & GitHub Copilot

    private var aiCopilotSettingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 1. Hero Header Banner
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(state.accentTheme.linearGradient.opacity(0.18))
                        .frame(width: 44, height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(state.accentTheme.primaryColor.opacity(0.35), lineWidth: 1)
                        )
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(state.accentTheme.linearGradient)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("AI Provider")
                            .font(.system(size: 16, weight: .bold))

                        if state.aiProvider == .githubCopilot {
                            if state.isCopilotConnected {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 6, height: 6)
                                    Text("Copilot Active")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.green)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(Color.green.opacity(0.12))
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(Color.green.opacity(0.25), lineWidth: 1))
                            } else {
                                Text("Offline")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2.5)
                                    .background(Color.white.opacity(0.06))
                                    .clipShape(Capsule())
                            }
                        }
                    }

                    Text("Which AI powers commit messages, PR descriptions and the assistant: your Copilot subscription, GitHub Models, or a local model")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.bottom, 2)

            // 2. AI Provider Selection (Modern 2x2 Grid)
            VStack(alignment: .leading, spacing: 10) {
                Text("Select Provider")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(AIProvider.allCases) { provider in
                        let isSelected = state.aiProvider == provider
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                state.aiProvider = provider
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                ZStack {
                                    Circle()
                                        .fill(isSelected ? Color.white.opacity(0.16) : Color.white.opacity(0.06))
                                        .frame(width: 28, height: 28)
                                    Image(systemName: provider.iconName)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(provider.rawValue)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                                        Spacer()
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 13))
                                                .foregroundStyle(state.accentTheme.primaryColor)
                                        }
                                    }

                                    Text(provider.description)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 64)
                            .background(
                                ZStack {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(state.accentTheme.primaryColor.opacity(0.10))
                                        VStack(spacing: 0) {
                                            LinearGradient(
                                                colors: [Color.white.opacity(0.12), Color.clear],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                            .frame(height: 16)
                                            Spacer()
                                        }
                                    } else {
                                        Color.white.opacity(0.04)
                                    }
                                }
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        isSelected
                                            ? Color.white.opacity(0.35)
                                            : Color.white.opacity(0.08),
                                        lineWidth: 1
                                    )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: Color.clear, radius: 0)
                        }
                        .buttonStyle(.hoverPlain)
                    }
                }
            }

            // 3. Provider Details & Authentication Card
            if state.aiProvider == .githubCopilot {
                VStack(alignment: .leading, spacing: 12) {
                    Text("GitHub Copilot Setup")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        if state.isCopilotConnected {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.green.opacity(0.15))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: "checkmark.shield.fill")
                                        .font(.system(size: 17))
                                        .foregroundStyle(Color.green)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text("Connected with Copilot Subscription")
                                            .font(.system(size: 13, weight: .semibold))
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.green)
                                    }

                                    Text("Active Account: ")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    + Text("@\(state.copilotUsername ?? "user")")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.primary)
                                }

                                Spacer()

                                Button {
                                    state.disconnectCopilot()
                                } label: {
                                    Text("Disconnect")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Color.red.opacity(0.9))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.red.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.red.opacity(0.2), lineWidth: 1))
                                }
                                .buttonStyle(.hoverPlain)
                            }
                            .padding(12)
                            .background(Color.green.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.green.opacity(0.22), lineWidth: 1))

                            copilotQuotaCard
                        } else if state.isDeviceFlowPolling, let code = state.activeDeviceCode {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Authorize GitXX on GitHub")
                                        .font(.system(size: 13, weight: .bold))
                                    Spacer()
                                    ProgressView().scaleEffect(0.65)
                                    Text("Waiting for approval...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text("Enter this one-time code on GitHub to authorize GitXX with Copilot:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 12) {
                                    Text(code.userCode)
                                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                                        .tracking(3)
                                        .foregroundStyle(state.accentTheme.primaryColor)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(Color.primary.opacity(0.06))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))

                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(code.userCode, forType: .string)
                                        state.showToast("Copied \(code.userCode) to clipboard!", type: .info)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "doc.on.doc")
                                            Text("Copy Code")
                                        }
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Open GitHub Page") {
                                        if let url = URL(string: code.verificationUri) {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(state.accentTheme.primaryColor)
                                }
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Seamlessly connects to GitHub Copilot using the official device flow or detects an existing login from your Mac.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 10) {
                                    Button {
                                        state.startDeviceCodeLogin()
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "person.badge.key.fill")
                                            Text("Sign in with GitHub (Copilot)")
                                                .fontWeight(.semibold)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(state.accentTheme.primaryColor)

                                    Button {
                                        state.checkCopilotStatus()
                                        if state.isCopilotConnected {
                                            state.showToast("Detected active Copilot session!", type: .success)
                                        } else {
                                            state.showToast("No active local Copilot session detected on Mac.", type: .info)
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "magnifyingglass")
                                            Text("Auto-detect from Mac")
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }

                        Divider()
                            .padding(.vertical, 2)

                        // Model Selector Row
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Preferred Model")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Active AI model for generating commit summaries and diff analysis")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Picker("", selection: $state.copilotModel) {
                                ForEach(CopilotModel.allCases) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 250)
                        }
                        .padding(.top, 4)
                    }
                    .padding(14)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
                }
            } else if state.aiProvider == .githubModels {
                VStack(alignment: .leading, spacing: 10) {
                    Text("GitHub Models Configuration")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Uses your standard GitHub Personal Access Token to access Azure AI inference models for free.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let token = state.githubToken, !token.isEmpty {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.green)
                                Text("GitHub Token configured: \(String(token.prefix(6)))...")
                                    .font(.caption.weight(.medium))
                            }
                        } else {
                            Text("⚠️ No GitHub Token configured. Please add one in GitHub Accounts & API tab.")
                                .font(.caption)
                                .foregroundStyle(Color.orange)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            } else if state.aiProvider == .ollama {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Local Ollama Configuration")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connects to local Ollama on http://localhost:11434. Ensure Ollama is running (`ollama run llama3.2`).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            // 5. Verification & Test Section
            VStack(alignment: .leading, spacing: 10) {
                Text("Verification & Test")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        runAITest()
                    } label: {
                        HStack(spacing: 6) {
                            if isTestingAI {
                                ProgressView()
                                    .scaleEffect(0.65)
                                Text("Generating...")
                                    .fontWeight(.medium)
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 12))
                                Text("Test AI Generation")
                                    .fontWeight(.medium)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTestingAI || (state.aiProvider == .githubCopilot && !state.isCopilotConnected))

                    if !testAIResult.isEmpty {
                        HStack(spacing: 6) {
                            Text(testAIResult)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(testAIResult.hasPrefix("✓") ? Color.green : Color.red)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(testAIResult.hasPrefix("✓") ? Color.green.opacity(0.08) : Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }

                    Spacer()
                }
                .padding(14)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            }
        }
    }

    // MARK: - AI Commits & Assistant

    private var aiWritingSettingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerSection(
                title: "Commits & Assistant",
                subtitle: "How AI writes your commit messages, and standing instructions for the ⌘I assistant"
            )

            // 4. Commit Message Style & Live Interactive Preview
            VStack(alignment: .leading, spacing: 10) {
                Text("Commit Message Style")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Format Convention")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Structure, prefixing, and formatting applied to commit messages")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Picker("", selection: $state.commitStyle) {
                            ForEach(CommitStyle.allCases) { style in
                                Text(style.rawValue).tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 250)
                    }

                    // Modern Terminal / Code Preview Card
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(Color.red.opacity(0.75)).frame(width: 8, height: 8)
                            Circle().fill(Color.yellow.opacity(0.75)).frame(width: 8, height: 8)
                            Circle().fill(Color.green.opacity(0.75)).frame(width: 8, height: 8)

                            Text("commit message preview")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)

                            Spacer()
                        }

                        Text(state.commitStyle.exampleText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .padding(14)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            }
            .id("commitStyleSection")

            // Assistant chat instructions
            VStack(alignment: .leading, spacing: 10) {
                Text("Assistant Instructions (⌘I chat)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Added to the assistant's system prompt for every chat: team conventions, how you like PR descriptions written, words that mean something specific to you, things it must never do.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $assistantInstructions)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 110, maxHeight: 200)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .topLeading) {
                            if assistantInstructions.isEmpty {
                                Text("e.g. \"Always fill every section of our PR template. Use Jira keys like CB-1234 in titles. Never push to main.\"")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .allowsHitTesting(false)
                            }
                        }
                    Text("A repository's `.github/copilot-instructions.md` is also included automatically when present.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            }

        }
    }

    private func runAITest() {
        isTestingAI = true
        testAIResult = ""

        Task {
            do {
                let testDiff = """
                diff --git a/Sources/Views/Toolbar.swift b/Sources/Views/Toolbar.swift
                + // Add liquid glass buttons
                + Button { state.push() } label: { Text("Push") }
                """
                let msg = try await AICommitService.shared.generateCommitMessage(
                    diff: testDiff,
                    provider: state.aiProvider,
                    style: state.commitStyle,
                    modelName: state.copilotModel.rawValue
                )
                await MainActor.run {
                    self.testAIResult = "✓ \(msg.summary)"
                    self.isTestingAI = false
                }
            } catch {
                await MainActor.run {
                    self.testAIResult = "✗ \(error.localizedDescription)"
                    self.isTestingAI = false
                }
            }
        }
    }

    // MARK: - 3. Terminal & Shell

    private var terminalSettingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerSection(
                title: "Terminal Shell & Aliases",
                subtitle: "Configure your interactive shell environment and custom command aliases"
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Default Shell Environment")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text(state.selectedShell.executablePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Picker("Shell:", selection: $state.selectedShell) {
                    ForEach(TerminalShell.allCases) { shell in
                        Text(shell.rawValue).tag(shell)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                            .font(.system(size: 12))
                        Text(state.selectedShell == .bash
                             ? "Bash aliases and functions from ~/.bash_profile and ~/.bashrc are enabled (shopt -s expand_aliases)."
                             : "Zsh aliases and functions from ~/.zshenv and ~/.zshrc are enabled (setopt aliases).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("All custom aliases (e.g. gs for git status, gtag, custom scripts) execute with full native performance.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Test Command Live Runner
            VStack(alignment: .leading, spacing: 12) {
                Text("Test Shell Command / Alias")
                    .font(.system(size: 13, weight: .bold))

                HStack(spacing: 8) {
                    TextField("Enter command or alias (e.g. gs)", text: $testCommandInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    Button {
                        runTestCommand()
                    } label: {
                        HStack(spacing: 4) {
                            if isRunningTestCommand {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text("Test")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(state.accentTheme.primaryColor)
                    .disabled(isRunningTestCommand || testCommandInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !testCommandResult.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Output:")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            Text(testCommandResult)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 120)
                        .padding(8)
                        .background(Color.black.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func runTestCommand() {
        guard let repo = state.currentRepo else {
            testCommandResult = "No active repository open."
            return
        }
        let cmd = testCommandInput.trimmingCharacters(in: .whitespaces)
        isRunningTestCommand = true
        testCommandResult = ""

        Task {
            do {
                let result = try await GitService.shared.executeShell(command: cmd, in: repo.path, shell: state.selectedShell)
                await MainActor.run {
                    self.isRunningTestCommand = false
                    if result.exitCode == 0 {
                        self.testCommandResult = result.stdout.isEmpty ? "(Success - no output)" : result.stdout
                    } else {
                        self.testCommandResult = "Exit Code \(result.exitCode)\n" + (result.stderr.isEmpty ? result.stdout : result.stderr)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isRunningTestCommand = false
                    self.testCommandResult = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 3. GitHub Accounts & API

    private var githubSettingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerSection(
                title: "GitHub Account",
                subtitle: "Sign in with the browser flow, the GitHub CLI, or a Personal Access Token"
            )

            if state.hasConfiguredGitHubToken {
                connectedAccountCard
            } else {
                notConnectedCard
            }
        }
    }

    // MARK: - API Usage & Network

    private var networkSettingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerSection(
                title: "API Usage & Network",
                subtitle: "GitHub rate limit, cached (304) responses and every request GitXX has made this session"
            )

            // Rate Limit & Quota Consumption Dashboard
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("API Rate Limit & Quota Consumption")
                            .font(.system(size: 13, weight: .bold))
                        Text("Monitor authenticated rate limit points and see how much quota is saved via HTTP 304 caching")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        state.refreshAPILogs()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                            Text("Refresh")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Metric Cards
                HStack(spacing: 10) {
                    // Tile 1: Remaining Quota
                    VStack(alignment: .leading, spacing: 4) {
                        Text("REMAINING QUOTA")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(state.rateLimit.remaining)")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(state.rateLimit.remaining < 500 ? Color.orange : Color.green)
                            Text("/ \(state.rateLimit.limit)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: state.rateLimit.percentRemaining)
                            .tint(state.rateLimit.remaining < 500 ? Color.orange : state.accentTheme.primaryColor)
                            .padding(.top, 2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                    // Tile 2: Quota Spent
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API QUOTA SPENT")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(state.apiLogStats.quotaSpent)")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.primary)
                            Text("pts")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text("Calls costing quota points")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                    // Tile 3: 304 Cached Saved
                    VStack(alignment: .leading, spacing: 4) {
                        Label("304 CACHED SAVED", systemImage: "bolt.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(state.apiLogStats.cached304Count)")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.cyan)
                            Text("saved")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text("0 Quota used (304 Not Mod)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                    // Tile 4: Reset Time
                    VStack(alignment: .leading, spacing: 4) {
                        Text("QUOTA RESETS AT")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(state.rateLimit.resetAt, style: .time)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.primary)
                        Text("Refreshes to 5,000 / hr")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // API Request History & Activity Log
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("API Request Activity Log")
                                .font(.system(size: 13, weight: .bold))

                            Text("\(state.apiRequestLogs.count) requests")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(state.accentTheme.primaryColor.opacity(0.12))
                                .foregroundStyle(state.accentTheme.primaryColor)
                                .clipShape(Capsule())
                        }

                        Text("Complete historical record of outbound requests to GitHub with status and latency")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button {
                            state.copyAPILogsToClipboard()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                                Text("Copy Log")
                                    .font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(state.apiRequestLogs.isEmpty)

                        Button(role: .destructive) {
                            state.clearAPILogs()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                Text("Clear History")
                                    .font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.hoverPlain)
                        .foregroundStyle(.red)
                        .font(.system(size: 11))
                        .disabled(state.apiRequestLogs.isEmpty)
                    }
                }

                // Filter pills & Search bar
                HStack(spacing: 8) {
                    // Filter segments
                    HStack(spacing: 4) {
                        apiFilterButton(title: "All", count: state.apiRequestLogs.count, tag: "all")
                        apiFilterButton(title: "Cached 304", count: state.apiLogStats.cached304Count, tag: "cached")
                        apiFilterButton(title: "GET", count: state.apiRequestLogs.filter { $0.method == "GET" && !$0.isCached304 }.count, tag: "get")
                        apiFilterButton(title: "Writes", count: state.apiRequestLogs.filter { $0.method == "POST" || $0.method == "PATCH" }.count, tag: "write")
                        apiFilterButton(title: "Errors", count: state.apiRequestLogs.filter { $0.statusCode >= 400 || $0.statusCode == 0 }.count, tag: "error")
                    }

                    Spacer()

                    // Search Field
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextField("Filter endpoints...", text: $apiLogSearch)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .frame(width: 140)
                        if !apiLogSearch.isEmpty {
                            Button {
                                apiLogSearch = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.hoverPlain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                }

                // Log Table
                VStack(spacing: 0) {
                    // Table Header
                    HStack(spacing: 8) {
                        Text("TIME")
                            .frame(width: 58, alignment: .leading)
                        Text("METHOD")
                            .frame(width: 52, alignment: .leading)
                        Text("STATUS")
                            .frame(width: 60, alignment: .leading)
                        Text("QUOTA IMPACT")
                            .frame(width: 115, alignment: .leading)
                        Text("LATENCY")
                            .frame(width: 65, alignment: .trailing)
                        Text("SIZE")
                            .frame(width: 60, alignment: .trailing)
                        Text("ENDPOINT")
                            .frame(minWidth: 120, alignment: .leading)
                            .padding(.leading, 8)
                    }
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.04))

                    Divider()

                    if filteredAPILogs.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: state.apiRequestLogs.isEmpty ? "network" : "line.3.horizontal.decrease.circle")
                                .font(.system(size: 26))
                                .foregroundStyle(.secondary.opacity(0.6))
                                .padding(.top, 24)

                            Text(state.apiRequestLogs.isEmpty ? "No API Requests Recorded Yet" : "No Matching Requests Found")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)

                            Text(state.apiRequestLogs.isEmpty
                                 ? "Pull requests, reviews, and CI checks will appear here with live rate limit and HTTP 304 caching statistics."
                                 : "Try clearing the search query or selecting a different filter category.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 340)
                                .padding(.bottom, 24)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredAPILogs.prefix(50))) { entry in
                                apiLogRow(for: entry)
                                Divider().opacity(0.3)
                            }
                        }
                    }
                }
                .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var connectedAccountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(state.accentTheme.primaryColor.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 22))
                        .foregroundStyle(state.accentTheme.primaryColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(state.authenticatedUsername != nil ? "@\(state.authenticatedUsername!)" : "GitHub Connected")
                            .font(.system(size: 14, weight: .bold))

                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text(state.authMethod.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.green.opacity(0.12))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                        Text("Active & secured in macOS Keychain")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        state.startGitHubOAuthFlow()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Re-authorize")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        tokenInput = ""
                        state.saveGitHubToken("")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Sign Out")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider()

            // Manual fallback & Switch Credentials
            DisclosureGroup(
                isExpanded: $showPATSection,
                content: {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Update Personal Access Token manually:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        HStack {
                            SecureField("ghp_xxxxxxxxxxxxxxxxxxxx", text: $tokenInput)
                                .textFieldStyle(.roundedBorder)

                            Button("Save Token") {
                                state.saveGitHubToken(tokenInput, method: .pat)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(state.accentTheme.primaryColor)
                        }

                        if state.detectedCLIToken != nil {
                            HStack(spacing: 8) {
                                Image(systemName: "apple.terminal")
                                    .foregroundStyle(state.accentTheme.primaryColor)
                                Text("GitHub CLI ('gh') session detected")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Switch to CLI Token") {
                                    state.importFromGitHubCLI()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(8)
                            .background(state.accentTheme.primaryColor.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                },
                label: {
                    Text("Manual Token & Switch Credentials")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            )
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
        )
    }

    private var notConnectedCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Hero: OAuth Device Flow
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(state.accentTheme.primaryColor.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: "globe.americas.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(state.accentTheme.primaryColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Sign in with GitHub")
                            .font(.system(size: 14, weight: .bold))
                        Text("RECOMMENDED")
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(state.accentTheme.primaryColor.opacity(0.15))
                            .foregroundStyle(state.accentTheme.primaryColor)
                            .clipShape(Capsule())
                    }

                    Text("Secure browser authorization via GitHub OAuth device flow. No copying tokens or configuring scopes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    state.startGitHubOAuthFlow()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "safari.fill")
                        Text("Sign in with GitHub")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(state.accentTheme.primaryColor)
                .controlSize(.regular)
            }
            .padding(16)
            .background(state.accentTheme.primaryColor.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(state.accentTheme.primaryColor.opacity(0.22), lineWidth: 1)
            )

            // Fallback options
            VStack(alignment: .leading, spacing: 12) {
                if state.detectedCLIToken != nil {
                    HStack(spacing: 12) {
                        Image(systemName: "apple.terminal")
                            .font(.system(size: 16))
                            .foregroundStyle(state.accentTheme.primaryColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("GitHub CLI ('gh') Authenticated")
                                .font(.system(size: 12, weight: .bold))
                            Text("Detected active CLI session on this Mac. Import to connect in 1 click.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Connect with gh CLI") {
                            state.importFromGitHubCLI()
                            tokenInput = state.githubToken ?? ""
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(state.accentTheme.primaryColor)
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }

                // Personal Access Token fallback
                DisclosureGroup(
                    isExpanded: $showPATSection,
                    content: {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Enter a classic or fine-grained Personal Access Token with repo, read:org, and workflow scopes:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)

                            HStack {
                                SecureField("ghp_xxxxxxxxxxxxxxxxxxxx", text: $tokenInput)
                                    .textFieldStyle(.roundedBorder)

                                Button("Save Token") {
                                    state.saveGitHubToken(tokenInput, method: .pat)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(state.accentTheme.primaryColor)
                                .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }

                            Button {
                                if let url = URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org,workflow&description=GitXX") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Generate token on GitHub.com")
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .font(.caption2)
                                .foregroundStyle(state.accentTheme.primaryColor)
                            }
                            .buttonStyle(.hoverPlain)
                        }
                    },
                    label: {
                        HStack(spacing: 6) {
                            Image(systemName: "key.horizontal")
                                .font(.system(size: 11))
                            Text("Or enter a Personal Access Token manually")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                )
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - API Activity Log Helpers

    private var filteredAPILogs: [APIRequestLogEntry] {
        state.apiRequestLogs.filter { entry in
            let matchesCategory: Bool
            switch apiLogFilter {
            case "cached":
                matchesCategory = entry.isCached304
            case "get":
                matchesCategory = entry.method == "GET" && !entry.isCached304
            case "write":
                matchesCategory = entry.method == "POST" || entry.method == "PATCH" || entry.method == "PUT" || entry.method == "DELETE"
            case "error":
                matchesCategory = entry.statusCode >= 400 || entry.statusCode == 0
            default:
                matchesCategory = true
            }

            guard matchesCategory else { return false }

            let query = apiLogSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if query.isEmpty { return true }

            return entry.endpoint.lowercased().contains(query) ||
                   entry.urlString.lowercased().contains(query) ||
                   entry.method.lowercased().contains(query) ||
                   String(entry.statusCode).contains(query) ||
                   (entry.errorDescription?.lowercased().contains(query) ?? false)
        }
    }

    private func apiFilterButton(title: String, count: Int, tag: String) -> some View {
        let isSelected = apiLogFilter == tag
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                apiLogFilter = tag
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.white.opacity(0.25) : Color.white.opacity(0.08))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.white.opacity(0.16) : Color.white.opacity(0.05))
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.hoverPlain)
    }

    @ViewBuilder
    private func apiLogRow(for entry: APIRequestLogEntry) -> some View {
        let isExpanded = expandedLogId == entry.id

        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedLogId = isExpanded ? nil : entry.id
                }
            } label: {
                HStack(spacing: 8) {
                    // Time
                    Text(entry.formattedTime)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)

                    // Method Badge
                    Text(entry.method)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(methodBadgeColor(for: entry.method).opacity(0.15))
                        .foregroundStyle(methodBadgeColor(for: entry.method))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .frame(width: 52, alignment: .leading)

                    // Status Badge
                    Text(entry.statusCode == 0 ? "ERR" : "\(entry.statusCode)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(statusCodeBadgeColor(for: entry).opacity(0.16))
                        .foregroundStyle(statusCodeBadgeColor(for: entry))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .frame(width: 60, alignment: .leading)

                    // Quota Impact
                    HStack(spacing: 3) {
                        if entry.isCached304 {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.yellow)
                            Text("0 (Cached)")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.green)
                        } else if entry.statusCode > 0 && entry.statusCode < 400 {
                            Text("-1 Quota pt")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else if entry.statusCode >= 400 {
                            Text("-1 (HTTP \(entry.statusCode))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.red.opacity(0.85))
                        } else {
                            Text("0 (Failed)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 115, alignment: .leading)

                    // Latency
                    Text(entry.formattedDuration)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 65, alignment: .trailing)

                    // Size
                    Text(entry.formattedSize)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)

                    // Endpoint
                    HStack(spacing: 4) {
                        Text(entry.shortEndpoint)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                    .frame(minWidth: 120, alignment: .leading)
                    .padding(.leading, 8)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)

            // Expanded Details View
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text("Full URL:")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text(entry.urlString)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }

                    if let rem = entry.rateLimitRemaining {
                        HStack {
                            Text("Rate Limit:")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .leading)
                            Text("\(rem) remaining of \(entry.rateLimitLimit ?? 5000)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.green)
                            if let reset = entry.rateLimitReset {
                                HStack(spacing: 3) {
                                    Text("• Resets at")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    Text(reset, style: .time)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if let err = entry.errorDescription, !err.isEmpty {
                        HStack(alignment: .top) {
                            Text("Error:")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.red)
                                .frame(width: 90, alignment: .leading)
                            Text(err)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.20))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
        .background(isExpanded ? Color.white.opacity(0.04) : Color.clear)
    }

    private func methodBadgeColor(for method: String) -> Color {
        switch method {
        case "GET": return Color.blue
        case "POST": return Color.purple
        case "PATCH": return Color.orange
        case "PUT": return Color.indigo
        case "DELETE": return Color.red
        default: return Color.secondary
        }
    }

    private func statusCodeBadgeColor(for entry: APIRequestLogEntry) -> Color {
        if entry.isCached304 {
            return Color.cyan
        } else if entry.statusCode >= 200 && entry.statusCode < 300 {
            return Color.green
        } else if entry.statusCode >= 400 || entry.statusCode == 0 {
            return Color.red
        } else {
            return Color.orange
        }
    }

    // MARK: - 4. Git Engine


    // MARK: - 5. About GitXX

    private var aboutSettingsView: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 10)

            ZStack {
                Circle()
                    .fill(state.accentTheme.linearGradient)
                    .frame(width: 72, height: 72)
                    .shadow(color: state.accentTheme.primaryColor.opacity(0.4), radius: 10, y: 4)

                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(Color.white)
            }

            VStack(spacing: 4) {
                Text("GitXX")
                    .font(.system(size: 22, weight: .black))

                Text("Version 1.0 (Build 2026.09)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("The next-generation native macOS Git GUI client engineered for performance, precision, and beauty.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 10) {
                bulletFeature(
                    icon: "bolt.fill",
                    title: "100% Local Asynchronous Process Runner",
                    desc: "All diffs, staging, branch switches, and commits run via low-overhead macOS Process calls with zero network latency."
                )

                Divider().padding(.vertical, 2)

                bulletFeature(
                    icon: "shippingbox.fill",
                    title: "GraphQL v4 Batching",
                    desc: "PR lists, commit trees, and review threads are fetched in a single consolidated GraphQL batch (cost: only 1 rate point)."
                )

                Divider().padding(.vertical, 2)

                bulletFeature(
                    icon: "lock.shield.fill",
                    title: "Hardware Keychain Encryption",
                    desc: "Access credentials and personal tokens never touch plain disk; they are stored using Apple's Security framework."
                )
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: 520)

            HStack(spacing: 12) {
                badgePill(label: "Apple Silicon Native")
                badgePill(label: "SwiftUI + AppKit")
                badgePill(label: "Zero Webview")
            }
            .padding(.top, 4)

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    // MARK: - Helper Views

    private func headerSection(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func bulletFeature(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(state.accentTheme.linearGradient)
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func badgePill(label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
    }

    // MARK: - Copilot Quota Card
    @ViewBuilder
    private var copilotQuotaCard: some View {
        let quota = state.copilotQuota
        let isUnlimited = quota?.isUnlimited ?? false
        let chatLimit = quota?.chatQuotaLimit ?? 200
        let consumed = state.appAIConsumedCount
        let remaining = isUnlimited ? nil : max(0, chatLimit - consumed)

        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(state.accentTheme.primaryColor.opacity(0.18))
                        .frame(width: 28, height: 28)
                    Image(systemName: "gauge.with.needle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(state.accentTheme.primaryColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text("Copilot Quota & Usage")
                            .font(.system(size: 13, weight: .bold))

                        Text(quota?.planDisplayName ?? "Copilot Active")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(state.accentTheme.primaryColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(state.accentTheme.primaryColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Text("Live consumption and remaining quota for this billing cycle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    state.refreshCopilotQuota()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(state.isRefreshingQuota ? 360 : 0))
                            .animation(state.isRefreshingQuota ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: state.isRefreshingQuota)
                        Text(state.isRefreshingQuota ? "Refreshing..." : "Refresh Quota")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.hoverPlain)
                .disabled(state.isRefreshingQuota)
            }

            // 3 Metric Stat Tiles
            HStack(spacing: 10) {
                // Tile 1: Consumed from GitXX
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                        Text("Consumed in GitXX")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(consumed)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary)
                    Text("Commit messages generated")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))

                // Tile 2: Remaining Quota
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.green)
                        Text("Remaining Available")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if isUnlimited {
                        HStack(spacing: 3) {
                            Text("Unlimited")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.green)
                            Text("∞")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(Color.green)
                        }
                    } else if let rem = remaining {
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            Text("\(rem)")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(rem < 20 ? Color.orange : Color.green)
                            Text("/ \(chatLimit)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Active")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.primary)
                    }

                    Text(isUnlimited ? "No monthly chat cap" : "Chat requests remaining")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))

                // Tile 3: Reset Cycle Date
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 10))
                            .foregroundStyle(state.accentTheme.primaryColor)
                        Text("Billing Reset Date")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Text(formattedQuotaResetDate(quota?.resetDate))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    Text(quotaResetDaysRemainingText(quota?.resetDate))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            }

            // Visual Progress Meter (for limited quotas) or Unlimited Banner
            if !isUnlimited, chatLimit > 0 {
                let fraction = min(1.0, max(0.0, Double(consumed) / Double(chatLimit)))
                let percentStr = String(format: "%.1f%%", fraction * 100)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("GitXX Usage: \(consumed) of \(chatLimit) requests (\(percentStr))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(remaining ?? 0) remaining")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(fraction > 0.85 ? Color.orange : state.accentTheme.primaryColor)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 6)

                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: fraction > 0.85
                                            ? [Color.orange, Color.red]
                                            : [state.accentTheme.primaryColor, Color.teal],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(6, geo.size.width * CGFloat(fraction)), height: 6)
                        }
                    }
                    .frame(height: 6)
                }
                .padding(.top, 2)
            } else if isUnlimited {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.green)
                    Text("Your \(quota?.planDisplayName ?? "Copilot Individual") plan includes unlimited chat inferences. GitXX requests are not constrained by a monthly limit.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(Color.green.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Footer reset button
            HStack {
                Spacer()
                Button {
                    state.resetAppAIConsumption()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                        Text("Reset GitXX local usage counter")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverPlain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func formattedQuotaResetDate(_ date: Date?) -> String {
        guard let date = date else { return "Monthly Cycle" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func quotaResetDaysRemainingText(_ date: Date?) -> String {
        guard let date = date else { return "Refreshes automatically" }
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: Date(), to: date)
        let days = max(0, components.day ?? 0)
        if days == 0 {
            return "Resets today"
        } else if days == 1 {
            return "Resets tomorrow"
        } else {
            return "\(days) days remaining"
        }
    }
}

// MARK: - Profile Row Card View

private struct ProfileRowCardView: View {
    let profile: GitUserProfile
    let isActive: Bool
    @ObservedObject var state: AppState
    let onEdit: (GitUserProfile) -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            UserAvatarView(profile: profile, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(profile.label)
                        .font(.system(size: 14, weight: .bold))
                        .fixedSize()

                    if isActive {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                            Text("ACTIVE")
                        }
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.12))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                        )
                        .fixedSize()
                    }
                }

                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize()

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text(profile.email)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                HStack(spacing: 12) {
                    if !profile.githubUsername.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 10))
                            Text("@\(profile.githubUsername)")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    }

                    if !profile.sshKeyPath.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 9))
                            Text(profile.sshKeyPath)
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                    }
                }
            }

            Spacer(minLength: 20)

            // Triple dots options menu - aligned flush to the right edge
            Menu {
                Button("Apply Globally (git config --global)") {
                    state.switchProfile(profile, global: true)
                }
                if !profile.sshKeyPath.isEmpty {
                    Button("Run ssh-add Now") {
                        Task {
                            let res = await GitService.shared.addSSHKey(path: profile.sshKeyPath)
                            state.showToast(res.message, type: res.success ? .success : .error)
                        }
                    }
                }
                Divider()
                Button("Edit Profile...") {
                    onEdit(profile)
                }
                if state.gitProfiles.count > 1 {
                    Button("Delete Profile", role: .destructive) {
                        state.deleteProfile(id: profile.id)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .iconHover(size: 24)
            .help("Profile options")
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(
            isActive
                ? Color.white.opacity(0.07)
                : (isHovered ? Color.white.opacity(0.04) : Color(NSColor.controlBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isActive
                        ? LinearGradient(
                            colors: [
                                Color.white.opacity(0.32),
                                Color.white.opacity(0.12)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        : LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.20 : 0.08),
                                Color.white.opacity(isHovered ? 0.08 : 0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            if !isActive {
                withAnimation(.easeInOut(duration: 0.15)) {
                    state.switchProfile(profile, global: false)
                }
            }
        }
        .onHover { isHovered = $0 }
        .help(isActive ? "Currently active profile" : "Click anywhere on this entry to switch to this profile")
    }
}

// MARK: - Shortcuts & CLI Settings Extensions

extension SettingsSheet {
    @ViewBuilder
    private var shortcutsSettingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shortcuts & Keybindings")
                        .font(.system(size: 16, weight: .bold))
                    Text("Customize keyboard shortcuts across the application")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Reset All to Defaults") {
                    state.resetAllShortcuts()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            shortcutLayoutCard

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                TextField("Filter shortcuts...", text: $shortcutSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                if !shortcutSearch.isEmpty {
                    Button {
                        shortcutSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.hoverPlain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            let filtered = state.shortcuts.filter {
                shortcutSearch.isEmpty ||
                $0.title.localizedCaseInsensitiveContains(shortcutSearch) ||
                $0.category.localizedCaseInsensitiveContains(shortcutSearch) ||
                $0.displayString.localizedCaseInsensitiveContains(shortcutSearch)
            }

            VStack(spacing: 8) {
                ForEach(filtered) { item in
                    shortcutCard(item: item)
                }
            }
        }
    }

    private var shortcutLayoutCard: some View {
        let layout = ShortcutLayout(rawValue: shortcutLayoutRaw) ?? .off
        let source = KeyboardLayoutAdapter.currentInputSource()
        let active = layout.matches(inputSourceName: source.name, id: source.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.system(size: 16))
                    .foregroundStyle(state.accentTheme.primaryColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Adapt shortcuts to keyboard layout")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Shortcuts stay on their QWERTY keys. With Dvorak selected, ⌘K is the key labelled K on a QWERTY keyboard, even though it types a different letter.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Picker("", selection: $shortcutLayoutRaw) {
                    ForEach(ShortcutLayout.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            if layout != .off {
                HStack(spacing: 6) {
                    Circle()
                        .fill(active ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(active
                         ? "Active: \(currentInputSourceName.isEmpty ? source.name : currentInputSourceName) is the current input source."
                         : "Idle: the current input source is \(source.name.isEmpty ? "unknown" : source.name). Shortcuts translate while \(layout.title) is selected in the menu bar.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 34)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
        .onReceive(NotificationCenter.default.publisher(for: NSTextInputContext.keyboardSelectionDidChangeNotification)) { _ in
            currentInputSourceName = KeyboardLayoutAdapter.currentInputSource().name
        }
    }

    private func shortcutCard(item: AppShortcutItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.primary)

                    Text(item.category)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)
                }

                Spacer()

                if editingShortcutId == item.id {
                    HStack(spacing: 6) {
                        modifierToggle("⌘", name: "command")
                        modifierToggle("⇧", name: "shift")
                        modifierToggle("⌥", name: "option")
                        modifierToggle("⌃", name: "control")

                        TextField("Key", text: $tempKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 44)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)

                        Button("Save") {
                            let cleanKey = tempKey.trimmingCharacters(in: .whitespaces)
                            if !cleanKey.isEmpty && !tempModifiers.isEmpty {
                                state.updateShortcut(id: item.id, newKey: cleanKey, newModifiers: tempModifiers)
                            }
                            editingShortcutId = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(state.accentTheme.primaryColor)
                        .controlSize(.small)

                        Button("Cancel") {
                            editingShortcutId = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(item.displayString)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                            )

                        if item.isModified {
                            Button("Reset") {
                                state.resetShortcut(id: item.id)
                            }
                            .buttonStyle(.hoverPlain)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(state.accentTheme.primaryColor)
                        }

                        Button {
                            tempKey = item.currentKey
                            tempModifiers = item.currentModifiers
                            editingShortcutId = item.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.secondary)
                                .frame(width: 24, height: 24)
                                .background(Color.white.opacity(0.06))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.hoverPlain)
                        .help("Edit shortcut")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func modifierToggle(_ symbol: String, name: String) -> some View {
        let isSelected = tempModifiers.contains(name)
        return Button {
            if isSelected {
                tempModifiers.removeAll(where: { $0 == name })
            } else {
                tempModifiers.append(name)
            }
        } label: {
            Text(symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 24, height: 22)
                .background(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.white.opacity(0.4) : Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.hoverPlain)
    }

    @ViewBuilder
    private var cliSettingsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Command Line Tool ('gitxx')")
                    .font(.system(size: 16, weight: .bold))
                Text("Launch GitXX directly from your terminal in any repository")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill((state.isCLIInstalled ? Color.green : Color.orange).opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: state.isCLIInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(state.isCLIInstalled ? Color.green : Color.orange)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(state.isCLIInstalled ? "CLI Tool is Active & Installed" : "CLI Tool Not Installed in PATH")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.primary)

                    Text(state.isCLIInstalled ? "Installed at ~/.local/bin/gitxx" : "Link the executable into your PATH to enable the 'gitxx' command")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    state.installCLIInPath()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal.fill")
                        Text(state.isCLIInstalled ? "Re-install / Update CLI" : "Install CLI Tool")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(state.accentTheme.primaryColor)
                .controlSize(.regular)
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 12) {
                Text("HOW TO USE IN TERMINAL")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.8))

                cliExampleCard(
                    title: "Open Current Directory",
                    command: "gitxx",
                    description: "Navigates to repository in current working directory and opens it in GitXX."
                )

                cliExampleCard(
                    title: "Open Specific Repository",
                    command: "gitxx ~/work/my-project",
                    description: "Opens the repository at the given path in GitXX."
                )

                cliExampleCard(
                    title: "Subdirectory Auto-Detection",
                    command: "cd src/views && gitxx",
                    description: "If executed inside any subdirectory of a repo, GitXX automatically discovers the repository root."
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "shield.checkmark.fill")
                        .foregroundStyle(state.accentTheme.primaryColor)
                        .font(.system(size: 12))
                    Text("Single Window & First-Time Confirmation")
                        .font(.system(size: 12, weight: .bold))
                }

                Text("• GitXX strictly enforces a single active window — running 'gitxx' will never spawn unwanted extra tabs or windows.\n• When opening a repository for the first time, GitXX presents a confirmation dialog before adding it to your trusted repositories.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Color.black.opacity(0.24))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("SHELL CONFIGURATION (IF COMMAND NOT FOUND)")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.8))

                Text("If your terminal reports 'command not found: gitxx', ensure '~/.local/bin' is included in your PATH by adding this line to your ~/.zshrc:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack {
                    Text("export PATH=\"$HOME/.local/bin:$PATH\"")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary)

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("export PATH=\"$HOME/.local/bin:$PATH\"", forType: .string)
                        hasCopiedPathExport = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            hasCopiedPathExport = false
                        }
                    } label: {
                        Text(hasCopiedPathExport ? "Copied!" : "Copy")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.black.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func cliExampleCard(title: String, command: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.primary)

            HStack {
                Text(command)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.accentTheme.primaryColor)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.hoverPlain)
                .help("Copy command")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.40))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}




extension SettingsSheet {
    // MARK: - General

    private var generalSettingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerSection(title: "General", subtitle: "Menu bar, keyboard and command line")

            settingsGroup("Menu bar") {
                menuBarIconSection
            }

            settingsGroup("Keyboard") {
                settingsRow(icon: "arrow.right.to.line", title: "Tab moves between all controls",
                            detail: "Tab and ⇧Tab reach every button, checkbox and chip (not just text fields), and Space or Return presses the focused one. Takes effect when GitXX relaunches.") {
                    Toggle("", isOn: $fullKeyboardNavigation).toggleStyle(.switch).labelsHidden()
                }
                if fullKeyboardNavigation != fullKeyboardNavigationAtLaunch {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                        Text("Relaunch GitXX to apply.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 34)
                }
                Divider()
                settingsRow(icon: "command", title: "⌘↩ runs the primary action",
                            detail: "In any dialog, ⌘↩ presses its main button (Create, Merge, Submit…), even while you're typing in a multi-line field.") {
                    EmptyView()
                }
                Divider()
                settingsRow(icon: "keyboard", title: "Shortcuts", detail: "Customize or reset every keyboard shortcut, and adapt them to Dvorak or other layouts.") {
                    Button("Open Shortcuts") { selectedCategory = .shortcuts }
                        .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                }
            }

            settingsGroup("Command line") {
                settingsRow(icon: "apple.terminal", title: "gitxx command",
                            detail: "Open GitXX on any repository from your terminal with `gitxx .`") {
                    Button("Set Up") { selectedCategory = .cli }
                        .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                }
            }
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        }
    }

    private func settingsRow<Trailing: View>(icon: String, title: String, detail: String,
                                             @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(state.accentTheme.primaryColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(.init(detail))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
    }

    var menuBarIconSection: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Show GitXX in the menu bar")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Adds the app icon to the macOS menu bar with recent repositories, New Branch, Fetch/Pull/Push, the AI assistant and Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $menuBarIcon)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    var surfaceShadingSection: some View {
        let theme = state.accentTheme
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Surface Shading")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $surfaceIntensity) {
                    ForEach(SurfaceStyle.Intensity.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }
            Text("The whole window shares one dark shade (no frosted glass): a soft wash of the secondary colour from the top-left and the tertiary from the bottom-right, running continuously across the toolbar, sidebars and content, like Slack's dark theme.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                surfaceColorSlot("Secondary", hex: $surfaceSecondaryHex, fallback: theme.secondaryColor)
                surfaceColorSlot("Tertiary", hex: $surfaceTertiaryHex, fallback: theme.tertiaryColor)
                Spacer()
                Button("Use theme colours") {
                    surfaceSecondaryHex = ""
                    surfaceTertiaryHex = ""
                }
                .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                .disabled(surfaceSecondaryHex.isEmpty && surfaceTertiaryHex.isEmpty)
            }
            VStack(spacing: 0) {
                Color.white.opacity(SurfaceStyle.lift(.toolbar)).frame(height: 24)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(0..<4, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(i == 1 ? theme.primaryColor.opacity(0.9) : Color.primary.opacity(0.12))
                                .frame(width: i == 1 ? 70 : 80, height: 7)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(width: 120, alignment: .leading)
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                    Color.clear
                }
            }
            .background(ThemedWindowWash(theme: theme))
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        }
    }

    private func surfaceColorSlot(_ title: String, hex: Binding<String>, fallback: Color) -> some View {
        let binding = Binding<Color>(
            get: { SurfaceStyle.color(hex: hex.wrappedValue) ?? fallback },
            set: { hex.wrappedValue = SurfaceStyle.hex(of: $0) }
        )
        return HStack(spacing: 6) {
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(hex.wrappedValue.isEmpty ? "Theme default" : "#\(hex.wrappedValue)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
