import Foundation

public enum ExchangeCodec {
    public static func json(for tasks: [DownloadRecord], secrets: [Int64: [String: String]]) throws -> Data {
        let entries: [[String: Any]] = tasks.filter { $0.kind == .http }.map { task in
            var item: [String: Any] = ["link": task.sourceURL]
            var headers = task.requestHeaders
            if let secret = secrets[task.id] { headers.merge(secret) { _, new in new } }
            if !headers.isEmpty { item["headers"] = headers }
            if let page = task.pageURL { item["downloadPage"] = page }
            if let agent = headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value { item["userAgent"] = agent }
            item["suggestedName"] = task.displayName
            return item
        }
        let value: Any = entries.count == 1 ? entries[0] : entries
        return try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }

    public static func curl(for task: DownloadRecord, secrets: [String: String] = [:]) -> String {
        var lines = ["curl '\(shellQuote(task.sourceURL))'"]
        var headers = task.requestHeaders
        headers.merge(secrets) { _, new in new }
        for name in headers.keys.sorted() {
            if let value = headers[name] { lines.append("  -H '\(shellQuote(name + ": " + value))'") }
        }
        if let page = task.pageURL { lines.append("  -H 'Referer: \(shellQuote(page))'") }
        lines.append("  -o '\(shellQuote(task.displayName))'")
        return lines.joined(separator: " \\\n")
    }

    private static func shellQuote(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "'\\''") }
}
