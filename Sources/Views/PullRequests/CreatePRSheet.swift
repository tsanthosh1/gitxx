import SwiftUI
import AppKit

/// New pull request sheet. Opens instantly: the base branch is a searchable field (no giant popup of every
/// remote branch) and everything else is loaded asynchronously from local git.
public struct CreatePRSheet: View {
    @ObservedObject var state: AppState
    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var baseBranch: String = ""
    @State private var isDraft: Bool = false
    @State private var context: AppState.CreatePRContext?
    @State private var headBranch: String = ""
    @State private var branchNames: [String] = []
    @State private var headNames: [String] = []
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var autoTitle = ""
    @State private var autoBody = ""
    @Environment(\.dismiss) private var dismiss

    private var needsPush: Bool {
        guard let context, context.headExistsLocally else { return false }
        return !context.hasUpstream || context.unpushedCommits > 0
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Create Pull Request", systemImage: "arrow.triangle.pull")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    branchRow
                    if let context { branchStatus(context) }
                    if let errorMessage { errorBanner(errorMessage) }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Title")
                            .font(.system(size: 12, weight: .semibold))
                        TextField("e.g. feat(auth): Support GitHub Enterprise SSO", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description")
                            .font(.system(size: 12, weight: .semibold))
                        TextEditor(text: $bodyText)
                            .font(.system(size: 12))
                            .frame(height: 150)
                            .padding(6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                    }

                    Toggle("Create as draft (not ready for review)", isOn: $isDraft)
                        .font(.system(size: 12))
                }
                .padding()
            }

