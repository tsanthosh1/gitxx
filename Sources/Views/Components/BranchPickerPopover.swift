import SwiftUI

public struct BranchPickerPopover: View {
    @ObservedObject var state: AppState
    @State private var searchText: String = ""
    @State private var newBranchName: String = ""
    @State private var isCreatingBranch: Bool = false
    @FocusState private var focusedField: Field?

    private enum Field { case search, newBranch }

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

                TextField("Filter branches...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focusedField, equals: .search)
                    .onSubmit {
                        if let first = filteredBranches.first(where: { !$0.isCurrent }) ?? filteredBranches.first {
                            checkout(first)
                        }
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Branch List
            ScrollView {
                LazyVStack(spacing: 3) {
                    if isCreatingBranch {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("New Branch Name")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                TextField("e.g. feat/login-screen", text: $newBranchName)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .newBranch)
                                    .onSubmit {
                                        createAndCheckout()
                                    }

                                Button("Create") {
                                    createAndCheckout()
                                }
                                .keyboardShortcut(.defaultAction)
                                .buttonStyle(.borderedProminent)
                                .disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty)

                                Button("Cancel") {
                                    isCreatingBranch = false
                                    newBranchName = ""
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 6)
                        .padding(.top, 6)
                    }

                    ForEach(filteredBranches) { branch in
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
                        .buttonStyle(.plain)
                        .background(branch.isCurrent ? Color.white.opacity(0.10) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 300)

            Divider()

            // Footer - Create Branch action
            HStack {
                Button {
                    isCreatingBranch.toggle()
                    if isCreatingBranch {
                        newBranchName = searchText
                        DispatchQueue.main.async { focusedField = .newBranch }
                    } else {
                        focusedField = .search
                    }
                } label: {
                    Label("New Branch...", systemImage: "plus.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .frame(height: 28)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)

                Spacer()

                Text("\(filteredBranches.count) branches")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial.opacity(0.4))
        }
        .frame(width: 440)
        .background(.ultraThinMaterial)
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
        .onAppear { DispatchQueue.main.async { focusedField = .search } }
    }

    private func checkout(_ branch: GitBranch) {
        withAnimation(.easeInOut(duration: 0.12)) {
            state.showBranchPicker = false
        }
        if !branch.isCurrent {
            state.checkoutBranch(branch.name)
        }
    }

    private func createAndCheckout() {
        let name = newBranchName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        state.createBranch(name: name)
        isCreatingBranch = false
        newBranchName = ""
        withAnimation(.easeInOut(duration: 0.12)) {
            state.showBranchPicker = false
        }
    }
}
