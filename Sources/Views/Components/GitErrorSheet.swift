import SwiftUI
import AppKit

/// Failure dialog for git operations: what happened, the files involved, and one-click fixes.
struct GitErrorSheet: View {
    @ObservedObject var state: AppState
    let error: GitOperationError

    @State private var runningAction: UUID?
    @State private var pendingConfirmation: GitFixAction?
    @State private var showDetails = false
    @State private var review: DiffReview?
    /// Set once the diff review closes, so the user can retry after stashing or reverting files there.
    @State private var reviewed: Bool

    init(state: AppState, error: GitOperationError, startReviewed: Bool = false) {
        self.state = state
        self.error = error
        _reviewed = State(initialValue: startReviewed)
        _showDetails = State(initialValue: error.showOutput)
    }

    private struct DiffReview: Identifiable {
        let id = UUID()
        let initial: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text(error.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(error.summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !error.highlights.isEmpty {
                highlightsBox
            }

            if !error.files.isEmpty {
                filesList
            }

            detailsSection

            if reviewed, let retry = error.retry {
                retryBanner(retry)
            }

            VStack(spacing: 7) {
                ForEach(error.actions) { action in
                    actionButton(action, isDefault: action.role == .primary && !(reviewed && error.retry != nil))
                }
            }

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error.details, forType: .string)
                    state.showToast("Copied error output", type: .success)
                } label: {
                    Label("Copy error", systemImage: "doc.on.doc")
                }
                .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
                Spacer()
                Button("Dismiss") { state.operationError = nil }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(PRActionButtonStyle(.secondary))
            }
        }
        .padding(20)
        .frame(width: 580)
        .disabled(runningAction != nil)
        .sheet(item: $review, onDismiss: { withAnimation(.easeOut(duration: 0.15)) { reviewed = true } }) { request in
            ChangedFilesDiffSheet(state: state, title: "Local changes blocking this \(error.title.lowercased().hasPrefix("pull") ? "pull" : "operation")",
                                  paths: error.files.filter { changedPaths.contains($0) } + error.files.filter { !changedPaths.contains($0) },
                                  initial: request.initial) { path in
                state.inspectFileFromError(path)
            }
        }
        .confirmationDialog(
            pendingConfirmation?.title ?? "",
            isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
            presenting: pendingConfirmation
        ) { action in
            Button(action.title, role: .destructive) { run(action) }
        } message: { action in
            Text(action.confirmation ?? "")
        }
    }

    private func pathText(_ file: String) -> AttributedString {
        let ns = file as NSString
        let dir = ns.deletingLastPathComponent
        var text = AttributedString()
        if !dir.isEmpty {
            var dirPart = AttributedString(dir + "/")
            dirPart.foregroundColor = .secondary
            text += dirPart
        }
        var namePart = AttributedString(ns.lastPathComponent)
        namePart.foregroundColor = .primary
        text += namePart
        return text
    }

    private var changedPaths: Set<String> { Set(state.files.map(\.path)) }

    private var filesList: some View {
        let changedPaths = changedPaths
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(error.files.count == 1 ? "1 file" : "\(error.files.count) files")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error.files.joined(separator: "\n"), forType: .string)
                    state.showToast("Copied \(error.files.count == 1 ? "path" : "paths")", type: .success)
                } label: {
                    Label("Copy paths", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.hoverPlain)
                .foregroundStyle(.secondary)
                if let first = error.files.first(where: { changedPaths.contains($0) }) {
                    Button {
                        review = DiffReview(initial: first)
                    } label: {
                        Label("Review all diffs", systemImage: "doc.text.magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(state.accentTheme.primaryColor)
                    .pointerCursor()
                    .padding(.leading, 10)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(error.files, id: \.self) { file in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(pathText(file))
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if changedPaths.contains(file) {
                                Button("View changes") { review = DiffReview(initial: file) }
                                    .buttonStyle(.hoverPlain)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(state.accentTheme.primaryColor)
                                    .pointerCursor()
                                    .help("Review this file's diff (and the others) in a separate window without leaving these fixes")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: min(CGFloat(error.files.count) * 22 + 10, 200))
        }
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var highlightsBox: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("What failed")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(error.highlights.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.red)
                    Text(line)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.red.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { showDetails.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showDetails ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(error.highlights.isEmpty ? "Git output" : "Full output")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            if showDetails {
                ScrollView {
                    Text(error.details)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 160)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func retryBanner(_ retry: GitFixAction) -> some View {
        let changed = changedPaths
        let remaining = error.files.filter { changed.contains($0) }.count
        let clear = remaining == 0
        return HStack(spacing: 10) {
            Image(systemName: clear ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(clear ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(clear ? "Blocking changes are out of the way" : "\(remaining) of \(error.files.count) file\(error.files.count == 1 ? "" : "s") still changed")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(clear ? "Retry now to run it again." : "Retry anyway, or use one of the fixes below.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { run(retry) } label: {
                HStack(spacing: 6) {
                    if runningAction == retry.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: retry.systemImage)
                    }
                    Text(retry.title)
                }
            }
            .buttonStyle(PRActionButtonStyle(.primary(state.accentTheme.primaryColor)))
            .keyboardShortcut(.defaultAction)
        }
        .padding(10)
        .background(state.accentTheme.primaryColor.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(state.accentTheme.primaryColor.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func actionButton(_ action: GitFixAction, isDefault: Bool) -> some View {
        Button {
            if action.confirmation != nil { pendingConfirmation = action } else { run(action) }
        } label: {
            HStack(spacing: 8) {
                if runningAction == action.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: action.systemImage)
                        .frame(width: 16)
                }
                Text(action.title)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PRActionButtonStyle(style(for: action.role)))
        .keyboardShortcut(isDefault ? .defaultAction : nil)
    }

    private func style(for role: GitFixAction.Role) -> PRActionButtonStyle.Kind {
        switch role {
        case .primary: return .primary(state.accentTheme.primaryColor)
        case .normal: return .secondary
        case .destructive: return .destructive
        }
    }

    private func run(_ action: GitFixAction) {
        runningAction = action.id
        Task {
            await action.perform()
            runningAction = nil
            if state.operationError?.id == error.id { state.operationError = nil }
        }
    }
}
