import SwiftUI
import AppKit

public struct ContentView: View {
    @StateObject private var state = AppState()

    /// The PR conversation and files tabs render the app toolbar themselves so it can scroll away with the page.
    private var toolbarOwnedByPRConversation: Bool {
        state.activeTab == .pullRequests && state.selectedPR != nil && [.overview, .filesChanged].contains(state.selectedPRTab)
    }

    public var body: some View {
        GeometryReader { geo in
            let isReduced = geo.size.width < 980

            ZStack {
                // Window configuration hook
                WindowAccessor()
                    .frame(width: 0, height: 0)

                VStack(spacing: 0) {
                    // Application Top Bar (Traffic lights area)
                    WindowTopBarView(state: state, isReduced: isReduced)
                        .zIndex(1)

                    if state.showHome {
                        HomeView(state: state)
                    } else {
                    VStack(spacing: 0) {
                    // Top Navigation Toolbar
                    if !toolbarOwnedByPRConversation {
                        TopToolbarView(state: state, isReduced: isReduced)

                        Divider()
                    }

                    // Navigation: Terminal, Pull Requests (full page browser-style), or Split View (Changes, History)
                    ZStack(alignment: .topLeading) {
                        if state.activeTab == .terminal {
                            TerminalView(state: state)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if state.activeTab == .pullRequests {
                            PullRequestsContainerView(state: state)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if state.activeTab == .actions {
                            ActionsContainerView(state: state, store: state.actions)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            HSplitView {
                                // Left Sidebar Pane
                                sidebarContent
                                    .frame(minWidth: 220, idealWidth: 300, maxWidth: 580)
                                    .themedSurface(state.accentTheme, .sidebar)

                                // Right Main Detail Pane
                                detailContent
                                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }

                        // Mask Overlay & Dropdowns below Toolbar (GitHub Desktop Style)
                        if state.showRepoPicker || state.showBranchPicker {
                            Color.black.opacity(0.45)
                                .ignoresSafeArea()
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.12)) {
                                        state.showRepoPicker = false
                                        state.showBranchPicker = false
                                    }
                                }

                            if state.showRepoPicker {
                                RepositoryPickerPopover(state: state)
                                    .padding(.leading, isReduced ? 200 : TopToolbarView.homeButtonWidth + 1)
                                    .padding(.top, toolbarOwnedByPRConversation ? 53 : 0)
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .top)),
                                        removal: .opacity
                                    ))
                            }

                            if state.showBranchPicker {
                                BranchPickerPopover(state: state)
                                    .padding(.leading, isReduced ? 300 : TopToolbarView.homeButtonWidth + state.repoButtonWidth + 2)
                                    .padding(.top, toolbarOwnedByPRConversation ? 53 : 0)
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .top)),
                                        removal: .opacity
                                    ))
                            }
                        }
                    }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    }
                }
                // Otherwise trackpad scrolls over the palette reach the page underneath.
                .allowsHitTesting(!state.showCommandPalette)

                ActionsFullScreenLogHost(state: state, store: state.actions)
                    .padding(.top, 30)

                // AI assistant bubble / panel (bottom-right, ⌘I)
                AIChatOverlay(state: state)

                // Toast HUD Notification (bottom right, left of the assistant bubble)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ToastNotificationView(state: state)
                            .padding(.trailing, 80)
                            .padding(.bottom, 20)
                    }
                }
                .allowsHitTesting(state.toastMessage != nil)

                // Command Palette (⌘K) Modal Overlay
                if state.showCommandPalette {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture {
                            state.showCommandPalette = false
                        }

                    VStack {
                        Spacer().frame(height: 70)
                        CommandPaletteView(state: state)
                        Spacer()
                    }
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.96).combined(with: .opacity),
                        removal: .scale(scale: 0.96).combined(with: .opacity)
                    ))
                }

                // First-Time Open Confirmation Modal
                if let pendingRepo = state.pendingFirstTimeRepo {
                    Color.black.opacity(0.50)
                        .ignoresSafeArea()
                        .onTapGesture {
                            state.cancelOpenFirstTimeRepo()
                        }

                    FirstTimeRepoConfirmationModal(
                        repo: pendingRepo,
                        accentColor: state.accentTheme.primaryColor,
                        onConfirm: {
                            state.confirmOpenFirstTimeRepo()
                        },
                        onCancel: {
                            state.cancelOpenFirstTimeRepo()
                        }
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .scale(scale: 0.95).combined(with: .opacity)
                    ))
                }

                // CLI Install Success Modal Overlay
                if state.showCLIInstallSuccessModal {
                    Color.black.opacity(0.50)
                        .ignoresSafeArea()
                        .onTapGesture {
                            state.showCLIInstallSuccessModal = false
                        }

                    CLIInstallSuccessModal(
                        accentColor: state.accentTheme.primaryColor,
                        onDismiss: {
                            state.showCLIInstallSuccessModal = false
                        }
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .scale(scale: 0.95).combined(with: .opacity)
                    ))
                }

                // Help & Shortcuts Modal Overlay
                if state.showHelpModal {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .onTapGesture {
                            state.showHelpModal = false
                        }

                    HelpModalView(
                        state: state,
                        onDismiss: {
                            state.showHelpModal = false
                        }
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .scale(scale: 0.95).combined(with: .opacity)
                    ))
                }
            }
            .background(ThemedWindowWash(theme: state.accentTheme).allowsHitTesting(false))
            .environment(\.themeCanvas, geo.frame(in: .global))
            .onAppear {
                state.isReducedWidth = isReduced
                state.isNarrowWidth = geo.size.width < 780
            }
            .onChange(of: isReduced) { _, newValue in
                state.isReducedWidth = newValue
            }
            .onChange(of: geo.size.width < 780) { _, narrow in
                state.isNarrowWidth = narrow
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .ignoresSafeArea(edges: .top)
        // Sheets
        .sheet(isPresented: $state.showStashDrawer) {
            StashDrawerView(state: state)
        }
        .sheet(item: $state.conflictResolverRequest) { request in
            ConflictsListSheet(state: state, request: request)
        }
        .sheet(item: $state.newBranchRequest) { request in
            NewBranchSheet(state: state, request: request)
        }
        .sheet(item: $state.tagTargetCommit) { commit in
            CreateTagSheet(state: state, commit: commit)
        }
        .sheet(item: $state.rebaseTargetCommit) { commit in
            InteractiveRebaseSheet(state: state, target: commit)
        }
        .sheet(isPresented: $state.showSettings) {
            SettingsSheet(state: state)
        }
        .sheet(isPresented: $state.showReviewModal) {
            PRReviewModalView(state: state)
        }
        .sheet(isPresented: $state.showCreatePRSheet) {
            CreatePRSheet(state: state)
        }
        .sheet(item: $state.operationError) { error in
            GitErrorSheet(state: state, error: error)
        }
        .sheet(isPresented: $state.showTerminalResultSheet) {
            TerminalOutputSheet(state: state)
        }
        // Keyboard & Menu Notifications
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettingsAction"))) { notif in
            if let cat = notif.object as? String {
                state.initialPreferencesCategory = cat
            }
            state.showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchTabChanges"))) { _ in
            if state.showHome { state.homeTab = .repositories } else { state.activeTab = .changes }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchTabHistory"))) { _ in
            if state.showHome { state.homeTab = .pullRequests } else { state.activeTab = .history }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DevScene"))) { note in
            DevFixtures.applyScene(note.object as? String ?? "", state: state)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowOpenWith"))) { _ in
            if !state.openWithTargets.isEmpty { state.showOpenWith.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchTabPRs"))) { _ in
            if state.showHome {
                state.homeTab = .conversations
                return
            }
            withAnimation(.easeInOut(duration: 0.15)) {
                state.selectedPR = nil
                state.activeTab = .pullRequests
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleAIChat"))) { _ in
            AIChatStore.shared.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NewBranchAction"))) { _ in
            state.beginNewBranch()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleAIVoice"))) { _ in
            AIChatStore.shared.toggleVoice()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GoHomeAction"))) { _ in
            withAnimation(.easeInOut(duration: 0.12)) { state.goHome() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchTabTerminal"))) { _ in
            state.activeTab = .terminal
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchTabActions"))) { _ in
            state.activeTab = .actions
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenGitHubLinkInApp"))) { note in
            guard let url = note.object as? URL else { return }
            if let target = GitHubURLTarget.parse(url.absoluteString), state.localRepository(owner: target.owner, repo: target.repo) != nil {
                state.openGitHubTarget(target)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RunDemoTerminalCommand"))) { _ in
            state.runTerminalCommand("gs")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleCommandPalette"))) { notif in
            if let initialQuery = notif.object as? String {
                state.commandPaletteInitialQuery = initialQuery
                state.showCommandPalette = true
            } else {
                state.showCommandPalette.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenBranchModal"))) { _ in
            state.showBranchPicker.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenRepoModal"))) { _ in
            if state.showHome { state.homeTab = .repositories } else { state.showRepoPicker = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FetchOriginAction"))) { _ in
            state.fetchOrigin()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PullOriginAction"))) { _ in
            state.pullOrigin()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PushOriginAction"))) { _ in
            state.pushOrigin()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RefreshAction"))) { _ in
            state.refreshRepo()
            if state.activeTab == .pullRequests {
                state.refreshSelectedPR()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowDemoToast"))) { _ in
            state.showToast("Changes pushed to origin/feature/demo-branch", type: .success)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowDemoFirstTimeConfirm"))) { _ in
            let demoPath = NSHomeDirectory() + "/Developer/demo-repo"
            state.pendingFirstTimeRepo = GitRepository(
                name: "demo-repo",
                path: demoPath,
                currentBranch: "main",
                remoteUrl: "https://github.com/octocat/demo-repo.git"
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowHelpModalAction"))) { _ in
            state.showHelpModal = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowCLIModalAction"))) { _ in
            state.showCLIInstallSuccessModal = true
        }
        .onKeyPress(.escape) {
            if state.showHelpModal {
                state.showHelpModal = false
                return .handled
            }
            if state.showCLIInstallSuccessModal {
                state.showCLIInstallSuccessModal = false
                return .handled
            }
            if state.pendingFirstTimeRepo != nil {
                state.cancelOpenFirstTimeRepo()
                return .handled
            }
            if state.showCommandPalette {
                state.showCommandPalette = false
                return .handled
            }
            if state.showRepoPicker {
                withAnimation(.easeInOut(duration: 0.12)) {
                    state.showRepoPicker = false
                }
                return .handled
            }
            if state.showBranchPicker {
                withAnimation(.easeInOut(duration: 0.12)) {
                    state.showBranchPicker = false
                }
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Sidebar Selection

    @ViewBuilder
    private var sidebarContent: some View {
        switch state.activeTab {
        case .changes:
            ChangesSidebarView(state: state)
        case .history:
            CommitLogSidebarView(state: state)
        case .pullRequests, .actions, .terminal:
            EmptyView()
        }
    }

    // MARK: - Detail Selection

    @ViewBuilder
    private var detailContent: some View {
        switch state.activeTab {
        case .changes:
            DiffViewer(state: state)
        case .history:
            CommitDetailView(state: state)
        case .pullRequests, .actions:
            EmptyView()
        case .terminal:
            TerminalView(state: state)
        }
    }
}
