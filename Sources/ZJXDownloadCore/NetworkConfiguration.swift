import Foundation

public struct EffectiveRequest: Sendable {
    public var headers: [String: String]
    public var credentialHeaders: [String: String]
    public var userAgent: String
    public var speedLimit: Int64
    public var connectionCount: Int
}

public enum NetworkConfiguration {
    public static let sensitiveHeaderNames: Set<String> = ["authorization", "cookie", "proxy-authorization", "set-cookie"]

    public static func prepare(url: URL, explicitHeaders: [String: String], settings: AppSettings,
                               taskLimit: Int64 = 0, taskConnectionCount: Int? = nil) -> EffectiveRequest {
        var headers = explicitHeaders.filter { !$0.key.contains("\r") && !$0.key.contains("\n") && !$0.value.contains("\r") && !$0.value.contains("\n") }
        var agent = settings.userAgent
        let hostRule = matchingHostRule(for: url, settings: settings)
        if let rule = hostRule {
            for (name, value) in rule.headers where !headers.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { headers[name] = value }
            if agent.isEmpty { agent = rule.userAgent }
        }
        if !agent.isEmpty, !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) { headers["User-Agent"] = agent }
        headers = headers.filter { $0.key.caseInsensitiveCompare("Host") != .orderedSame }
        headers["Accept-Encoding"] = "identity"
        let secrets = headers.filter { sensitiveHeaderNames.contains($0.key.lowercased()) }
        let publicHeaders = headers.filter { !sensitiveHeaderNames.contains($0.key.lowercased()) }
        let hostLimit = hostRule?.speedLimitBytesPerSecond ?? 0
        let limits = [taskLimit, settings.globalSpeedLimitBytesPerSecond, hostLimit].filter { $0 > 0 }
        let ruleConnections = taskConnectionCount.map { max(1, min($0, 256)) }
            ?? hostRule?.connectionCount.map { max(1, min($0, 256)) } ?? 0
        return EffectiveRequest(headers: publicHeaders, credentialHeaders: secrets, userAgent: agent,
                                speedLimit: limits.min() ?? 0, connectionCount: ruleConnections)
    }

    public static func matchingHostRule(for url: URL, settings: AppSettings) -> HostRule? {
        settings.hostRules
            .filter { wildcard($0.pattern, value: url.host ?? "") }
            .sorted { $0.pattern.filter { $0 == "*" }.count < $1.pattern.filter { $0 == "*" }.count }
            .first
    }

    /// HTTP credentials are scoped to an origin, which includes scheme and port.
    /// URLSession may preserve sensitive headers across redirects, so callers must
    /// use this comparison before reusing request headers on another URL.
    public static func hasSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let leftScheme = lhs.scheme?.lowercased(),
              let rightScheme = rhs.scheme?.lowercased(),
              let leftHost = lhs.host?.lowercased(),
              let rightHost = rhs.host?.lowercased() else { return false }
        return leftScheme == rightScheme && leftHost == rightHost && effectivePort(lhs) == effectivePort(rhs)
    }

    public static func removingSensitiveHeaders(_ headers: [String: String],
                                                from source: URL, to destination: URL) -> [String: String] {
        guard !hasSameOrigin(source, destination) else { return headers }
        return headers.filter { !sensitiveHeaderNames.contains($0.key.lowercased()) }
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    public static func validate(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, !url.absoluteString.contains("\n") else { return false }
        return true
    }

    public static func normalizedPort(_ port: Int) throws -> Int {
        guard (1024...65535).contains(port) else { throw ValidationError("端口必须在 1024 到 65535 之间。") }
        return port
    }

    public static func wildcard(_ pattern: String, value: String) -> Bool {
        let p = pattern.lowercased()
        let v = value.lowercased()
        let pieces = p.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var cursor = v.startIndex
        for (index, piece) in pieces.enumerated() {
            guard let match = v.range(of: piece, range: cursor..<v.endIndex) else { return false }
            if index == 0 && match.lowerBound != v.startIndex { return false }
            cursor = match.upperBound
        }
        return p.hasSuffix("*") || cursor == v.endIndex
    }
}

public struct ValidationError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Shares the configured global byte budget across HTTP, Range and HLS transfers.
public actor SharedGlobalRateLimiter {
    public static let shared = SharedGlobalRateLimiter()
    private var reservedUntil: [String: Date] = [:]

    public func resetGlobalReservation() {
        reservedUntil["global"] = .now
    }

    public func reserve(bytes: Int64, limit: Int64, bucket: String = "global") -> TimeInterval {
        guard bytes > 0, limit > 0 else { return 0 }
        let now = Date.now
        let start = max(now, reservedUntil[bucket] ?? now)
        let end = start.addingTimeInterval(Double(bytes) / Double(limit))
        reservedUntil[bucket] = end
        return max(0, end.timeIntervalSince(now))
    }
}
