import Foundation
import Security

public struct HTTPResponse: Sendable {
    public let data: Data
    public let response: HTTPURLResponse
    public init(data: Data, response: HTTPURLResponse) {
        self.data = data
        self.response = response
    }
}

public struct HTTPClient: Sendable {
    public let session: URLSession
    public let userAgent: String

    public init(settings: AppSettings = AppSettings()) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = .shared
        if settings.proxy.isUsable {
            var proxy: [AnyHashable: Any] = [
                kCFNetworkProxiesHTTPEnable: 1,
                kCFNetworkProxiesHTTPProxy: settings.proxy.host,
                kCFNetworkProxiesHTTPPort: settings.proxy.port,
                kCFNetworkProxiesHTTPSProxy: settings.proxy.host,
                kCFNetworkProxiesHTTPSPort: settings.proxy.port
            ]
            if settings.proxy.scheme == .socks5 {
                proxy[kCFNetworkProxiesSOCKSEnable] = 1
                proxy[kCFNetworkProxiesSOCKSProxy] = settings.proxy.host
                proxy[kCFNetworkProxiesSOCKSPort] = settings.proxy.port
            }
            configuration.connectionProxyDictionary = proxy
        }
        session = URLSession(configuration: configuration, delegate: TLSDelegate(allowInsecure: settings.tls.allowInsecureCertificates, proxyUsername: settings.proxy.username, proxyPassword: settings.proxy.password), delegateQueue: nil)
        userAgent = settings.userAgent.isEmpty ? "ABDownloadManager/1.0 (macOS)" : settings.userAgent
    }

    public func request(
        url: URL,
        headers: [String: String] = [:],
        method: String = "GET",
        range: ClosedRange<Int64>? = nil,
        body: Data? = nil
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers where request.value(forHTTPHeaderField: key) == nil {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadEngineError.invalidResponse(-1) }
        return HTTPResponse(data: data, response: http)
    }


    public func stream(url: URL, headers: [String: String] = [:], range: ClosedRange<Int64>? = nil) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { if request.value(forHTTPHeaderField: key) == nil { request.setValue(value, forHTTPHeaderField: key) } }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadEngineError.invalidResponse(-1) }
        return (bytes, http)
    }

    public func probe(source: DownloadSource) async throws -> ResourceInfo {
        var head: HTTPResponse?
        if source.url.scheme?.lowercased() == "http" || source.url.scheme?.lowercased() == "https" {
            head = try? await request(url: source.url, headers: source.headers, method: "HEAD")
        }
        var response = head
        if response == nil || !(200..<400).contains(response!.response.statusCode) {
            response = try await request(url: source.url, headers: source.headers, range: 0...0)
        }
        guard let response else { throw DownloadEngineError.invalidResponse(-1) }
        let status = response.response.statusCode
        guard (200..<400).contains(status) else { throw DownloadEngineError.invalidResponse(status) }
        let headers = response.response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key).lowercased()] = String(describing: entry.value)
        }
        let length = headers["content-length"].flatMap(Int64.init)
        let contentRangeLength = headers["content-range"].flatMap { value -> Int64? in
            guard let slash = value.lastIndex(of: "/") else { return nil }
            return Int64(value[value.index(after: slash)...])
        }
        let supportsRanges = status == 206 || headers["accept-ranges"]?.lowercased().contains("bytes") == true
        return ResourceInfo(
            contentLength: contentRangeLength ?? length,
            supportsRanges: supportsRanges,
            validator: ResourceValidator(etag: headers["etag"], lastModified: headers["last-modified"]),
            contentType: headers["content-type"],
            suggestedFilename: filename(from: headers["content-disposition"]),
            finalURL: response.response.url ?? source.url,
            contentDisposition: headers["content-disposition"]
        )
    }

    private func filename(from contentDisposition: String?) -> String? {
        guard let contentDisposition else { return nil }
        for part in contentDisposition.split(separator: ";") {
            let value = part.trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasPrefix("filename*=") {
                let encoded = String(value.dropFirst("filename*=".count)).replacingOccurrences(of: "UTF-8''", with: "")
                return encoded.removingPercentEncoding
            }
            if value.lowercased().hasPrefix("filename=") {
                return String(value.dropFirst("filename=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
}


private final class TLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let allowInsecure: Bool
    let proxyUsername: String
    let proxyPassword: String
    init(allowInsecure: Bool, proxyUsername: String, proxyPassword: String) { self.allowInsecure = allowInsecure; self.proxyUsername = proxyUsername; self.proxyPassword = proxyPassword }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.isProxy(), !proxyUsername.isEmpty {
            completionHandler(.useCredential, URLCredential(user: proxyUsername, password: proxyPassword, persistence: .forSession)); return
        }
        guard allowInsecure, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust else { completionHandler(.performDefaultHandling, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
