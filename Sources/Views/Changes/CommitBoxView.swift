import SwiftUI

public struct CommitBoxView: View {
    @ObservedObject var state: AppState
    @FocusState private var isSummaryFocused: Bool
    @State private var showUserPopover: Bool = false

    var stagedCount: Int {
        state.files.filter { $0.isStaged }.count
    }

    var totalChangedCount: Int {
        Set(state.files.map(\.path)).count
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                // Summary textfield
                HStack(spacing: 8) {
                    Button {
                        showUserPopover.toggle()
                    } label: {
                        UserAvatarView(profile: state.activeProfile, size: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Committing as \(state.activeProfile.name) <\(state.activeProfile.email)>. Click to switch identity.")
                    .popover(isPresented: $showUserPopover, arrowEdge: .top) {
                        UserProfilePopoverView(state: state)
                    }

                    TextField("Summary (required)", text: $state.commitSummary)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .focused($isSummaryFocused)
                        .onSubmit {
                            if !state.commitSummary.isEmpty {
                                state.commitStaged()
                            }
                        }

                    // AI Generate Commit Message Button
                    AICommitButton(state: state)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
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
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
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

                        Spacer()

                        Text("⌘↩")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .opacity(0.8)
                    }
                    .foregroundStyle(Color.white.opacity((state.commitSummary.trimmingCharacters(in: .whitespaces).isEmpty || totalChangedCount == 0) ? 0.55 : 1))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .padding(.horizontal, 10)
                    .background(
                        (state.commitSummary.trimmingCharacters(in: .whitespaces).isEmpty || totalChangedCount == 0)
                            ? LinearGradient(colors: [state.accentTheme.primaryColor.opacity(0.32), state.accentTheme.primaryColor.opacity(0.32)], startPoint: .top, endPoint: .bottom)
                            : state.accentTheme.linearGradient
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(
                        color: (state.commitSummary.trimmingCharacters(in: .whitespaces).isEmpty || totalChangedCount == 0)
                            ? Color.clear
                            : state.accentTheme.primaryColor.opacity(0.35),
                        radius: 4,
                        x: 0,
                        y: 1.5
                    )
                }
                .buttonStyle(.plain)
                .disabled(state.commitSummary.trimmingCharacters(in: .whitespaces).isEmpty || totalChangedCount == 0)
                .help("Commit staged files to current branch (⌘Enter)")

                // Status message
                HStack {
                    Text(stagedCount > 0 ? "\(stagedCount) of \(totalChangedCount) files staged" : "Will stage all \(totalChangedCount) changed files")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
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

// MARK: - Liquid Glass AI Commit Generator Button

private struct AICommitButton: View {
    @ObservedObject var state: AppState
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if state.isGeneratingCommitAI {
                    state.cancelAICommit()
                } else if state.aiProvider == .githubCopilot && !state.isCopilotConnected {
                    state.showAIAuthPopover = true
                } else {
                    state.generateAICommit()
                }
            } label: {
                HStack(spacing: 5) {
                    if state.isGeneratingCommitAI {
                        if isHovered {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.red.opacity(0.9))
                            Text("Cancel")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.red.opacity(0.9))
                        } else {
                            ProgressView()
                                .scaleEffect(0.65)
                                .frame(width: 14, height: 14)
                            Text("Thinking...")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.primary)
                        }
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(state.accentTheme.linearGradient)
                        Text("AI")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(state.isGeneratingCommitAI 
                                  ? (isHovered ? Color.red.opacity(0.12) : state.accentTheme.primaryColor.opacity(0.18))
                                  : (isHovered ? Color.white.opacity(0.12) : Color.white.opacity(0.06)))

                        // Liquid glass specular sheen
                        VStack(spacing: 0) {
                            LinearGradient(
                                colors: [Color.white.opacity(isHovered ? 0.35 : 0.18), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 11)
                            Spacer()
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isHovered ? 0.50 : 0.22),
                                    Color.white.opacity(isHovered ? 0.18 : 0.06)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: state.isGeneratingCommitAI ? (isHovered ? Color.red.opacity(0.3) : state.accentTheme.primaryColor.opacity(0.4)) : Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
                .scaleEffect(isHovered ? 1.02 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: isHovered)
            }
            .buttonStyle(.plain)
            .help(state.isGeneratingCommitAI ? "Click to cancel AI generation" : "Generate commit message with AI (⌥⌘G). Click dropdown for model options.")
            .keyboardShortcut("g", modifiers: [.option, .command])
            .onHover { isHovered = $0 }

            // Chevron options dropdown
            Button {
                state.showAIAuthPopover.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(0.75))
                    .frame(width: 14, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("AI Commit Generator Settings & Models")
            .popover(isPresented: $state.showAIAuthPopover, arrowEdge: .top) {
                AIAuthPopoverView(state: state)
            }
        }
        .padding(.trailing, 2)
    }
}

