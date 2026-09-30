import SwiftUI
import AppKit

/// Where each side of an image diff is read from.
public struct ImageDiffSources: Equatable, Sendable {
    public enum Side: Equatable, Sendable {
        /// A git revision spec such as `HEAD`, `abc123^`, or `""` for the index (read as `:<path>`).
        case revision(String)
        case workingTree
        case none
    }
    public var old: Side
    public var new: Side

    public init(old: Side, new: Side) {
        self.old = old
        self.new = new
    }

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff", "ico", "icns"]

    public static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}

/// Before/after preview for changed image files: side by side, or overlaid with an opacity slider.
struct ImageDiffView: View {
    let repoPath: String
    let path: String
    let sources: ImageDiffSources

    private struct Loaded: Equatable {
        var image: NSImage?
        var bytes: Int
        static func == (a: Loaded, b: Loaded) -> Bool { a.image === b.image && a.bytes == b.bytes }
    }

    private enum Mode: String, CaseIterable {
        case sideBySide = "2-up"
        case onion = "Onion skin"
    }

    @State private var old: Loaded?
    @State private var new: Loaded?
    @State private var loading = true
    @State private var mode: Mode = .sideBySide
    @State private var opacity: Double = 0.5

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .disabled(old?.image == nil || new?.image == nil)
                if mode == .onion, old?.image != nil, new?.image != nil {
                    Text("Before").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: $opacity, in: 0...1).frame(width: 180)
                    Text("After").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mode == .onion, let o = old?.image, let n = new?.image {
                VStack(spacing: 8) {
                    ZStack {
                        checkerboard
                        Image(nsImage: o).resizable().interpolation(.none).aspectRatio(contentMode: .fit).opacity(1 - opacity)
                        Image(nsImage: n).resizable().interpolation(.none).aspectRatio(contentMode: .fit).opacity(opacity)
                    }
                    .aspectRatio(maxSize(o, n), contentMode: .fit)
                    .frame(maxWidth: maxSize(o, n).width, maxHeight: maxSize(o, n).height)
                    caption("Before", old).foregroundStyle(.red.opacity(0.9))
                    caption("After", new).foregroundStyle(.green.opacity(0.9))
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    pane(title: "Before", loaded: old, tint: .red, missing: "Added in this change")
                    Divider()
                    pane(title: "After", loaded: new, tint: .green, missing: "Deleted in this change")
                }
            }
        }
        .task(id: "\(repoPath)|\(path)|\(String(describing: sources))") { await load() }
    }

    private func pane(title: String, loaded: Loaded?, tint: Color, missing: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(tint.opacity(0.12), in: Capsule())
            if let image = loaded?.image {
                ZStack {
                    checkerboard
                    Image(nsImage: image).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                }
                .aspectRatio(pixelSize(image), contentMode: .fit)
                .frame(maxWidth: pixelSize(image).width, maxHeight: pixelSize(image).height)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(tint.opacity(0.6), lineWidth: 1))
                caption(nil, loaded).foregroundStyle(.secondary)
            } else {
                Spacer()
                Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(.secondary.opacity(0.5))
                Text(loaded == nil ? missing : "Can't preview this image").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func caption(_ label: String?, _ loaded: Loaded?) -> some View {
        let size = loaded?.image.map(pixelSize) ?? .zero
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(loaded?.bytes ?? 0), countStyle: .file)
        let dims = "\(Int(size.width)) × \(Int(size.height)) px · \(bytes)"
        return Text(label.map { "\($0): \(dims)" } ?? dims)
            .font(.system(size: 11, design: .monospaced))
    }

    private var checkerboard: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 8
            for row in 0..<Int(ceil(size.height / cell)) {
                for col in 0..<Int(ceil(size.width / cell)) where (row + col) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                             with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }

    private func pixelSize(_ image: NSImage) -> CGSize {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    private func maxSize(_ a: NSImage, _ b: NSImage) -> CGSize {
        let x = pixelSize(a), y = pixelSize(b)
        return CGSize(width: max(x.width, y.width), height: max(x.height, y.height))
    }

    private func load() async {
        loading = true
        async let o = read(sources.old)
        async let n = read(sources.new)
        let (od, nd) = await (o, n)
        old = od.map { Loaded(image: NSImage(data: $0), bytes: $0.count) }
        new = nd.map { Loaded(image: NSImage(data: $0), bytes: $0.count) }
        if old?.image == nil || new?.image == nil { mode = .sideBySide }
        loading = false
    }

    private func read(_ side: ImageDiffSources.Side) async -> Data? {
        switch side {
        case .none:
            return nil
        case .workingTree:
            let url = URL(fileURLWithPath: repoPath).appendingPathComponent(path)
            return await Task.detached { try? Data(contentsOf: url) }.value
        case .revision(let rev):
            return await GitService.shared.blobData(revision: rev, path: path, in: repoPath)
        }
    }
}
