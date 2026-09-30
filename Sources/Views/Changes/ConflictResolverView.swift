import SwiftUI

// MARK: - Model

/// Per-file three-way merge state: each conflict takes Yours, Theirs, both (in the order applied), or custom text.
@MainActor
final class ConflictMergeModel: ObservableObject {
    enum Side { case ours, theirs }
    enum SideState: Equatable { case pending, applied, ignored }

    struct Chunk: Equatable {
        var ours: SideState = .pending
        var theirs: SideState = .pending
        var order: [Side] = []
        var custom: [String]?

        var isResolved: Bool { custom != nil || (ours != .pending && theirs != .pending) }
    }

    let repo: String
    let path: String
    @Published var document: ConflictDocument?
    @Published var loadError: String?
    @Published var chunks: [Int: Chunk] = [:]
    @Published var current: Int = 0
    @Published var textMode = false
    @Published var editedText = ""

    init(repo: String, path: String) {
        self.repo = repo
        self.path = path
    }

    func load() async {
        do {
            let doc = try await ConflictMerge.load(repo: repo, path: path)
            document = doc
            chunks = Dictionary(uniqueKeysWithValues: conflictIds.map { ($0, Chunk()) })
        } catch {
            loadError = error.localizedDescription
        }
    }

    var conflictIds: [Int] {
        document?.segments.compactMap { if case let .conflict(id, _, _, _) = $0 { return id }; return nil } ?? []
    }

    var unresolvedCount: Int { conflictIds.filter { chunks[$0]?.isResolved != true }.count }

    func lines(for id: Int) -> (ours: [String], base: [String], theirs: [String]) {
        for segment in document?.segments ?? [] {
            if case let .conflict(cid, ours, base, theirs) = segment, cid == id { return (ours, base, theirs) }
        }
        return ([], [], [])
    }

    /// What the result pane shows for a conflict: custom text, the applied sides in order, or the base while undecided.
    func result(for id: Int) -> [String] {
        let chunk = chunks[id] ?? Chunk()
        if let custom = chunk.custom { return custom }
        let l = lines(for: id)
        if chunk.order.isEmpty { return chunk.isResolved ? [] : l.base }
        return chunk.order.flatMap { $0 == .ours ? l.ours : l.theirs }
    }

    func apply(_ side: Side, _ id: Int) {
        var chunk = chunks[id] ?? Chunk()
        chunk.custom = nil
        if side == .ours { chunk.ours = .applied } else { chunk.theirs = .applied }
        if !chunk.order.contains(side) { chunk.order.append(side) }
        chunks[id] = chunk
        advanceIfResolved(id)
    }

    func ignore(_ side: Side, _ id: Int) {
        var chunk = chunks[id] ?? Chunk()
        chunk.custom = nil
        if side == .ours { chunk.ours = .ignored } else { chunk.theirs = .ignored }
        chunk.order.removeAll { $0 == side }
        chunks[id] = chunk
        advanceIfResolved(id)
    }

    /// One click: take this side and drop the other.
    func take(_ side: Side, _ id: Int) {
        var chunk = Chunk()
        chunk.ours = side == .ours ? .applied : .ignored
        chunk.theirs = side == .theirs ? .applied : .ignored
        chunk.order = [side]
        chunks[id] = chunk
        advanceIfResolved(id)
    }

    func setCustom(_ text: String, _ id: Int) {
        var chunk = chunks[id] ?? Chunk()
        chunk.custom = text.isEmpty ? [] : text.components(separatedBy: "\n")
        chunks[id] = chunk
    }

    func reset(_ id: Int) { chunks[id] = Chunk() }

    func takeAll(_ side: Side) {
        for id in conflictIds { take(side, id) }
    }

    /// IntelliJ's "Resolve simple conflicts": one side unchanged from base, or both sides made the same change.
    @discardableResult
    func resolveSimple() -> Int {
        var count = 0
        for id in conflictIds where chunks[id]?.isResolved != true {
            let l = lines(for: id)
            if l.ours == l.theirs || l.theirs == l.base { take(.ours, id); count += 1 }
            else if l.ours == l.base { take(.theirs, id); count += 1 }
        }
        return count
    }

