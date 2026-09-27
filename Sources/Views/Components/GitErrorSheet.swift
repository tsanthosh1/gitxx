import SwiftUI
import AppKit

/// Failure dialog for git operations: what happened, the files involved, and one-click fixes.
struct GitErrorSheet: View {
    @ObservedObject var state: AppState
    let error: GitOperationError

    @State private var runningAction: UUID?
    @State private var pendingConfirmation: GitFixAction?
    @State private var showDetails = false

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

            if !error.files.isEmpty {
                filesList
            }

            detailsSection

            VStack(spacing: 7) {
                ForEach(error.actions) { action in
                    actionButton(action)
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

    private var filesList: some View {
        let changedPaths = Set(state.files.map(\.path))
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
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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
                                Button("View changes") { state.inspectFileFromError(file) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(state.accentTheme.primaryColor)
                                    .pointerCursor()
                                    .help("Show this file's diff on the Changes tab; you can come back to these fixes from there")
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

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { showDetails.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showDetails ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("Git output")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    private func actionButton(_ action: GitFixAction) -> some View {
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
        .keyboardShortcut(action.role == .primary ? .defaultAction : nil)
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
