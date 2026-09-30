import SwiftUI

/// Native merge confirmation: strategy, commit message, delete-branch option and the readiness breakdown.
public struct PRMergeSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var method: GitHubAPIService.MergeMethod = .squash
    @State private var commitTitle: String = ""
    @State private var commitMessage: String = ""
    @State private var deleteBranch: Bool = false
    @State private var errorMessage: String? = nil

    private var allowedMethods: [GitHubAPIService.MergeMethod] {
        let allowed = state.prMeta?.allowedMergeMethods ?? ["squash", "merge", "rebase"]
        return allowed.compactMap { GitHubAPIService.MergeMethod(rawValue: $0) }
    }

    private var isMerging: Bool { state.isPRActionRunning("merge") }

    public var body: some View {
        if let pr = state.selectedPR {
            let readiness = PRMergeReadiness.evaluate(pr: pr, checks: state.prChecks, timeline: state.prTimeline, meta: state.prMeta)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Merge pull request #\(pr.number)")
                            .font(.system(size: 15, weight: .bold))
                        Text("\(pr.headBranch) → \(pr.baseBranch)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        readinessCard(readiness)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Merge method")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.secondary)
                            Picker("", selection: $method) {
                                ForEach(allowedMethods, id: \.self) { m in
                                    Text(m.displayName).tag(m)
                                }
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.large)
                            .labelsHidden()
                            Text(method.description)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }

                        if method != .rebase {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Commit message")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.secondary)
                                TextField("Commit title", text: $commitTitle)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 10)
                                    .frame(height: 32)
                                    .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
                                TextEditor(text: $commitMessage)
                                    .font(.system(size: 12.5))
                                    .scrollContentBackground(.hidden)
                                    .frame(height: 90)
                                    .padding(6)
                                    .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12)))
                            }
                        }

                        if state.prMeta?.deleteBranchOnMerge == true {
                            Label("This repository deletes head branches automatically after merge.", systemImage: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                        Toggle(isOn: $deleteBranch) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Delete branch after merge")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Removes '\(pr.headBranch)' from GitHub once merged.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.large)
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(20)
                }

                Divider()

                HStack(spacing: 10) {
                    if readiness.isMergeBlocked {
                        Label("GitHub may reject this merge until requirements are met", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(PRActionButtonStyle(.secondary))
                        .keyboardShortcut(.cancelAction)
                    Button {
                        merge()
                    } label: {
                        PRActionLabel(method.displayName, systemImage: "arrow.triangle.merge", isRunning: isMerging)
                    }
                    .buttonStyle(PRActionButtonStyle(.primary(Color(red: 35/255, green: 134/255, blue: 54/255))))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isMerging || pr.hasConflicts || pr.isDraft)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .frame(width: 600, height: 640)
            .onAppear {
                if let first = allowedMethods.first { method = first }
                commitTitle = "\(pr.title) (#\(pr.number))"
                deleteBranch = false
            }
            .onChange(of: method) { _, newValue in
                commitTitle = newValue == .merge
                    ? "Merge pull request #\(pr.number) from \(pr.headBranch)"
                    : "\(pr.title) (#\(pr.number))"
            }
        } else {
            Text("No pull request selected")
                .frame(width: 400, height: 200)
        }
    }

    @ViewBuilder
    private func readinessCard(_ readiness: PRMergeReadiness) -> some View {
        let color: Color = readiness.status == .ready ? .green : (readiness.status == .pending ? .yellow : .red)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: readiness.status == .ready ? "checkmark.circle.fill" : (readiness.status == .pending ? "clock.fill" : "xmark.octagon.fill"))
                    .foregroundStyle(color)
                    .font(.system(size: 16))
                Text(readiness.headline)
                    .font(.system(size: 14, weight: .semibold))
            }
            if readiness.blockers.isEmpty {
                Text(readiness.status == .pending
                     ? "\(readiness.pendingRequired) required check\(readiness.pendingRequired == 1 ? " is" : "s are") still running."
                     : "All merge requirements are satisfied.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(readiness.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "xmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.3)))
    }

    private func merge() {
        errorMessage = nil
        let title = method == .rebase ? nil : commitTitle
        let message = method == .rebase ? nil : commitMessage
        let chosen = method
        let delete = deleteBranch
        Task {
            do {
                try await state.mergeSelectedPR(method: chosen, commitTitle: title, commitMessage: message, deleteBranch: delete)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
