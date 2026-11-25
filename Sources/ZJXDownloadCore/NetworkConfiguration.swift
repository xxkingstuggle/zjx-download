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
            if !rule.userAgent.isEmpty { agent = rule.userAgent }
        }
        if !agent.isEmpty, !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) { headers["User-Agent"] = agent }
        headers = headers.filter { $0.key.caseInsensitiveCompare("Host") != .orderedSame }
        headers["Accept-Encoding"] = "identity"
        let secrets = headers.filter { sensitiveHeaderNames.contains($0.key.lowercased()) }
        let publicHeaders = headers.filter { !sensitiveHeaderNames.contains($0.key.lowercased()) }
        let hostLimit = hostRule?.speedLimitBytesPerSecond ?? 0
        let limits = [taskLimit, settings.globalSpeedLimitBytesPerSecond, hostLimit].filter { $0 > 0 }
        let normalizedTaskConnections = taskConnectionCount.flatMap { $0 > 0 ? max(1, min($0, 256)) : nil }
        let normalizedHostConnections = hostRule?.connectionCount.flatMap { $0 > 0 ? max(1, min($0, 256)) : nil }
        let ruleConnections = normalizedTaskConnections ?? normalizedHostConnections ?? 0
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
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let pat = Array(trimmed.lowercased())
        let str = Array(value.lowercased())
        var patIndex = 0
        var strIndex = 0
        var starIndex: Int?
        var matchIndex = 0

        while strIndex < str.count {
            if patIndex < pat.count && pat[patIndex] == str[strIndex] {
                patIndex += 1
                strIndex += 1
            } else if patIndex < pat.count && pat[patIndex] == "*" {
                starIndex = patIndex
                matchIndex = strIndex
                patIndex += 1
            } else if let star = starIndex {
                patIndex = star + 1
                matchIndex += 1
                strIndex = matchIndex
            } else {
                return false
            }
        }
        while patIndex < pat.count && pat[patIndex] == "*" {
            patIndex += 1
        }
        return patIndex == pat.count
    }

    public static func applyProxy(settings: AppSettings, proxyPassword: String, to config: URLSessionConfiguration) {
        switch settings.proxyMode {
        case .direct:
            config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        case .system:
            config.connectionProxyDictionary = nil
        case .manual:
            if settings.proxyScheme == .socks5 {
                var proxy: [AnyHashable: Any] = [
                    "SOCKSEnable": 1,
                    "SOCKSProxy": settings.proxyHost,
                    "SOCKSPort": settings.proxyPort,
                    "HTTPEnable": 0,
                    "HTTPSEnable": 0,
                    "ExceptionsList": settings.proxyBypass
                ]
                if !settings.proxyUsername.isEmpty {
                    proxy["SOCKSUser"] = settings.proxyUsername
                    proxy["SOCKSPassword"] = proxyPassword
                }
                config.connectionProxyDictionary = proxy
            } else {
                var proxy: [AnyHashable: Any] = [
                    "HTTPEnable": 1,
                    "HTTPProxy": settings.proxyHost,
                    "HTTPPort": settings.proxyPort,
                    "HTTPSEnable": 1,
                    "HTTPSProxy": settings.proxyHost,
                    "HTTPSPort": settings.proxyPort,
                    "SOCKSEnable": 0,
                    "ExceptionsList": settings.proxyBypass
                ]
                if !settings.proxyUsername.isEmpty {
                    proxy["HTTPProxyUsername"] = settings.proxyUsername
                    proxy["HTTPProxyPassword"] = proxyPassword
                    proxy["HTTPSProxyUsername"] = settings.proxyUsername
                    proxy["HTTPSProxyPassword"] = proxyPassword
                }
                config.connectionProxyDictionary = proxy
            }
        case .pac:
            config.connectionProxyDictionary = ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": settings.pacURL]
        }
    }

    public static func loopbackSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }

    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let maxCount = max(lhs.count, rhs.count)
        var diff: UInt8 = lhs.count == rhs.count ? 0 : 1
        for index in 0..<maxCount {
            let left: UInt8 = index < lhs.count ? lhs[lhs.index(lhs.startIndex, offsetBy: index)] : 0
            let right: UInt8 = index < rhs.count ? rhs[rhs.index(rhs.startIndex, offsetBy: index)] : 0
            diff |= left ^ right
        }
        return diff == 0
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
    private static let maximumReservationHorizon: TimeInterval = 5.0
    private var reservedUntil: [String: Date] = [:]

    public func resetGlobalReservation() {
        reservedUntil["global"] = .now
    }

    public func resetBucket(_ bucket: String) {
        reservedUntil.removeValue(forKey: bucket)
    }

    public func resetAll() {
        reservedUntil.removeAll(keepingCapacity: true)
    }

    public func reserve(bytes: Int64, limit: Int64, bucket: String = "global") -> TimeInterval {
        guard bytes > 0, limit > 0 else { return 0 }
        let now = Date.now
        let start = max(now, reservedUntil[bucket] ?? now)
        let proposedEnd = start.addingTimeInterval(Double(bytes) / Double(limit))
        let cappedEnd = min(proposedEnd, now.addingTimeInterval(Self.maximumReservationHorizon))
        reservedUntil[bucket] = cappedEnd
        return max(0, cappedEnd.timeIntervalSince(now))
    }
}
