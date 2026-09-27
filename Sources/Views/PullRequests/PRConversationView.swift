import SwiftUI
import AppKit

// MARK: - Full Conversation Timeline

public struct PRConversationView: View {
    @ObservedObject var state: AppState
    let pr: PullRequest
    /// Height of the full chrome floating over this view (see `PRConversationChromeContainer`).
    var topInset: CGFloat = 0
    /// Height of the chrome currently on screen; the sidebar follows it as the bars slide away.
    var visibleChromeHeight: CGFloat = 0
    var onChromeHidden: ((Bool) -> Void)? = nil

    @AppStorage("gitxx_pr_sidebar_visible") private var sidebarVisible = true
    private var resolvedFilter: ResolvedFilter { state.prThreadFilter }
    @State private var focusedItemId: String? = nil
    @FocusState private var isTimelineFocused: Bool

    public enum ResolvedFilter: String, CaseIterable {
        case all = "All"
        case unresolved = "Unresolved"
        case resolved = "Resolved"
    }

    // Flatten timeline for keyboard nav
    private var displayedItems: [PRTimelineItem] {
        guard !state.prTimeline.isEmpty else { return [] }
        return state.prTimeline.filter { item in
            if case .reviewThread(let t) = item {
                switch resolvedFilter {
                case .all: return true
                case .unresolved: return !t.isResolved
                case .resolved: return t.isResolved
                }
            }
            return true
        }
    }

    // Count of inline threads
    private var threadCount: Int {
        state.prTimeline.filter {
            if case .reviewThread = $0 { return true }
            return false
        }.count
    }

    private var threadResolutionKnown: Bool {
        state.prTimeline.allSatisfy {
            if case .reviewThread(let t) = $0 { return t.isResolutionKnown }
            return true
        }
    }

    private var unresolvedCount: Int {
        state.prTimeline.filter {
            if case .reviewThread(let t) = $0 { return !t.isResolved }
            return false
        }.count
    }

