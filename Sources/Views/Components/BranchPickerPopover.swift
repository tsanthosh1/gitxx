import SwiftUI

public struct BranchPickerPopover: View {
    @ObservedObject var state: AppState
    @State private var searchText: String = ""
    @State private var highlighted = 0

    var filteredBranches: [GitBranch] {
        if searchText.isEmpty {
            return state.branches
        }
        return state.branches.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))

                PaletteSearchField(
                    text: $searchText,
                    placeholder: "Filter branches...",
                    onSubmit: {
                        let list = filteredBranches
                        if list.indices.contains(highlighted) { checkout(list[highlighted]) }
                    },
                    onDownArrow: { move(1) },
                    onUpArrow: { move(-1) },
                    onEscape: {
                        if searchText.isEmpty { state.showBranchPicker = false } else { searchText = "" }
                    },
                    fontSize: 13,
                    keepsFocus: false
                )
                .frame(height: 20)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.hoverPlain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Branch List
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(filteredBranches.enumerated()), id: \.element.id) { index, branch in
                        Button {
                            checkout(branch)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: branch.isRemote ? "network" : (branch.isCurrent ? "checkmark" : "arrow.triangle.branch"))
                                    .foregroundStyle(branch.isCurrent ? Color.primary : Color.secondary)
                                    .font(.system(size: 13, weight: branch.isCurrent ? .bold : .regular))
                                    .frame(width: 20)

                                Text(branch.displayName)
                                    .font(.system(size: 13, weight: branch.isCurrent ? .semibold : .regular))
                                    .foregroundStyle(branch.isCurrent ? Color.primary : Color.primary)

                                Spacer()

                                if branch.isRemote {
                                    Text("remote")
                                        .font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .clipShape(Capsule())
                                }

                                if branch.isCurrent {
                                    Text("current")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.10))
                                        .foregroundStyle(Color.primary)
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverPlain)
                        .background(index == highlighted ? Color.primary.opacity(0.18) : (branch.isCurrent ? Color.white.opacity(0.10) : Color.clear))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onHover { if $0 { highlighted = index } }
                        .id(branch.id)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 300)
            .onChange(of: highlighted) { _, index in
                let list = filteredBranches
                guard list.indices.contains(index) else { return }
                proxy.scrollTo(list[index].id, anchor: nil)
            }
            }
            .onChange(of: searchText) { _, _ in resetHighlight() }
            .onAppear { resetHighlight() }

            Divider()

            // Footer - Create Branch action
            HStack {
                Button {
                    state.beginNewBranch(name: searchText.trimmingCharacters(in: .whitespaces))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text(searchText.trimmingCharacters(in: .whitespaces).isEmpty || filteredBranches.contains(where: { $0.displayName == searchText })
                             ? "New Branch…" : "Create “\(searchText.trimmingCharacters(in: .whitespaces))”…")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text("⇧⌘N")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(state.accentTheme.primaryColor)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(state.accentTheme.primaryColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .help("Create a branch, choosing its base (⇧⌘N)")

                Spacer()

                Text("\(filteredBranches.count) branches")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))
        }
        .frame(width: 440)
        .themedSurface(state.accentTheme, .elevated)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.24), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
    }

    private func move(_ delta: Int) {
        let count = filteredBranches.count
        guard count > 0 else { return }
        highlighted = min(max(highlighted + delta, 0), count - 1)
    }

    /// Starts on the first branch you could switch to, so Return checks it out.
    private func resetHighlight() {
        highlighted = filteredBranches.firstIndex(where: { !$0.isCurrent }) ?? 0
    }

    private func checkout(_ branch: GitBranch) {
        withAnimation(.easeInOut(duration: 0.12)) {
            state.showBranchPicker = false
        }
        if !branch.isCurrent {
            state.checkoutBranch(branch.name)
        }
    }
}
