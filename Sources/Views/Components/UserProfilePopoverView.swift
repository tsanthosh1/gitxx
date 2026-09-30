import SwiftUI

public struct UserProfilePopoverView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Git identity")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    openPreferences(PreferenceCategory.general)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.icon(size: 24))
                .help("Settings (⌘,)")
            }
            .padding(.horizontal, 6)

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

            footerRow("Manage Profiles…", icon: "person.2", hint: nil) {
                openPreferences(PreferenceCategory.gitUsers)
            }
            footerRow("Settings…", icon: "gearshape", hint: "⌘,") {
                openPreferences(PreferenceCategory.general)
            }
        }
        .padding(10)
        .frame(width: 320)
        .themedSurface(state.accentTheme, .elevated)
    }

    private func openPreferences(_ category: PreferenceCategory) {
        dismiss()
        state.initialPreferencesCategory = category.rawValue
        state.showSettings = true
    }

    private func footerRow(_ title: String, icon: String, hint: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if let hint {
                    Text(hint)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(ProfileFooterRowStyle())
    }
}

/// Avatar of the active git identity; opens the profile switcher.
struct ProfileAvatarButton: View {
    @ObservedObject var state: AppState
    var size: CGFloat = 28
    @State private var showPopover = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            UserAvatarView(profile: state.activeProfile, size: size)
        }
        .buttonStyle(.icon(size: size + 4, cornerRadius: (size + 4) / 2, active: showPopover))
        .help("Git identity: \(state.activeProfile.name) <\(state.activeProfile.email)>. Click to switch.")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            UserProfilePopoverView(state: state)
        }
    }
}

private struct ProfileFooterRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0)),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { hovering = $0 }
                .pointerCursor()
        }
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

                            .lineLimit(1)

                        if !profile.githubUsername.isEmpty {
                            Text("@\(profile.githubUsername)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(isActive ? Color.white.opacity(0.7) : Color.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text(profile.email)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(isActive ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !profile.sshKeyPath.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 8))
                            Text((profile.sshKeyPath as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(isActive ? Color.white.opacity(0.6) : Color.secondary.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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
        .buttonStyle(.hoverPlain)
        .onHover { isHovered = $0 }
    }
}
