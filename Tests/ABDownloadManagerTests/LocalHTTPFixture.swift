import Foundation
import Network

/// A deterministic loopback HTTP server used by integration tests. It has no
/// dependency on the public internet and exercises headers, redirects, ranges,
/// authentication, cookies, and HLS playlists.
final class LocalHTTPFixture: @unchecked Sendable {
    let body: Data
    private let lock = NSLock()
    private(set) var requestedRanges: [String] = []
    private(set) var requestCount = 0
    private let listener: NWListener
    private(set) var baseURL: URL!
    private let queue = DispatchQueue(label: "ABDM.tests.fixture")

    init() throws {
        body = Data((0..<(4 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 * 31 + 7) })
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        Thread.sleep(forTimeInterval: 0.05)
        guard let port = listener.port?.rawValue, port != 0 else { throw URLError(.cannotConnectToHost) }
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() { listener.cancel() }
    func ranges() -> [String] { lock.lock(); defer { lock.unlock() }; return requestedRanges }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
        let lines = request.components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ").map(String.init) ?? []
            let method = first.first ?? "GET"
            let path = first.dropFirst().first ?? "/"
            var headers: [String: String] = [:]
            for line in lines.dropFirst() { let p = line.split(separator: ":", maxSplits: 1).map(String.init); if p.count == 2 { headers[p[0].lowercased()] = p[1].trimmingCharacters(in: .whitespaces) } }
            self.lock.lock(); self.requestCount += 1; if let range = headers["range"] { self.requestedRanges.append(range) }; self.lock.unlock()
            self.reply(connection, method: method, path: path, headers: headers)
        }
    }

    private func reply(_ connection: NWConnection, method: String, path: String, headers: [String: String]) {
        var status = "200 OK", responseBody = body, extra = "Accept-Ranges: bytes\r\nETag: \"fixture-v1\"\r\nLast-Modified: Wed, 21 Oct 2015 07:28:00 GMT\r\n"
        if path == "/named" { extra += "Content-Disposition: attachment; filename=\"category-proof.zip\"\r\n" }
        if path == "/redirect" { status = "302 Found"; responseBody = Data(); extra += "Location: /file\r\n" }
        else if path == "/proxy.pac" { responseBody = Data("function FindProxyForURL(url, host) { return \"DIRECT\"; }".utf8); extra = "Content-Type: application/x-ns-proxy-autoconfig\r\n" }
        else if path == "/norange" { extra = "ETag: \"norange-v1\"\r\n" }
        else if path == "/auth" && headers["authorization"] != "Basic dGVzdDpzZWNyZXQ=" { status = "401 Unauthorized"; responseBody = Data("unauthorized".utf8); extra += "WWW-Authenticate: Basic realm=fixture\r\n" }
        else if path == "/cookie" && headers["cookie"] != "session=ok" { status = "403 Forbidden"; responseBody = Data("missing cookie".utf8) }
        else if path == "/hls/index.m3u8" { responseBody = Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:1,\n/ hls/one.ts\n#EXTINF:1,\n/hls/two.ts\n#EXT-X-ENDLIST\n".replacingOccurrences(of: "/ hls", with: "/hls").utf8); extra = "Content-Type: application/vnd.apple.mpegurl\r\n" }
        else if path == "/hls/one.ts" { responseBody = Data("segment-one".utf8); extra = "" }
        else if path == "/hls/two.ts" { responseBody = Data("segment-two".utf8); extra = "" }
        else if (path == "/file" || path == "/cookie" || path == "/named" || path == "/slow"), let range = headers["range"], let bounds = parseRange(range) {
            let end = min(bounds.upperBound, Int64(body.count - 1)); let start = min(bounds.lowerBound, end)
            responseBody = body.subdata(in: Int(start)..<(Int(end) + 1)); status = "206 Partial Content"; extra += "Content-Range: bytes \(start)-\(end)/\(body.count)\r\n"
        }
        let bodyData = method == "HEAD" ? Data() : responseBody
        let head = "HTTP/1.1 \(status)\r\nContent-Length: \(responseBody.count)\r\n\(extra)Connection: close\r\n\r\n".data(using: .utf8)! + bodyData
        if path == "/slow" && method != "HEAD" {
            queue.asyncAfter(deadline: .now() + .milliseconds(700)) {
                connection.send(content: head, completion: .contentProcessed { _ in connection.cancel() })
            }
        } else {
            connection.send(content: head, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func parseRange(_ value: String) -> ClosedRange<Int64>? {
        let value = value.replacingOccurrences(of: "bytes=", with: ""); let values = value.split(separator: "-").compactMap { Int64($0) }; guard values.count == 2 else { return nil }; return values[0]...values[1]
    }
}