    private func advanceIfResolved(_ id: Int) {
        guard chunks[id]?.isResolved == true, let index = conflictIds.firstIndex(of: id), index == current else { return }
        if let next = conflictIds.indices.first(where: { $0 > index && chunks[conflictIds[$0]]?.isResolved != true })
            ?? conflictIds.indices.first(where: { chunks[conflictIds[$0]]?.isResolved != true }) {
            current = next
        }
    }

    func move(_ delta: Int) {
        let ids = conflictIds
        guard !ids.isEmpty else { return }
        current = (current + delta + ids.count) % ids.count
    }

    var resultText: String {
        if textMode { return editedText }
        var out: [String] = []
        for segment in document?.segments ?? [] {
            switch segment {
            case .common(let lines): out += lines
            case .conflict(let id, _, _, _): out += result(for: id)
            }
        }
        return out.joined(separator: "\n") + ((document?.trailingNewline ?? true) && !out.isEmpty ? "\n" : "")
    }

    func enterTextMode() {
        editedText = resultText
        textMode = true
    }
}

// MARK: - View

/// IntelliJ-style three-pane merge: Yours | Result | Theirs, aligned conflict by conflict.
struct ConflictResolverView: View {
    @ObservedObject var state: AppState
    let sides: ConflictSides
    let inWindow: Bool
    let onDone: (Bool) -> Void
    @StateObject private var model: ConflictMergeModel
    @State private var expanded: Set<Int> = []
    @State private var editingChunk: Int?
    @State private var chunkDraft = ""
    @State private var applying = false
    @State private var confirmUnresolved = false

    init(state: AppState, repo: String, path: String, sides: ConflictSides, inWindow: Bool = false, onDone: @escaping (Bool) -> Void) {
        self.state = state
        self.sides = sides
        self.inWindow = inWindow
        self.onDone = onDone
        _model = StateObject(wrappedValue: ConflictMergeModel(repo: repo, path: path))
    }

    private var accent: Color { state.accentTheme.primaryColor }
    private static let oursTint = Color(red: 0.35, green: 0.55, blue: 1.0)
    private static let theirsTint = Color(red: 0.3, green: 0.8, blue: 0.45)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.loadError {
                message("Couldn't load the conflict: \(error)", icon: "exclamationmark.triangle.fill", color: .orange)
            } else if let doc = model.document {
                if doc.isBinary || doc.oursMissing || doc.theirsMissing {
                    wholeFileChoice(doc)
                } else if model.textMode {
                    textEditorPane
                } else {
                    columnHeaders
                    Divider()
                    mergePanes(doc)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: inWindow ? 900 : 1100, idealWidth: 1280, maxWidth: inWindow ? .infinity : nil,
               minHeight: inWindow ? 500 : 640, idealHeight: 780, maxHeight: inWindow ? .infinity : nil)
        .task { await model.load() }
        .background(keyShortcuts)
        .alert("Apply with unresolved conflicts?", isPresented: $confirmUnresolved) {
            Button("Apply Anyway", role: .destructive) { Task { await apply() } }
            Button("Keep Resolving", role: .cancel) {}
        } message: {
            Text("\(model.unresolvedCount) conflict\(model.unresolvedCount == 1 ? "" : "s") will keep the base version (the text before either change).")
        }
    }

