import SwiftUI

/// GitHub-style right sidebar for the conversation tab: merge status, reviewers with verdicts,
/// labels and keyboard shortcuts.
struct PRConversationSidebar: View {
    @ObservedObject var state: AppState
    let pr: PullRequest

    @State private var showLabelPicker = false

    private var meta: PRDetailMeta? {
        guard let m = state.prMeta, m.prNumber == pr.number else { return nil }
        return m
    }

    private var readiness: PRMergeReadiness {
        PRMergeReadiness.evaluate(pr: pr, checks: state.prChecks, timeline: state.prTimeline)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                mergeStatusSection
                sectionDivider
                reviewersSection
                sectionDivider
                labelsSection
                sectionDivider
                shortcutsSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 272)
        .background(Color(red: 13/255, green: 17/255, blue: 23/255))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
            .padding(.vertical, 12)
    }

    private func sectionHeader(_ title: String, trailing: AnyView? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.bottom, 8)
    }

    // MARK: Merge status

    private var mergeStatusSection: some View {
        let r = readiness
        let rows: [(icon: String, color: Color, text: String)] = {
            var rows: [(String, Color, String)] = []
            switch meta?.reviewDecision ?? "" {
            case "APPROVED": rows.append(("checkmark.circle.fill", .green, "Approved"))
            case "CHANGES_REQUESTED": rows.append(("xmark.circle.fill", .red, "Changes requested"))
            case "REVIEW_REQUIRED": rows.append(("exclamationmark.circle.fill", .orange, "Review required"))
            default:
                switch pr.reviewVerdict {
                case .approved: rows.append(("checkmark.circle.fill", .green, "Approved"))
                case .changesRequested: rows.append(("xmark.circle.fill", .red, "Changes requested"))
                default: rows.append(("circle.dashed", .secondary, "No required reviews"))
                }
            }
            if state.prChecks.isEmpty {
                rows.append(("circle.dashed", .secondary, "No checks reported"))
            } else if r.failedRequired > 0 {
                rows.append(("xmark.circle.fill", .red, "\(r.failedRequired) required check\(r.failedRequired == 1 ? "" : "s") failing"))
            } else if r.pendingRequired > 0 {
                rows.append(("clock.fill", .yellow, "\(r.pendingRequired) required check\(r.pendingRequired == 1 ? "" : "s") running"))
            } else {
                let optional = r.failedOptional > 0 ? " · \(r.failedOptional) optional failing" : ""
                rows.append(("checkmark.circle.fill", .green, "Required checks passed\(optional)"))
            }
            if r.totalThreads > 0 && r.resolutionKnown {
                rows.append(r.unresolvedThreads > 0
                    ? ("bubble.left.fill", .orange, "\(r.unresolvedThreads) of \(r.totalThreads) threads unresolved")
                    : ("checkmark.bubble.fill", .green, "All \(r.totalThreads) threads resolved"))
            }
            if pr.state.isActive {
                if pr.hasConflicts { rows.append(("exclamationmark.triangle.fill", .red, "Merge conflicts")) }
                else if pr.isBehind || (state.prBehindCounts[pr.number] ?? 0) > 0 {
                    let n = state.prBehindCounts[pr.number] ?? 0
                    rows.append(("arrow.down.circle.fill", .orange, n > 0 ? "\(n) commit\(n == 1 ? "" : "s") behind \(pr.baseBranch)" : "Behind \(pr.baseBranch)"))
                }
                else if pr.mergeable == true { rows.append(("checkmark.circle.fill", .green, "No conflicts")) }
            }
            return rows
        }()

        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Merge status")
            Button {
                state.prScrollToMergeBoxRequested = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: row.icon)
                                .font(.system(size: 12))
                                .foregroundStyle(row.color)
                                .frame(width: 16)
                            Text(row.text)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.primary.opacity(0.9))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.035))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(row.color.opacity(0.7)).frame(width: 2)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Jump to the merge box")
        }
    }

    // MARK: Reviewers

    private static let reviewerOrder = ["CHANGES_REQUESTED", "APPROVED", "COMMENTED", "REQUESTED", "DISMISSED"]

    private var reviewers: [PRReviewerStatus] {
        let list = meta?.reviewers ?? fallbackReviewers
        return list.sorted { a, b in
            let ai = Self.reviewerOrder.firstIndex(of: a.state) ?? 9
            let bi = Self.reviewerOrder.firstIndex(of: b.state) ?? 9
            if ai != bi { return ai < bi }
            return a.login.localizedCaseInsensitiveCompare(b.login) == .orderedAscending
        }
    }

    /// Derived from timeline review events until GraphQL metadata arrives.
    private var fallbackReviewers: [PRReviewerStatus] {
        var latest: [String: PRReviewEvent] = [:]
        for item in state.prTimeline {
            if case .reviewEvent(let r) = item, r.authorName != pr.authorName {
                if let existing = latest[r.authorName], existing.submittedAt > r.submittedAt { continue }
                latest[r.authorName] = r
            }
        }
        return latest.values.map { PRReviewerStatus(login: $0.authorName, avatarUrl: $0.authorAvatarUrl, state: $0.state.uppercased()) }
    }

    private var reviewersSection: some View {
        let list = reviewers
        let approved = list.filter { $0.state == "APPROVED" }.count
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Reviewers", trailing: list.isEmpty ? nil : AnyView(
                Text("\(approved)/\(list.filter { !$0.isTeam }.count) approved")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(approved > 0 ? Color.green : Color.secondary)
            ))
            if list.isEmpty {
                Text(meta == nil ? "Loading…" : "No reviews yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(list) { reviewer in
                        reviewerRow(reviewer)
                    }
                }
            }
        }
    }

    private func reviewerRow(_ reviewer: PRReviewerStatus) -> some View {
        HStack(spacing: 8) {
            if reviewer.isTeam {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 9))
                    .frame(width: 20, height: 20)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Circle())
            } else {
                PRAvatarView(authorName: reviewer.login, avatarUrl: reviewer.avatarUrl, size: 20)
            }
            Text(reviewer.login)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: reviewer.stateIcon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(reviewerColor(reviewer))
                .frame(width: 16)
        }
        .help("\(reviewer.login): \(reviewer.stateTitle)")
    }

    private func reviewerColor(_ reviewer: PRReviewerStatus) -> Color {
        switch reviewer.state {
        case "APPROVED": return .green
        case "CHANGES_REQUESTED": return .red
        case "REQUESTED": return .orange
        default: return .secondary
        }
    }

    // MARK: Labels

    private var labelsSection: some View {
        let canEdit = (meta?.canTriage ?? true) && (pr.state.isActive || pr.state == .closed)
        return VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Labels", trailing: canEdit ? AnyView(
                Button {
                    showLabelPicker.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showLabelPicker, arrowEdge: .leading) {
                    PRLabelPickerPopover(state: state)
                }
                .help("Edit labels")
            ) : nil)
            if let labels = meta?.labels, !labels.isEmpty {
                PRSidebarFlowLayout(spacing: 6) {
                    ForEach(labels) { PRLabelPill(label: $0) }
                }
            } else {
                Text(meta == nil ? "Loading…" : "None yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Keyboard")
            let keys: [(String, String)] = [("c · f · s", "Conversation · Files · Checks"), ("g", "Jump to… (↑↓ ↩)"), ("j / k", "Next / previous item"), ("u", "Next unresolved thread"), ("r", "Reply to focused thread"), ("n", "New comment"), ("m", "Merge box"), ("⇧⌘R", "Review"), ("⇧⌘M", "Merge")]
            VStack(alignment: .leading, spacing: 5) {
                ForEach(keys, id: \.0) { key, label in
                    HStack(spacing: 8) {
                        Text(key)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .frame(width: 62, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text(label)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

/// Minimal wrapping layout for label pills and avatars.
struct PRSidebarFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
