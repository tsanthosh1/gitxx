import SwiftUI
import AppKit

public struct FirstTimeRepoConfirmationModal: View {
    let repo: GitRepository
    let accentColor: Color
    let onConfirm: () -> Void
    let onCancel: () -> Void

    public var body: some View {
        VStack(spacing: 0) {
            // Icon Header
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.16))
                        .frame(width: 52, height: 52)
                    Circle()
                        .strokeBorder(accentColor.opacity(0.35), lineWidth: 1)
                        .frame(width: 52, height: 52)

                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
                .padding(.top, 6)

                VStack(spacing: 4) {
                    Text("Open Repository in GitXX?")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.primary)

                    Text("This repository has not been opened in GitXX before.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 14)

            // Recessed Repository Info Box
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(accentColor)
                        .font(.system(size: 14))

                    Text(repo.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.primary)

                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10, weight: .semibold))
                        Text(repo.currentBranch)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                    .foregroundStyle(Color.secondary)
                }

                Divider()
                    .overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 3) {
                    Text("LOCATION")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.secondary.opacity(0.7))

                    Text(repo.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                if let remote = repo.remoteUrl, !remote.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("REMOTE URL")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.secondary.opacity(0.7))

                        Text(remote)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(14)
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

            // Action Buttons Footer
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Don't Open")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                Button(action: onConfirm) {
                    Text("Open Repository")
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
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 440)
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
}
