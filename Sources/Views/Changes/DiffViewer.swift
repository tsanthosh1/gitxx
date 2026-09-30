import SwiftUI
import AppKit

public struct DiffViewer: View {
    @ObservedObject var state: AppState
    let diff: FileDiff?
    let title: String?
    @State private var anchorRow: Int?
    @State private var pendingDiscard: DiscardRequest?
    @State private var hoveredRow: Int?
    @State private var hoveredBlock: Int?
    /// Working-tree lines of the shown file, used to reveal unchanged lines between hunks.
    @State private var fileLines: [String]?
    @State private var expansions: [Int: GapExpansion] = [:]
    @State private var layoutCache = LayoutCache()
    /// Path of a large diff the user chose to render anyway.
    @State private var largeDiffApproved: String?

    /// Diffs above this many lines ask before rendering.
    private static let largeDiffLines = 5000

    private final class LayoutCache {
        var key = ""
        var layout = Layout()
    }

    private static let laneWidth: CGFloat = 20
    private static let checkWidth: CGFloat = 18
    private static let expandStep = 20

    private struct DiscardRequest: Identifiable {
        let id = UUID()
        let keys: Set<DiffLineKey>
        let label: String
    }

    /// Unchanged lines revealed in a gap: `top` continues below the previous hunk, `bottom` grows up from the next one.
    private struct GapExpansion: Equatable {
        var top = 0
        var bottom = 0
    }

    private enum RowKind {
        case line
        case header
        case context
        case expander(gap: Int, hidden: Int)
    }

    private struct Row: Identifiable {
        let id: Int
        let kind: RowKind
        let hunk: Int
        let index: Int
        let line: DiffLine
        /// Set for `+`/`-` rows, which can be staged individually.
        let key: DiffLineKey?
        /// Contiguous run of changed lines this row belongs to; the left lane toggles a whole run.
        let block: Int?
        let blockStart: Bool

        var isExpander: Bool { if case .expander = kind { return true } else { return false } }
    }

    private struct Layout {
        var rows: [Row] = []
        var blocks: [Set<DiffLineKey>] = []
    }

    private struct HunkRange {
        let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        /// First line number the hunk covers on each side (a zero count means "after line N").
        var oldFirst: Int { oldCount == 0 ? oldStart + 1 : oldStart }
        var newFirst: Int { newCount == 0 ? newStart + 1 : newStart }
        var oldEnd: Int { oldFirst + oldCount }
        var newEnd: Int { newFirst + newCount }
    }

    public init(state: AppState, diff: FileDiff? = nil, title: String? = nil) {
        self.state = state
        self.diff = diff
        self.title = title
    }

    private var activeDiff: FileDiff? {
        diff ?? state.currentDiff
    }

    /// Line toggling only applies to the working-copy diff of the Changes tab.
    private var lineStaging: Bool {
        diff == nil && state.activeTab == .changes && state.lineStagingEnabled
    }

    private var canDiscardLines: Bool {
        lineStaging && state.selectedFile?.changeKind != .untracked
    }

    /// Unchanged lines can be revealed when the diff's new side is the working tree.
    private var canExpandContext: Bool {
        diff == nil && state.activeTab == .changes && (state.lineStagingEnabled || state.selectedFile?.isStaged == false)
    }

    private var expansionSourceID: String {
        guard canExpandContext, let d = activeDiff else { return "" }
        return "\(d.path)|\(d.hunks.count)|\(d.additions)|\(d.deletions)|\(d.hunks.first?.header ?? "")"
    }

    private static func range(of header: String) -> HunkRange? {
        guard let match = header.firstMatch(of: /@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) else { return nil }
        return HunkRange(oldStart: Int(match.1) ?? 1, oldCount: match.2.flatMap { Int($0) } ?? 1,
                         newStart: Int(match.3) ?? 1, newCount: match.4.flatMap { Int($0) } ?? 1)
    }

