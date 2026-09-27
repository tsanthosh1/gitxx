import SwiftUI
import AppKit

public enum HelpSection: String, CaseIterable, Identifiable {
    case features = "Features"
    case shortcuts = "Shortcuts"
    case howTo = "How-To Guides"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .features: return "sparkles"
        case .shortcuts: return "command"
        case .howTo: return "book.closed.fill"
        }
    }
}

public struct HelpModalView: View {
    @ObservedObject var state: AppState
    let onDismiss: () -> Void

    @State private var selectedSection: HelpSection = .features
    @State private var searchQuery: String = ""

    public var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
                .overlay(Color.white.opacity(0.08))
            contentScrollView
        }
        .frame(width: 720, height: 540)
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Color.black.opacity(0.35)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.24), Color.white.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.60), radius: 26, x: 0, y: 14)
    }

    @ViewBuilder
    private var headerTitleView: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(state.accentTheme.primaryColor.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(state.accentTheme.primaryColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("GitXX Help & Reference")
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(Color.primary)
                Text("Features, keyboard shortcuts, and workflow guides")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
            }
        }
    }

    @ViewBuilder
    private var sectionPickerView: some View {
        HStack(spacing: 3) {
            ForEach(HelpSection.allCases) { section in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        selectedSection = section
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: section.iconName)
                            .font(.system(size: 10, weight: .semibold))
                        Text(section.rawValue)
                            .font(.system(size: 11.5, weight: selectedSection == section ? .semibold : .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selectedSection == section ? Color.white.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(selectedSection == section ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 12) {
            headerTitleView

            Spacer()

            sectionPickerView

            Button("Done") {
                onDismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .buttonStyle(.borderedProminent)
            .tint(state.accentTheme.primaryColor)
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.25))
    }

    @ViewBuilder
    private var contentScrollView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                switch selectedSection {
                case .features:
                    featuresSection
                case .shortcuts:
                    shortcutsSection
                case .howTo:
                    howToSection
                }
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Features Section

    @ViewBuilder
    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("APPLICATION FUNCTIONALITIES")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.secondary.opacity(0.8))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                featureCard(
                    icon: "arrow.triangle.swap",
                    title: "Changes & Diff Viewer",
                    description: "Stage, unstage, or discard changes per file or in bulk. Supports side-by-side split and unified diff modes.",
                    tag: "⌘1"
                )

                featureCard(
                    icon: "sparkles",
                    title: "AI Commit Generator",
                    description: "Generate conventional commit messages from staged diffs using OpenAI, Anthropic, Gemini, or Ollama.",
                    tag: "AI Powered"
                )

                featureCard(
                    icon: "clock.arrow.circlepath",
                    title: "Commit History",
                    description: "Explore graphical git commit trees, author profiles, full commit metadata, and affected file diffs.",
                    tag: "⌘2"
                )

                featureCard(
                    icon: "arrow.triangle.pull",
                    title: "Pull Requests",
                    description: "Review GitHub pull requests directly, view CI check statuses, checkout PR branches, and leave feedback.",
                    tag: "⌘3"
                )

                featureCard(
                    icon: "terminal.fill",
                    title: "Embedded Terminal",
                    description: "Full interactive terminal with support for zsh, bash, and fish, preloaded with git aliases.",
                    tag: "⌘4"
                )

                featureCard(
                    icon: "command",
                    title: "Command Palette",
                    description: "Instant access to commands, branch switching, repository opening, and raw git commands.",
                    tag: "⌘K"
                )

                featureCard(
                    icon: "apple.terminal",
                    title: "Terminal CLI ('gitxx')",
                    description: "Open any repository in GitXX from your terminal using 'gitxx'. Reuses your single window seamlessly.",
                    tag: "CLI"
                )

                featureCard(
                    icon: "person.crop.circle.badge.checkmark",
                    title: "Multi-Profile Git Identities",
                    description: "Easily toggle between Work and Personal Git configs (name, email, SSH keys, GPG signing).",
                    tag: "Profiles"
                )
            }
        }
    }

    private func featureCard(icon: String, title: String, description: String, tag: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state.accentTheme.primaryColor)

                Text(title)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color.primary)

                Spacer()

                Text(tag)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.accentTheme.primaryColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(state.accentTheme.primaryColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Shortcuts Section

    @ViewBuilder
    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("KEYBOARD SHORTCUTS")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.8))

                Spacer()

                Button {
                    onDismiss()
                    state.initialPreferencesCategory = "Shortcuts & Keybindings"
                    state.showSettings = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10.5))
                        Text("Customize in Settings →")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(state.accentTheme.primaryColor)
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 6) {
                ForEach(state.shortcuts) { item in
                    HStack(spacing: 12) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.primary)

                        Spacer()

                        Text(item.category)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.secondary.opacity(0.7))

                        Text(item.displayString)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                            )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.24))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
                }
            }
        }
    }

    // MARK: - How-To Guides Section

    @ViewBuilder
    private var howToSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("WORKFLOW GUIDES")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.secondary.opacity(0.8))

            howToCard(
                title: "Opening Repositories from the Terminal",
                steps: [
                    "Ensure 'gitxx' is installed via Settings > Command Line Tool or Command Palette (⌘K).",
                    "Navigate to any repository in Terminal: 'cd ~/work/my-project'.",
                    "Type 'gitxx' and press Enter. GitXX will open that repository in your active window.",
                    "If opened for the first time, a confirmation dialog will ask to trust and open the repository."
                ]
            )

            howToCard(
                title: "Generating AI Commit Messages",
                steps: [
                    "Stage the files you want to commit in the Changes tab (⌘1).",
                    "Click the '✨ AI' button in the commit box header or press ⌘I.",
                    "Review the generated commit summary and description, make any edits, and commit with ⌘Enter."
                ]
            )

            howToCard(
                title: "Configuring Work vs Personal Git Profiles",
                steps: [
                    "Open Preferences (⌘,) and select 'Git Users & Profiles'.",
                    "Add profiles with specific names, email addresses, and SSH keys.",
                    "Click the user avatar in the top-right toolbar anytime to switch your active profile."
                ]
            )
        }
    }

    private func howToCard(title: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(state.accentTheme.primaryColor)

                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(state.accentTheme.primaryColor)
                            .frame(width: 16, alignment: .leading)

                        Text(step)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.28))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
