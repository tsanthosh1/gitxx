import Foundation

/// Represents a cached pull request list payload with tab counts and timestamp
public struct CachedPRList: Codable, Sendable {
    public let pullRequests: [PullRequest]
    public let tabCounts: [String: Int]
    public let timestamp: Date

    public init(pullRequests: [PullRequest], tabCounts: [String: Int], timestamp: Date = Date()) {
        self.pullRequests = pullRequests
        self.tabCounts = tabCounts
        self.timestamp = timestamp
    }
}

/// Fast in-memory and persistent disk cache for PR lists and tab counts.
/// Enables 0ms instantaneous switching between PR tabs and instant repo open.
public final class PRListCache: @unchecked Sendable {
    public static let shared = PRListCache()

    private let lock = NSLock()
    private var memoryCache: [String: CachedPRList] = [:]
    private var countsMemoryCache: [String: [String: Int]] = [:]
    private let cacheDirectory: URL

    private init() {
        let baseDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDirectory = baseDir.appendingPathComponent("GitXX/PRListCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    private func cacheKey(owner: String, repo: String, filter: PRFilter) -> String {
        let safeFilter = filter.rawValue.replacingOccurrences(of: " ", with: "_").lowercased()
        return "\(owner)_\(repo)_\(safeFilter)"
    }

    private func countsKey(owner: String, repo: String) -> String {
        return "\(owner)_\(repo)_counts"
    }

    // MARK: - Synchronous In-Memory & Disk Access

    public func get(owner: String, repo: String, filter: PRFilter) -> CachedPRList? {
        let key = cacheKey(owner: owner, repo: repo, filter: filter)

        // 1. In-memory check (0ms)
        lock.lock()
        if let memoryHit = memoryCache[key] {
            lock.unlock()
            return memoryHit
        }
        lock.unlock()

        // 2. Persistent disk check (< 3ms)
        let fileURL = cacheDirectory.appendingPathComponent("\(key).json")
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode(CachedPRList.self, from: data) else {
            return nil
        }

        lock.lock()
        memoryCache[key] = list
        lock.unlock()
        return list
    }

    public func getTabCounts(owner: String, repo: String) -> [PRFilter: Int]? {
        let key = countsKey(owner: owner, repo: repo)

        lock.lock()
        if let hit = countsMemoryCache[key] {
            lock.unlock()
            return mapRawCounts(hit)
        }
        lock.unlock()

        let fileURL = cacheDirectory.appendingPathComponent("\(key).json")
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let rawCounts = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return nil
        }

        lock.lock()
        countsMemoryCache[key] = rawCounts
        lock.unlock()
        return mapRawCounts(rawCounts)
    }

    private func mapRawCounts(_ raw: [String: Int]) -> [PRFilter: Int] {
        var result: [PRFilter: Int] = [:]
        for (k, v) in raw {
            if let filter = PRFilter(rawValue: k) {
                result[filter] = v
            } else if k == "Merged" {
                result[.closed] = v
            }
        }
        return result
    }

    // MARK: - Cache Writing

    public func set(owner: String, repo: String, filter: PRFilter, prs: [PullRequest], tabCounts: [PRFilter: Int]) {
        let key = cacheKey(owner: owner, repo: repo, filter: filter)
        var stringCounts: [String: Int] = [:]
        for (f, count) in tabCounts {
            stringCounts[f.rawValue] = count
        }

        let cached = CachedPRList(pullRequests: prs, tabCounts: stringCounts, timestamp: Date())

        lock.lock()
        memoryCache[key] = cached
        if !stringCounts.isEmpty {
            countsMemoryCache[countsKey(owner: owner, repo: repo)] = stringCounts
        }
        lock.unlock()

        // Asynchronously persist to disk
        let prListURL = cacheDirectory.appendingPathComponent("\(key).json")
        let countsURL = cacheDirectory.appendingPathComponent("\(countsKey(owner: owner, repo: repo)).json")

        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(cached) {
                try? data.write(to: prListURL, options: .atomic)
            }
            if !stringCounts.isEmpty, let countData = try? JSONEncoder().encode(stringCounts) {
                try? countData.write(to: countsURL, options: .atomic)
            }
        }
    }

    public func clearAll() {
        lock.lock()
        memoryCache.removeAll()
        countsMemoryCache.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}
