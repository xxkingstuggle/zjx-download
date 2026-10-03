import Foundation
import Network

public struct DNSSettings: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
        case system
        case https
        case tls
        public var id: String { rawValue }
    }

    public var mode: Mode
    /// DNS-over-HTTPS endpoint, including the provider's query path.
    public var httpsURL: String
    /// DNS-over-TLS resolver hostname.
    public var tlsHost: String
    /// Optional comma/semicolon/newline separated bootstrap IP addresses.
    public var bootstrapAddresses: String

    public init(
        mode: Mode = .system,
        httpsURL: String = "https://cloudflare-dns.com/dns-query",
        tlsHost: String = "cloudflare-dns.com",
        bootstrapAddresses: String = "1.1.1.1, 1.0.0.1"
    ) {
        self.mode = mode
        self.httpsURL = httpsURL
        self.tlsHost = tlsHost
        self.bootstrapAddresses = bootstrapAddresses
    }

    public enum ConfigurationError: Error, LocalizedError, Equatable {
        case invalidHTTPSResolver
        case invalidTLSResolver
        case invalidBootstrapAddress(String)
        public var errorDescription: String? {
            switch self {
            case .invalidHTTPSResolver: "DNS-over-HTTPS requires a valid https:// resolver URL."
            case .invalidTLSResolver: "DNS-over-TLS requires a resolver hostname."
            case .invalidBootstrapAddress(let value): "Invalid DNS bootstrap IP address: \(value)"
            }
        }
    }

    public func resolverConfiguration() throws -> NWParameters.PrivacyContext.ResolverConfiguration? {
        guard mode != .system else { return nil }
        let port = NWEndpoint.Port(rawValue: mode == .https ? 443 : 853)!
        let serverAddresses = try bootstrapAddresses
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { raw -> NWEndpoint in
                let value = String(raw)
                if let ipv4 = IPv4Address(value) { return .hostPort(host: .ipv4(ipv4), port: port) }
                if let ipv6 = IPv6Address(value) { return .hostPort(host: .ipv6(ipv6), port: port) }
                throw ConfigurationError.invalidBootstrapAddress(value)
            }
        switch mode {
        case .system:
            return nil
        case .https:
            guard let url = URL(string: httpsURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme?.lowercased() == "https", url.host != nil else {
                throw ConfigurationError.invalidHTTPSResolver
            }
            return .https(url, serverAddresses: serverAddresses)
        case .tls:
            let host = tlsHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, !host.contains("/"), !host.contains(":"), !host.contains(" ") else {
                throw ConfigurationError.invalidTLSResolver
            }
            return .tls(.hostPort(host: .name(host, nil), port: port), serverAddresses: serverAddresses)
        }
    }

    /// Applies per-process encrypted DNS requirements. This does not edit
    /// macOS network-service preferences or install a system DNS profile.
    public func applyToDefaultPrivacyContext() throws {
        let context = NWParameters.PrivacyContext.default
        if mode == .system {
            context.requireEncryptedNameResolution(false, fallbackResolver: nil)
        } else {
            context.requireEncryptedNameResolution(true, fallbackResolver: try resolverConfiguration())
        }
    }
}
