import SwiftUI
import AppKit

public struct PRCommentCardView: View {
    public let authorName: String
    public let authorAvatarUrl: String?
    public let relativeDateString: String
    public let markdownContent: String
    public let authorAssociation: String
    public let showEditedBadge: Bool
    public let editedByBotName: String?
    public let isLastInTimeline: Bool
    public var onSave: ((String) async throws -> Void)?
    public var onToggleChecklist: ((Int) async throws -> Void)?

    @State private var isEditing: Bool = false
    @State private var editedText: String = ""
    @State private var editTab: EditTab = .write
    @State private var isSaving: Bool = false
    @State private var saveErrorMessage: String? = nil
    @State private var showCopiedFeedback: Bool = false

    public enum EditTab: String, CaseIterable {
        case write = "Write"
        case preview = "Preview"
    }

    public init(
        authorName: String,
        authorAvatarUrl: String? = nil,
        relativeDateString: String,
        markdownContent: String,
        authorAssociation: String = "Author",
        showEditedBadge: Bool = false,
        editedByBotName: String? = nil,
        isLastInTimeline: Bool = true,
        onSave: ((String) async throws -> Void)? = nil,
        onToggleChecklist: ((Int) async throws -> Void)? = nil
    ) {
        self.authorName = authorName
        self.authorAvatarUrl = authorAvatarUrl
        self.relativeDateString = relativeDateString
        self.markdownContent = markdownContent
        self.authorAssociation = authorAssociation
        self.showEditedBadge = showEditedBadge
        self.editedByBotName = editedByBotName
        self.isLastInTimeline = isLastInTimeline
        self.onSave = onSave
        self.onToggleChecklist = onToggleChecklist
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Timeline Avatar Column
            VStack(spacing: 0) {
                PRAvatarView(
                    authorName: authorName,
                    avatarUrl: authorAvatarUrl,
                    size: 38
                )

                if !isLastInTimeline {
                    Rectangle()
                        .fill(Color(red: 48/255, green: 54/255, blue: 61/255).opacity(0.6))
                        .frame(width: 2)
                        .padding(.top, 6)
                }
            }
            .frame(width: 38)

            // Comment Box Card with Speech Arrow
            ZStack(alignment: .topLeading) {
                // Speech Bubble Pointer / Beak
                SpeechBeak()
                    .fill(Color(red: 22/255, green: 27/255, blue: 34/255))
                    .frame(width: 8, height: 14)
                    .overlay(
                        SpeechBeakStroke()
                            .stroke(Color(red: 48/255, green: 54/255, blue: 61/255), lineWidth: 1)
                    )
                    .offset(x: -8, y: 12)

                // Main Card Container
                VStack(alignment: .leading, spacing: 0) {
                    // Header Bar
                    HStack(spacing: 6) {
                        Text(authorName)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color(red: 230/255, green: 237/255, blue: 243/255))
                            .textSelection(.enabled)

                        Text("commented")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))

                        Text(relativeDateString)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))

                        if let botName = editedByBotName {
                            HStack(spacing: 4) {
                                Text("•")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                                Text("edited by \(botName)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                                Text("Bot")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color(red: 48/255, green: 54/255, blue: 61/255).opacity(0.8))
                                    .foregroundStyle(Color(red: 201/255, green: 209/255, blue: 217/255))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                            }
                        } else if showEditedBadge {
                            HStack(spacing: 4) {
                                Text("•")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                                Text("edited")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                            }
                        }

                        if showCopiedFeedback {
                            Text("Copied!")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(red: 63/255, green: 185/255, blue: 80/255))
                                .padding(.horizontal, 6)
                                .transition(.opacity)
                        }

                        Spacer()

                        // Author Association Pill Badge
                        Text(authorAssociation)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color(red: 48/255, green: 54/255, blue: 61/255), lineWidth: 1)
                            )

                        // Quick Edit Button (if onSave is provided and not already editing)
                        if onSave != nil && !isEditing {
                            Button {
                                startEditing()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 11))
                                    Text("Edit")
                                        .font(.system(size: 11.5, weight: .medium))
                                }
                                .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(Color(red: 48/255, green: 54/255, blue: 61/255).opacity(0.35))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .help("Edit comment")
                        }

                        // Three dots menu
                        Menu {
                            if onSave != nil && !isEditing {
                                Button {
                                    startEditing()
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                            }

                            Button {
                                copyRawMarkdown()
                            } label: {
                                Label("Copy Raw Markdown", systemImage: "doc.on.doc")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                                .padding(4)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 22, height: 22)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(red: 22/255, green: 27/255, blue: 34/255))

                    Rectangle()
                        .fill(Color(red: 48/255, green: 54/255, blue: 61/255))
                        .frame(height: 1)

                    // Card Body
                    if isEditing {
                        editingBodyView
                    } else {
                        GitHubMarkdownView(markdown: markdownContent, onToggleChecklist: onToggleChecklist)
                            .padding(16)
                            .background(Color(red: 13/255, green: 17/255, blue: 23/255))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(red: 48/255, green: 54/255, blue: 61/255), lineWidth: 1)
                )
            }
        }
        .frame(maxWidth: 960, alignment: .leading)
    }

    // MARK: - Editing UI

    @ViewBuilder
    private var editingBodyView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Write / Preview Subtabs Header
            HStack(spacing: 4) {
                Button {
                    editTab = .write
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11))
                        Text("Write")
                            .font(.system(size: 12, weight: editTab == .write ? .semibold : .regular))
                    }
                    .foregroundStyle(editTab == .write ? Color(red: 230/255, green: 237/255, blue: 243/255) : Color(red: 125/255, green: 133/255, blue: 144/255))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(editTab == .write ? Color(red: 13/255, green: 17/255, blue: 23/255) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(editTab == .write ? Color(red: 48/255, green: 54/255, blue: 61/255) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    editTab = .preview
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "eye")
                            .font(.system(size: 11))
                        Text("Preview")
                            .font(.system(size: 12, weight: editTab == .preview ? .semibold : .regular))
                    }
                    .foregroundStyle(editTab == .preview ? Color(red: 230/255, green: 237/255, blue: 243/255) : Color(red: 125/255, green: 133/255, blue: 144/255))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(editTab == .preview ? Color(red: 13/255, green: 17/255, blue: 23/255) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(editTab == .preview ? Color(red: 48/255, green: 54/255, blue: 61/255) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Color(red: 22/255, green: 27/255, blue: 34/255))

            Rectangle()
                .fill(Color(red: 48/255, green: 54/255, blue: 61/255))
                .frame(height: 1)

            // Editor / Live Preview
            Group {
                if editTab == .write {
                    TextEditor(text: $editedText)
                        .font(.system(size: 13, design: .monospaced))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 220, maxHeight: 420)
                        .background(Color(red: 13/255, green: 17/255, blue: 23/255))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(red: 48/255, green: 54/255, blue: 61/255), lineWidth: 1)
                        )
                        .padding(12)
                } else {
                    ScrollView {
                        if editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Nothing to preview")
                                .font(.system(size: 13))
                                .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))
                                .italic()
                                .padding(24)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            GitHubMarkdownView(markdown: editedText)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(minHeight: 220, maxHeight: 420)
                    .background(Color(red: 13/255, green: 17/255, blue: 23/255))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(red: 48/255, green: 54/255, blue: 61/255), lineWidth: 1)
                    )
                    .padding(12)
                }
            }
            .background(Color(red: 13/255, green: 17/255, blue: 23/255))

            // Error notice if save failed
            if let error = saveErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.red)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            // Bottom Actions Bar
            HStack(spacing: 10) {
                Text("Markdown styling supported")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 125/255, green: 133/255, blue: 144/255))

                Spacer()

                Button {
                    isEditing = false
                    editedText = markdownContent
                    saveErrorMessage = nil
                } label: {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 248/255, green: 81/255, blue: 73/255))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(red: 33/255, green: 38/255, blue: 45/255))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(red: 48/255, green: 54/255, blue: 61/255), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isSaving)

                Button {
                    submitEdit()
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isSaving ? "Updating..." : "Update comment")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color(red: 35/255, green: 134/255, blue: 54/255))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .background(Color(red: 13/255, green: 17/255, blue: 23/255))
        }
    }

    // MARK: - Actions

    private func startEditing() {
        editedText = markdownContent
        editTab = .write
        saveErrorMessage = nil
        isEditing = true
    }

    private func copyRawMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdownContent, forType: .string)
        withAnimation {
            showCopiedFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                showCopiedFeedback = false
            }
        }
    }

    private func submitEdit() {
        guard let onSave = onSave else { return }
        isSaving = true
        saveErrorMessage = nil

        Task {
            do {
                try await onSave(editedText)
                await MainActor.run {
                    isSaving = false
                    isEditing = false
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveErrorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Speech Bubble Pointer Shapes

private struct SpeechBeak: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct SpeechBeakStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
