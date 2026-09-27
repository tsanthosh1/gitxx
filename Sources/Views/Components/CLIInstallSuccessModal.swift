import SwiftUI
import AppKit

public struct CLIInstallSuccessModal: View {
    let accentColor: Color
    let onDismiss: () -> Void

    @State private var hasCopied: Bool = false

    public var body: some View {
        VStack(spacing: 0) {
            // Header with success badge
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.16))
                        .frame(width: 54, height: 54)
                    Circle()
                        .strokeBorder(Color.green.opacity(0.40), lineWidth: 1.5)
                        .frame(width: 54, height: 54)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.green)
                }
                .padding(.top, 8)

                VStack(spacing: 4) {
                    Text("CLI Tool Installed Successfully")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.primary)

                    Text("The 'gitxx' terminal command is now active and ready to use.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 16)

            // Details and Instructions Box
            VStack(alignment: .leading, spacing: 12) {
                // Location row
                HStack(spacing: 8) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(accentColor)

                    Text("Installed binary:")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.secondary)

                    Spacer()

                    Text("~/.local/bin/gitxx")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                Divider()
                    .overlay(Color.white.opacity(0.08))

                // How to use header
                Text("HOW TO USE IN TERMINAL")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.8))

                // Instruction examples
                VStack(spacing: 8) {
                    instructionRow(
                        command: "gitxx",
                        description: "Opens GitXX in current directory (if inside a git repository)"
                    )

                    instructionRow(
                        command: "gitxx /path/to/repo",
                        description: "Opens any repository directly in GitXX"
                    )

                    instructionRow(
                        command: "gitxx --help",
                        description: "Displays CLI version and command-line usage flags"
                    )
                }

                Divider()
                    .overlay(Color.white.opacity(0.08))

                // Single window tip
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(accentColor)
                        .padding(.top, 1)

                    Text("GitXX reuses your existing active window without creating extra windows or tabs.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(16)
            .background(Color.black.opacity(0.32))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 20)

            Divider()
                .overlay(Color.white.opacity(0.10))

            // Footer action buttons
            HStack(spacing: 12) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("gitxx", forType: .string)
                    hasCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        hasCopied = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(hasCopied ? "Copied!" : "Copy 'gitxx'")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text("Got It")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .shadow(color: accentColor.opacity(0.40), radius: 4, x: 0, y: 1.5)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 480)
        .background(
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Color.black.opacity(0.40)
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
        .shadow(color: Color.black.opacity(0.55), radius: 24, x: 0, y: 12)
    }

    private func instructionRow(command: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(command)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Color.black.opacity(0.40))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )

            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
                .padding(.leading, 2)
        }
    }
}