            Divider()

            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                    Text(needsPush ? "Pushing \(headBranch) and creating…" : "Creating…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    create()
                } label: {
                    Text(needsPush ? "Push & Create Pull Request" : "Create Pull Request")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isCreating || sameBranch || headBranch.trimmingCharacters(in: .whitespaces).isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty || baseBranch.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 540, height: 520)
        .task { await loadContext() }
        .task(id: baseBranch + "\u{0}" + headBranch) {
            guard context != nil, !baseBranch.isEmpty, !headBranch.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await reloadCommits()
        }
    }

    // MARK: - Branches

    private var branchRow: some View {
        HStack(alignment: .top, spacing: 12) {
            BranchSuggestField(label: "Base (Target)", text: $baseBranch, candidates: branchNames, defaultName: context?.defaultBase)
            Image(systemName: "arrow.left")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 22)
            BranchSuggestField(label: "Compare (Source)", text: $headBranch, candidates: headNames, defaultName: state.currentBranch,
                               defaultLabel: "current")
        }
    }

    private var sameBranch: Bool {
        baseBranch.trimmingCharacters(in: .whitespaces) == headBranch.trimmingCharacters(in: .whitespaces)
    }

    @ViewBuilder
    private func branchStatus(_ context: AppState.CreatePRContext) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if sameBranch {
                Label("Source and base are both \(headBranch) — pick a different source or base.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !context.commitSubjects.isEmpty {
                Label("\(context.commitSubjects.count == 30 ? "30+" : "\(context.commitSubjects.count)") commit\(context.commitSubjects.count == 1 ? "" : "s") ahead of \(baseBranch)",
                      systemImage: "point.3.connected.trianglepath.dotted")
            }
            if !context.hasUpstream {
                Label("\(headBranch) isn't on GitHub yet — it will be pushed first", systemImage: "icloud.and.arrow.up")
                    .foregroundStyle(.orange)
            } else if context.unpushedCommits > 0 {
                Label("\(context.unpushedCommits) local commit\(context.unpushedCommits == 1 ? "" : "s") not pushed — they will be pushed first", systemImage: "icloud.and.arrow.up")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }

    private func errorBanner(_ message: String) -> some View {
        let lower = message.lowercased()
        let exists = lower.contains("already exists")
        let noCommits = lower.contains("no commits between")
        return VStack(alignment: .leading, spacing: 8) {
            Label(noCommits ? "\(headBranch) has no commits that aren't already in \(baseBranch)." : message,
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if exists {
                    Button("Open existing pull request") { openExisting() }
                        .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                }
                if lower.contains("head") && (lower.contains("invalid") || lower.contains("not found")) {
                    Button("Push \(headBranch) & retry") { create(forcePush: true) }
                        .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Actions

    private func loadContext() async {
        if headBranch.isEmpty { headBranch = state.currentBranch }
        let ctx = await state.loadCreatePRContext(base: nil, head: headBranch)
        context = ctx
        branchNames = state.remoteBranchNames
        headNames = state.allBranchNames
        if baseBranch.isEmpty {
            baseBranch = ctx.defaultBase
                ?? ["main", "master", "develop"].first(where: branchNames.contains)
                ?? branchNames.first ?? "main"
        }
        applyDefaults(ctx)
    }

    private func reloadCommits() async {
        let ctx = await state.loadCreatePRContext(base: baseBranch, head: headBranch.trimmingCharacters(in: .whitespaces))
        context = ctx
        applyDefaults(ctx)
    }

    private func applyDefaults(_ ctx: AppState.CreatePRContext) {
        if title.isEmpty || title == autoTitle {
            let suggested = ctx.commitSubjects.count == 1 ? ctx.commitSubjects[0] : Self.humanize(headBranch)
            title = suggested
            autoTitle = suggested
        }
        if let template = ctx.template, bodyText.isEmpty || bodyText == autoBody {
            bodyText = template
            autoBody = template
        }
    }

    private static func humanize(_ branch: String) -> String {
        let last = branch.split(separator: "/").last.map(String.init) ?? branch
        let words = last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private func create(forcePush: Bool = false) {
        errorMessage = nil
        isCreating = true
        let push = forcePush || needsPush
        Task {
            do {
                try await state.createPullRequest(
                    title: title.trimmingCharacters(in: .whitespaces),
                    body: bodyText,
                    headBranch: headBranch.trimmingCharacters(in: .whitespaces),
                    baseBranch: baseBranch.trimmingCharacters(in: .whitespaces),
                    isDraft: isDraft,
                    pushFirst: push
                )
            } catch {
                errorMessage = error.localizedDescription
                context = await state.loadCreatePRContext(base: baseBranch, head: headBranch)
            }
            isCreating = false
        }
    }

    private func openExisting() {
        if let pr = state.pullRequests.first(where: { $0.headBranch == headBranch && $0.state.isActive }) {
            state.showCreatePRSheet = false
            Task { await state.openPullRequest(number: pr.number) }
        } else if let ctx = state.prRepoContext(),
                  let url = URL(string: "https://github.com/\(ctx.owner)/\(ctx.repo)/pulls?q=is%3Apr+is%3Aopen+head%3A\(headBranch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? headBranch)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Branch text field with a filtered suggestion popover; only matching names are rendered, so huge repos stay fast.
struct BranchSuggestField: View {
    let label: String
    @Binding var text: String
    let candidates: [String]
    var defaultName: String?
    var defaultLabel = "default"

    @State private var showSuggestions = false
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Array(candidates.prefix(12)) }
        var prefix: [String] = [], contains: [String] = []
        for name in candidates {
            let lower = name.lowercased()
            if lower == query { continue }
            if lower.hasPrefix(query) { prefix.append(name) } else if contains.count < 12, lower.contains(query) { contains.append(name) }
            if prefix.count >= 12 { break }
        }
        return Array((prefix + contains).prefix(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Branch", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(maxWidth: .infinity)
                .focused($focused)
                .onChange(of: focused) { _, isFocused in showSuggestions = isFocused }
                .onChange(of: text) { _, _ in if focused { showSuggestions = true } }
                .onSubmit { showSuggestions = false }
                .popover(isPresented: Binding(get: { showSuggestions && !suggestions.isEmpty }, set: { showSuggestions = $0 }),
                         attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    suggestionList
                }
        }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.self) { name in
                Button {
                    text = name
                    showSuggestions = false
                    focused = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(name)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if name == defaultName {
                            Text(defaultLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 360)
    }
}