    /// Layout is rebuilt only when the diff, revealed context or file lines change, not on hover.
    private func cachedLayout(_ diff: FileDiff) -> Layout {
        let source = self.diff == nil ? "live:\(state.currentDiffRevision)" : "fixed:\(diff.hunks.count):\(diff.additions):\(diff.deletions)"
        let exp = expansions.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.top):\($0.value.bottom)" }.joined(separator: ",")
        let key = "\(diff.path)|\(source)|\(exp)|\(fileLines?.count ?? -1)"
        if layoutCache.key != key {
            layoutCache.layout = layout(diff)
            layoutCache.key = key
        }
        return layoutCache.layout
    }

    private func layout(_ diff: FileDiff) -> Layout {
        var out = Layout()
        out.rows.reserveCapacity(diff.hunks.reduce(0) { $0 + $1.lines.count } + 8)
        let ranges = diff.hunks.map { Self.range(of: $0.header) }
        let lines = fileLines

        func appendContext(_ newRange: ClosedRange<Int>, delta: Int, lines: [String]) {
            for n in newRange where n >= 1 && n <= lines.count {
                let line = DiffLine(type: .context, content: lines[n - 1], oldLineNumber: n + delta, newLineNumber: n)
                out.rows.append(Row(id: out.rows.count, kind: .context, hunk: -1, index: -1, line: line, key: nil, block: nil, blockStart: false))
            }
        }

        /// Gap `g` sits before hunk `g`; gap `hunks.count` is after the last hunk.
        func appendGap(_ g: Int) {
            guard let lines, ranges.allSatisfy({ $0 != nil }) else { return }
            let from = g == 0 ? 1 : ranges[g - 1]!.newEnd
            let to = g == diff.hunks.count ? lines.count : ranges[g]!.newFirst - 1
            guard to >= from else { return }
            let delta = g == diff.hunks.count
                ? ranges[g - 1]!.oldEnd - ranges[g - 1]!.newEnd
                : ranges[g]!.oldFirst - ranges[g]!.newFirst
            let total = to - from + 1
            let exp = expansions[g] ?? GapExpansion()
            let top = min(g == 0 ? 0 : exp.top, total)
            let bottom = min(g == diff.hunks.count ? 0 : exp.bottom, total - top)
            if top > 0 { appendContext(from...(from + top - 1), delta: delta, lines: lines) }
            let hidden = total - top - bottom
            if hidden > 0 {
                out.rows.append(Row(id: out.rows.count, kind: .expander(gap: g, hidden: hidden), hunk: -1, index: -1,
                                    line: DiffLine(type: .context, content: ""), key: nil, block: nil, blockStart: false))
            }
            if bottom > 0 { appendContext((to - bottom + 1)...to, delta: delta, lines: lines) }
        }

        for (h, hunk) in diff.hunks.enumerated() {
            appendGap(h)
            var currentBlock: Int?
            for (i, line) in hunk.lines.enumerated() {
                let selectable = line.type == .addition || line.type == .deletion
                let kind: RowKind = line.type == .hunkHeader ? .header : .line
                var blockStart = false
                if selectable {
                    if currentBlock == nil {
                        out.blocks.append([])
                        currentBlock = out.blocks.count - 1
                        blockStart = true
                    }
                    out.blocks[currentBlock!].insert(DiffLineKey(hunk: h, line: i))
                } else {
                    currentBlock = nil
                }
                out.rows.append(Row(id: out.rows.count, kind: kind, hunk: h, index: i, line: line,
                                    key: selectable ? DiffLineKey(hunk: h, line: i) : nil,
                                    block: selectable ? currentBlock : nil, blockStart: blockStart))
            }
        }
        if !diff.hunks.isEmpty { appendGap(diff.hunks.count) }
        return out
    }

    private func expand(gap: Int, up: Bool, all: Bool = false) {
        var exp = expansions[gap] ?? GapExpansion()
        let step = all ? Int.max / 4 : Self.expandStep
        if up { exp.bottom += step } else { exp.top += step }
        expansions[gap] = exp
    }

    private func loadFileLines() async {
        guard canExpandContext, let path = activeDiff?.path, let repoPath = state.currentRepo?.path else {
            fileLines = nil
            return
        }
        let url = URL(fileURLWithPath: repoPath).appendingPathComponent(path)
        let loaded: [String]? = await Task.detached(priority: .userInitiated) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            var parts = text.components(separatedBy: "\n")
            if parts.last == "" { parts.removeLast() }
            return parts
        }.value
        fileLines = loaded
    }

    private func isStaged(_ row: Row) -> Bool {
        row.key.map(state.currentDiffStagedLines.contains) ?? false
    }

    private func hunkKeys(_ hunk: Int, in diff: FileDiff) -> Set<DiffLineKey> {
        Set(PartialPatch.selectableIndices(in: diff.hunks[hunk]).map { DiffLineKey(hunk: hunk, line: $0) })
    }

    /// Click toggles one line; ⇧-click applies the clicked line's new state to every line since the last click.
    private func toggleLine(_ row: Row, in rows: [Row]) {
        guard lineStaging, let key = row.key else { return }
        let stage = !state.currentDiffStagedLines.contains(key)
        var keys: Set<DiffLineKey> = [key]
        if NSEvent.modifierFlags.contains(.shift), let anchor = anchorRow, anchor != row.id, rows.indices.contains(anchor) {
            keys = Set(rows[min(anchor, row.id)...max(anchor, row.id)].compactMap(\.key))
        }
        anchorRow = row.id
        state.setLinesStaged(keys, staged: stage)
    }

    private var tint: Color { state.accentTheme.primaryColor }
    private var selectionFill: Color { tint.opacity(0.42) }

    private func changeColor(_ type: DiffLineType, strong: Bool) -> Color {
        switch type {
        case .addition: return Color.green.opacity(strong ? 0.32 : 0.10)
        case .deletion: return Color.red.opacity(strong ? 0.32 : 0.10)
        default: return Color.secondary.opacity(0.06)
        }
    }

    private func numberText(_ n: Int?, width: CGFloat = 40) -> some View {
        Text(verbatim: n.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .frame(width: width, alignment: .trailing)
            .padding(.trailing, 6)
    }

    /// Left lane (GitHub Desktop style): spans each run of changed lines; a dash marks a partial selection and a
    /// tick a full one. Clicking it toggles the whole run.
    @ViewBuilder
    private func lane(_ row: Row, blocks: [Set<DiffLineKey>]) -> some View {
        if lineStaging {
            if let b = row.block, blocks.indices.contains(b) {
                let keys = blocks[b]
                let staged = keys.intersection(state.currentDiffStagedLines).count
                let hovered = hoveredBlock == b
                let fill: Color = staged == 0
                    ? Color.secondary.opacity(hovered ? 0.35 : 0.16)
                    : tint.opacity(hovered ? 0.6 : 0.45)
                ZStack {
                    Rectangle().fill(fill)
                    if row.blockStart && staged > 0 {
                        Image(systemName: staged == keys.count ? "checkmark" : "minus")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: Self.laneWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { state.setLinesStaged(keys, staged: staged < keys.count) }
                .onHover { inside in
                    if inside { hoveredBlock = b } else if hoveredBlock == b { hoveredBlock = nil }
                }
                .pointerCursor()
                .help(staged == keys.count ? "Unstage these lines" : "Stage these lines")
            } else {
                Color.secondary.opacity(0.04)
                    .frame(width: Self.laneWidth)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    /// Line-number gutter with its own tick column; clicking a changed line toggles it.
    private func stagingGutter<Content: View>(_ row: Row, active: Bool, allRows: [Row], @ViewBuilder _ content: () -> Content) -> some View {
        let selectable = lineStaging && active && row.key != nil
        let staged = selectable && isStaged(row)
        let hovered = selectable && hoveredRow == row.id
        let background: Color = staged
            ? (hovered ? tint.opacity(0.55) : selectionFill)
            : (active && row.key != nil ? changeColor(row.line.type, strong: hovered) : Color.secondary.opacity(0.06))
        return HStack(spacing: 0) {
            if lineStaging {
                ZStack {
                    if staged {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                    }
                }
                .frame(width: Self.checkWidth)
            }
            content()
        }
        .foregroundStyle(staged ? Color.primary.opacity(0.9) : Color.secondary.opacity(0.6))
        .frame(maxHeight: .infinity)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture { if selectable { toggleLine(row, in: allRows) } }
        .onHover { inside in
            guard selectable else { return }
            if inside { hoveredRow = row.id } else if hoveredRow == row.id { hoveredRow = nil }
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: Row, in diff: FileDiff) -> some View {
        if lineStaging, let key = row.key {
            let staged = isStaged(row)
            Button(staged ? "Unstage Line" : "Stage Line") { state.setLinesStaged([key], staged: !staged) }
            let hunk = hunkKeys(row.hunk, in: diff)
            let allStaged = state.currentDiffStagedLines.isSuperset(of: hunk)
            Button(allStaged ? "Unstage Hunk" : "Stage Hunk") { state.setLinesStaged(hunk, staged: !allStaged) }
            if canDiscardLines {
                Divider()
                Button("Discard Line…", role: .destructive) {
                    pendingDiscard = DiscardRequest(keys: [key], label: "Discard Line")
                }
                Button("Discard Hunk…", role: .destructive) {
                    pendingDiscard = DiscardRequest(keys: hunk, label: "Discard Hunk")
                }
            }
        }
    }

    @ViewBuilder
    private func hunkHeader(_ row: Row, in diff: FileDiff, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            if lineStaging {
                Color.secondary.opacity(0.04).frame(width: Self.laneWidth)
            }
            Image(systemName: "ellipsis")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
                .padding(.leading, lineStaging ? 4 : 10)
            Text(row.line.content)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            if canDiscardLines {
                Button("Discard hunk") {
                    pendingDiscard = DiscardRequest(keys: hunkKeys(row.hunk, in: diff), label: "Discard Hunk")
                }
                .buttonStyle(PRActionButtonStyle(.subtle, size: .compact))
            }
        }
        .frame(height: 30)
        .padding(.trailing, 10)
        .frame(width: width, alignment: .leading)
        .background(Color.white.opacity(0.05))
    }

    /// Row between hunks: arrows reveal unchanged lines above or below, like GitHub's expanders.
    private func expanderRow(gap: Int, hidden: Int, hunkCount: Int, width: CGFloat) -> some View {
        let canUp = gap < hunkCount
        let canDown = gap > 0
        return HStack(spacing: 0) {
            if lineStaging {
                Color.secondary.opacity(0.04).frame(width: Self.laneWidth)
            }
            HStack(spacing: 2) {
                if hidden <= Self.expandStep {
                    expandButton("arrow.up.and.down", help: "Show \(hidden) unchanged lines") { expand(gap: gap, up: canUp, all: true) }
                } else {
                    if canDown {
                        expandButton("arrow.down", help: "Show \(Self.expandStep) more lines below") { expand(gap: gap, up: false) }
                    }
                    if canUp {
                        expandButton("arrow.up", help: "Show \(Self.expandStep) more lines above") { expand(gap: gap, up: true) }
                    }
                }
            }
            .frame(width: (lineStaging ? Self.checkWidth : 0) + 92, alignment: .center)
            .frame(maxHeight: .infinity)
            .background(Color.secondary.opacity(0.08))
            Button {
                expand(gap: gap, up: canUp, all: true)
            } label: {
                Text(hidden == 1 ? "1 unchanged line" : "\(hidden) unchanged lines")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
            .buttonStyle(.hoverPlain)
            .pointerCursor()
            .help("Show all")
            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .frame(width: width, alignment: .leading)
        .background(Color.accentColor.opacity(0.04))
    }

    private func expandButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .pointerCursor()
        .help(help)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Diff Header Bar
            HStack(spacing: 12) {
                // File info
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.secondary)

                    let fullTitle = title ?? activeDiff?.path ?? "No file selected"
                    Text(state.isNarrowWidth ? (fullTitle as NSString).lastPathComponent : fullTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(fullTitle)
                }
                .layoutPriority(1)

                if let current = activeDiff {
                    HStack(spacing: 6) {
                        Text("+\(current.additions)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)

                        Text("-\(current.deletions)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                    .fixedSize()
                }

                if lineStaging, !state.isNarrowWidth, let current = activeDiff {
                    let total = PartialPatch.changedLines(in: current).count
                    let staged = state.currentDiffStagedLines.count
                    Text(staged == 0 ? "Nothing staged" : (staged == total ? "All lines staged" : "\(staged) of \(total) lines staged"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .help("Click a line number to stage or unstage that line (⇧-click for a range); click the bar on the left to toggle a block of changes")
                }

                Spacer(minLength: 8)

                // Split / Unified Diff View Toggle
                Picker("", selection: $state.diffMode) {
                    ForEach(DiffDisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: state.isNarrowWidth ? 112 : 140)

                // Open in External Editor
                if let path = activeDiff?.path, let repoPath = state.currentRepo?.path {
                    Button {
                        let fullPath = (repoPath as NSString).appendingPathComponent(path)
                        LinkRouter.open(URL(fileURLWithPath: fullPath))
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 12))
                            if !state.isNarrowWidth {
                                Text("Open")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .frame(height: 26)
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .help("Open in Default External Editor")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .themedSurface(state.accentTheme, .header)

            Divider()

            // Diff Content Area
            if let activeDiff = activeDiff {
                if activeDiff.isBinary {
                    binaryFileNotice
                } else if activeDiff.hunks.isEmpty {
                    emptyDiffNotice
                } else if largeDiffApproved != activeDiff.path,
                          case let lines = activeDiff.hunks.reduce(0, { $0 + $1.lines.count }), lines > Self.largeDiffLines {
                    largeDiffNotice(activeDiff, lines: lines)
                } else {
                    if state.diffMode == .unified {
                        unifiedDiffView(activeDiff)
                    } else {
                        splitDiffView(activeDiff)
                    }
                }
            } else {
                noSelectionPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.12))
        .onChange(of: activeDiff?.path) { _, _ in
            anchorRow = nil
            expansions = [:]
        }
        .task(id: expansionSourceID) { await loadFileLines() }
        .confirmationDialog(
            "Discard these changes?",
            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
            presenting: pendingDiscard
        ) { request in
            Button(request.label, role: .destructive) {
                state.discardLines(request.keys)
            }
        } message: { _ in
            Text("The working-copy changes will be lost. This can't be undone.")
        }
    }

    // MARK: - Unified Diff View

    @ViewBuilder
    private func unifiedDiffView(_ diff: FileDiff) -> some View {
        GeometryReader { proxy in
            let built = cachedLayout(diff)
            let allRows = built.rows
            // A single two-axis scroll view keeps the LazyVStack lazy; nesting a horizontal
            // ScrollView inside a vertical one forces every line to be built up front.
            ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(allRows) { row in
                            let line = row.line
                            switch row.kind {
                            case .header:
                                hunkHeader(row, in: diff, width: proxy.size.width)
                            case .expander(let gap, let hidden):
                                expanderRow(gap: gap, hidden: hidden, hunkCount: diff.hunks.count, width: proxy.size.width)
                            case .line, .context:
                                HStack(alignment: .center, spacing: 0) {
                                    lane(row, blocks: built.blocks)
                                    stagingGutter(row, active: true, allRows: allRows) {
                                        numberText(line.oldLineNumber)
                                        numberText(line.newLineNumber)
                                            .padding(.trailing, 2)
                                    }
                                    .overlay(alignment: .trailing) {
                                        Rectangle()
                                            .fill(Color.secondary.opacity(0.12))
                                            .frame(width: 1)
                                    }

                                    Text(line.type.prefixSymbol)
                                        .frame(width: 20, alignment: .center)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(line.type.textColor)

                                    Text(line.content.isEmpty ? " " : line.content)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(line.type == .addition ? Color.green : (line.type == .deletion ? Color.red : Color.primary))
                                        .padding(.leading, 4)

                                    Spacer(minLength: 40)
                                }
                                .frame(height: 22)
                                .frame(minWidth: proxy.size.width, alignment: .leading)
                                .background(line.type.backgroundColor)
                                .contextMenu { rowMenu(row, in: diff) }
                            }
                        }
                    }
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
    }

    // MARK: - Split (Side-by-Side) Diff View

    @ViewBuilder
    private func splitDiffView(_ diff: FileDiff) -> some View {
        GeometryReader { proxy in
            let colWidth = max(proxy.size.width / 2, 450)
            let built = cachedLayout(diff)
            let allRows = built.rows
            let fullWidth = colWidth * 2 + (lineStaging ? Self.laneWidth : 0)
            // A single two-axis scroll view keeps the LazyVStack lazy; nesting a horizontal
            // ScrollView inside a vertical one forces every line to be built up front.
            ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(allRows) { row in
                            let line = row.line
                            switch row.kind {
                            case .header:
                                hunkHeader(row, in: diff, width: fullWidth)
                            case .expander(let gap, let hidden):
                                expanderRow(gap: gap, hidden: hidden, hunkCount: diff.hunks.count, width: fullWidth)
                            case .line, .context:
                                HStack(spacing: 0) {
                                    lane(row, blocks: built.blocks)
                                    // Left Pane (Old code / deletions)
                                    HStack(spacing: 0) {
                                        stagingGutter(row, active: line.type == .deletion, allRows: allRows) {
                                            numberText(line.oldLineNumber)
                                        }

                                        Text(line.type == .deletion || line.type == .context ? line.content : "")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(line.type == .deletion ? Color.red : Color.primary)
                                            .padding(.leading, 4)

                                        Spacer(minLength: 4)
                                    }
                                    .frame(width: colWidth, height: 22, alignment: .leading)
                                    .background(line.type == .deletion ? Color.red.opacity(0.15) : Color.clear)

                                    Divider()

                                    // Right Pane (New code / additions)
                                    HStack(spacing: 0) {
                                        stagingGutter(row, active: line.type == .addition, allRows: allRows) {
                                            numberText(line.newLineNumber)
                                        }

                                        Text(line.type == .addition || line.type == .context ? line.content : "")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(line.type == .addition ? Color.green : Color.primary)
                                            .padding(.leading, 4)

                                        Spacer(minLength: 4)
                                    }
                                    .frame(width: colWidth, height: 22, alignment: .leading)
                                    .background(line.type == .addition ? Color.green.opacity(0.15) : Color.clear)
                                }
                                .frame(height: 22)
                                .contextMenu { rowMenu(row, in: diff) }
                            }
                        }
                    }
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
            }
        }
    }

    // MARK: - State Placeholders

    private var noSelectionPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("Select a file to inspect diff")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var binaryFileNotice: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.zipper")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Binary file differs")
                .font(.headline)
            Text("GitXX does not show inline diffs for binary assets.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func largeDiffNotice(_ diff: FileDiff, lines: Int) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.text.below.ecg")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Large diff")
                .font(.headline)
            Text("\(lines.formatted()) lines changed (+\(diff.additions.formatted()) −\(diff.deletions.formatted())). Rendering it may take a moment.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Show diff anyway") { largeDiffApproved = diff.path }
                .buttonStyle(PRActionButtonStyle(.secondary))
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
    }

    private var emptyDiffNotice: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "equal.circle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No textual changes")
                .font(.headline)
            Text("File contents match the index or HEAD.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
