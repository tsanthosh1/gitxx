import SwiftUI

public struct NewBranchRequest: Identifiable {
    public let id = UUID()
    public let initialName: String
}

/// Create branch (⇧⌘N): name with live validation, a searchable base branch, and whether to switch to it.
struct NewBranchSheet: View {
    @ObservedObject var state: AppState
    let request: NewBranchRequest
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var base: GitBranch?
    @State private var switchToIt = true
    @State private var pickingBase: Bool
    @State private var baseQuery = ""
    @FocusState private var focus: Field?

    private enum Field { case name, base, baseSearch, switchToggle, create, cancel }

    private var tabOrder: [Field] {
        var order: [Field] = [.name, .base]
        if pickingBase { order.append(.baseSearch) }
        order.append(.switchToggle)
        if canCreate { order.append(.create) }
        order.append(.cancel)
        return order
    }

    init(state: AppState, request: NewBranchRequest, showBasePicker: Bool = false) {
        self.state = state
        self.request = request
        _pickingBase = State(initialValue: showBasePicker)
    }

    private static let prefixes = ["feat/", "fix/", "chore/", "docs/", "refactor/"]

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var currentBranch: GitBranch? { state.branches.first(where: \.isCurrent) }

    /// The repo's main line: a local main/master/develop, else its remote counterpart.
    private var defaultBranch: GitBranch? {
        for candidate in ["main", "master", "develop"] {
            if let local = state.branches.first(where: { !$0.isRemote && $0.name == candidate }) { return local }
        }
        for candidate in ["origin/main", "origin/master", "origin/develop"] {
            if let remote = state.branches.first(where: { $0.isRemote && $0.name == candidate }) { return remote }
        }
        return nil
    }

    private var selectedBase: GitBranch? { base ?? currentBranch }

    /// Mirrors `git check-ref-format --branch` for the mistakes people actually make.
    private var problem: String? {
        let n = trimmed
        if n.isEmpty { return nil }
        if n.hasPrefix("-") || n.hasPrefix("/") || n.hasSuffix("/") || n.hasSuffix(".") || n.hasSuffix(".lock") || n == "@" {
            return "Branch names can't start with - or /, or end with /, . or .lock"
        }
        if n.contains("..") || n.contains("@{") || n.contains("//") || n.contains("/.") { return "Branch names can't contain .., @{, // or /." }
        if n.rangeOfCharacter(from: CharacterSet(charactersIn: "~^:?*[\\\u{7f}")) != nil { return "Branch names can't contain ~ ^ : ? * [ or \\" }
        if state.branches.contains(where: { !$0.isRemote && $0.name == n }) { return "A local branch named \(n) already exists" }
        return nil
    }

    private var remoteTwin: GitBranch? {
        state.branches.first { $0.isRemote && $0.displayName == trimmed }
    }

    private var canCreate: Bool { !trimmed.isEmpty && problem == nil && state.currentRepo != nil }