    // MARK: Header & footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text((model.path as NSString).lastPathComponent).font(.system(size: 14, weight: .semibold))
                Text(model.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if let doc = model.document, doc.conflictCount > 0, !model.textMode {
                let unresolved = model.unresolvedCount
                Text(unresolved == 0 ? "All \(doc.conflictCount) resolved" : "\(unresolved) of \(doc.conflictCount) unresolved")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(unresolved == 0 ? Color.green : Color.orange)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background((unresolved == 0 ? Color.green : Color.orange).opacity(0.14), in: Capsule())
                HStack(spacing: 2) {
                    Button { model.move(-1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.icon(size: 26)).help("Previous conflict (⌥↑)")
                    Button { model.move(1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.icon(size: 26)).help("Next conflict (⌥↓)")
                }
                Button {
                    let n = model.resolveSimple()
                    state.showToast(n == 0 ? "No simple conflicts: each one changes both sides differently" : "Resolved \(n) simple conflict\(n == 1 ? "" : "s")", type: .info)
                } label: { Label("Resolve Simple", systemImage: "wand.and.stars") }
                    .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                    .help("Take the only changed side, or the shared change when both sides did the same thing")
                Button { model.takeAll(.ours) } label: { Text("Accept \(sides.oursTitle)") }
                    .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                Button { model.takeAll(.theirs) } label: { Text("Accept \(sides.theirsTitle)") }
                    .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
            }
            if inWindow {
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.icon(size: 26))
                .help("Full screen (⌃⌘F)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let doc = model.document, !doc.isBinary, !doc.oursMissing, !doc.theirsMissing {
                Toggle(isOn: Binding(get: { model.textMode }, set: { on in
                    if on { model.enterTextMode() } else { model.textMode = false }
                })) {
                    Text("Edit result as text").font(.system(size: 12))
                }
                .toggleStyle(.checkbox)
                .help("Edit the whole merged file freely; conflict buttons are paused while this is on")
            }
            Spacer()
            Text("⌥↑ ⌥↓ move between conflicts · ⌘↩ apply")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Button("Cancel") { onDone(false) }
                .buttonStyle(PRActionButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
            Button {
                if !model.textMode && model.unresolvedCount > 0 { confirmUnresolved = true } else { Task { await apply() } }
            } label: {
                HStack(spacing: 6) {
                    if applying { ProgressView().controlSize(.small) }
                    Text("Apply")
                    KeyCap("⌘"); KeyCap("↩")
                }
            }
            .buttonStyle(PRActionButtonStyle(.primary(accent)))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(applying || model.document == nil || model.document?.isBinary == true
                      || model.document?.oursMissing == true || model.document?.theirsMissing == true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var keyShortcuts: some View {
        ZStack {
            Button("") { model.move(-1) }.keyboardShortcut(.upArrow, modifiers: .option)
            Button("") { model.move(1) }.keyboardShortcut(.downArrow, modifiers: .option)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func apply() async {
        applying = true
        defer { applying = false }
        let text = model.resultText
        if model.textMode, text.contains("\n<<<<<<< ") || text.hasPrefix("<<<<<<< ") {
            state.showToast("The text still has conflict markers (<<<<<<<). Remove them first.", type: .error)
            return
        }
        do {
            try await ConflictMerge.apply(repo: model.repo, path: model.path, text: text)
            state.showToast("Resolved \((model.path as NSString).lastPathComponent)", type: .success)
            onDone(true)
        } catch {
            state.showToast("Couldn't save: \(error.localizedDescription)", type: .error)
        }
    }

    // MARK: Panes

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            columnTitle(sides.oursTitle, sides.oursDetail, color: Self.oursTint, icon: "person.fill")
            Color.clear.frame(width: gutterWidth)
            columnTitle("Result", "Saved to \((model.path as NSString).lastPathComponent)", color: accent, icon: "arrow.triangle.merge")
            Color.clear.frame(width: gutterWidth)
            columnTitle(sides.theirsTitle, sides.theirsDetail, color: Self.theirsTint, icon: "arrow.down.to.line")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func columnTitle(_ title: String, _ detail: String, color: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private let gutterWidth: CGFloat = 34

    private func mergePanes(_ doc: ConflictDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(doc.segments.enumerated()), id: \.offset) { index, segment in
                        switch segment {
                        case .common(let lines):
                            commonRow(index: index, lines: lines, isFirst: index == 0, isLast: index == doc.segments.count - 1)
                        case .conflict(let id, _, _, _):
                            conflictRow(id: id).id("conflict-\(id)")
                        }
                    }
                }
                .padding(8)
            }
            .background(Color.black.opacity(0.12))
            .onChange(of: model.current) { _, index in
                guard model.conflictIds.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("conflict-\(model.conflictIds[index])", anchor: .center) }
            }
            .onChange(of: model.document?.path) { _, _ in
                if let first = model.conflictIds.first {
                    DispatchQueue.main.async { proxy.scrollTo("conflict-\(first)", anchor: .center) }
                }
            }
        }
    }

    private func commonRow(index: Int, lines: [String], isFirst: Bool, isLast: Bool) -> some View {
        let context = 4
        let collapsible = lines.count > context * 2 + 3 && !expanded.contains(index)
        let head = collapsible && !isFirst ? Array(lines.prefix(context)) : (collapsible ? [] : lines)
        let tail = collapsible && !isLast ? Array(lines.suffix(context)) : []
        let hidden = collapsible ? lines.count - head.count - tail.count : 0
        return VStack(spacing: 0) {
            if !head.isEmpty { threeColumns(head, head, head, dim: true) }
            if hidden > 0 {
                Button {
                    _ = withAnimation(.easeOut(duration: 0.15)) { expanded.insert(index) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.and.down").font(.system(size: 9.5, weight: .semibold))
                        Text("\(hidden) unchanged line\(hidden == 1 ? "" : "s")").font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .background(Color.primary.opacity(0.04))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
            }
            if !tail.isEmpty { threeColumns(tail, tail, tail, dim: true) }
        }
    }

    private func conflictRow(id: Int) -> some View {
        let l = model.lines(for: id)
        let chunk = model.chunks[id] ?? ConflictMergeModel.Chunk()
        let result = model.result(for: id)
        let isCurrent = model.conflictIds.firstIndex(of: id) == model.current
        let rows = max(l.ours.count, l.theirs.count, result.count, 1)
        return HStack(alignment: .top, spacing: 0) {
            codeBlock(l.ours, rows: rows, tint: Self.oursTint, state: chunk.ours)
            gutter(side: .ours, id: id, sideState: chunk.ours)
            resultBlock(id: id, lines: result, rows: rows, chunk: chunk, base: l.base)
            gutter(side: .theirs, id: id, sideState: chunk.theirs)
            codeBlock(l.theirs, rows: rows, tint: Self.theirsTint, state: chunk.theirs)
        }
        .padding(.vertical, 3)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isCurrent ? accent.opacity(0.7) : Color.clear, lineWidth: 1.5)
                .padding(.horizontal, -3)
        )
        .contentShape(Rectangle())
        .onTapGesture { if let i = model.conflictIds.firstIndex(of: id) { model.current = i } }
    }

    private func gutter(side: ConflictMergeModel.Side, id: Int, sideState: ConflictMergeModel.SideState) -> some View {
        VStack(spacing: 3) {
            if sideState == .pending && editingChunk != id && model.chunks[id]?.custom == nil {
                Button {
                    model.apply(side, id)
                } label: {
                    Image(systemName: side == .ours ? "chevron.right.2" : "chevron.left.2")
                        .font(.system(size: 10.5, weight: .bold))
                }
                .buttonStyle(.icon(size: 24))
                .foregroundStyle(side == .ours ? Self.oursTint : Self.theirsTint)
                .help(side == .ours ? "Apply \(sides.oursTitle) to the result" : "Apply \(sides.theirsTitle) to the result")
                Button { model.ignore(side, id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold))
                }
                .buttonStyle(.icon(size: 24))
                .foregroundStyle(.secondary)
                .help("Ignore this side")
            } else if sideState == .applied {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green).frame(height: 24)
            } else if sideState == .ignored {
                Image(systemName: "minus").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary).frame(height: 24)
            }
        }
        .frame(width: gutterWidth)
        .padding(.top, 2)
    }

