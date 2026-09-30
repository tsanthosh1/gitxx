import SwiftUI
import AppKit

/// One line of `git blame --porcelain` output with its commit details.
struct BlameLine: Identifiable, Sendable {
    let id: Int
    let sha: String
    let author: String
    let date: Date
    let summary: String
    let content: String
    /// First line of a run attributed to the same commit; only these show the gutter text.
    var startsRun: Bool

    var isUncommitted: Bool { sha.allSatisfy { $0 == "0" } }
}

enum BlameParser {
    static func parse(_ porcelain: String) -> [BlameLine] {
        struct Info { var author = ""; var time: TimeInterval = 0; var summary = "" }
        var infos: [String: Info] = [:]
        var lines: [BlameLine] = []
        var sha = ""
        var info = Info()
        for raw in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("\t") {
                infos[sha] = info
                let previous = lines.last?.sha
                lines.append(BlameLine(id: lines.count, sha: sha, author: info.author, date: Date(timeIntervalSince1970: info.time),
                                       summary: info.summary, content: String(raw.dropFirst()), startsRun: previous != sha))
                continue
            }
            let parts = raw.split(separator: " ", maxSplits: 1)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            if key.count == 40, key.allSatisfy(\.isHexDigit) {
                sha = String(key)
                info = infos[sha] ?? Info()
            } else if key == "author" {
                info.author = value
            } else if key == "author-time" {
                info.time = TimeInterval(value) ?? 0
            } else if key == "summary" {
                info.summary = value
            }
        }
        return lines
    }
}

/// Full-file blame with a commit gutter. `revision` nil blames the working copy, so uncommitted lines show up too.
struct BlameView: View {
    @ObservedObject var state: AppState
    let repoPath: String
    let path: String
    let revision: String?
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [BlameLine] = []
    @State private var error: String?
    @State private var loading = true
    @State private var hoveredSha: String?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.text.rectangle").foregroundStyle(.secondary)
                Text("Blame").font(.system(size: 13, weight: .semibold))
                Text(path).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let revision {
                    Text("at \(String(revision.prefix(7)))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if !lines.isEmpty {
                    Text("\(Set(lines.map(\.sha)).count) commits · \(Set(lines.map(\.author)).count) authors")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in row(line) }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(minWidth: 960, idealWidth: 1100, minHeight: 560, idealHeight: 720)
        .task { await load() }
    }

    private func row(_ line: BlameLine) -> some View {
        HStack(spacing: 0) {
            gutter(line)
                .frame(width: 330, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(hoveredSha == line.sha ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05))
                .overlay(alignment: .top) {
                    if line.startsRun && line.id > 0 { Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1) }
                }
                .contentShape(Rectangle())
                .onHover { hoveredSha = $0 ? line.sha : (hoveredSha == line.sha ? nil : hoveredSha) }
                .onTapGesture { open(line) }
                .help(line.isUncommitted ? "Not committed yet" : "\(String(line.sha.prefix(7))) \(line.summary)\n\(line.author), \(Self.dateFormatter.string(from: line.date))")
            Text("\(line.id + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.7))
                .frame(width: 48, alignment: .trailing)
                .padding(.trailing, 10)
            Text(line.content.isEmpty ? " " : line.content)
                .font(.system(size: 12, design: .monospaced))
                .fixedSize()
            Spacer(minLength: 20)
        }
        .frame(height: 20)
        .background(hoveredSha == line.sha ? Color.accentColor.opacity(0.05) : .clear)
    }

    @ViewBuilder
    private func gutter(_ line: BlameLine) -> some View {
        if line.startsRun {
            HStack(spacing: 8) {
                Text(line.isUncommitted ? "·······" : String(line.sha.prefix(7)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(line.isUncommitted ? Color.orange : Color.accentColor)
                Text(line.isUncommitted ? "Uncommitted change" : line.summary)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if !line.isUncommitted {
                    Text(line.author).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 90, alignment: .trailing)
                    Text(Self.dateFormatter.string(from: line.date)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        } else {
            Color.clear
        }
    }

    private func open(_ line: BlameLine) {
        guard !line.isUncommitted else { return }
        if let commit = state.commits.first(where: { $0.sha == line.sha }) {
            dismiss()
            state.activeTab = .history
            state.selectCommit(commit)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line.sha, forType: .string)
            state.showToast("Copied \(String(line.sha.prefix(7))) — it isn't in the loaded history", type: .info)
        }
    }

    private func load() async {
        var args = ["blame", "--porcelain"]
        if let revision { args.append(revision) }
        args += ["--", path]
        do {
            let result = try await GitService.shared.execute(arguments: args, in: repoPath)
            if result.isSuccess {
                lines = BlameParser.parse(result.stdout)
                if lines.isEmpty { error = "This file is empty." }
            } else {
                error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "git blame failed." : result.stderr
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
