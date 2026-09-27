import Foundation

public struct APIRequestLogEntry: Identifiable, Codable, Sendable {
    public let id: String
    public let timestamp: Date
    public let method: String
    public let urlString: String
    public let endpoint: String
    public let statusCode: Int
    public let durationMs: Double
    public let rateLimitRemaining: Int?
    public let rateLimitLimit: Int?
    public let rateLimitReset: Date?
    public let isCached304: Bool
    public let responseSizeBytes: Int
    public let errorDescription: String?

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
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
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.urlString = urlString

        if let url = URL(string: urlString) {
            let path = url.path
            let query = url.query.map { "?\($0)" } ?? ""
            self.endpoint = path + query
        } else {
            self.endpoint = urlString
        }

        self.statusCode = statusCode
        self.durationMs = durationMs
        self.rateLimitRemaining = rateLimitRemaining
        self.rateLimitLimit = rateLimitLimit
        self.rateLimitReset = rateLimitReset
        self.isCached304 = isCached304
        self.responseSizeBytes = responseSizeBytes
        self.errorDescription = errorDescription
    }

    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    public var formattedDuration: String {
        if durationMs < 1000 {
            return String(format: "%.0f ms", durationMs)
        } else {
            return String(format: "%.2f s", durationMs / 1000.0)
        }
    }

    public var formattedSize: String {
        if responseSizeBytes <= 0 {
            return "0 B"
        } else if responseSizeBytes < 1024 {
            return "\(responseSizeBytes) B"
        } else if responseSizeBytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(responseSizeBytes) / 1024.0)
        } else {
            return String(format: "%.2f MB", Double(responseSizeBytes) / (1024.0 * 1024.0))
        }
    }

    public var isSuccess: Bool {
        return (statusCode >= 200 && statusCode < 300) || statusCode == 304
    }

    public var quotaCost: Int {
        return isCached304 ? 0 : 1
    }

    public var quotaCostBadgeText: String {
        if isCached304 {
            return "⚡️ 0 (Cached 304)"
        } else if statusCode >= 200 && statusCode < 400 {
            return "-1 Quota"
        } else if statusCode == 0 {
            return "Failed"
        } else {
            return "-1 Quota (\(statusCode))"
        }
    }

    public var shortEndpoint: String {
        // Truncate long URLs to compact readable representation
        var clean = endpoint
        if clean.hasPrefix("/repos/") {
            let parts = clean.dropFirst(7).components(separatedBy: "/")
            if parts.count >= 2 {
                let rest = parts.dropFirst(2).joined(separator: "/")
                clean = "/\(rest)"
            }
        }
        return clean
    }
}