    public var body: some View {
        HStack(spacing: 0) {
            Group {
                if state.isLoadingPRTimeline && state.prTimeline.isEmpty {
                    timelineLoadingView
                        .padding(24)
                        .padding(.top, topInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if let errMsg = state.prTimelineError {
                    timelineErrorView(message: errMsg)
                        .padding(24)
                        .padding(.top, topInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    // High-performance 120 FPS WebKit GPU hardware-accelerated conversation stream
                    PRConversationWebView(
                        pr: pr,
                        timeline: state.prTimeline,
                        checks: state.prChecks,
                        filter: resolvedFilter,
                        meta: state.prMeta?.prNumber == pr.number ? state.prMeta : nil,
                        scrollToMergeBox: state.prScrollToMergeBoxRequested,
                        onAction: { action in
                            await state.handlePRWebAction(action)
                        },
                        onScrolledToMergeBox: {
                            state.prScrollToMergeBoxRequested = false
                        },
                        topInset: topInset,
                        onChromeHidden: { hidden in onChromeHidden?(hidden) },
                        openNavPanel: state.prNavPanelRequested,
                        onNavPanelOpened: {
                            state.prNavPanelRequested = false
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360)

            if sidebarVisible && !state.isNarrowWidth {
                PRConversationSidebar(state: state, pr: pr)
                    .padding(.top, visibleChromeHeight)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 13/255, green: 17/255, blue: 23/255))
        .onAppear {
            if state.prTimeline.isEmpty && !state.isLoadingPRTimeline {
                state.loadPRTimeline(for: pr)
            }
        }
        .onChange(of: pr.number) { _, _ in
            state.loadPRTimeline(for: pr)
        }
    }

    private func navigateFocus(step: Int, proxy: ScrollViewProxy) {
        let items = displayedItems
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex(where: { $0.id == focusedItemId }) ?? (step > 0 ? -1 : items.count)
        let nextIndex = min(max(currentIndex + step, 0), items.count - 1)
        let target = items[nextIndex]
        focusedItemId = target.id
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(target.id, anchor: .center)
        }
    }

    // MARK: - Error State

    @ViewBuilder
    private func timelineErrorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Failed to load conversation")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 230/255, green: 237/255, blue: 243/255))
                    Text(message)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color(red: 248/255, green: 81/255, blue: 73/255))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    state.loadPRTimeline(for: pr)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(14)
            .background(Color(red: 255/255, green: 160/255, blue: 50/255).opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.25), lineWidth: 1)
            )

            Text("Check Settings → API Log to see the raw response from GitHub.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        }
        .padding(.top, 12)
    }

    // MARK: - Loading Skeleton

    @ViewBuilder
    private var timelineLoadingView: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(alignment: .top, spacing: 14) {
                    Circle()
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.12))
                            .frame(width: 200, height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.08))
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                    }
                }
                .shimmering()
            }
        }
        .padding(.top, 12)
    }

    // MARK: - Timeline Item Router

    @ViewBuilder
    private func timelineItemView(_ item: PRTimelineItem, isLast: Bool) -> some View {
        switch item {
        case .issueComment(let comment):
            PRCommentCardView(
                authorName: comment.authorName,
                authorAvatarUrl: comment.authorAvatarUrl,
                relativeDateString: formatRelativeDate(comment.createdAt),
                markdownContent: comment.body,
                authorAssociation: comment.authorName == pr.authorName ? "Author" : "Contributor",
                showEditedBadge: false,
                editedByBotName: nil,
                isLastInTimeline: isLast
            )
            .padding(.bottom, isLast ? 0 : 20)

        case .reviewEvent(let review):
            ReviewEventRow(review: review, isLast: isLast)
                .padding(.bottom, isLast ? 0 : 16)

        case .reviewThread(let thread):
            ReviewThreadView(thread: thread, prAuthor: pr.authorName)
                .padding(.bottom, isLast ? 0 : 16)

        case .commitPushed(let commits):
            CommitPushRow(commits: commits)
                .padding(.bottom, isLast ? 0 : 16)

        case .merged(let authorName, let mergedAt, let sha):
            StatusEventRow(
                icon: "arrow.triangle.merge",
                color: .purple,
                label: Text("\(authorName) ").bold() + Text("merged commit ") + Text(String(sha.prefix(7))).font(.system(size: 12, design: .monospaced)).bold() + Text(" into the base branch"),
                date: mergedAt
            )
            .padding(.bottom, isLast ? 0 : 10)

        case .closed(let authorName, let closedAt):
            StatusEventRow(
                icon: "xmark.circle",
                color: .red,
                label: Text("\(authorName) ").bold() + Text("closed this pull request"),
                date: closedAt
            )
            .padding(.bottom, isLast ? 0 : 10)

        case .reopened(let authorName, let reopenedAt):
            StatusEventRow(
                icon: "arrow.counterclockwise.circle",
                color: .green,
                label: Text("\(authorName) ").bold() + Text("reopened this pull request"),
                date: reopenedAt
            )
            .padding(.bottom, isLast ? 0 : 10)

        case .labeled(let name, _, let addedAt, let actorName):
            StatusEventRow(
                icon: "tag",
                color: .secondary,
                label: Text("\(actorName) ").bold() + Text("added the ") + Text(name).bold() + Text(" label"),
                date: addedAt
            )
            .padding(.bottom, isLast ? 0 : 8)

        case .readyForReview(let authorName, let at):
            StatusEventRow(
                icon: "eye",
                color: .green,
                label: Text("\(authorName) ").bold() + Text("marked this pull request as ready for review"),
                date: at
            )
            .padding(.bottom, isLast ? 0 : 10)
        }
    }

    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Review Event Banner (Approved / Changes Requested)

private struct ReviewEventRow: View {
    let review: PRReviewEvent
    let isLast: Bool

    @State private var isBodyExpanded: Bool = true

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Avatar column with optional timeline line
            VStack(spacing: 0) {
                PRAvatarView(authorName: review.authorName, avatarUrl: review.authorAvatarUrl, size: 38)
                if !isLast {
                    Rectangle()
                        .fill(Color(red: 48/255, green: 54/255, blue: 61/255).opacity(0.5))
                        .frame(width: 2)
                        .padding(.top, 6)
                }
            }
            .frame(width: 38)

            // Review card
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: review.badgeIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(review.badgeColor)

