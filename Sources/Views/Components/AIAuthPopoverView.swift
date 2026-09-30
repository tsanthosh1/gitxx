import SwiftUI
import AppKit

public struct AIAuthPopoverView: View {
    @ObservedObject var state: AppState

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(state.accentTheme.primaryColor.opacity(0.18))
                        .frame(width: 28, height: 28)
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(state.accentTheme.primaryColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("AI Commit Generator")
                        .font(.system(size: 13, weight: .bold))
                    Text("Powered by \(state.aiProvider.rawValue)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    ForEach(AIProvider.allCases) { provider in
                        Button {
                            state.aiProvider = provider
                        } label: {
                            HStack {
                                Text(provider.rawValue)
                                if state.aiProvider == provider {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }

            Divider()

            if state.aiProvider == .githubCopilot {
                copilotSection
            } else {
                alternativeProviderSection
            }

            Divider()

            // Options: Style & Model
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Commit Style")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $state.commitStyle) {
                        ForEach(CommitStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .scaleEffect(0.9)
                }

                if state.aiProvider == .githubCopilot {
                    HStack {
                        Text("Model")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $state.copilotModel) {
                            ForEach(CopilotModel.allCases) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .scaleEffect(0.9)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .themedSurface(state.accentTheme, .elevated)
    }

    // MARK: - Copilot Section

    @ViewBuilder
    private var copilotSection: some View {
        if state.isCopilotConnected {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Connected as ")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    + Text("@\(state.copilotUsername ?? "user")")
                        .font(.system(size: 12, weight: .semibold))

                    Spacer()

                    Button("Disconnect") {
                        state.disconnectCopilot()
                    }
                    .buttonStyle(.hoverPlain)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.85))
                }
                .padding(8)
                .background(Color.green.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Compact Quota Indicator
                let quota = state.copilotQuota
                let isUnlimited = quota?.isUnlimited ?? false
                let chatLimit = quota?.chatQuotaLimit ?? 200
                let consumed = state.appAIConsumedCount
                let remaining = isUnlimited ? nil : max(0, chatLimit - consumed)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.needle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(state.accentTheme.primaryColor)

                        Text(quota?.planDisplayName ?? "Copilot Active")
                            .font(.system(size: 11, weight: .semibold))

                        Spacer()

                        Text("GitXX: \(consumed) used")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    if isUnlimited {
                        HStack(spacing: 4) {
                            Text("Unlimited chat requests available")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.green)
                            Spacer()
                            Text("∞")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.green)
                        }
                    } else if let rem = remaining {
                        let fraction = min(1.0, max(0.0, Double(consumed) / Double(chatLimit)))
                        HStack {
                            Text("\(rem) of \(chatLimit) remaining")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(rem < 20 ? Color.orange : Color.green)
                            Spacer()
                            if let date = quota?.resetDate {
                                Text("Resets \(formattedDate(date))")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.08))
                                    .frame(height: 4)

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
                                    .frame(width: max(4, geo.size.width * CGFloat(fraction)), height: 4)
                            }
                        }
                        .frame(height: 4)
                    }
                }
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))

                Text("Your GitHub Copilot subscription is ready. Click the AI button in the commit box to generate commit messages.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if state.isDeviceFlowPolling, let code = state.activeDeviceCode {
            VStack(alignment: .leading, spacing: 10) {
                Text("Approve authorization in browser")
                    .font(.system(size: 12, weight: .semibold))

                HStack {
                    Text(code.userCode)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(state.accentTheme.primaryColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.userCode, forType: .string)
                        state.showToast("Copied code to clipboard", type: .info)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy code")
                }

                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Waiting for GitHub approval...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Button("Open Browser Again") {
                    if let url = URL(string: code.verificationUri) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect your GitHub account with active Copilot to generate commit messages without separate API fees.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Button {
                    state.startDeviceCodeLogin()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 12))
                        Text("Connect GitHub Copilot")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(state.accentTheme.linearGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.hoverPlain)

                Button {
                    state.checkCopilotStatus()
                    if state.isCopilotConnected {
                        state.showToast("Found active Copilot login!", type: .success)
                    } else {
                        state.showToast("No active local Copilot session detected.", type: .info)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                        Text("Auto-detect existing login from Mac")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.hoverPlain)
            }
        }
    }

    // MARK: - Alternative Providers Section

    @ViewBuilder
    private var alternativeProviderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.aiProvider.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button("Configure in Preferences...") {
                state.showSettings = true
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

