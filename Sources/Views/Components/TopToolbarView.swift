import SwiftUI
import AppKit

public struct TopToolbarView: View {
    @ObservedObject var state: AppState
    let isReduced: Bool
    @State private var isRepoHovered: Bool = false
    @State private var isBranchHovered: Bool = false
    @State private var hoveredTab: AppTab? = nil
    @State private var isHomeHovered: Bool = false
    static let homeButtonWidth: CGFloat = 44

    public var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let isUltraCompact = totalWidth < 980
            let isCompact = totalWidth < 1100
            let repoBranchWidth: CGFloat = isUltraCompact ? 125 : (isCompact ? 145 : 165)

            HStack(spacing: 0) {
                if !isReduced {
                    leftRepoBranchSection(isCompact: isCompact, isUltraCompact: isUltraCompact, repoBranchWidth: repoBranchWidth)
                    Spacer(minLength: 6)
                }

                centerNavigationTabs(isCompact: isCompact)

                Spacer(minLength: 6)

                rightUtilitySection(isCompact: isCompact, isUltraCompact: isUltraCompact)
            }
            .frame(height: 52)
        }
        .frame(height: 52)
        .themedSurface(state.accentTheme, .toolbar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }

    // MARK: - Left Section: Repository & Branch Switchers (GitHub Desktop Style)

    @ViewBuilder
    private func leftRepoBranchSection(isCompact: Bool, isUltraCompact: Bool, repoBranchWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { state.goHome() }
            } label: {
                Image(systemName: "house")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isHomeHovered ? Color.primary : Color.primary.opacity(0.75))
                    .frame(width: Self.homeButtonWidth, height: 52)
                    .background(isHomeHovered ? Color.primary.opacity(0.07) : Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .onHover { isHomeHovered = $0 }
            .help("Home: recent repositories and your pull requests (⇧⌘H)")

            selectorDivider(hidden: isHomeHovered || isRepoHovered || state.showRepoPicker)

            selectorButton(
                caption: "Repository",
                title: state.currentRepo?.name ?? "No repository",
                fullTitle: repoTooltip,
                icon: "book.closed.fill",
                busy: state.switchingRepoPath != nil,
                isOpen: state.showRepoPicker,
                isHovered: isRepoHovered,
                showCaption: !isUltraCompact,
                maxTitleWidth: isUltraCompact ? 150 : 260
            ) {
                withAnimation(.easeInOut(duration: 0.12)) {
                    state.showBranchPicker = false
                    state.showRepoPicker.toggle()
                }
            }
            .onHover { isRepoHovered = $0 }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { state.repoButtonWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in state.repoButtonWidth = w }
                }
            )

            selectorDivider(hidden: isRepoHovered || isBranchHovered || state.showRepoPicker || state.showBranchPicker)

            selectorButton(
                caption: state.switchingBranchTo != nil ? "Switching…" : "Branch",
                title: state.switchingBranchTo ?? state.currentBranch,
                fullTitle: "Branch: \(state.currentBranch)\nSwitch or create branch (⌘B)",
                icon: "arrow.triangle.branch",
                busy: state.switchingBranchTo != nil,
                isOpen: state.showBranchPicker,
                isHovered: isBranchHovered,
                showCaption: !isUltraCompact,
                maxTitleWidth: isUltraCompact ? 160 : 300
            ) {
                withAnimation(.easeInOut(duration: 0.12)) {
                    state.showRepoPicker = false
                    state.showBranchPicker.toggle()
                }
            }
            .onHover { isBranchHovered = $0 }

            selectorDivider(hidden: isBranchHovered || state.showBranchPicker)
        }
        .layoutPriority(1)
    }

    private var repoTooltip: String {
        guard let repo = state.currentRepo else { return "Open a repository (⌘O)" }
        let slug = state.gitHubService.parseRepoOwnerAndName(from: repo.remoteUrl).map { "\($0.owner)/\($0.name)" }
        return [slug ?? repo.name, repo.path, "Switch repository (⌘O)"].joined(separator: "\n")
    }

    /// Sizes to the full name; only when the window is too narrow does the name middle-truncate
    /// (keeping both the prefix and the distinguishing suffix, e.g. `chore/…-infra`).
    private func selectorButton(
        caption: String,
        title: String,
        fullTitle: String,
        icon: String,
        busy: Bool = false,
        isOpen: Bool,
        isHovered: Bool,
        showCaption: Bool,
        maxTitleWidth: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                            .transition(.opacity)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary.opacity(0.8))
                            .transition(.opacity)
                    }
                }
                .frame(width: 16, height: 16)
                .animation(.easeInOut(duration: 0.15), value: busy)
                VStack(alignment: .leading, spacing: 0) {
                    if showCaption {
                        Text(caption)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    CappedWidthLayout(maxWidth: maxTitleWidth) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 106, alignment: .leading)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOpen ? Color.white.opacity(0.12) : (isHovered ? Color.white.opacity(0.07) : Color.clear))
            )
            .padding(.horizontal, 4)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .help(fullTitle)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    /// Fades out next to a hovered/open selector so the divider never touches the highlight.
    private func selectorDivider(hidden: Bool) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(hidden ? 0 : 0.12))
            .frame(width: 1, height: 24)
            .animation(.easeOut(duration: 0.1), value: hidden)
    }

    // MARK: - Center Section: Workspace Views Segmented Control

    @ViewBuilder
    private func centerNavigationTabs(isCompact: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(AppTab.allCases) { tab in
                let isSelected = state.activeTab == tab
                let count: Int? = (tab == .changes && !state.files.isEmpty) ? Set(state.files.map(\.path)).count : ((tab == .pullRequests && !state.pullRequests.isEmpty) ? state.pullRequests.count : nil)
                NavTabButton(
                    tab: tab,
                    isSelected: isSelected,
                    isCompact: isCompact,
                    badgeCount: count
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if tab == .pullRequests {
                            state.selectedPR = nil
                        }
                        state.activeTab = tab
                    }
                }
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
        .padding(.leading, isReduced ? 14 : 0)
    }

    // MARK: - Right Section: GitHub Desktop Remote Sync & Tools

    @ViewBuilder
    private func rightUtilitySection(isCompact: Bool, isUltraCompact: Bool) -> some View {
        HStack(spacing: isCompact ? 5 : 6) {
            // GitHub Desktop Style Push / Pull / Fetch Split Button
            GitHubSyncButton(state: state)

            // Command Palette Search Bar (⌘K)
            CommandPaletteSearchBarButton(isCompact: isCompact, isUltraCompact: isUltraCompact) {
                state.showCommandPalette = true
            }

            // Subtle vertical divider
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 20)
                .padding(.horizontal, 1)

            // User Identity Avatar Button
            ProfileAvatarButton(state: state, size: 28)
        }
        .padding(.trailing, isCompact ? 8 : 12)
    }
}