                    Text(review.authorName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 230/255, green: 237/255, blue: 243/255))

                    Text(review.displayLabel)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))

                    Spacer()

                    // State badge
                    HStack(spacing: 4) {
                        Image(systemName: review.badgeIcon)
                            .font(.system(size: 9))
                        Text(review.verdict.title)
                            .font(.system(size: 10.5, weight: .bold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(review.badgeColor.opacity(0.15))
                    .foregroundStyle(review.badgeColor)
                    .clipShape(Capsule())

                    Text(Self.relativeFormatter.localizedString(for: review.submittedAt, relativeTo: Date()))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    review.badgeColor.opacity(0.06)
                )
                .clipShape(RoundedRectangle(cornerRadius: review.body.isEmpty ? 8 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: review.body.isEmpty ? 8 : 0)
                        .stroke(review.badgeColor.opacity(0.2), lineWidth: 1)
                )

                // Optional body
                if !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if isBodyExpanded {
                        GitHubMarkdownView(markdown: review.body)
                            .padding(14)
                            .background(Color(red: 13/255, green: 17/255, blue: 23/255))
                            .clipShape(
                                .rect(
                                    topLeadingRadius: 0,
                                    bottomLeadingRadius: 8,
                                    bottomTrailingRadius: 8,
                                    topTrailingRadius: 0
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(review.badgeColor.opacity(0.15), lineWidth: 1)
                                    .padding(.top, 8)
                                    .clipped()
                            )
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isBodyExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isBodyExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                            Text(isBodyExpanded ? "Collapse" : "Show review body")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: 960, alignment: .leading)
    }
}

// MARK: - Inline Review Thread

private struct ReviewThreadView: View {
    let thread: PRReviewThread
    let prAuthor: String

    @State private var isCollapsed: Bool = false
    @State private var showAllReplies: Bool = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Indented indicator for inline threads
            VStack(spacing: 0) {
                Spacer().frame(height: 8)
                Image(systemName: thread.isResolved ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(thread.isResolved ? Color.green.opacity(0.7) : Color.orange)
                    .frame(width: 38, height: 22)
            }
            .frame(width: 38)

            // Thread card
            VStack(alignment: .leading, spacing: 0) {
                // File path header
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Text(thread.directoryPath.isEmpty ? "" : thread.directoryPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        + Text(thread.fileDisplayName)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 230/255, green: 237/255, blue: 243/255))

                    if let line = thread.line {
                        Text(":\(line)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if thread.isResolved {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                            Text("Resolved")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .foregroundStyle(Color.green)
                        .clipShape(Capsule())
                    } else if thread.replyCount > 0 {
                        Text("\(thread.replyCount) \(thread.replyCount == 1 ? "reply" : "replies")")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isCollapsed.toggle()
                        }
                    } label: {
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isCollapsed ? "Expand thread" : "Collapse thread")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(red: 22/255, green: 27/255, blue: 34/255))

                Divider()
                    .background(Color(red: 48/255, green: 54/255, blue: 61/255))

                if !isCollapsed {
                    VStack(alignment: .leading, spacing: 0) {
                        // Diff hunk context
                        if let hunk = thread.diffHunk, !hunk.isEmpty {
                            diffHunkView(hunk)
                            Divider()
                                .background(Color(red: 48/255, green: 54/255, blue: 61/255))
                        }

                        // Root comment
                        if let root = thread.firstComment {
                            reviewCommentRow(root, isRoot: true, isLast: thread.replyCount == 0)
                        }

                        // Replies
                        let replies = Array(thread.comments.dropFirst())
                        if !replies.isEmpty {
                            let visibleReplies = showAllReplies ? replies : Array(replies.prefix(2))
                            ForEach(Array(visibleReplies.enumerated()), id: \.element.id) { idx, reply in
                                Divider()
                                    .background(Color(red: 48/255, green: 54/255, blue: 61/255))
                                    .padding(.horizontal, 0)
                                reviewCommentRow(reply, isRoot: false, isLast: idx == visibleReplies.count - 1 && (showAllReplies || replies.count <= 2))
                            }

                            if !showAllReplies && replies.count > 2 {
                                Button {
                                    withAnimation {
                                        showAllReplies = true
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "ellipsis.message")
                                            .font(.system(size: 11))
                                        Text("Show \(replies.count - 2) more \(replies.count - 2 == 1 ? "reply" : "replies")")
                                            .font(.system(size: 11.5, weight: .medium))
                                    }
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                .background(Color(red: 13/255, green: 17/255, blue: 23/255))
                            }
                        }
                    }
                    .background(Color(red: 13/255, green: 17/255, blue: 23/255))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(thread.isResolved
                        ? Color.green.opacity(0.2)
                        : Color(red: 48/255, green: 54/255, blue: 61/255),
                        lineWidth: 1)
            )
        }
        .frame(maxWidth: 960, alignment: .leading)
    }

    @ViewBuilder
    private func diffHunkView(_ hunk: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunk.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    let isAddition = line.hasPrefix("+")
                    let isDeletion = line.hasPrefix("-")
                    let isHeader = line.hasPrefix("@@")
                    HStack(spacing: 0) {
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(
                                isAddition ? Color(red: 63/255, green: 185/255, blue: 80/255) :
                                isDeletion ? Color(red: 248/255, green: 81/255, blue: 73/255) :
                                isHeader ? Color(red: 121/255, green: 192/255, blue: 255/255) :
                                Color(red: 201/255, green: 209/255, blue: 217/255)
                            )
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .background(
                        isAddition ? Color(red: 20/255, green: 60/255, blue: 30/255).opacity(0.5) :
                        isDeletion ? Color(red: 60/255, green: 20/255, blue: 20/255).opacity(0.5) :
                        Color.clear
                    )
                }
            }
        }
        .padding(.vertical, 8)
        .background(Color(red: 13/255, green: 17/255, blue: 23/255))
    }

    @ViewBuilder
    private func reviewCommentRow(_ comment: PRReviewComment, isRoot: Bool, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Comment header
            HStack(spacing: 8) {
                PRAvatarView(authorName: comment.authorName, avatarUrl: comment.authorAvatarUrl, size: 26)

                Text(comment.authorName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(red: 230/255, green: 237/255, blue: 243/255))

                if comment.authorName == prAuthor {
                    Text("Author")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(red: 48/255, green: 54/255, blue: 61/255), lineWidth: 1)
                        )
                        .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                }

                if !isRoot {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if let updated = comment.updatedAt, updated > comment.createdAt.addingTimeInterval(5) {
                    Text("edited")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }

                Text(Self.relativeFormatter.localizedString(for: comment.createdAt, relativeTo: Date()))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))

                if let url = comment.htmlUrl, let nsurl = URL(string: url) {
                    Button {
                        NSWorkspace.shared.open(nsurl)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Open in browser")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // Comment body
            GitHubMarkdownView(markdown: comment.body)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
    }
}

