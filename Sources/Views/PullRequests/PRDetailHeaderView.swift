import SwiftUI
import AppKit

/// Two-row PR detail header: title, meta line and actions (with a merge-status chip), then tabs with
/// the current tab's tools.
/// Labels, reviewers and participants live in the conversation sidebar (`PRConversationSidebar`).
struct PRDetailHeaderView: View {
    @ObservedObject var state: AppState
    let pr: PullRequest

    @AppStorage("gitxx_pr_sidebar_visible") private var sidebarVisible = true
    @State private var copiedBranch = false
    @State private var confirmClose = false
    @State private var confirmRevert = false
    @State private var showMergeStatus = false

    private var readiness: PRMergeReadiness {
        PRMergeReadiness.evaluate(pr: pr, checks: state.prChecks, timeline: state.prTimeline, meta: state.prMeta)
    }

    /// Navy surface distinct from the neutral app toolbar above and the conversation canvas below.
    static let surface = Color(red: 22/255, green: 27/255, blue: 38/255)

    private var behindBy: Int? {
        state.prBehindCounts[pr.number].flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .padding(.vertical, 8)
            tabBar
                .padding(.leading, 6)
                .padding(.trailing, 14)
        }
        .background(Self.surface)
        .confirmationDialog("Close pull request #\(pr.number)?", isPresented: $confirmClose) {
            Button("Close pull request", role: .destructive) {
                Task { try? await state.closeSelectedPR() }
            }
        } message: {
            Text("The pull request can be reopened later.")
        }
        .confirmationDialog("Revert pull request #\(pr.number)?", isPresented: $confirmRevert) {
            Button("Create revert pull request") {
                Task { try? await state.revertSelectedPR(draft: false) }
            }
            Button("Create as draft") {
                Task { try? await state.revertSelectedPR(draft: true) }
            }
        } message: {
            Text("GitHub creates a new branch with a commit that reverts the changes merged into '\(pr.baseBranch)', and opens a pull request for it.")
        }
    }

    // MARK: Title bar

    private var backButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                state.selectedPR = nil
            }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
        .pointerCursor()
        .help("Back to pull requests (Esc)")
    }

    private var titleBar: some View {
        HStack(alignment: .center, spacing: 8) {
            backButton

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(pr.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .help(pr.title)
                    Text(verbatim: "#\(pr.number)")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                metaLine
            }
            .frame(minWidth: 150, alignment: .leading)

            Spacer(minLength: 12)

            // Steps down (compact chip, Update branch moved to the chip/menu, icon-only buttons) as space runs out.
            ViewThatFits(in: .horizontal) {
                actionButtons(level: 0)
                actionButtons(level: 1)
                actionButtons(level: 2)
                actionButtons(level: 3)
            }
            .layoutPriority(1)
        }
    }

    /// State, author, branches, size and freshness; drops detail as the window narrows.
    private var metaLine: some View {
        ViewThatFits(in: .horizontal) {
            metaContent(showAuthor: true, showStats: true, showUpdated: true)
            metaContent(showAuthor: false, showStats: true, showUpdated: true)
            metaContent(showAuthor: false, showStats: false, showUpdated: true)
            metaContent(showAuthor: false, showStats: false, showUpdated: false)
            stateBadge
        }
        .frame(minWidth: 0, alignment: .leading)
    }

    private func metaContent(showAuthor: Bool, showStats: Bool, showUpdated: Bool) -> some View {
        HStack(spacing: 6) {
            stateBadge
            if showAuthor {
                HStack(spacing: 5) {
                    PRAvatarView(authorName: pr.authorName, avatarUrl: pr.authorAvatarUrl, size: 15)
                    Text(pr.authorName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            branchChip(pr.baseBranch)
            Image(systemName: "arrow.left")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.tertiary)
            branchChip(pr.headBranch)
            copyBranchButton
            if showStats {
                HStack(spacing: 5) {
                    Text("+\(pr.additions.formatted())").foregroundStyle(.green)
                    Text("−\(pr.deletions.formatted())").foregroundStyle(.red)
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            if showUpdated {
                metaDot
                refreshControl
            }
        }
        .fixedSize()
    }

    private var metaDot: some View {
        Circle().fill(Color.secondary.opacity(0.5)).frame(width: 2.5, height: 2.5)
    }

    private var copyBranchButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pr.headBranch, forType: .string)
            copiedBranch = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedBranch = false }
        } label: {
            Image(systemName: copiedBranch ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(copiedBranch ? Color.green : Color.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .help("Copy branch name")
    }

    private var refreshControl: some View {
        HStack(spacing: 2) {
            if let refreshed = state.prLastRefreshedAt {
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text("Updated \(PRDateFormatterHelper.shared.formatRelative(date: refreshed))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .help(pr.state.isActive ? "Last refreshed. Checks, mergeability and comments refresh automatically while this PR is open." : "Last refreshed")
            }
            Button {
                state.refreshSelectedPR()
            } label: {
                PRActionLabel("", systemImage: "arrow.clockwise", isRunning: state.isLoadingPRTimeline || state.isLoadingPRChecks)
                    .font(.system(size: 10.5))
            }
            .buttonStyle(.hoverPlain)
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .help("Refresh this pull request (⌘R)")
        }
    }

    private var stateBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: pr.state.iconName)
                .font(.system(size: 9, weight: .bold))
            Text(pr.state == .draft ? "Draft" : pr.state.rawValue.capitalized)
                .font(.system(size: 10.5, weight: .bold))
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(pr.state.badgeColor.opacity(0.18))
        .foregroundStyle(pr.state.badgeColor)
        .clipShape(Capsule())
        .fixedSize()
    }

    private func branchChip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(Color.secondary.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 200)
            .help(name)
    }

    // MARK: Merge status

    private enum Severity: Int, Comparable {
        case ok, running, warning, blocking
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

        var color: Color {
            switch self {
            case .ok: return .green
            case .running: return .yellow
            case .warning: return .orange
            case .blocking: return .red
            }
        }

        var icon: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .running: return "clock.fill"
            case .warning: return "exclamationmark.circle.fill"
            case .blocking: return "xmark.octagon.fill"
            }
        }
    }

    private enum StatusAction {
        case review, checks, threads, conflicts, updateBranch, readyForReview
    }

    private struct StatusItem: Identifiable {
        let id: String
        let severity: Severity
        /// Chip wording, e.g. "196 behind".
        let short: String
        /// Checklist wording, e.g. "196 commits behind main".
        let detail: String
        let action: StatusAction?
    }

    /// Every merge criterion, passing ones included, most severe first.
    private var statusItems: [StatusItem] {
        let r = readiness
        var items: [StatusItem] = []
        if pr.isDraft {
            items.append(.init(id: "draft", severity: .blocking, short: "Draft", detail: "Draft — not ready for review", action: .readyForReview))
        }
        if pr.hasConflicts {
            items.append(.init(id: "conflicts", severity: .blocking, short: "Conflicts", detail: "Merge conflicts with \(pr.baseBranch)", action: .conflicts))
        } else if pr.mergeable == true {
            items.append(.init(id: "conflicts", severity: .ok, short: "", detail: "No conflicts with \(pr.baseBranch)", action: nil))
        }
        if r.failedRequired > 0 {
            items.append(.init(id: "checks", severity: .blocking, short: "\(r.failedRequired) check\(r.failedRequired == 1 ? "" : "s") failing",
                               detail: "\(r.failedRequired) required check\(r.failedRequired == 1 ? "" : "s") failing", action: .checks))
        } else if r.pendingRequired > 0 {
            items.append(.init(id: "checks", severity: .running, short: "Checks running",
                               detail: "\(r.pendingRequired) required check\(r.pendingRequired == 1 ? "" : "s") running", action: .checks))
        } else if !state.prChecks.isEmpty {
            let optional = r.failedOptional > 0 ? " · \(r.failedOptional) optional failing" : ""
            items.append(.init(id: "checks", severity: .ok, short: "", detail: "Required checks passed\(optional)", action: .checks))
        }
        if let behindBy {
            items.append(.init(id: "behind", severity: .warning, short: "\(behindBy) behind",
                               detail: "\(behindBy) commit\(behindBy == 1 ? "" : "s") behind \(pr.baseBranch)", action: .updateBranch))
        } else if pr.isBehind {
            items.append(.init(id: "behind", severity: .warning, short: "Behind", detail: "Behind \(pr.baseBranch)", action: .updateBranch))
        }
        let decision = state.prMeta?.prNumber == pr.number ? state.prMeta?.reviewDecision : nil
        switch (decision, pr.reviewVerdict) {
        case ("CHANGES_REQUESTED", _), (nil, .changesRequested):
            items.append(.init(id: "review", severity: .blocking, short: "Changes requested", detail: "Changes requested", action: .review))
        case ("APPROVED", _), (nil, .approved):
            items.append(.init(id: "review", severity: .ok, short: "", detail: "Approved", action: nil))
        case ("REVIEW_REQUIRED", _):
            items.append(.init(id: "review", severity: .warning, short: "Review required", detail: "Review required", action: .review))
        default:
            if r.isReviewBlocked {
                items.append(.init(id: "review", severity: .warning, short: "Review required", detail: "Approval required", action: .review))
            }
        }
        if r.isPushRestricted {
            items.append(.init(id: "push", severity: .blocking, short: "Not authorized", detail: "You're not authorized to push to \(pr.baseBranch)", action: nil))
        }
        if r.resolutionKnown && r.totalThreads > 0 {
            items.append(r.unresolvedThreads > 0
                ? .init(id: "threads", severity: .warning, short: "\(r.unresolvedThreads) unresolved",
                        detail: "\(r.unresolvedThreads) of \(r.totalThreads) threads unresolved", action: .threads)
                : .init(id: "threads", severity: .ok, short: "", detail: "All \(r.totalThreads) threads resolved", action: nil))
        }
        return items.enumerated()
            .sorted { $0.element.severity != $1.element.severity ? $0.element.severity > $1.element.severity : $0.offset < $1.offset }
            .map(\.element)
    }

    private func mergeStatusChip(compact: Bool) -> some View {
        let items = statusItems
        let problems = items.filter { $0.severity != .ok }
        let worst = problems.first?.severity ?? .ok
        let summary = problems.isEmpty ? "Ready to merge" : problems.prefix(2).map(\.short).joined(separator: " · ")
        let extra = problems.count > 2 ? " +\(problems.count - 2)" : ""
        return Button {
            showMergeStatus.toggle()
        } label: {
            chipLabel(icon: worst.icon, text: compact ? (problems.isEmpty ? "Ready" : "\(problems.count)") : summary + extra, color: worst.color)
        }
        .buttonStyle(.hoverPlain)
        .pointerCursor()
        .help(problems.isEmpty ? "Ready to merge" : "Merge status: " + problems.map(\.detail).joined(separator: ", "))
        .popover(isPresented: $showMergeStatus, arrowEdge: .bottom) { mergeStatusPopover(items) }
    }

    private func chipLabel(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .opacity(0.7)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(color.opacity(0.14))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.3), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }

    private func mergeStatusPopover(_ items: [StatusItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(readiness.headline)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("into \(pr.baseBranch)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.severity.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(item.severity.color)
                            .frame(width: 18)
                        Text(item.detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(item.severity == .ok ? .secondary : .primary)
                        Spacer(minLength: 16)
                        if let action = item.action { statusActionButton(action) }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                }
            }
            .padding(.vertical, 6)
            Divider()
            Button {
                showMergeStatus = false
                state.selectedPRTab = .overview
                state.prScrollToMergeBoxRequested = true
            } label: {
                Label("Go to merge box", systemImage: "arrow.down.to.line")
                    .font(.system(size: 12))
            }
            .buttonStyle(.hoverPlain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(width: 380)
    }

    @ViewBuilder
    private func statusActionButton(_ action: StatusAction) -> some View {
        let title: String = switch action {
        case .review: "Review"
        case .checks: "View checks"
        case .threads: "Show"
        case .conflicts: "Resolve on GitHub"
        case .updateBranch: "Update branch"
        case .readyForReview: "Ready for review"
        }
        Button {
            showMergeStatus = false
            switch action {
            case .review: state.showReviewModal = true
            case .checks: state.selectedPRTab = .checks
            case .threads:
                state.selectedPRTab = .overview
                state.prThreadFilter = .unresolved
            case .conflicts:
                if let url = URL(string: pr.url + "/conflicts") { NSWorkspace.shared.open(url) }
            case .updateBranch: Task { try? await state.updateSelectedPRBranch() }
            case .readyForReview: Task { try? await state.setSelectedPRDraft(false) }
            }
        } label: {
            Text(title)
        }
        .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
    }

    // MARK: Actions

    private var canUpdateBranch: Bool { pr.isBehind || pr.hasConflicts || behindBy != nil }

    @ViewBuilder
    private func actionButtons(level: Int) -> some View {
        let iconOnly = level >= 3
        HStack(spacing: 6) {
            if pr.state.isActive {
                mergeStatusChip(compact: level >= 1)

                if canUpdateBranch && level < 2 {
                    updateBranchButton
                }

                if pr.isDraft {
                    Button {
                        Task { try? await state.setSelectedPRDraft(false) }
                    } label: {
                        PRActionLabel("Ready for review", systemImage: "eye", isRunning: state.isPRActionRunning("draft"))
                    }
                    .buttonStyle(PRActionButtonStyle(.secondary))
                    .disabled(state.isPRActionRunning("draft"))
                    .help("Mark this draft as ready for review")
                }

                Button {
                    state.showReviewModal = true
                } label: {
                    if iconOnly {
                        Image(systemName: "checkmark.bubble")
                    } else {
                        Label("Review", systemImage: "checkmark.bubble")
                    }
                }
                .buttonStyle(PRActionButtonStyle(reviewIsPrimaryAction ? .primary(Color(red: 35/255, green: 134/255, blue: 54/255)) : .secondary))
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("Approve, request changes, or comment (⇧⌘R)")

                Button {
                    state.showMergeSheet = true
                } label: {
                    PRActionLabel(iconOnly ? "" : "Merge", systemImage: "arrow.triangle.merge", isRunning: state.isPRActionRunning("merge"))
                }
                .buttonStyle(PRActionButtonStyle(readiness.status == .ready ? .primary(Color(red: 35/255, green: 134/255, blue: 54/255)) : .secondary))
                .disabled(pr.hasConflicts || pr.isDraft || state.isPRActionRunning("merge"))
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .help(mergeHelp)
            } else if pr.state == .merged {
                Button {
                    confirmRevert = true
                } label: {
                    PRActionLabel("Revert", systemImage: "arrow.uturn.backward", isRunning: state.isPRActionRunning("revert"))
                }
                .buttonStyle(PRActionButtonStyle(.secondary))
                .disabled(state.isPRActionRunning("revert"))
                .help("Create a pull request that reverts these changes")
            } else if pr.state == .closed {
                Button {
                    Task { try? await state.reopenSelectedPR() }
                } label: {
                    PRActionLabel("Reopen", systemImage: "arrow.uturn.backward", isRunning: state.isPRActionRunning("reopen"))
                }
                .buttonStyle(PRActionButtonStyle(.secondary))
            }

            moreMenu
        }
        .fixedSize()
    }

    private var updateBranchButton: some View {
        Button {
            Task { try? await state.updateSelectedPRBranch() }
        } label: {
            PRActionLabel("Update branch", systemImage: "arrow.triangle.pull", isRunning: state.isPRActionRunning("updateBranch"))
        }
        .buttonStyle(PRActionButtonStyle(.secondary))
        .disabled(state.isPRActionRunning("updateBranch"))
        .help(updateBranchHelp)
    }

    private var updateBranchHelp: String {
        var text = behindBy.map { "'\(pr.headBranch)' is \($0) commit\($0 == 1 ? "" : "s") behind '\(pr.baseBranch)'. Merge the latest changes into this branch." }
            ?? "Merge the latest changes from '\(pr.baseBranch)' into this branch"
        if pr.hasConflicts {
            text += "\nThe branch has merge conflicts with '\(pr.baseBranch)'; they must be resolved before it can be merged."
        }
        return text
    }

    /// Only one green button at a time: Merge when ready, otherwise Review for someone who can still review.
    private var reviewIsPrimaryAction: Bool {
        guard readiness.status != .ready else { return false }
        if let meta = state.prMeta, meta.prNumber == pr.number { return !meta.viewerDidAuthor }
        return true
    }

    private var mergeHelp: String {
        if pr.isDraft { return "Draft pull requests cannot be merged" }
        if pr.hasConflicts { return "Resolve conflicts before merging" }
        if readiness.isMergeBlocked { return "Merge (blocked: \(readiness.blockers.joined(separator: ", ")))" }
        return "Merge into \(pr.baseBranch) (⇧⌘M)"
    }

    private var moreMenu: some View {
        Menu {
            if !pr.url.isEmpty, let url = URL(string: pr.url) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pr.url, forType: .string)
                    state.showToast("Copied PR link", type: .success)
                } label: {
                    Label("Copy Link", systemImage: "link")
                }
            }
            Button {
                state.checkoutBranch(pr.headBranch)
            } label: {
                Label("Checkout Branch Locally", systemImage: "arrow.triangle.branch")
            }
            if pr.state.isActive {
                Divider()
                if canUpdateBranch {
                    Button {
                        Task { try? await state.updateSelectedPRBranch() }
                    } label: {
                        Label("Update Branch", systemImage: "arrow.triangle.pull")
                    }
                }
                if !pr.isDraft {
                    Button {
                        Task { try? await state.setSelectedPRDraft(true) }
                    } label: {
                        Label("Convert to Draft", systemImage: "doc.badge.ellipsis")
                    }
                }
                Button(role: .destructive) {
                    confirmClose = true
                } label: {
                    Label("Close Pull Request", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 14)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PRActionButtonStyle(.secondary))
        .fixedSize()
        .help("More actions")
    }

    // MARK: Tabs

    private var tabBar: some View {
        let fileCount = state.prFiles.isEmpty ? pr.changedFilesCount : state.prFiles.count
        let failing = state.prChecks.filter(\.isFailure).count
        let running = state.prChecks.filter(\.isPending).count
        let unresolved = readiness.unresolvedThreads
        let threadCount = readiness.totalThreads

        func tabs(titles: Bool) -> some View {
            HStack(spacing: 2) {
                tabButton(.overview, title: "Conversation", icon: "bubble.left.and.bubble.right", showTitle: titles,
                          count: pr.commentsCount > 0 ? "\(pr.commentsCount)" : nil,
                          badge: unresolved > 0 ? ("\(unresolved) open", Color.orange) : nil)
                tabDivider
                tabButton(.commits, title: "Commits", icon: "point.3.connected.trianglepath.dotted", showTitle: titles,
                          count: state.prCommits.isEmpty ? nil : "\(state.prCommits.count)", badge: nil)
                tabDivider
                tabButton(.checks, title: "Checks", icon: "checkmark.shield", showTitle: titles,
                          count: state.prChecks.isEmpty ? nil : "\(state.prChecks.count)",
                          badge: failing > 0 ? ("\(failing) failing", Color.red) : (running > 0 ? ("\(running) running", Color.yellow) : nil))
                tabDivider
                tabButton(.filesChanged, title: "Files changed", icon: "doc.on.doc", showTitle: titles,
                          count: fileCount > 0 ? "\(fileCount)" : nil, badge: nil)
            }
            .fixedSize()
        }

        return HStack(spacing: 2) {
            ViewThatFits(in: .horizontal) {
                tabs(titles: true)
                tabs(titles: false)
            }
            .frame(minWidth: 0, alignment: .leading)

            Spacer(minLength: 8)

            if state.selectedPRTab == .overview {
                HStack(spacing: 2) {
                    if threadCount > 0 && readiness.resolutionKnown {
                        threadFilterMenu
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 1, height: 14)
                            .padding(.horizontal, 4)
                    }

                    Button {
                        state.prScrollToMergeBoxRequested = true
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                    .help("Jump to checks & merge box (m)")

                    Button {
                        state.prNavPanelRequested = true
                    } label: {
                        Image(systemName: "list.bullet.indent")
                    }
                    .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                    .help("Jump to a comment, review or thread (g)")

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { sidebarVisible.toggle() }
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .buttonStyle(PRActionButtonStyle(sidebarVisible ? .selected : .subtle, size: .compact))
                    .help(sidebarVisible ? "Hide reviewers & labels sidebar" : "Show reviewers & labels sidebar")
                }
                .fixedSize()
            }
        }
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    private var tabDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 3)
    }

    private var threadFilterMenu: some View {
        Menu {
            Picker("Threads", selection: $state.prThreadFilter) {
                ForEach(PRConversationView.ResolvedFilter.allCases, id: \.self) { f in
                    Text(f == .all ? "All threads" : f.rawValue).tag(f)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(state.prThreadFilter == .all ? "All threads" : state.prThreadFilter.rawValue)
                    .font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .opacity(0.6)
            }
            .foregroundStyle(state.prThreadFilter == .all ? Color.secondary : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(state.prThreadFilter == .all ? Color.clear : Color.primary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.hoverPlain)
        .fixedSize()
        .help("Filter review threads")
    }

    private func tabButton(_ tab: PRDetailTab, title: String, icon: String, showTitle: Bool = true, count: String?, badge: (String, Color)?) -> some View {
        let isSelected = state.selectedPRTab == tab
        let key: String = switch tab {
        case .overview: "c"
        case .commits: "o"
        case .filesChanged: "f"
        case .checks: "s"
        }
        return Button {
            state.selectedPRTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                if showTitle {
                    Text(title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                }
                if let count {
                    Text(count)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(Color.secondary.opacity(0.18))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                }
                if let (text, color) = badge {
                    Text(text)
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(color.opacity(0.16))
                        .foregroundStyle(color)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 35)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? Color.primary.opacity(0.85) : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.hoverPlain)
        .pointerCursor()
        .help("\(title) (\(key))")
    }
}
