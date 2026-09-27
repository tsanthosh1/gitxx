import Foundation

/// Anything listed in a file tree: PR files, working-copy changes.
public protocol FileTreeItem: Hashable {
    var treePath: String { get }
}

extension PRFileChange: FileTreeItem {
    public var treePath: String { filename }
}

/// Flattened directory tree of changed files for the Files sidebar. Single-child directory chains are merged
/// (`src/main/java` shows as one row), like github.com.
public enum PRFileTree {
    public struct Row<Item: FileTreeItem>: Identifiable, Hashable {
        public enum Kind: Hashable {
            case directory(name: String, fileCount: Int)
            case file(Item)
        }
        public let id: String
        public let depth: Int
        public let kind: Kind
    }

    private final class Node<Item> {
        var dirs: [String: Node<Item>] = [:]
        var files: [Item] = []
        var fileCount = 0
    }

    public static func directoryID(_ path: String) -> String { "dir:" + path }

    /// Files in the order the tree lists them (folders first, then files), ignoring collapsed state.
    public static func orderedFiles<Item: FileTreeItem>(_ files: [Item]) -> [Item] {
        rows(for: files, collapsed: []).compactMap { row in
            if case .file(let file) = row.kind { return file }
            return nil
        }
    }

    public static let treeModeDefaultsKey = "gitxx_pr_files_tree"

    /// Whether the Files sidebar is in tree mode (defaults to on).
    public static var isTreeMode: Bool {
        UserDefaults.standard.object(forKey: treeModeDefaultsKey) as? Bool ?? true
    }

    /// Visible rows, skipping the contents of collapsed directories (identified by `directoryID`).
    public static func rows<Item: FileTreeItem>(for files: [Item], collapsed: Set<String>) -> [Row<Item>] {
        let root = Node<Item>()
        for file in files {
            var node = root
            node.fileCount += 1
            let parts = file.treePath.split(separator: "/").map(String.init)
            for dir in parts.dropLast() {
                let next = node.dirs[dir] ?? Node<Item>()
                node.dirs[dir] = next
                node = next
                node.fileCount += 1
            }
            node.files.append(file)
        }
        var out: [Row<Item>] = []
        emit(root, path: "", depth: 0, collapsed: collapsed, into: &out)
        return out
    }

    private static func emit<Item: FileTreeItem>(_ node: Node<Item>, path: String, depth: Int, collapsed: Set<String>, into out: inout [Row<Item>]) {
        for name in node.dirs.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            var child = node.dirs[name]!
            var label = name
            var childPath = path.isEmpty ? name : path + "/" + name
            while child.files.isEmpty, child.dirs.count == 1, let (only, grandchild) = child.dirs.first {
                label += "/" + only
                childPath += "/" + only
                child = grandchild
            }
            let id = directoryID(childPath)
            out.append(Row(id: id, depth: depth, kind: .directory(name: label, fileCount: child.fileCount)))
            if !collapsed.contains(id) {
                emit(child, path: childPath, depth: depth + 1, collapsed: collapsed, into: &out)
            }
        }
        let name = { (item: Item) in (item.treePath as NSString).lastPathComponent }
        for file in node.files.sorted(by: { name($0).localizedStandardCompare(name($1)) == .orderedAscending }) {
            out.append(Row(id: file.treePath, depth: depth, kind: .file(file)))
        }
    }
}