    private func resultBlock(id: Int, lines: [String], rows: Int, chunk: ConflictMergeModel.Chunk, base: [String]) -> some View {
        let resolved = chunk.isResolved
        let tint = resolved ? accent : Color.red
        return ZStack(alignment: .topTrailing) {
            if editingChunk == id {
                VStack(alignment: .trailing, spacing: 4) {
                    PlainCodeEditor(text: $chunkDraft)
                        .frame(minHeight: CGFloat(max(rows, 3)) * 17 + 16)
                        .padding(4)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    HStack(spacing: 6) {
                        Button("Cancel") { editingChunk = nil }
                            .buttonStyle(PRActionButtonStyle(.secondary, size: .compact))
                        Button("Use This Text") {
                            model.setCustom(chunkDraft, id)
                            editingChunk = nil
                        }
                        .buttonStyle(PRActionButtonStyle(.primary(accent), size: .compact))
                    }
                }
                .padding(4)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            } else {
                codeBlock(lines, rows: rows, tint: tint, state: resolved ? .applied : .pending,
                          placeholder: resolved ? "(removed)" : (base.isEmpty ? "(empty in the base)" : nil))
                HStack(spacing: 2) {
                    if resolved {
                        Button { model.reset(id) } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold)) }
                            .buttonStyle(.icon(size: 22)).help("Undo this resolution")
                    }
                    Button {
                        chunkDraft = lines.joined(separator: "\n")
                        editingChunk = id
                    } label: { Image(systemName: "pencil").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.icon(size: 22)).help("Edit this part of the result")
                }
                .padding(3)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func codeBlock(_ lines: [String], rows: Int, tint: Color, state sideState: ConflictMergeModel.SideState,
                           placeholder: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if lines.isEmpty, let placeholder {
                Text(placeholder).font(.system(size: 11.5, design: .monospaced)).italic().foregroundStyle(.tertiary)
                    .frame(height: 17)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 17, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .textSelection(.enabled)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: CGFloat(rows) * 17 + 6, alignment: .topLeading)
        .background(tint.opacity(sideState == .ignored ? 0.04 : 0.13), in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .leading) {
            Rectangle().fill(tint.opacity(sideState == .ignored ? 0.3 : 0.9)).frame(width: 2.5)
        }
        .opacity(sideState == .ignored ? 0.55 : 1)
    }