    private var baseCandidates: [GitBranch] {
        let q = baseQuery.trimmingCharacters(in: .whitespaces)
        let list = state.branches.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            if $0.isRemote != $1.isRemote { return !$0.isRemote }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return q.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            nameSection
            baseSection
            optionsSection
            footer
        }
        .padding(20)
        .frame(width: 500)
        .tabCycle(tabOrder, focus: $focus)
        .onAppear {
            name = request.initialName.replacingOccurrences(of: " ", with: "-")
            DispatchQueue.main.async { focus = .name }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(state.accentTheme.primaryColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Create branch").font(.system(size: 15, weight: .semibold))
                Text(state.currentRepo?.name ?? "").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 3) {
                KeyCap("⇧"); KeyCap("⌘"); KeyCap("N")
            }
            .foregroundStyle(.secondary)
            .help("Open this from anywhere with ⇧⌘N")
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            label("Name")
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("feat/login-screen", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .focused($focus, equals: .name)
                    .onSubmit(create)
                    .onChange(of: name) { _, value in
                        if value.contains(" ") { name = value.replacingOccurrences(of: " ", with: "-") }
                    }
                if !name.isEmpty {
                    Button { name = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.icon(size: 22, cornerRadius: 11))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(problem != nil ? Color.red.opacity(0.7) : (focus == .name ? state.accentTheme.primaryColor.opacity(0.8) : Color.primary.opacity(0.12)), lineWidth: 1))

            HStack(spacing: 5) {
                ForEach(Self.prefixes, id: \.self) { prefix in
                    Button { applyPrefix(prefix) } label: {
                        Text(prefix)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(name.hasPrefix(prefix) ? state.accentTheme.primaryColor : Color.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background((name.hasPrefix(prefix) ? state.accentTheme.primaryColor.opacity(0.15) : Color.primary.opacity(0.06)), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.hoverPlain)
                }
                Spacer()
            }

            if let problem {
                message(problem, icon: "exclamationmark.circle.fill", color: .red)
            } else if let twin = remoteTwin {
                message("\(twin.name) already exists on the remote. To work on it, check it out from the branch list instead.", icon: "info.circle.fill", color: .orange)
            }
        }
    }

    private var baseSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            label("Based on")
            HStack(spacing: 6) {
                Button(action: toggleBasePicker) {
                    HStack(spacing: 8) {
                        Image(systemName: selectedBase?.isRemote == true ? "cloud" : "arrow.triangle.branch")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(selectedBase?.name ?? "HEAD")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if selectedBase?.isCurrent == true { tag("current") }
                        Spacer()
                        Image(systemName: pickingBase ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(pickingBase ? state.accentTheme.primaryColor.opacity(0.8) : Color.primary.opacity(0.12)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .keyboardFocusable($focus, .base, accent: state.accentTheme.primaryColor, press: toggleBasePicker)
            }

            if !quickPicks.isEmpty {
                HStack(spacing: 5) {
                    Text("Quick pick")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                    ForEach(quickPicks, id: \.branch.name) { pick in
                        quickBase(pick.label, pick.branch, frequent: pick.frequent)
                    }
                    Spacer(minLength: 0)
                }
            }

            if pickingBase {
                basePicker
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var basePicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Filter branches", text: $baseQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focus, equals: .baseSearch)
                    .onSubmit { if let first = baseCandidates.first { pickBase(first) } }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            Divider()
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(baseCandidates.prefix(200)) { branch in
                        BaseBranchRow(branch: branch, selected: branch.name == selectedBase?.name,
                                      accent: state.accentTheme.primaryColor) { pickBase(branch) }
                    }
                    if baseCandidates.isEmpty {
                        Text("No branches match “\(baseQuery)”")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(10)
                    }
                }
                .padding(4)
            }
            .frame(height: 180)
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { switchToIt.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: switchToIt ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(switchToIt ? state.accentTheme.primaryColor : Color.secondary)
                    Text("Switch to the new branch").font(.system(size: 12.5))
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .keyboardFocusable($focus, .switchToggle, accent: state.accentTheme.primaryColor, cornerRadius: 4) { switchToIt.toggle() }
            let changes = Set(state.files.map(\.path)).count
            if switchToIt && changes > 0 {
                Text(selectedBase?.isCurrent != false
                     ? "Your \(changes) uncommitted change\(changes == 1 ? "" : "s") will come with you."
                     : "Your \(changes) uncommitted change\(changes == 1 ? "" : "s") will come with you, unless they clash with \(selectedBase?.name ?? "the base").")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    private var footer: some View {
        HStack {
            if canCreate {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(PRActionButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
                .keyboardFocusable($focus, .cancel, accent: state.accentTheme.primaryColor, cornerRadius: 6) { dismiss() }
            Button(switchToIt ? "Create & Switch" : "Create Branch", action: create)
                .buttonStyle(PRActionButtonStyle(.primary(state.accentTheme.primaryColor)))
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .keyboardFocusable($focus, .create, accent: state.accentTheme.primaryColor, cornerRadius: 6, press: create)
        }
    }

    private var summary: String {
        "\(trimmed) from \(selectedBase?.name ?? "HEAD")"
    }

    // MARK: Pieces

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.1), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private func message(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
    }

    private func quickBase(_ title: String, _ branch: GitBranch, frequent: Bool) -> some View {
        let selected = branch.name == selectedBase?.name
        return Button { pickBase(branch) } label: {
            HStack(spacing: 4) {
                Image(systemName: frequent ? "clock.arrow.circlepath" : (branch.isRemote ? "cloud" : "arrow.triangle.branch"))
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(selected ? state.accentTheme.primaryColor : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .frame(maxWidth: 150)
            .background(selected ? state.accentTheme.primaryColor.opacity(0.15) : Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.hoverPlain)
        .help(frequent ? "You often branch from \(branch.name)" : "Base it on \(branch.name)")
    }

    // MARK: Frequent bases (per repository)

    private var usageKey: String { "gitxx_branch_bases_" + (state.currentRepo?.path ?? "") }

    private struct QuickPick {
        let label: String
        let branch: GitBranch
        let frequent: Bool
    }

    /// Current branch, the default branch, then the bases you've used most in this repository.
    private var quickPicks: [QuickPick] {
        var picks: [QuickPick] = []
        func add(_ label: String, _ branch: GitBranch?, frequent: Bool = false) {
            guard let branch, !picks.contains(where: { $0.branch.name == branch.name }) else { return }
            picks.append(QuickPick(label: label, branch: branch, frequent: frequent))
        }
        add("current", currentBranch)
        add(defaultBranch?.displayName ?? "", defaultBranch)
        let counts = UserDefaults.standard.dictionary(forKey: usageKey) as? [String: Int] ?? [:]
        for name in counts.sorted(by: { $0.value > $1.value }).map(\.key) where picks.count < 6 {
            add(name, state.branches.first { $0.name == name }, frequent: true)
        }
        return picks.count > 1 || picks.first?.branch.name != selectedBase?.name ? picks : []
    }

    private func recordBaseUse(_ branch: GitBranch?) {
        guard let branch else { return }
        var counts = UserDefaults.standard.dictionary(forKey: usageKey) as? [String: Int] ?? [:]
        counts[branch.name, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: usageKey)
    }

    private func applyPrefix(_ prefix: String) {
        var rest = name
        if let existing = Self.prefixes.first(where: { rest.hasPrefix($0) }) { rest.removeFirst(existing.count) }
        name = name.hasPrefix(prefix) ? rest : prefix + rest
        focus = .name
    }

    private func toggleBasePicker() {
        withAnimation(.easeOut(duration: 0.15)) { pickingBase.toggle() }
        if pickingBase { DispatchQueue.main.async { focus = .baseSearch } }
    }

    private func pickBase(_ branch: GitBranch) {
        base = branch
        baseQuery = ""
        withAnimation(.easeOut(duration: 0.15)) { pickingBase = false }
        focus = .name
    }

    private func create() {
        guard canCreate else { return }
        recordBaseUse(selectedBase)
        state.createBranch(name: trimmed, base: selectedBase, checkout: switchToIt)
        dismiss()
    }
}

private struct BaseBranchRow: View {
    let branch: GitBranch
    let selected: Bool
    let accent: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: branch.isRemote ? "cloud" : "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(branch.name)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if branch.isCurrent {
                    Text("current")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovering ? Color.primary.opacity(0.08) : (selected ? accent.opacity(0.12) : .clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .onHover { hovering = $0 }
    }
}
