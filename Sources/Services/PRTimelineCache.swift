import Foundation

/// Fast in-memory and persistent disk cache for PR conversation timelines and checks.
/// Enables 0ms instantaneous render on PR selection followed by silent background revalidation.
public final class PRTimelineCache: @unchecked Sendable {
    public static let shared = PRTimelineCache()

    private let lock = NSLock()
    private var memoryCache: [String: [PRTimelineItem]] = [:]
    private var checksMemoryCache: [String: [PRCheckRun]] = [:]
    private let cacheDirectory: URL

    private init() {
        let baseDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDirectory = baseDir.appendingPathComponent("GitXX/TimelineCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    private func cacheKey(owner: String, repo: String, prNumber: Int) -> String {
        return "\(owner)_\(repo)_\(prNumber)"
    }

    // MARK: - Synchronous In-Memory Access (0ms)

    public func getInMemory(owner: String, repo: String, prNumber: Int) -> [PRTimelineItem]? {
        lock.lock()
        defer { lock.unlock() }
        let key = cacheKey(owner: owner, repo: repo, prNumber: prNumber)
        return memoryCache[key]
    }

    public func getChecksInMemory(owner: String, repo: String, prNumber: Int) -> [PRCheckRun]? {
        lock.lock()
        defer { lock.unlock() }
        let key = cacheKey(owner: owner, repo: repo, prNumber: prNumber)
        return checksMemoryCache[key]
    }

    // MARK: - Synchronous / Async Full Cache Lookup (Memory -> Disk)

    public func get(owner: String, repo: String, prNumber: Int) -> [PRTimelineItem]? {
        let key = cacheKey(owner: owner, repo: repo, prNumber: prNumber)

        // 1. Check memory cache first (0ms)
        lock.lock()
        if let memoryHit = memoryCache[key] {
            lock.unlock()
            return memoryHit
        }
        lock.unlock()

        // 2. Check persistent disk cache (< 3ms)
        let fileURL = cacheDirectory.appendingPathComponent("\(key).json")
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([PRTimelineItem].self, from: data) else {
            return nil
        }

        lock.lock()
        memoryCache[key] = items
        lock.unlock()
        return items
    }

    public func getChecks(owner: String, repo: String, prNumber: Int) -> [PRCheckRun]? {
        let key = cacheKey(owner: owner, repo: repo, prNumber: prNumber)

        lock.lock()
        if let hit = checksMemoryCache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let fileURL = cacheDirectory.appendingPathComponent("\(key)_checks.json")
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let checks = try? JSONDecoder().decode([PRCheckRun].self, from: data) else {
            return nil
        }

        lock.lock()
        checksMemoryCache[key] = checks
        lock.unlock()
        return checks
    }

    public func set(owner: String, repo: String, prNumber: Int, items: [PRTimelineItem]) {
        let key = cacheKey(owner: owner, repo: repo, prNumber: prNumber)
        lock.lock()
        memoryCache[key] = items
        lock.unlock()

        let fileURL = cacheDirectory.appendingPathComponent("\(key).json")
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(items) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func setChecks(owner: String, repo: String, prNumber: Int, checks: [PRCheckRun]) {
        let key = cacheKey(owner: owner, repo: repo, prNumber: prNumber)
        lock.lock()
        checksMemoryCache[key] = checks
        lock.unlock()

        let fileURL = cacheDirectory.appendingPathComponent("\(key)_checks.json")
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(checks) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func clear(owner: String, repo: String, prNumber: Int) {
        let key = cacheKey(owner: owner, repo: repo, prNumber: prNumber)
        lock.lock()
        memoryCache.removeValue(forKey: key)
        checksMemoryCache.removeValue(forKey: key)
        auxMemoryCache = auxMemoryCache.filter { !$0.key.hasPrefix(key + "_") }
        lock.unlock()

        for suffix in ["", "_checks", "_files", "_meta"] {
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent("\(key)\(suffix).json"))
        }
    }

    // MARK: - Changed Files, Detail Metadata & Repo Labels

    private var auxMemoryCache: [String: Any] = [:]

    public func getFiles(owner: String, repo: String, prNumber: Int) -> [PRFileChange]? {
        getAux(key: cacheKey(owner: owner, repo: repo, prNumber: prNumber) + "_files")
    }

    public func setFiles(owner: String, repo: String, prNumber: Int, files: [PRFileChange]) {
        setAux(files, key: cacheKey(owner: owner, repo: repo, prNumber: prNumber) + "_files")
    }

    public func getMeta(owner: String, repo: String, prNumber: Int) -> PRDetailMeta? {
        getAux(key: cacheKey(owner: owner, repo: repo, prNumber: prNumber) + "_meta")
    }

    public func setMeta(owner: String, repo: String, prNumber: Int, meta: PRDetailMeta) {
        setAux(meta, key: cacheKey(owner: owner, repo: repo, prNumber: prNumber) + "_meta")
    }

    public func getRepoLabels(owner: String, repo: String) -> [PRLabel]? {
        getAux(key: "\(owner)_\(repo)__labels")
    }

    public func setRepoLabels(owner: String, repo: String, labels: [PRLabel]) {
        setAux(labels, key: "\(owner)_\(repo)__labels")
    }

    private func getAux<T: Codable & Sendable>(key: String) -> T? {
        lock.lock()
        if let hit = auxMemoryCache[key] as? T {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let fileURL = cacheDirectory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode(T.self, from: data) else {
            return nil
        }
        lock.lock()
        auxMemoryCache[key] = value
        lock.unlock()
        return value
    }

    private func setAux<T: Codable & Sendable>(_ value: T, key: String) {
        lock.lock()
        auxMemoryCache[key] = value
        lock.unlock()

        let fileURL = cacheDirectory.appendingPathComponent("\(key).json")
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
