import Foundation
import CryptoKit

public struct CachedHTTPResponse: Codable, Sendable {
    public let url: String
    public let etag: String?
    public let lastModified: String?
    public let data: Data
    public let timestamp: Date

    public init(url: String, etag: String?, lastModified: String?, data: Data, timestamp: Date = Date()) {
        self.url = url
        self.etag = etag
        self.lastModified = lastModified
        self.data = data
        self.timestamp = timestamp
    }
}

/// Transport for GitHub API calls. URLSession's own HTTP cache is disabled: it would serve GitHub's
/// `max-age=60` responses without revalidating and hide 304s, so `GitHubHTTPCache` does conditional requests itself.
public enum GitHubHTTP {
    public static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }
}

public actor GitHubHTTPCache {
    public static let shared = GitHubHTTPCache()

    private var memoryCache: [String: CachedHTTPResponse] = [:]
    /// Keys in least- to most-recently used order, bounding the in-memory cache.
    private var recency: [String] = []
    private let maxMemoryEntries = 400
    private let maxDiskAge: TimeInterval = 14 * 24 * 3600
    private let cacheDirectory: URL
    /// Fingerprint of the active token: GitHub responses vary by credentials, so entries never cross accounts.
    private var scope = ""

    private init() {
        let baseDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDirectory = baseDir.appendingPathComponent("GitXX/GitHubCache", isDirectory: true)

        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        let dir = self.cacheDirectory, maxAge = maxDiskAge
        Task.detached(priority: .background) { Self.pruneDisk(dir, olderThan: maxAge) }
    }

    public func setScope(token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        scope = trimmed.isEmpty ? "" : String(SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    private nonisolated static func pruneDisk(_ dir: URL, olderThan maxAge: TimeInterval) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: file) }
        }
    }

    private func touch(_ key: String) {
        if let i = recency.lastIndex(of: key) { recency.remove(at: i) }
        recency.append(key)
        while recency.count > maxMemoryEntries {
            memoryCache.removeValue(forKey: recency.removeFirst())
        }
    }

    private func cacheKey(for urlString: String) -> String {
        let data = Data((scope + "|" + urlString).utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    public func get(for urlString: String) -> CachedHTTPResponse? {
        // 1. Check memory cache first
        let key = cacheKey(for: urlString)
        if let memoryHit = memoryCache[key] {
            touch(key)
            return memoryHit
        }

        // 2. Check disk cache
        let fileURL = cacheDirectory.appendingPathComponent("\(key).json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: fileURL)
            let cached = try JSONDecoder().decode(CachedHTTPResponse.self, from: data)
            memoryCache[key] = cached
            touch(key)
            return cached
        } catch {
            return nil
        }
    }

    public func store(urlString: String, etag: String?, lastModified: String?, data: Data) {
        let key = cacheKey(for: urlString)
        let response = CachedHTTPResponse(
            url: urlString,
            etag: etag,
            lastModified: lastModified,
            data: data,
            timestamp: Date()
        )

        // Store in memory
        memoryCache[key] = response
        touch(key)

        // Persist to disk asynchronously
        let targetDir = self.cacheDirectory
        Task.detached(priority: .background) {
            let fileURL = targetDir.appendingPathComponent("\(key).json")
            if let encoded = try? JSONEncoder().encode(response) {
                try? encoded.write(to: fileURL, options: .atomic)
            }
        }
    }

    public func remove(for urlString: String) {
        let key = cacheKey(for: urlString)
        memoryCache.removeValue(forKey: key)
        recency.removeAll { $0 == key }
        let fileURL = cacheDirectory.appendingPathComponent("\(key).json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    public func clear() {
        memoryCache.removeAll()
        recency.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}