    private func threeColumns(_ a: [String], _ b: [String], _ c: [String], dim: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            plain(a)
            Color.clear.frame(width: gutterWidth)
            plain(b)
            Color.clear.frame(width: gutterWidth)
            plain(c)
        }
    }

    private func plain(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 17, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textEditorPane: some View {
        PlainCodeEditor(text: $model.editedText)
            .background(Color.black.opacity(0.12))
    }

    private func wholeFileChoice(_ doc: ConflictDocument) -> some View {
        VStack(spacing: 14) {
            Image(systemName: doc.isBinary ? "doc.fill" : "trash")
                .font(.system(size: 30)).foregroundStyle(.secondary)
            Text(doc.isBinary ? "This is a binary file, so it can't be merged line by line."
                 : doc.oursMissing ? "\(sides.oursTitle) deleted this file; \(sides.theirsTitle) changed it."
                 : "\(sides.theirsTitle) deleted this file; \(sides.oursTitle) changed it.")
                .font(.system(size: 13))
            Text("Keep one version of the whole file:").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(doc.oursMissing ? "Delete (\(sides.oursTitle))" : "Keep \(sides.oursTitle)") { Task { await acceptWhole(ours: true) } }
                    .buttonStyle(PRActionButtonStyle(.secondary))
                Button(doc.theirsMissing ? "Delete (\(sides.theirsTitle))" : "Keep \(sides.theirsTitle)") { Task { await acceptWhole(ours: false) } }
                    .buttonStyle(PRActionButtonStyle(.secondary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func acceptWhole(ours: Bool) async {
        do {
            try await ConflictMerge.accept(repo: model.repo, path: model.path, ours: ours)
            onDone(true)
        } catch {
            state.showToast("Couldn't resolve: \(error.localizedDescription)", type: .error)
        }
    }

    private func message(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 12.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Window

/// Hosts the merge view in its own resizable window (zoom, full screen), unlike a fixed-size sheet.
@MainActor
enum ConflictResolverWindow {
    private static var open: [String: NSWindow] = [:]
    private static var delegates: [String: CloseDelegate] = [:]

    static func show(state: AppState, repo: String, path: String, sides: ConflictSides, onDone: @escaping (Bool) -> Void) {
        let key = repo + "\u{0}" + path
        if let existing = open[key] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1500, visible.width * 0.92), height: min(960, visible.height * 0.92))
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)

        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Merge \((path as NSString).lastPathComponent)"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 900, height: 520)
        window.appearance = NSApp.effectiveAppearance

        var finished = false
        let finish: (Bool) -> Void = { changed in
            guard !finished else { return }
            finished = true
            open[key] = nil
            delegates[key] = nil
            window.close()
            onDone(changed)
        }
        let root = ConflictResolverView(state: state, repo: repo, path: path, sides: sides, inWindow: true, onDone: finish)
            .padding(.top, 22)
            .background(Color(NSColor.windowBackgroundColor))
        window.contentView = NSHostingView(rootView: root)
        let delegate = CloseDelegate { finish(false) }
        window.delegate = delegate
        delegates[key] = delegate
        open[key] = window
        window.makeKeyAndOrderFront(nil)
    }

    private final class CloseDelegate: NSObject, NSWindowDelegate {
        let onClose: @MainActor () -> Void
        init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { onClose() }
        }
    }
}

/// Plain-text code editor (NSTextView): fast on large files and free of smart quotes / autocorrect.
struct PlainCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 12

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.delegate = context.coordinator
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