// MARK: - Command Palette Search Bar Button Component

private struct CommandPaletteSearchBarButton: View {
    let isCompact: Bool
    let isUltraCompact: Bool
    let action: () -> Void
    @State private var isHovered: Bool = false

    private var barWidth: CGFloat {
        if isUltraCompact {
            return 120
        } else if isCompact {
            return 140
        } else {
            return 185
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // 1. Prefix Terminal Prompt Icon (> _)
            CommandPalettePromptIcon(size: 11.5)
                .foregroundStyle(isHovered ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.70))
                .padding(.leading, 9)

            // 2. Search Bar Placeholder Text
            Text((isCompact || isUltraCompact) ? "Search..." : "Search or jump to...")
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(isHovered ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.65))
                .lineLimit(1)

            Spacer(minLength: 4)

            // 3. Shortcut Keycap Badge on the right (⌘K)
            HStack(spacing: 2) {
                Image(systemName: "command")
                    .font(.system(size: 9, weight: .medium))
                Text("K")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
            }
            .foregroundStyle(isHovered ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.75))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.10 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(isHovered ? 0.16 : 0.08),
                        lineWidth: 0.5
                    )
            )
            .padding(.trailing, 7)
        }
        .frame(width: barWidth, height: 30)
        .background(
            Capsule()
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    Color.white.opacity(isHovered ? 0.30 : 0.16),
                    lineWidth: 1
                )
        )
        .clipShape(Capsule())
        .overlay(
            NativeSearchBarRepresentable(isHovered: $isHovered, action: action)
                .clipShape(Capsule())
        )
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help("Search or run command (⌘K)")
    }
}

// MARK: - Native Search Bar Mouse Tracking & I-Beam Cursor

private struct NativeSearchBarRepresentable: NSViewRepresentable {
    @Binding var isHovered: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> NativeSearchBarCursorView {
        let view = NativeSearchBarCursorView()
        view.onHoverChange = { hovered in
            self.isHovered = hovered
        }
        view.onClick = action
        return view
    }

    func updateNSView(_ nsView: NativeSearchBarCursorView, context: Context) {
        nsView.onHoverChange = { hovered in
            self.isHovered = hovered
        }
        nsView.onClick = action
    }
}

private final class NativeSearchBarCursorView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.iBeam.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.iBeam.set()
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        onHoverChange?(false)
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            onClick?()
        }
    }
}

// MARK: - Navigation Tab Segment Button

private struct NavTabButton: View {
    let tab: AppTab
    let isSelected: Bool
    let isCompact: Bool
    let badgeCount: Int?
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if tab == .pullRequests {
                    PullRequestGlyph(size: isCompact ? 14 : 13, color: isSelected ? Color.white : (isHovered ? Color.primary : Color.secondary))
                } else {
                    Image(systemName: tab.iconName)
                        .font(.system(size: isCompact ? 13 : 12, weight: isSelected ? .semibold : .medium))
                }

                if !isCompact {
                    Text(tab.rawValue)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if let count = badgeCount, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(isSelected ? Color.white.opacity(0.20) : Color.white.opacity(0.08))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .clipShape(Capsule())
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .offset(y: -1)
            .padding(.horizontal, isCompact ? 8 : 11)
            .frame(height: 32)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .foregroundStyle(isSelected ? Color.white : (isHovered ? Color.primary : Color.secondary))
            .background(backgroundFill)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.hoverPlain)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help("\(tab.rawValue) (⌘\(String(tab.keyboardShortcutKey.character)))")
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var backgroundFill: some View {
        if isSelected {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.15))

                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.42),
                                Color.white.opacity(0.14)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(0.35), radius: 3, x: 0, y: 1.5)
        } else if isHovered {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.06))
        } else {
            Color.clear
        }
    }
}


/// Uses the child's natural width, capped at `maxWidth` and at the space offered by the parent.
struct CappedWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let sub = subviews.first else { return .zero }
        let ideal = sub.sizeThatFits(.unspecified)
        let width = min(ideal.width, maxWidth, proposal.width ?? .infinity)
        return CGSize(width: width, height: sub.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
