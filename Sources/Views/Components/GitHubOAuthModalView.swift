import SwiftUI
import AppKit

public struct GitHubOAuthModalView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var hasCopiedCode: Bool = false

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 20) {
            // Header with GitHub Icon & Gradient Badge
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.5, green: 0.3, blue: 0.95), state.accentTheme.primaryColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 54, height: 54)
                        .shadow(color: state.accentTheme.primaryColor.opacity(0.35), radius: 8, y: 3)

                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text("Sign in with GitHub")
                    .font(.system(size: 17, weight: .bold))

                Text("Connect your GitHub account securely via Device Authorization. No manual token configuration required.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Divider()

            // Main Flow Content
            if let error = state.githubOAuthError {
                // Error State
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button("Try Again") {
                        state.startGitHubOAuthFlow()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(state.accentTheme.primaryColor)
                }
            } else if let userCode = state.githubOAuthUserCode {
                // Active Device Code State
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Text("ENTER THIS CODE ON GITHUB:")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .tracking(1)

                        HStack(spacing: 12) {
                            Text(userCode)
                                .font(.system(size: 28, weight: .heavy, design: .monospaced))
                                .tracking(4)
                                .foregroundStyle(state.accentTheme.primaryColor)
                                .textSelection(.enabled)

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(userCode, forType: .string)
                                hasCopiedCode = true
                                state.showToast("User code '\(userCode)' copied!", type: .info)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: hasCopiedCode ? "checkmark" : "doc.on.doc")
                                    Text(hasCopiedCode ? "Copied" : "Copy")
                                }
                                .font(.system(size: 11.5, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(state.accentTheme.primaryColor.opacity(0.35), lineWidth: 1.5)
                        )

                        Text("Code has been automatically copied to your clipboard.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    // Action Button to Open Browser
                    Button {
                        if let uri = state.githubOAuthVerificationUri, let url = URL(string: uri) {
                            LinkRouter.open(url)
                        } else if let url = URL(string: "https://github.com/login/device") {
                            LinkRouter.open(url)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "safari")
                            Text("Open GitHub Verification in Browser")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(state.accentTheme.primaryColor)
                    .controlSize(.large)

                    // Waiting indicator
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Waiting for authorization in browser...")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            } else {
                // Initial Connecting State
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Requesting authorization code from GitHub...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 24)
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    state.cancelGitHubOAuthFlow()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
