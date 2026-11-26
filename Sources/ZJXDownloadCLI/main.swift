import CoreFoundation
import Foundation
import ZJXDownloadCore

@main
struct DownloadCLI {
    private static let loopbackSession = URLSession(configuration: NetworkConfiguration.loopbackSessionConfiguration())

    private enum ProbeResult {
        case ready
        case unavailable
        case error(String)
    }

    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(_ args: [String]) async throws {
        guard !args.isEmpty else { usage(); exit(2) }
        if args.contains("--help") || args == ["help"] { usage(); return }
        let root = ProcessInfo.processInfo.environment["ZJX_DOWNLOAD_API"] ?? "http://127.0.0.1:15151"
        let pieces = Array(args)
        if pieces.first == "gui" {
            guard pieces.count >= 2 else { usage(); exit(2) }
            switch pieces[1] {
            case "run":
                try openApp(background: pieces.contains("--background"))
                print("zjx-download started")
            case "start-if-not-started":
                switch await probe(root: root) {
                case .ready:
                    print("zjx-download ready")
                    return
                case .error(let message):
                    throw CLIError.server(message)
                case .unavailable:
                    break
                }
                try openApp(background: true)
                let deadline = Date.now.addingTimeInterval(20)
                while Date.now < deadline {
                    switch await probe(root: root) {
                    case .ready:
                        print("zjx-download ready")
                        return
                    case .error(let message):
                        throw CLIError.server(message)
                    case .unavailable:
                        try await Task.sleep(for: .milliseconds(500))
                    }
                }
                throw CLIError.server("已请求启动应用，但集成 API 未在 20 秒内通过 ping 确认就绪。")
            case "exit":
                _ = try await request("POST", "/quit", body: Data(), root: root)
                print("quit requested")
            case "integration":
                guard pieces.count == 2 || (pieces.count == 3 && pieces[2] == "show") else {
                    usage(); exit(2)
                }
                switch await probe(root: root) {
                case .ready: print(root)
                case .unavailable: print("UNKNOWN")
                case .error(let message): throw CLIError.server(message)
                }
            default:
                usage(); exit(2)
            }
            return
        }
        if pieces.starts(with: ["native-messaging", "install"]) || pieces.starts(with: ["native-messaging", "uninstall"]) {
            let action = pieces[1]
            let script = resolveAppBundleURL().appendingPathComponent("Contents/Helpers/manage-native-host")
            guard FileManager.default.isExecutableFile(atPath: script.path) else {
                throw CLIError.server("找不到 Native Messaging 管理脚本：\(script.path)")
            }
            let process = Process(); process.executableURL = script; process.arguments = [action]
            try process.run(); process.waitUntilExit()
            if process.terminationStatus != 0 { exit(Int32(process.terminationStatus)) }
            return
        }
        guard pieces.count >= 2, pieces[0] == "download" else { usage(); exit(2) }
        switch pieces[1] {
        case "show":
            var watch = false
            var ids: [Int64] = []
            for token in pieces.dropFirst(2) {
                if token == "--watch" { watch = true; continue }
                ids.append(try parsePositiveID(token, label: "任务 ID"))
            }
            try await show(ids: ids, watch: watch, root: root)
        case "add":
            guard pieces.count >= 4 else { usage(); exit(2) }
            let kind = pieces[2]
            guard kind == "http" || kind == "hls" else { throw CLIError.arguments("类型应为 http 或 hls。") }
            let options = try parseOptions(Array(pieces.dropFirst(3)))
            guard let link = options["link"], let url = URL(string: link),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw CLIError.arguments("--link 必须是有效的 HTTP(S) 地址。")
            }
            var source: [String: Any] = ["type": kind, "link": link]
            if let value = options["download-page"] { source["downloadPage"] = value }
            if let value = options["name"] { source["suggestedName"] = value }
            if let value = options["folder"] { source["folder"] = value }
            var queueID: Int64?
            if let value = options["queue"] {
                let parsed = try parsePositiveID(value, label: "--queue")
                source["queueId"] = parsed
                queueID = parsed
            }
            if let value = options["category"] {
                source["categoryId"] = try parsePositiveID(value, label: "--category")
            }
            if options["start"] == "true" { source["startDownload"] = true }
            if !options["headers", default: ""].isEmpty { source["headers"] = parseHeaders(options["headers"]!) }
            let requestID = UUID().uuidString
            let body = try JSONSerialization.data(withJSONObject: ["requestId": requestID,
                "items": [source], "options": ["silentAdd": true, "silentStart": options["start"] == "true"]], options: [.sortedKeys])
            let result = try await request("POST", "/add", body: body, root: root, timeout: 130)
            let taskID = try decodeReceipt(result, requestID: requestID)
            print(taskID)
            if options["start-queue"] == "true" {
                guard let queueID else { throw CLIError.arguments("使用 --start-queue 时必须同时指定 --queue ID。") }
                _ = try await request("POST", "/queues/\(queueID)/start", body: Data(), root: root)
            }
        case "pause", "resume", "remove":
            var removeFile = false
            var ids: [Int64] = []
            for token in pieces.dropFirst(2) {
                if token == "--remove-file" {
                    guard pieces[1] == "remove" else { throw CLIError.arguments("--remove-file 仅支持 download remove。") }
                    removeFile = true
                    continue
                }
                ids.append(try parsePositiveID(token, label: "任务 ID"))
            }
            guard !ids.isEmpty else { throw CLIError.arguments("至少提供一个任务 ID。") }
            var failures = false
            for id in ids {
                let method = pieces[1] == "remove" ? "DELETE" : "POST"
                let suffix = pieces[1] == "remove" ? (removeFile ? "remove?removeFiles=true" : "remove") : pieces[1]
                do { _ = try await request(method, "/tasks/\(id)/\(suffix)", body: Data(), root: root) }
                catch {
                    failures = true
                    FileHandle.standardError.write(Data("\(id): \(error.localizedDescription)\n".utf8))
                }
            }
            if failures { exit(1) }
        default:
            usage(); exit(2)
        }
    }

    private static func decodeReceipt(_ data: Data, requestID: String) throws -> Int64 {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["requestId"] as? String == requestID,
              let acceptedValue = object["accepted"] as? NSNumber,
              CFGetTypeID(acceptedValue) == CFBooleanGetTypeID(),
              let countValue = object["acceptedCount"] as? NSNumber,
              CFGetTypeID(countValue) != CFBooleanGetTypeID(), countValue.intValue == 1,
              countValue.doubleValue == 1,
              let ids = object["acceptedTaskIDs"] as? [NSNumber], ids.count == 1,
              let items = object["items"] as? [[String: Any]], items.count == 1,
              CFGetTypeID(ids[0]) != CFBooleanGetTypeID(), ids[0].int64Value > 0,
              ids[0].doubleValue == Double(ids[0].int64Value),
              let index = items[0]["index"] as? NSNumber,
              CFGetTypeID(index) != CFBooleanGetTypeID(), index.intValue == 0, index.doubleValue == 0,
              let itemID = items[0]["taskID"] as? NSNumber,
              CFGetTypeID(itemID) != CFBooleanGetTypeID(), itemID.int64Value > 0,
              itemID.doubleValue == Double(itemID.int64Value),
              ids[0].int64Value == itemID.int64Value,
              acceptedValue.boolValue else {
            let message = receiptFailureMessage(data)
            throw CLIError.server(message)
        }
        if !(items[0]["error"] is NSNull) {
            let error = items[0]["error"] ?? "<missing>"
            throw CLIError.server("App 返回的接收回执同时包含任务编号和错误：\(String(describing: error))")
        }
        return itemID.int64Value
    }

    private static func receiptFailureMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "App 未返回有效的任务接收回执。"
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let item = (object["items"] as? [[String: Any]])?.first, let message = item["error"] as? String { return message }
        if (object["declined"] as? Bool) == true { return "用户拒绝了下载请求。" }
        return "App 未确认本请求已持久化接收；不会猜测任务编号。"
    }

    private static func show(ids: [Int64], watch: Bool, root: String) async throws {
        repeat {
            let bytes = try await request("GET", "/tasks", body: nil, root: root)
            let all = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] ?? []
            let rows = ids.isEmpty ? all : all.filter { ids.contains(($0["id"] as? NSNumber)?.int64Value ?? -1) }
            if rows.isEmpty { print("No downloads found.") }
            for row in rows {
                let id = row["id"] ?? "?", status = row["status"] ?? "?", name = row["name"] ?? "?", folder = row["folder"] ?? "?"
                let progressText: String
                if let progress = (row["progress"] as? NSNumber)?.doubleValue {
                    progressText = String(format: "%.0f%%", progress * 100)
                } else {
                    progressText = "-"
                }
                let speedBytes = (row["speedBytesPerSecond"] as? NSNumber)?.int64Value ?? 0
                let speedText = speedBytes > 0 ? ByteFormatting.speed(speedBytes, unit: "binary") : "-"
                print("\(id)\t\(status)\t\(progressText)\t\(speedText)\t\(name)\t\(folder)")
            }
            if watch { try await Task.sleep(for: .seconds(1)); print("---") }
        } while watch
    }

    private static func probe(root: String) async -> ProbeResult {
        guard let url = endpoint(root: root, path: "/ping") else { return .error("API 地址无效。") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = ProcessInfo.processInfo.environment["ZJX_DOWNLOAD_API_KEY"] {
            request.setValue(key, forHTTPHeaderField: "X-API-Key")
        }
        do {
            let (data, response) = try await loopbackSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .error("集成 API 未返回 HTTP 响应。") }
            if http.statusCode == 200, String(data: data, encoding: .utf8) == "pong" { return .ready }
            if http.statusCode == 401 { return .error("集成 API 可达，但 API Key 缺失或无效；未重新启动应用。") }
            return .error("集成 API 返回 HTTP \(http.statusCode)：\(responseMessage(data))")
        } catch { return .unavailable }
    }

    private static func request(_ method: String, _ path: String, body: Data?, root: String,
                                timeout: TimeInterval = 4) async throws -> Data {
        guard let url = endpoint(root: root, path: path) else { throw CLIError.server("API 地址无效。") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if method != "GET", let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let key = ProcessInfo.processInfo.environment["ZJX_DOWNLOAD_API_KEY"] {
            request.setValue(key, forHTTPHeaderField: "X-API-Key")
        }
        let (data, response) = try await loopbackSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CLIError.server("本机 API 返回 HTTP \(status)：\(responseMessage(data))")
        }
        return data
    }

    private static func endpoint(root: String, path: String) -> URL? {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return URL(string: base + path)
    }

    private static func responseMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            if let code = error["code"] as? String { return "\(code): \(message)" }
            return message
        }
        return String(data: data, encoding: .utf8) ?? "无可读错误信息。"
    }

    private static func openApp(background: Bool) throws {
        let appURL = resolveAppBundleURL()
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw CLIError.server("找不到 \(appURL.path)。")
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = (background ? ["-g"] : []) + ["-a", appURL.path] + (background ? ["--args", "--background"] : [])
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 { throw CLIError.server("无法打开 \(appURL.path)。") }
    }

    private static func resolveAppBundleURL() -> URL {
        var cursor = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        while cursor.path != "/" {
            if cursor.pathExtension == "app" { return cursor }
            cursor.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: "/Applications/zjx-download.app")
    }

    private static func parsePositiveID(_ raw: String, label: String) throws -> Int64 {
        guard let value = Int64(raw), value > 0 else {
            throw CLIError.arguments("\(label) 必须是正整数：\(raw)")
        }
        return value
    }

    private static func parseOptions(_ args: [String]) throws -> [String: String] {
        var result: [String: String] = [:]; var index = 0
        while index < args.count {
            let value = args[index]
            guard value.hasPrefix("--") else { throw CLIError.arguments("无法识别参数：\(value)") }
            let key = String(value.dropFirst(2))
            if ["start", "start-queue", "watch", "remove-file", "background"].contains(key) {
                result[key] = "true"; index += 1; continue
            }
            guard index + 1 < args.count else { throw CLIError.arguments("--\(key) 缺少值。") }
            if key == "header" { result["headers", default: ""] += args[index + 1] + "\n" }
            else { result[key] = args[index + 1] }
            index += 2
        }
        return result
    }

    private static func parseHeaders(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in value.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            result[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func usage() {
        print("zjx-download-cli download add <http|hls> --link URL [--header 'Name: value'] [--folder PATH] [--name NAME] [--download-page URL] [--queue ID] [--category ID] [--start] [--start-queue]\nzjx-download-cli download show [ID...] [--watch]\nzjx-download-cli download pause|resume ID...\nzjx-download-cli download remove ID... [--remove-file]\nzjx-download-cli gui run [--background]|start-if-not-started|exit|integration [show]\nzjx-download-cli native-messaging install|uninstall")
    }
}

enum CLIError: Error, LocalizedError {
    case arguments(String), server(String)
    var errorDescription: String? {
        switch self {
        case .arguments(let message), .server(let message): message
        }
    }
}
