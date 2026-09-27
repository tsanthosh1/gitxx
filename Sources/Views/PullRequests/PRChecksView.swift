import SwiftUI
import AppKit

/// Checks tab: blocker-ordered list on the left, the selected check's details and job log on the right.
struct PRChecksView: View {
    @ObservedObject var state: AppState
    let pr: PullRequest

    @State private var filter: CheckFilter = .all
    @State private var selectedID: String?

    enum CheckFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case failing = "Failing"
        case pending = "Running"
        case required = "Required"
        var id: String { rawValue }

        func matches(_ check: PRCheckRun) -> Bool {
            switch self {
            case .all: return true
            case .failing: return check.isFailure
            case .pending: return check.isPending
            case .required: return check.isRequired
            }
        }
    }

    private var visibleChecks: [PRCheckRun] {
        PRCheckRun.sortedByBlockerPriority(state.prChecks).filter(filter.matches)
    }

    private var selectedCheck: PRCheckRun? {
        let visible = visibleChecks
        return visible.first { $0.id == selectedID } ?? visible.first
    }

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 240, idealWidth: 380, maxWidth: 560)
            detailPane
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if state.prChecks.isEmpty && !state.isLoadingPRChecks {
                state.loadPRChecks(for: pr)
            }
        }
    }

    // MARK: - List pane

    private var listPane: some View {
        VStack(spacing: 0) {
            summaryHeader
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            if !state.prChecks.isEmpty {
                filterBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider()
            listContent
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    @ViewBuilder
    private var listContent: some View {
        let visible = visibleChecks
        if state.prChecks.isEmpty {
            VStack(spacing: 10) {
                if state.isLoadingPRChecks {
                    ProgressView().controlSize(.small)
                    Text("Fetching CI checks…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("No GitHub Actions checks or commit statuses for this commit.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Query again") { state.loadPRChecks(for: pr) }
                        .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            Text("No \(filter.rawValue.lowercased()) checks")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let groups = PRCheckRun.Group.allCases.compactMap { group -> (PRCheckRun.Group, [PRCheckRun])? in
                let items = visible.filter { $0.group == group }
                return items.isEmpty ? nil : (group, items)
            }
            List(selection: Binding(get: { selectedCheck?.id }, set: { selectedID = $0 })) {
                ForEach(groups, id: \.0) { group, items in
                    Section {
                        ForEach(items) { check in
                            CheckListRow(check: check).tag(check.id)
                        }
                    } header: {
                        groupHeader(group, items: items)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private func groupHeader(_ group: PRCheckRun.Group, items: [PRCheckRun]) -> some View {
        let required = items.filter(\.isRequired).count
        return HStack(spacing: 6) {
            Text(group.title)
            Text("\(items.count)").monospacedDigit().foregroundStyle(.secondary)
            if required > 0 {
                Text("· \(required) required")
                    .foregroundStyle(group == .failing ? Color.red : Color.secondary)
            }
        }
        .font(.system(size: 11, weight: .semibold))
    }

    private var filterBar: some View {
        HStack(spacing: 5) {
            ForEach(CheckFilter.allCases) { item in
                let count = state.prChecks.filter(item.matches).count
                Button {
                    filter = item
                } label: {
                    HStack(spacing: 4) {
                        Text(item.rawValue)
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(PRActionButtonStyle(filter == item ? .selected : .subtle, size: .compact))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var summaryHeader: some View {
        let checks = state.prChecks
        let r = PRMergeReadiness.evaluate(pr: pr, checks: checks, timeline: state.prTimeline)
        let failed = checks.filter(\.isFailure).count
        let pending = checks.filter(\.isPending).count
        let rerunnable = checks.contains { ($0.isFailure || $0.conclusion?.lowercased() == "cancelled") && $0.actionsRunId != nil }

        HStack(alignment: .top, spacing: 10) {
            Group {
                if state.isLoadingPRChecks && checks.isEmpty {
                    ProgressView().controlSize(.small)
                } else if failed > 0 {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                } else if pending > 0 {
                    Image(systemName: "clock.fill").foregroundStyle(.yellow)
                } else if !checks.isEmpty {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 20))
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(headline(r, total: checks.count))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if !checks.isEmpty {
                    HStack(spacing: 8) {
                        Text("\(r.passed) passed").foregroundStyle(.green)
                        if failed > 0 { Text("\(failed) failed").foregroundStyle(.red) }
                        if pending > 0 { Text("\(pending) running").foregroundStyle(.yellow) }
                        Text("· \(r.requiredTotal) required").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                Text("Commit \(pr.headSha.map { String($0.prefix(7)) } ?? pr.headBranch)\(pending > 0 && pr.state.isActive ? " · auto-refreshing" : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    state.loadPRChecks(for: pr)
                } label: {
                    PRActionLabel("Refresh", systemImage: "arrow.clockwise", isRunning: state.isLoadingPRChecks)
                }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                if rerunnable && pr.state.isActive {
                    Button {
                        Task { try? await state.rerunFailedChecks() }
                    } label: {
                        PRActionLabel("Re-run failed", systemImage: "arrow.counterclockwise", isRunning: state.isPRActionRunning("rerun"))
                    }
                    .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                    .disabled(state.isPRActionRunning("rerun"))
                    .help("Re-run failed jobs in their GitHub Actions workflow runs")
                }
            }
        }
    }

    private func headline(_ r: PRMergeReadiness, total: Int) -> String {
        if state.isLoadingPRChecks && total == 0 { return "Fetching CI checks…" }
        if total == 0 { return "No checks reported" }
        if r.failedRequired > 0 { return "\(r.failedRequired) required check\(r.failedRequired == 1 ? "" : "s") failed — merge blocked" }
        if r.pendingRequired > 0 { return "\(r.pendingRequired) required check\(r.pendingRequired == 1 ? " is" : "s are") still running" }
        if r.requiredTotal > 0 && r.failedOptional == 0 && r.pendingOptional == 0 { return "All \(r.requiredTotal) required checks passed" }
        if r.failedOptional > 0 { return "\(r.failedOptional) optional check\(r.failedOptional == 1 ? "" : "s") failed (non-blocking)" }
        if r.pendingOptional > 0 { return "\(r.pendingOptional) check\(r.pendingOptional == 1 ? "" : "s") in progress" }
        return "All \(total) checks passed"
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let check = selectedCheck {
            CheckDetailPane(state: state, check: check, prIsActive: pr.state.isActive)
                .id(check.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text("Select a check to see its details and log")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CheckListRow: View {
    let check: PRCheckRun

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: check.iconName)
                .foregroundStyle(check.statusColor)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(check.displayConclusion).foregroundStyle(check.statusColor)
                    if let duration = check.durationText { Text("· \(duration)") }
                    if let app = check.appName, !app.isEmpty { Text("· \(app)").lineLimit(1) }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            CheckRequirementBadge(isRequired: check.isRequired)
        }
        .padding(.vertical, 3)
        .help(check.name)
    }
}

private struct CheckRequirementBadge: View {
    let isRequired: Bool

    var body: some View {
        Text(isRequired ? "Required" : "Optional")
            .font(.system(size: 9, weight: .bold))
            .textCase(.uppercase)
            .foregroundStyle(isRequired ? Color.red : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background((isRequired ? Color.red : Color.secondary).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct CheckDetailPane: View {
    @ObservedObject var state: AppState
    let check: PRCheckRun
    let prIsActive: Bool

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private var summaryText: String? {
        let parts = [check.outputTitle, check.outputSummary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            if let summary = summaryText {
                Divider()
                ScrollView {
                    Text(Self.markdown(summary))
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .frame(maxHeight: check.actionsJobId == nil ? .infinity : 200)
                .fixedSize(horizontal: false, vertical: check.actionsJobId != nil)
            }
            Divider()
            logSection
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: check.iconName)
                    .foregroundStyle(check.statusColor)
                    .font(.system(size: 22, weight: .bold))
                VStack(alignment: .leading, spacing: 4) {
                    Text(check.name)
                        .font(.system(size: 16, weight: .semibold))
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text(check.displayConclusion)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(check.statusColor)
                        CheckRequirementBadge(isRequired: check.isRequired)
                        if let app = check.appName, !app.isEmpty {
                            Text(app)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                actions
            }
            HStack(spacing: 24) {
                meta("Started", check.startedAt)
                meta("Completed", check.isPending ? nil : check.completedAt)
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.isPending ? "Running for" : "Duration")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(check.durationText ?? "—")
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            .padding(.leading, 34)
        }
    }

    private func meta(_ title: String, _ date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            if let date {
                Text(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
                    .font(.system(size: 12))
                    .help(Self.dateFormatter.string(from: date))
            } else {
                Text("—").font(.system(size: 12))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if prIsActive, check.isRerunnable, let jobId = check.actionsJobId {
                Button {
                    Task { try? await state.rerunCheck(jobId: jobId) }
                } label: {
                    PRActionLabel("Re-run", systemImage: "arrow.counterclockwise", isRunning: state.isPRActionRunning("rerun-\(jobId)"))
                }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                .disabled(state.isPRActionRunning("rerun-\(jobId)"))
                .help("Re-run this job")
            }
            if let urlString = check.htmlUrl, let url = URL(string: urlString) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open on GitHub", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
            }
        }
    }

    @ViewBuilder
    private var logSection: some View {
        if let jobId = check.actionsJobId {
            if check.isPending {
                placeholder(icon: "clock", text: "This job is still running. Its log will be available here once it finishes.", spinner: true)
            } else {
                CheckLogPanel(state: state, check: check, jobId: jobId, fillsHeight: true)
                    .frame(maxHeight: .infinity)
            }
        } else if summaryText == nil {
            placeholder(icon: "doc.text.magnifyingglass",
                        text: "\(check.appName ?? "This service") didn't report any details. Open it on GitHub for more.",
                        spinner: false)
        }
    }

    private func placeholder(icon: String, text: String, spinner: Bool) -> some View {
        VStack(spacing: 10) {
            if spinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
