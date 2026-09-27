import SwiftUI

public struct UserProfilePopoverView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Profiles list options
            VStack(spacing: 3) {
                ForEach(state.gitProfiles) { profile in
                    let isActive = state.activeProfileId == profile.id
                    ProfileOptionRow(
                        profile: profile,
                        isActive: isActive,
                        accentColor: state.accentTheme.primaryColor
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            state.switchProfile(profile)
                        }
                        dismiss()
                    }
                }
            }

            Divider()
                .padding(.vertical, 2)

            // Footer: Manage in Preferences
            Button {
                dismiss()
                state.initialPreferencesCategory = PreferenceCategory.gitUsers.rawValue
                state.showSettings = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                    Text("Manage Profiles in Preferences...")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Profile Option Row

private struct ProfileOptionRow: View {
    let profile: GitUserProfile
    let isActive: Bool
    let accentColor: Color
    let onSelect: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                UserAvatarView(profile: profile, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.label)
                            .font(.system(size: 12.5, weight: isActive ? .bold : .medium))
                            .foregroundStyle(isActive ? Color.white : Color.primary)

                        if !profile.githubUsername.isEmpty {
                            Text("@\(profile.githubUsername)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(isActive ? Color.white.opacity(0.7) : Color.secondary)
                        }
                    }

                    HStack(spacing: 5) {
                        Text(profile.email)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(isActive ? Color.white.opacity(0.85) : Color.secondary)
                            .lineLimit(1)

                        if !profile.sshKeyPath.isEmpty {
                            Text("•")
                                .font(.system(size: 9))
                                .foregroundStyle(isActive ? Color.white.opacity(0.4) : Color.secondary.opacity(0.4))

                            Image(systemName: "key.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(isActive ? Color.white.opacity(0.6) : Color.secondary.opacity(0.6))

                            Text(profile.sshKeyPath)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(isActive ? Color.white.opacity(0.6) : Color.secondary.opacity(0.6))
                        }
                    }
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                Group {
                    if isActive {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                            )
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
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
