import Foundation
import CoreServices

/// Monitors the repository directory and its .git folder recursively using native macOS FSEvents.
/// Whenever files are edited, created, deleted, or git operations (commit, checkout, stash, etc.)
/// happen outside GitXX (e.g. in VS Code, Terminal, Cursor), this watcher delivers debounced change events.
public final class RepoFileWatcher: @unchecked Sendable {
    private var streamRef: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.gitxx.repofilewatcher", qos: .utility)
    private var debounceWorkItem: DispatchWorkItem?

    public var onRepoChanged: (@Sendable () -> Void)?

    public init() {}

    deinit {
        stopWatching()
    }

    public func startWatching(at path: String) {
        stopWatching()

        guard FileManager.default.fileExists(atPath: path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [path] as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)

        let callback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let clientCallBackInfo = clientCallBackInfo else { return }
            let watcher = Unmanaged<RepoFileWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String]) ?? []
            guard paths.isEmpty || paths.contains(where: { !RepoFileWatcher.isGitInternalNoise($0) }) else { return }
            watcher.handleFSEvent()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25, // 250ms coalescing latency
            flags
        ) else {
            return
        }

        self.streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stopWatching() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil

        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
    }

    /// Writes git makes for its own bookkeeping (locks, objects, reflogs, fetch state, fsmonitor) that don't
    /// change what GitXX shows. Reacting to them makes every status/fetch retrigger another refresh.
    static func isGitInternalNoise(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/") else { return path.hasSuffix("/.git") }
        let inner = path[range.upperBound...]
        if inner.hasSuffix(".lock") { return true }
        let noisyPrefixes = ["objects/", "logs/", "fsmonitor", "FETCH_HEAD", "ORIG_HEAD", "gitk.cache", "lfs/", "hooks/", "info/", "modules/"]
        return noisyPrefixes.contains { inner.hasPrefix($0) }
    }

    private func handleFSEvent() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onRepoChanged?()
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.2, execute: item)
    }
}
