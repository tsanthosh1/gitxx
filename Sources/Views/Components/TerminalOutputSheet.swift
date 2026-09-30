import SwiftUI
import AppKit

public struct TerminalOutputSheet: View {
    @ObservedObject var state: AppState

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.lastTerminalResult?.command ?? "git command")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)

                    if let repo = state.currentRepo {
                        Text("Executed in \(repo.name)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let res = state.lastTerminalResult {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(res.isSuccess ? Color.green : Color.red)
                            .frame(width: 7, height: 7)
                        Text(res.isSuccess ? "Exit 0" : "Exit \(res.exitCode)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(res.isSuccess ? .green : .red)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((res.isSuccess ? Color.green : Color.red).opacity(0.12))
                    .clipShape(Capsule())
                }

                Button {
                    let content = (state.lastTerminalResult?.stdout.isEmpty == false ? state.lastTerminalResult?.stdout : state.lastTerminalResult?.stderr) ?? ""
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    state.showToast("Copied terminal output", type: .success)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(.system(size: 12))
                }
                .buttonStyle(.bordered)

                Button {
                    state.showTerminalResultSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.hoverPlain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .themedSurface(state.accentTheme, .header)

            Divider()

            // Terminal Output Pane
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let stdout = state.lastTerminalResult?.stdout ?? ""
                    let stderr = state.lastTerminalResult?.stderr ?? ""

                    if !stdout.isEmpty {
                        Text(stdout)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.primary)
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !stderr.isEmpty {
                        Text(stderr)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.red.opacity(0.9))
                            .textSelection(.enabled)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if stdout.isEmpty && stderr.isEmpty {
                        Text("Command completed with no output.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(14)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
        .frame(width: 680, height: 440)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
