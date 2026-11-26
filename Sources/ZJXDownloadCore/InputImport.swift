import Foundation

public struct ImportedDownload: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var username: String?
    public var password: String?
    public var downloadPage: URL?
    public var suggestedName: String?
    public var userAgent: String?

    public init(url: URL, headers: [String: String] = [:], username: String? = nil, password: String? = nil,
                downloadPage: URL? = nil, suggestedName: String? = nil, userAgent: String? = nil) {
        self.url = url; self.headers = headers; self.username = username; self.password = password
        self.downloadPage = downloadPage; self.suggestedName = suggestedName; self.userAgent = userAgent
    }
}

public struct ImportParseResult: Sendable {
    public var items: [ImportedDownload]
    public var errors: [String]
}

public enum InputImport {
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>\"']+"#, options: [.caseInsensitive])

    public static func parse(_ input: String) -> ImportParseResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ImportParseResult(items: [], errors: ["没有可导入的内容。"] ) }
        if let data = trimmed.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            return parseJSON(json)
        }
        let curl = parseCurl(trimmed)
        if !curl.items.isEmpty || !curl.errors.isEmpty { return curl }
        let urls = extractURLs(trimmed)
        var seen = Set<String>()
        let items = urls.compactMap { url -> ImportedDownload? in
            guard NetworkConfiguration.validate(url), seen.insert(url.absoluteString).inserted else { return nil }
            return ImportedDownload(url: url, headers: [:], username: nil, password: nil, downloadPage: nil, suggestedName: nil, userAgent: nil)
        }
        return ImportParseResult(items: items, errors: items.isEmpty ? ["没有找到有效的 HTTP 或 HTTPS 地址。"] : [])
    }

    public static func expand(pattern: String, start: Int, end: Int, padding: Int? = nil) throws -> [URL] {
        guard start >= 0, end >= start else { throw ValidationError("起止范围无效。") }
        guard end - start < 1000 else { throw ValidationError("一次最多生成 1000 个地址。") }
        let width = padding ?? max(String(start).count, String(end).count)
        guard (0...64).contains(width), pattern.contains("*") else { throw ValidationError("批量模板须包含 *，补零宽度须在 0 到 64 之间。") }
        return try (start...end).map { value in
            let number = padding == 0 ? String(value) : String(format: "%0*d", width, value)
            let expanded = pattern.replacingOccurrences(of: "*", with: number)
            guard let url = URL(string: expanded), NetworkConfiguration.validate(url) else { throw ValidationError("生成的地址无效：\(expanded)") }
            return url
        }
    }

    public static func extractURLs(_ text: String) -> [URL] {
        let ns = text as NSString
        return urlPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            var value = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ").,;!]}"))
            if value.hasSuffix("\\") { value.removeLast() }
            guard let url = URL(string: value), NetworkConfiguration.validate(url) else { return nil }
            return url
        }
    }

    private static func parseJSON(_ value: Any) -> ImportParseResult {
        let objects: [[String: Any]]
        if let array = value as? [[String: Any]] { objects = array }
        else if let object = value as? [String: Any] { objects = [object] }
        else { return ImportParseResult(items: [], errors: ["JSON 顶层必须是对象或对象数组。"] ) }
        var items: [ImportedDownload] = []
        var errors: [String] = []
        var seen = Set<String>()
        for (index, object) in objects.enumerated() {
            guard let link = object["link"] as? String, let url = URL(string: link), NetworkConfiguration.validate(url) else {
                errors.append("第 \(index + 1) 项缺少有效的 link。")
                continue
            }
            guard seen.insert(url.absoluteString).inserted else { continue }
            var headers = object["headers"] as? [String: String] ?? [:]
            if let agent = object["userAgent"] as? String, !agent.isEmpty { headers["User-Agent"] = agent }
            if let username = object["username"] as? String, let password = object["password"] as? String,
               !username.isEmpty, !password.isEmpty {
                headers["Authorization"] = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
            }
            items.append(ImportedDownload(url: url, headers: headers,
                                          username: object["username"] as? String, password: object["password"] as? String,
                                          downloadPage: (object["downloadPage"] as? String).flatMap(URL.init(string:)),
                                          suggestedName: object["suggestedName"] as? String,
                                          userAgent: object["userAgent"] as? String))
        }
        return ImportParseResult(items: items, errors: errors)
    }

    private static func parseCurl(_ text: String) -> ImportParseResult {
        let joined = text.replacingOccurrences(of: "\\\r\n", with: "").replacingOccurrences(of: "\\\n", with: "")
        guard joined.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("curl ") }) else {
            return ImportParseResult(items: [], errors: [])
        }
        var items: [ImportedDownload] = []
        var errors: [String] = []
        for (lineIndex, rawLine) in joined.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("curl ") else { continue }
            do {
                let tokens = try shellWords(line)
                var headers: [String: String] = [:]
                var urls: [URL] = []
                var suggestedName: String?
                var page: URL?
                var index = 1
                while index < tokens.count {
                    let token = tokens[index]
                    if ["-L", "--location", "--compressed", "-s", "--silent", "-S", "--show-error", "-f", "--fail", "-O", "--remote-name"].contains(token) {
                        index += 1; continue
                    }
                    if ["-H", "--header", "-b", "--cookie", "-u", "--user", "-A", "--user-agent", "-e", "--referer", "-o", "--output", "--url", "-X", "--request"].contains(token) {
                        index += 1
                        guard index < tokens.count else { throw ValidationError("\(token) 缺少参数。") }
                        let value = tokens[index]
                        switch token {
                        case "-H", "--header":
                            guard let split = value.firstIndex(of: ":") else { throw ValidationError("请求头缺少冒号。") }
                            let name = String(value[..<split]).trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty, !value.contains("\r"), !value.contains("\n") else { throw ValidationError("请求头格式无效。") }
                            headers[name] = String(value[value.index(after: split)...]).trimmingCharacters(in: .whitespaces)
                        case "-b", "--cookie":
                            guard !value.contains("\r"), !value.contains("\n") else { throw ValidationError("Cookie 请求头不能换行。") }
                            let existingKey = headers.keys.first { $0.caseInsensitiveCompare("Cookie") == .orderedSame }
                            let existing = existingKey.flatMap { headers.removeValue(forKey: $0) }
                            if let existing, !existing.isEmpty {
                                headers["Cookie"] = "\(existing); \(value)"
                            } else {
                                headers["Cookie"] = value
                            }
                        case "-u", "--user": headers["Authorization"] = "Basic " + Data(value.utf8).base64EncodedString()
                        case "-A", "--user-agent": headers["User-Agent"] = value
                        case "-e", "--referer": headers["Referer"] = value; page = URL(string: value)
                        case "-o", "--output": suggestedName = URL(fileURLWithPath: value).lastPathComponent
                        case "-X", "--request":
                            guard value.uppercased() == "GET" else { throw ValidationError("下载导入只支持 GET 请求。") }
                        default:
                            guard let url = URL(string: value), NetworkConfiguration.validate(url) else { throw ValidationError("URL 无效。") }
                            urls.append(url)
                        }
                    } else {
                        guard !token.hasPrefix("-"), let url = URL(string: token), NetworkConfiguration.validate(url) else {
                            throw ValidationError("存在不支持的 cURL 参数。请使用 HTTP GET URL 和 -H 请求头。")
                        }
                        urls.append(url)
                    }
                    index += 1
                }
                guard !urls.isEmpty else { throw ValidationError("没有有效 URL。") }
                items += urls.map { ImportedDownload(url: $0, headers: headers, downloadPage: page,
                    suggestedName: suggestedName, userAgent: headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value) }
            } catch {
                errors.append("第 \(lineIndex + 1) 行：\(error.localizedDescription)")
            }
        }
        return ImportParseResult(items: items, errors: errors)
    }

    /// Tokenizes shell quoting only; it never evaluates substitutions, variables, or commands.
    private static func shellWords(_ text: String) throws -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in text {
            if escaped { word.append(character); escaped = false; started = true; continue }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
                started = true
            } else if character == "'" || character == "\"" { quote = character; started = true }
            else if character.isWhitespace {
                if started { words.append(word); word = ""; started = false }
            } else {
                guard !";|&<>`".contains(character), character != "$" else { throw ValidationError("cURL 中不支持 shell 命令、变量或重定向。") }
                word.append(character); started = true
            }
        }
        guard quote == nil, !escaped else { throw ValidationError("cURL 引号或转义未结束。") }
        if started { words.append(word) }
        return words
    }
}
