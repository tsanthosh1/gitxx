import SwiftUI
import AppKit

public struct TerminalView: View {
    @ObservedObject var state: AppState
    @State private var autoScrollID: UUID = UUID()

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }

    private var currentTimeString: String {
        timeFormatter.string(from: Date())
    }

    private var currentPromptPath: String {
        guard let repo = state.currentRepo else { return "~" }
        let path = repo.path
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return (path as NSString).lastPathComponent
    }

    private var isDirty: Bool {
        !state.files.isEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Terminal Chrome Header Bar
            terminalHeaderBar

            Divider()

            // Main Terminal Scroll Canvas
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // Completed Command Output History
                        ForEach(state.terminalEntries) { entry in
                            terminalEntryBlock(entry)
                        }

                        // Live Interactive Input Prompt
                        livePromptRow
                            .id(autoScrollID)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: state.terminalEntries.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(autoScrollID, anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo(autoScrollID, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Terminal Chrome Header Bar

    private var terminalHeaderBar: some View {
        HStack(spacing: 12) {

            // Shell & Repo Indicator
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)

                Text(state.currentRepo?.name ?? "Terminal")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)

                Text("— \(state.selectedShell.executablePath)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if state.isExecutingGitCommand {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .frame(width: 14, height: 14)
                }
            }

            // Shell Switcher (Bash / Zsh with aliases enabled)
            Picker("", selection: $state.selectedShell) {
                ForEach(TerminalShell.allCases) { shell in
                    Text(shell.rawValue).tag(shell)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 126)
            .help("Switch shell environment. User aliases and rc files (~/.bashrc or ~/.zshrc) are loaded automatically.")

            Spacer()

            // Quick Git Action Chips
            HStack(spacing: 6) {
                quickChip("status -s", cmd: "git status -s")
                quickChip("diff --stat", cmd: "git diff --stat")
                quickChip("log -n 5", cmd: "git log --oneline -n 5")
                quickChip("branch -a", cmd: "git branch -a")
            }

            // Copy Buffer Button
            Button {
                var buffer = ""
                for entry in state.terminalEntries {
                    buffer += "[\(timeFormatter.string(from: entry.timestamp))] \(entry.fullPath) on \(entry.branchName)\n"
                    buffer += "$ \(entry.command)\n"
                    if !entry.stdout.isEmpty { buffer += "\(entry.stdout)\n" }
                    if !entry.stderr.isEmpty { buffer += "\(entry.stderr)\n" }
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(buffer, forType: .string)
                state.showToast("Copied terminal buffer", type: .success)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                    Text("Copy")
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .help("Copy full terminal buffer to clipboard")

            // Clear Screen Button
            Button {
                state.clearTerminal()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text("Clear")
                }
                .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .help("Clear terminal screen (⌘K)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func quickChip(_ label: String, cmd: String) -> some View {
        Button {
            state.runTerminalCommand(cmd)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12))
                .foregroundStyle(.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }



    // MARK: - Terminal Entry Block

    @ViewBuilder
    private func terminalEntryBlock(_ entry: TerminalEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Powerline / Starship Style Prompt Line
            HStack(spacing: 6) {
                // Timestamp
                Text("[\(timeFormatter.string(from: entry.timestamp))]")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)

                // Directory & Shell tag
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                    Text(entry.directoryName)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Text("(\(entry.shellName))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                .foregroundStyle(Color.blue)

                Text("on")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                // Branch + Dirty Status Indicator (*)
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                    Text(entry.branchName)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))

                    if entry.isDirty {
                        Text("*")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.yellow)
                    } else {
                        Text("✔")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.green)
                    }
                }
                .foregroundStyle(entry.isDirty ? Color.orange : Color.green)

                // Ahead / Behind Badge
                if entry.commitsAhead > 0 {
                    Text("↑\(entry.commitsAhead)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                }
                if entry.commitsBehind > 0 {
                    Text("↓\(entry.commitsBehind)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                }

                Spacer()

                // Execution Duration
                Text("\(Int(entry.duration * 1000))ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                // Exit Code Badge
                HStack(spacing: 3) {
                    Circle()
                        .fill(entry.isSuccess ? Color.green : Color.red)
                        .frame(width: 5, height: 5)
                    Text(entry.isSuccess ? "0" : "\(entry.exitCode)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(entry.isSuccess ? .green : .red)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background((entry.isSuccess ? Color.green : Color.red).opacity(0.12))
                .clipShape(Capsule())
            }
            .frame(height: 18)

            // Command Prompt Line
            HStack(spacing: 8) {
                Text("❯")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(entry.isSuccess ? Color.green : Color.red)

                Text(entry.command)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.primary)
            }
            .frame(height: 22)

            // Stdout Output
            if !entry.stdout.isEmpty {
                Text(entry.stdout)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.primary)
                    .textSelection(.enabled)
                    .padding(.leading, 14)
                    .padding(.top, 2)
            }

            // Stderr Output
            if !entry.stderr.isEmpty {
                Text(entry.stderr)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.red.opacity(0.95))
                    .textSelection(.enabled)
                    .padding(.leading, 14)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Live Interactive Prompt

    private var livePromptRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Live Prompt Header (Timestamp, Directory, Branch with *)
            HStack(spacing: 6) {
                Text("[\(currentTimeString)]")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                    Text(currentPromptPath)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Text("(\(state.selectedShell.rawValue.lowercased()))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                .foregroundStyle(Color.blue)

                Text("on")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                    Text(state.currentBranch)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))

                    if isDirty {
                        Text("*")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                            .foregroundStyle(Color.yellow)
                    } else {
                        Text("✔")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.green)
                    }
                }
                .foregroundStyle(isDirty ? Color.orange : Color.green)

                if state.commitsAhead > 0 {
                    Text("↑\(state.commitsAhead)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                }
                if state.commitsBehind > 0 {
                    Text("↓\(state.commitsBehind)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                }

            }
            .frame(height: 18)

            // Command Input Line with ❯ Prompt
            HStack(spacing: 8) {
                Text("❯")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(state.accentTheme.primaryColor)

                TerminalPromptField(
                    text: $state.terminalInput,
                    onCommit: {
                        let cmd = state.terminalInput
                        state.runTerminalCommand(cmd)
                    },
                    onUpArrow: {
                        navigateHistory(direction: 1)
                    },
                    onDownArrow: {
                        navigateHistory(direction: -1)
                    }
                )
                .frame(height: 22)
            }
            .frame(height: 22)
        }
    }

    private func navigateHistory(direction: Int) {
        let history = state.terminalCommandHistory
        guard !history.isEmpty else { return }

        if direction == 1 { // Up arrow (older)
            if state.terminalHistoryIndex == -1 {
                state.terminalHistoryIndex = history.count - 1
            } else if state.terminalHistoryIndex > 0 {
                state.terminalHistoryIndex -= 1
            }
            state.terminalInput = history[state.terminalHistoryIndex]
        } else { // Down arrow (newer)
            if state.terminalHistoryIndex != -1 {
                if state.terminalHistoryIndex < history.count - 1 {
                    state.terminalHistoryIndex += 1
                    state.terminalInput = history[state.terminalHistoryIndex]
                } else {
                    state.terminalHistoryIndex = -1
                    state.terminalInput = ""
                }
            }
        }
    }
}
