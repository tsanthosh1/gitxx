import Foundation
import AppKit

public struct APILogStats: Sendable {
    public let totalRequests: Int
    public let cached304Count: Int
    public let quotaSpent: Int
    public let latestRemaining: Int?
    public let latestLimit: Int?
    public let latestReset: Date?
    public let averageLatencyMs: Double

    public init(
        totalRequests: Int = 0,
        cached304Count: Int = 0,
        quotaSpent: Int = 0,
        latestRemaining: Int? = nil,
        latestLimit: Int? = nil,
        latestReset: Date? = nil,
        averageLatencyMs: Double = 0
    ) {
        self.totalRequests = totalRequests
        self.cached304Count = cached304Count
        self.quotaSpent = quotaSpent
        self.latestRemaining = latestRemaining
        self.latestLimit = latestLimit
        self.latestReset = latestReset
        self.averageLatencyMs = averageLatencyMs
    }
}

public actor GitHubAPILogger {
    public static let shared = GitHubAPILogger()

    public static let logUpdatedNotification = Notification.Name("GitXXAPILogUpdated")

    private var logs: [APIRequestLogEntry] = []
    private let maxEntries = 1000
    private let logFileURL: URL

    private var latestRemaining: Int? = nil
    private var latestLimit: Int? = nil
    private var latestReset: Date? = nil

    private init() {
        let baseDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let gitxxDir = baseDir.appendingPathComponent("GitXX", isDirectory: true)
        try? FileManager.default.createDirectory(at: gitxxDir, withIntermediateDirectories: true)
        self.logFileURL = gitxxDir.appendingPathComponent("api_request_logs.json")

        // Load existing logs from disk
        if FileManager.default.fileExists(atPath: logFileURL.path),
           let data = try? Data(contentsOf: logFileURL),
           let saved = try? JSONDecoder().decode([APIRequestLogEntry].self, from: data) {
            self.logs = Array(saved.prefix(maxEntries))
            if let first = self.logs.first(where: { $0.rateLimitRemaining != nil }) {
                self.latestRemaining = first.rateLimitRemaining
                self.latestLimit = first.rateLimitLimit
                self.latestReset = first.rateLimitReset
            }
        }
    }

    public func record(
        method: String,
        urlString: String,
        statusCode: Int,
        durationMs: Double,
        rateLimitRemaining: Int? = nil,
        rateLimitLimit: Int? = nil,
        rateLimitReset: Date? = nil,
        isCached304: Bool = false,
        responseSizeBytes: Int = 0,
        errorDescription: String? = nil
    ) {
        let entry = APIRequestLogEntry(
            method: method,
            urlString: urlString,
            statusCode: statusCode,
            durationMs: durationMs,
            rateLimitRemaining: rateLimitRemaining,
            rateLimitLimit: rateLimitLimit,
            rateLimitReset: rateLimitReset,
            isCached304: isCached304,
            responseSizeBytes: responseSizeBytes,
            errorDescription: errorDescription
        )

        logs.insert(entry, at: 0)
        if logs.count > maxEntries {
            logs.removeLast(logs.count - maxEntries)
        }

        if let rem = rateLimitRemaining {
            self.latestRemaining = rem
        }
        if let lim = rateLimitLimit {
            self.latestLimit = lim
        }
        if let res = rateLimitReset {
            self.latestReset = res
        }

        saveToDiskAsync()

        Task { @MainActor in
            NotificationCenter.default.post(name: GitHubAPILogger.logUpdatedNotification, object: nil)
        }
    }

    public func getLogs() -> [APIRequestLogEntry] {
        return logs
    }

    public func getStats() -> APILogStats {
        let total = logs.count
        let cached = logs.filter { $0.isCached304 }.count
        // Quota spent: any request that returned >= 200 and is not 304, or any non-cached call
        let quota = logs.filter { !$0.isCached304 && $0.statusCode > 0 && $0.statusCode != 304 }.count
        let avgLat: Double
        if total > 0 {
            let totalMs = logs.reduce(0.0) { $0 + $1.durationMs }
            avgLat = totalMs / Double(total)
        } else {
            avgLat = 0
        }

        return APILogStats(
            totalRequests: total,
            cached304Count: cached,
            quotaSpent: quota,
            latestRemaining: latestRemaining,
            latestLimit: latestLimit,
            latestReset: latestReset,
            averageLatencyMs: avgLat
        )
    }

    public func clear() {
        logs.removeAll()
        try? FileManager.default.removeItem(at: logFileURL)
        Task { @MainActor in
            NotificationCenter.default.post(name: GitHubAPILogger.logUpdatedNotification, object: nil)
        }
    }

    public func exportAsJSON() -> String {
        guard let data = try? JSONEncoder().encode(logs),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    public func exportAsText() -> String {
        var lines: [String] = []
        lines.append("Time\tMethod\tStatus\tDuration\tRemaining\tSize\tEndpoint")
        for entry in logs {
            let remStr = entry.rateLimitRemaining.map(String.init) ?? "-"
            let cachedTag = entry.isCached304 ? "[304-CACHED]" : ""
            lines.append("\(entry.formattedTime)\t\(entry.method)\t\(entry.statusCode) \(cachedTag)\t\(String(format: "%.0fms", entry.durationMs))\t\(remStr)\t\(entry.responseSizeBytes)B\t\(entry.endpoint)")
        }
        return lines.joined(separator: "\n")
    }

    private func saveToDiskAsync() {
        let currentLogs = self.logs
        let url = self.logFileURL
        Task.detached(priority: .background) {
            if let data = try? JSONEncoder().encode(currentLogs) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
