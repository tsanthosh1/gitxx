import SwiftUI

public struct PRReviewModalView: View {
    @ObservedObject var state: AppState
    @State private var verdict: ReviewVerdict = .approved
    @State private var commentText: String = ""
    @State private var errorMessage: String? = nil
    @FocusState private var isEditorFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var isOwnPR: Bool {
        if let meta = state.prMeta, meta.prNumber == state.selectedPR?.number {
            return meta.viewerDidAuthor
        }
        guard let pr = state.selectedPR else { return false }
        return state.isCurrentUserAuthor(of: pr)
    }

    private var isSubmitting: Bool { state.isPRActionRunning("review") }

    private var canSubmit: Bool {
        if isSubmitting { return false }
        if isOwnPR && verdict != .commented { return false }
        if verdict != .approved && commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your review")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 8) {
                            verdictRow(
                                title: "Approve",
                                desc: "Give your approval to merge these changes.",
                                verdictOption: .approved,
                                icon: "checkmark.circle.fill",
                                color: .green,
                                disabled: isOwnPR
                            )
                            verdictRow(
                                title: "Request changes",
                                desc: "Submit feedback that must be addressed before merging.",
                                verdictOption: .changesRequested,
                                icon: "exclamationmark.circle.fill",
                                color: .red,
                                disabled: isOwnPR
                            )
                            verdictRow(
                                title: "Comment",
                                desc: "Submit general feedback without explicit approval.",
                                verdictOption: .commented,
                                icon: "text.bubble.fill",
                                color: .blue,
                                disabled: false
                            )
                        }

                        if isOwnPR {
                            Label("You authored this pull request, so GitHub only allows comment reviews.", systemImage: "info.circle")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(verdict == .approved ? "Comment (optional)" : "Comment")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Markdown supported")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }

                        TextEditor(text: $commentText)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .focused($isEditorFocused)
                            .frame(minHeight: 150)
                            .padding(8)
                            .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isEditorFocused ? Color.white.opacity(0.35) : Color.primary.opacity(0.12), lineWidth: 1)
                            )
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

            footer
        }
        .frame(width: 580, height: 600)
        .onAppear {
            if isOwnPR { verdict = .commented }
            isEditorFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.bubble.fill")
                .font(.system(size: 18))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review pull request")
                    .font(.system(size: 15, weight: .bold))
                if let pr = state.selectedPR {
                    Text(verbatim: "#\(pr.number) · \(pr.title)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("⌘↵ to submit")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(PRActionButtonStyle(.secondary))
            .keyboardShortcut(.cancelAction)

            Button {
                submit()
            } label: {
                PRActionLabel(submitTitle, systemImage: submitIcon, isRunning: isSubmitting)
            }
            .buttonStyle(PRActionButtonStyle(.primary(submitColor)))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var submitTitle: String {
        switch verdict {
        case .approved: return "Approve"
        case .changesRequested: return "Request changes"
        default: return "Submit comment"
        }
    }

    private var submitIcon: String {
        switch verdict {
        case .approved: return "checkmark"
        case .changesRequested: return "exclamationmark.bubble"
        default: return "text.bubble"
        }
    }

    private var submitColor: Color {
        switch verdict {
        case .approved: return Color(red: 35/255, green: 134/255, blue: 54/255)
        case .changesRequested: return Color(red: 218/255, green: 54/255, blue: 51/255)
        default: return Color.accentColor
        }
    }

    private func submit() {
        guard canSubmit else { return }
        errorMessage = nil
        let text = commentText
        let chosen = verdict
        Task {
            do {
                try await state.submitPRReview(verdict: chosen, comment: text)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func verdictRow(title: String, desc: String, verdictOption: ReviewVerdict, icon: String, color: Color, disabled: Bool) -> some View {
        let isSelected = verdict == verdictOption

        Button {
            verdict = verdictOption
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.system(size: 20))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? color : Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? color.opacity(0.10) : Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? color.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}