// MARK: - Commit Push Row

private struct CommitPushRow: View {
    let commits: [PRCommitEvent]
    @State private var isExpanded: Bool = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
                    .frame(width: 38, height: 22)
                    .padding(.top, 2)
            }
            .frame(width: 38)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if commits.count == 1 {
                        Group {
                            Text(commits[0].authorName).fontWeight(.semibold)
                            + Text(" pushed ")
                            + Text(commits[0].shortSha)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color(red: 201/255, green: 209/255, blue: 217/255))
                    } else {
                        Button {
                            withAnimation { isExpanded.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                Text("\(commits.count) commits")
                                    .fontWeight(.semibold)
                                + Text(" were pushed")
                            }
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color(red: 201/255, green: 209/255, blue: 217/255))
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    if let last = commits.last {
                        Text(Self.relativeFormatter.localizedString(for: last.authoredAt, relativeTo: Date()))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                // Commit message(s)
                if commits.count == 1 {
                    Text(commits[0].firstLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if isExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(commits) { commit in
                            HStack(spacing: 8) {
                                Text(commit.shortSha)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 52, alignment: .leading)
                                Text(commit.firstLine)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(commit.authorName)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(red: 22/255, green: 27/255, blue: 34/255))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(red: 48/255, green: 54/255, blue: 61/255), lineWidth: 1)
                    )
                }
            }
        }
        .frame(maxWidth: 960, alignment: .leading)
    }
}

// MARK: - Status Event Row (merged / closed / labeled etc.)

private struct StatusEventRow: View {
    let icon: String
    let color: Color
    let label: Text
    let date: Date

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            // Minimal icon in timeline gutter
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 38, alignment: .center)

            label
                .font(.system(size: 12.5))
                .foregroundStyle(Color(red: 201/255, green: 209/255, blue: 217/255))

            Spacer()

            Text(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 960, alignment: .leading)
    }
}

// MARK: - Shimmer modifier (simple pulsing opacity for loading skeleton)

private struct ShimmeringModifier: ViewModifier {
    @State private var phase: Bool = false

    func body(content: Content) -> some View {
        content
            .opacity(phase ? 0.4 : 0.8)
            .animation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: phase
            )
            .onAppear { phase = true }
    }
}

extension View {
    fileprivate func shimmering() -> some View {
        modifier(ShimmeringModifier())
    }
}
