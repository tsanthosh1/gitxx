import SwiftUI
import AppKit

public struct WindowTopBarView: View {
    @ObservedObject var state: AppState
    let isReduced: Bool
    @State private var isRepoHovered: Bool = false
    @State private var isBranchHovered: Bool = false

    public var body: some View {
        HStack(spacing: 8) {
            // Space to clear window traffic lights (Close, Minimize, Maximize)
            Spacer()
                .frame(width: 78)

            HStack(spacing: 2) {
                // Back Button (⌘← or ⌘[)
                WindowTopBarIconButton(
                    systemName: "arrow.left",
                    size: .large,
                    helpText: state.canNavigateBack
                        ? "Back to \(state.backStack.last?.title ?? "Previous Page") (⌘←)"
                        : "Back (⌘←)",
                    disabled: !state.canNavigateBack
                ) {
                    state.navigateBack()
                }

                // Forward Button (⌘→ or ⌘])
                WindowTopBarIconButton(
                    systemName: "arrow.right",
                    size: .large,
                    helpText: state.canNavigateForward
                        ? "Forward to \(state.forwardStack.last?.title ?? "Next Page") (⌘→)"
                        : "Forward (⌘→)",
                    disabled: !state.canNavigateForward
                ) {
                    state.navigateForward()
                }

                // Page History Button (⌘E)
                WindowTopBarIconButton(
                    systemName: "clock.arrow.circlepath",
                    helpText: "Page History (⌘E)"
                ) {
                    state.showPageHistoryPopover.toggle()
                }
                .popover(isPresented: $state.showPageHistoryPopover, arrowEdge: .bottom) {
                    PageHistoryPopoverView(state: state)
                }
            }

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 14)
                .opacity(isReduced && !state.showHome ? 1 : 0)

            if isReduced && !state.showHome {
                WindowTopBarIconButton(systemName: "house", helpText: "Home (⇧⌘H)") {
                    withAnimation(.easeInOut(duration: 0.12)) { state.goHome() }
                }

                // Repository Selection (Simple text + chevron, no border)
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        state.showBranchPicker = false
                        state.showRepoPicker.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if state.switchingRepoPath != nil {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "book.closed.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(isRepoHovered ? Color.primary : Color.secondary)
                        }

                        Text(state.currentRepo?.name ?? "No Repository")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isRepoHovered ? Color.white : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(state.showRepoPicker ? 180 : 0))
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isRepoHovered = $0 }
                .help("Switch repository (⌘O)")

                // Slash separator
                Text("/")
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(Color.secondary.opacity(0.4))

                // Branch Selection (Simple text + chevron, no border)
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        state.showRepoPicker = false
                        state.showBranchPicker.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        if state.switchingBranchTo != nil {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 11))
                                .foregroundStyle(isBranchHovered ? Color.primary : Color.secondary)
                        }

                        Text(state.switchingBranchTo ?? state.currentBranch)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isBranchHovered ? Color.white : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(state.showBranchPicker ? 180 : 0))
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isBranchHovered = $0 }
                .help("Switch or create branch (⌘B)")
            }

            Spacer()

            // Right-aligned utility buttons in the title bar
            HStack(spacing: 4) {
                // Copy Page Web Link
                WindowTopBarIconButton(
                    systemName: "link",
                    helpText: "Copy browser link for current page"
                ) {
                    state.copyCurrentBrowserLink()
                }

                // Open in Web Browser
                WindowTopBarIconButton(
                    systemName: "arrow.up.right.square",
                    helpText: "Open current view in browser"
                ) {
                    state.openCurrentInBrowser()
                }

                // Reveal in Finder
                WindowTopBarIconButton(
                    systemName: "folder",
                    helpText: "Reveal repository in Finder"
                ) {
                    if let repoPath = state.currentRepo?.path {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repoPath)
                    }
                }

                // Subtle vertical divider
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)

                // Refresh Repository
                WindowTopBarIconButton(
                    systemName: "arrow.triangle.2.circlepath",
                    helpText: "Refresh repository status (⌘R)"
                ) {
                    state.refreshRepo()
                }

                // Settings
                WindowTopBarIconButton(
                    systemName: "gearshape",
                    helpText: "Settings & Preferences (⌘,)"
                ) {
                    state.showSettings = true
                }

                // Help & Documentation
                WindowTopBarIconButton(
                    systemName: "questionmark.circle",
                    helpText: "Help, Shortcuts & Documentation (⌘/)"
                ) {
                    state.showHelpModal = true
                }
            }
            .padding(.trailing, 12)
        }
        .frame(height: 30)
        .background(WindowDragArea())
        .background(.ultraThinMaterial)
    }
}

// MARK: - Window Top Bar Icon Button

private struct WindowTopBarIconButton: View {
    enum Size { case regular, large }

    let systemName: String
    var size: Size = .regular
    let helpText: String
    var disabled: Bool = false
    let action: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size == .large ? 14 : 11.5, weight: size == .large ? .semibold : .medium))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.30) : (isHovered ? Color.primary : Color.secondary))
                .frame(width: size == .large ? 28 : 24, height: size == .large ? 24 : 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(!disabled && isHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovered = $0 }
        .help(helpText)
    }
}
