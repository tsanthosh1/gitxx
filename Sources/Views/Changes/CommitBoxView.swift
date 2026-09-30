import SwiftUI

public struct CommitBoxView: View {
    @ObservedObject var state: AppState
    @FocusState private var isSummaryFocused: Bool

    var stagedCount: Int {
        state.files.filter { $0.isStaged }.count
    }

    var totalChangedCount: Int {
        Set(state.files.map(\.path)).count
    }

    private var summaryEmpty: Bool { state.commitSummary.trimmingCharacters(in: .whitespaces).isEmpty }
    private var canCommit: Bool { !summaryEmpty && totalChangedCount > 0 }
    @FocusState private var isDescriptionFocused: Bool

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                // Summary textfield
                HStack(spacing: 8) {
                    ProfileAvatarButton(state: state, size: 20)

                    TextField("Summary (required)", text: $state.commitSummary)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .focused($isSummaryFocused)
                        .onSubmit {
                            if !state.commitSummary.isEmpty {
                                state.commitStaged()
                            }
                        }

                    if !state.commitSummary.isEmpty {
                        let count = state.commitSummary.count
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(count > 72 ? Color.orange : Color.secondary.opacity(0.7))
                            .help(count > 72 ? "Summaries over 72 characters get cut off in many git tools" : "Summary length (aim for 72 or fewer)")
                    }

                    // AI Generate Commit Message Button
                    AICommitButton(state: state)
                }
                .padding(.leading, 6)
                .padding(.trailing, 5)
                .padding(.vertical, 5)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSummaryFocused ? state.accentTheme.primaryColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1)
                )

                // Optional description (Flexible height expanding with pane resize)
                ZStack(alignment: .topLeading) {
                    if state.commitDescription.isEmpty {
                        Text("Description (optional)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $state.commitDescription)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .focused($isDescriptionFocused)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isDescriptionFocused ? state.accentTheme.primaryColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1)
                )

                // Commit action button
                Button {
                    state.commitStaged()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))

                        Text("Commit to \(state.currentBranch)")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer(minLength: 10)

                        HStack(spacing: 3) {
                            KeyCap("⌘")
                            KeyCap("↩")
                        }
                        .opacity(canCommit ? 1 : 0.6)
                    }
                    .foregroundStyle(Color.white.opacity(canCommit ? 1 : 0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .padding(.leading, 11)
                    .padding(.trailing, 7)
                    .background(
                        canCommit
                            ? AnyShapeStyle(state.accentTheme.linearGradient)
                            : AnyShapeStyle(state.accentTheme.primaryColor.opacity(0.28))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(canCommit ? Color.clear : state.accentTheme.primaryColor.opacity(0.3))
                    )
                    .shadow(color: canCommit ? state.accentTheme.primaryColor.opacity(0.35) : .clear, radius: 4, x: 0, y: 1.5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .disabled(!canCommit)
                .help("Commit to \(state.currentBranch) (⌘↩)")

                // Status message
                HStack(spacing: 6) {
                    Text(stagedCount > 0 ? "\(stagedCount) of \(totalChangedCount) files staged" : "Will stage all \(totalChangedCount) changed files")
                    Spacer()
                    if totalChangedCount > 0 && summaryEmpty {
                        Text("Add a summary to commit")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.02))
    }
}

/// A keyboard key drawn as a small cap, for shortcut hints inside buttons.
struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .frame(minWidth: 20, minHeight: 19)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.white.opacity(0.18)))
    }
}

// MARK: - AI Commit Generator Button

/// One pill: "✦ AI" generates (or cancels while thinking), the chevron opens provider and model options.
private struct AICommitButton: View {
    @ObservedObject var state: AppState
    @State private var hoverMain = false
    @State private var hoverMenu = false

    var body: some View {
        let accent = state.accentTheme.primaryColor
        let busy = state.isGeneratingCommitAI
        HStack(spacing: 0) {
            Button {
                if busy {
                    state.cancelAICommit()
                } else if state.aiProvider == .githubCopilot && !state.isCopilotConnected {
                    state.showAIAuthPopover = true
                } else {
                    state.generateAICommit()
                }
            } label: {
                HStack(spacing: 5) {
                    if busy {
                        if hoverMain {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("Cancel")
                        } else {
                            ProgressView().controlSize(.mini)
                            Text("Writing…")
                        }
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(state.accentTheme.linearGradient)
                        Text("AI")
                    }
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(busy && hoverMain ? Color.red : Color.primary.opacity(hoverMain ? 1 : 0.85))
                .padding(.leading, 8)
                .padding(.trailing, 7)
                .frame(height: 24)
                .background(hoverMain ? Color.primary.opacity(0.08) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .onHover { hoverMain = $0 }
            .help(busy ? "Cancel AI generation" : "Write the commit message with AI (⌥⌘G)")
            .keyboardShortcut("g", modifiers: [.option, .command])

            Rectangle()
                .fill(accent.opacity(0.3))
                .frame(width: 1, height: 14)

            Button {
                state.showAIAuthPopover.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 20, height: 24)
                    .background(hoverMenu || state.showAIAuthPopover ? Color.primary.opacity(0.08) : Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .onHover { hoverMenu = $0 }
            .help("AI provider and model")
            .popover(isPresented: $state.showAIAuthPopover, arrowEdge: .top) {
                AIAuthPopoverView(state: state)
            }
        }
        .background(accent.opacity(busy ? 0.18 : 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(accent.opacity(0.35)))
        .animation(.easeOut(duration: 0.1), value: hoverMain)
        .animation(.easeOut(duration: 0.1), value: hoverMenu)
    }
}
