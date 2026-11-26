import CoreFoundation
import Foundation
import ZJXDownloadCore

@main
struct NativeHost {
    private static let loopbackSession = URLSession(configuration: NetworkConfiguration.loopbackSessionConfiguration())
    private static let maximumRequestIDBytes = 128
    private static let maximumAPIKeyBytes = 4096
    private static let maximumImportItems = 1_000
    private static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    private enum ProbeResult {
        case ready
        case unavailable
        case invalidResponse
        case rejected(HostAPIError)
    }

    private enum DeadlineValue {
        case absent
        case valid(Int64)
        case invalid
    }

    static func main() async {
        do {
            while let frame = try NativeHostProtocol.readFrame(from: .standardInput) {
                let response = await handle(frame)
                let bytes = try JSONSerialization.data(withJSONObject: response, options: [.fragmentsAllowed, .sortedKeys])
                try NativeHostProtocol.writeFrame(bytes, to: .standardOutput)
            }
        } catch {
            FileHandle.standardError.write(Data("native host: \(error.localizedDescription)\n".utf8))
        }
    }

    @MainActor
    private static func handle(_ frame: Data) async -> [String: Any] {
        let rawRequest: Any
        do { rawRequest = try JSONSerialization.jsonObject(with: frame) }
        catch { return failure(NSNull(), "INVALID_REQUEST", "Native Messaging 请求不是有效 JSON。") }
        guard let request = rawRequest as? [String: Any] else {
            return failure(NSNull(), "INVALID_REQUEST", "Native Messaging 请求必须是 JSON 对象。")
        }
        let idValue = request["id"] ?? NSNull()
        guard let id = request["id"] as? String, isValidRequestID(id) else {
            return failure(idValue, "INVALID_REQUEST", "Native Messaging 请求编号无效。")
        }
        guard let content = request["content"] as? [String: Any],
              let action = content["action"] as? String, ["ping", "add"].contains(action),
              let payloadText = content["payload"] as? String,
              let payloadData = payloadText.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return failure(id, "INVALID_REQUEST", "Native Messaging content 或 JSON payload 无效。")
        }
        let options: [String: Any]
        if let rawOptions = payload["options"] {
            guard let object = rawOptions as? [String: Any] else {
                return failure(id, "INVALID_REQUEST", "Native Messaging options 必须是 JSON 对象。")
            }
            options = object
        } else {
            options = [:]
        }
        let deadlineMilliseconds: Int64?
        switch deadlineValue(options["requestDeadlineMs"]) {
        case .absent:
            deadlineMilliseconds = nil
        case .invalid:
            return failure(id, "INVALID_REQUEST", "requestDeadlineMs 必须是有限的正毫秒整数。")
        case .valid(let value):
            deadlineMilliseconds = value
        }
        if isExpired(deadlineMilliseconds) {
            return failure(id, "REQUEST_TIMEOUT", "下载请求已超过调用方截止时间。")
        }
        guard let port = portValue(options["apiPort"]) else {
            return failure(id, "INVALID_REQUEST", "本机集成端口无效。")
        }
        let apiKey: String
        if let rawKey = options["apiKey"] {
            guard let value = rawKey as? String else {
                return failure(id, "INVALID_REQUEST", "本机集成密钥格式无效。")
            }
            apiKey = value
        } else {
            apiKey = ""
        }
        guard apiKey.utf8.count <= maximumAPIKeyBytes,
              !apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return failure(id, "INVALID_REQUEST", "本机集成密钥格式无效。")
        }

        guard let payloadID = payload["requestId"] as? String,
              isValidRequestID(payloadID), payloadID == id else {
            return failure(id, "INVALID_REQUEST", "payload.requestId 必须与 Native 消息 id 相同。")
        }

        var forwardedBody = Data()
        if action == "add" {
            guard let items = payload["items"] as? [[String: Any]], !items.isEmpty else {
                return failure(id, "INVALID_REQUEST", "add 的 items 不能为空。")
            }
            var businessPayload = payload
            var businessOptions = options
            businessOptions.removeValue(forKey: "apiKey")
            businessOptions.removeValue(forKey: "apiPort")
            businessOptions.removeValue(forKey: "requestDeadlineMs")
            if businessOptions.isEmpty { businessPayload.removeValue(forKey: "options") }
            else { businessPayload["options"] = businessOptions }
            do { forwardedBody = try JSONSerialization.data(withJSONObject: businessPayload, options: [.sortedKeys]) }
            catch { return failure(id, "INVALID_REQUEST", "无法编码下载请求。") }
        }

        if action == "add" {
            switch await probe(port: port, apiKey: apiKey, deadlineMilliseconds: deadlineMilliseconds) {
            case .ready:
                break
            case .invalidResponse:
                return failure(id, "INVALID_RESPONSE", "该端口没有返回有效的 zjx-download ping 响应；未转发下载请求。")
            case .rejected(let error):
                return failure(id, error.code, error.message)
            case .unavailable:
                guard !isExpired(deadlineMilliseconds) else {
                    return failure(id, "REQUEST_TIMEOUT", "下载请求已超过调用方截止时间。")
                }
                do { try launchApp() }
                catch { return failure(id, "SERVICE_UNAVAILABLE", error.localizedDescription) }
                guard !isExpired(deadlineMilliseconds) else {
                    return failure(id, "REQUEST_TIMEOUT", "应用启动后下载请求已超过调用方截止时间。")
                }
                var ready = false
                for _ in 0..<15 {
                    guard !isExpired(deadlineMilliseconds) else {
                        return failure(id, "REQUEST_TIMEOUT", "等待应用就绪时下载请求已超过调用方截止时间。")
                    }
                    switch await probe(port: port, apiKey: apiKey, deadlineMilliseconds: deadlineMilliseconds) {
                    case .ready:
                        ready = true
                    case .invalidResponse:
                        return failure(id, "INVALID_RESPONSE", "该端口没有返回有效的 zjx-download ping 响应；未转发下载请求。")
                    case .rejected(let error):
                        return failure(id, error.code, error.message)
                    case .unavailable:
                        let sleepSeconds = min(1, remainingSeconds(until: deadlineMilliseconds) ?? 1)
                        guard sleepSeconds > 0 else {
                            return failure(id, "REQUEST_TIMEOUT", "等待应用就绪时下载请求已超过调用方截止时间。")
                        }
                        do { try await Task.sleep(for: .seconds(sleepSeconds)) }
                        catch { return failure(id, "REQUEST_TIMEOUT", "等待应用就绪被取消。") }
                    }
                    if ready { break }
                }
                guard ready else { return failure(id, "SERVICE_UNAVAILABLE", "已请求启动应用，但本机集成服务未就绪。") }
            }
        }

        guard !isExpired(deadlineMilliseconds) else {
            return failure(id, "REQUEST_TIMEOUT", "下载请求已超过调用方截止时间，未转发。")
        }
        do {
            let body = action == "ping" ? Data() : forwardedBody
            let result = try await requestAPI(path: action == "ping" ? "/ping" : "/add", body: body,
                                              port: port, apiKey: apiKey,
                                              requestID: action == "add" ? id : nil,
                                              deadlineMilliseconds: deadlineMilliseconds,
                                              forwardDeadlineHeader: action == "add",
                                              timeout: action == "ping" ? 2 : 130)
            if action == "ping" {
                guard String(data: result, encoding: .utf8) == "pong" else {
                    return failure(id, "INVALID_RESPONSE", "应用的 ping 响应无效。")
                }
            } else if !validReceipt(result, requestID: id) {
                return failure(id, "INVALID_RESPONSE", "应用没有返回可核验的接收回执。")
            }
            return ["id": id, "content": ["action": NSNull(), "isError": false,
                "payload": String(data: result, encoding: .utf8) ?? ""]]
        } catch let error as HostAPIError {
            return failure(id, error.code, error.message)
        } catch {
            return failure(id, "SERVICE_UNAVAILABLE", error.localizedDescription)
        }
    }

    private static func portValue(_ rawValue: Any?) -> Int? {
        guard let number = rawValue as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return rawValue == nil ? 15151 : nil
        }
        let value = number.intValue
        guard number.doubleValue == Double(value), (1024...65_535).contains(value) else { return nil }
        return value
    }

    private static func isValidRequestID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            value.utf8.count <= maximumRequestIDBytes &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validReceipt(_ data: Data, requestID: String) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["requestId"] as? String == requestID,
              let accepted = value["accepted"] as? NSNumber,
              CFGetTypeID(accepted) == CFBooleanGetTypeID(),
              let count = value["acceptedCount"] as? NSNumber,
              CFGetTypeID(count) != CFBooleanGetTypeID(), count.intValue >= 0,
              count.intValue <= maximumImportItems,
              count.doubleValue == Double(count.intValue),
              let ids = value["acceptedTaskIDs"] as? [NSNumber],
              let items = value["items"] as? [[String: Any]], !items.isEmpty,
              items.count <= maximumImportItems,
              count.intValue == ids.count, accepted.boolValue == (ids.count > 0) else { return false }
        let idsAreValid = ids.allSatisfy { number in
            CFGetTypeID(number) != CFBooleanGetTypeID() && number.int64Value > 0 &&
                number.int64Value <= maximumSafeInteger && number.doubleValue == Double(number.int64Value)
        }
        guard idsAreValid else { return false }
        var indexes: [Int] = []
        var acceptedItems: [(index: Int, id: Int64)] = []
        for item in items {
            guard let rawIndex = item["index"] as? NSNumber,
                  CFGetTypeID(rawIndex) != CFBooleanGetTypeID(), rawIndex.intValue >= 0,
                  rawIndex.doubleValue == Double(rawIndex.intValue),
                  let rawID = item["taskID"], let rawError = item["error"] else { return false }
            indexes.append(rawIndex.intValue)
            if rawID is NSNull {
                guard rawError is String else { return false }
                continue
            }
            guard rawError is NSNull, let number = rawID as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.int64Value > 0,
                  number.int64Value <= maximumSafeInteger,
                  number.doubleValue == Double(number.int64Value) else { return false }
            acceptedItems.append((rawIndex.intValue, number.int64Value))
        }
        guard indexes.sorted() == Array(0..<items.count) else { return false }
        return acceptedItems.sorted { $0.index < $1.index }.map { $0.id } == ids.map(\.int64Value)
    }

    private static func failure(_ id: Any, _ code: String, _ message: String) -> [String: Any] {
        let safeMessage = String(message.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(1024))
        let data = try? JSONSerialization.data(withJSONObject: ["errorType": code, "message": safeMessage], options: [.sortedKeys])
        return ["id": id, "content": ["action": NSNull(), "isError": true,
            "payload": String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"]]
    }

    private static func deadlineValue(_ rawValue: Any?) -> DeadlineValue {
        guard let rawValue else { return .absent }
        guard let number = rawValue as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue > 0,
              number.doubleValue < Double(Int64.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return .invalid }
        let value = number.int64Value
        guard value > 0, Double(value) == number.doubleValue else { return .invalid }
        return .valid(value)
    }

    private static func remainingSeconds(until deadlineMilliseconds: Int64?) -> TimeInterval? {
        guard let deadlineMilliseconds else { return nil }
        return Double(deadlineMilliseconds) / 1_000 - Date.now.timeIntervalSince1970
    }

    private static func isExpired(_ deadlineMilliseconds: Int64?) -> Bool {
        guard let remaining = remainingSeconds(until: deadlineMilliseconds) else { return false }
        return remaining <= 0
    }

    private static func requestTimeoutError() -> HostAPIError {
        .rejected(status: 408, code: "REQUEST_TIMEOUT", message: "下载请求已超过调用方截止时间。")
    }

    private static func probe(port: Int, apiKey: String, deadlineMilliseconds: Int64?) async -> ProbeResult {
        do {
            let response = try await requestAPI(path: "/ping", body: Data(), port: port, apiKey: apiKey,
                                                deadlineMilliseconds: deadlineMilliseconds, timeout: 2)
            return String(data: response, encoding: .utf8) == "pong" ? .ready : .invalidResponse
        } catch let error as HostAPIError {
            if case .unreachable = error { return .unavailable }
            return .rejected(error)
        } catch { return .unavailable }
    }

    private static func launchApp() throws {
        let appURL = resolveAppBundleURL()
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw HostAPIError.unreachable("找不到应用：\(appURL.path)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-a", appURL.path, "--args", "--background"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HostAPIError.unreachable("无法启动应用（退出码 \(process.terminationStatus)）。")
        }
    }

    private static func resolveAppBundleURL() -> URL {
        var cursor = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        while cursor.path != "/" {
            if cursor.pathExtension == "app" { return cursor }
            cursor.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: "/Applications/zjx-download.app")
    }

    private static func requestAPI(path: String, body: Data, port: Int, apiKey: String,
                                   requestID: String? = nil, deadlineMilliseconds: Int64? = nil,
                                   forwardDeadlineHeader: Bool = false,
                                   timeout: TimeInterval) async throws -> Data {
        guard (1024...65_535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw HostAPIError.rejected(status: 400, code: "INVALID_REQUEST", message: "本机集成地址无效。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        let remaining = remainingSeconds(until: deadlineMilliseconds)
        if let remaining, remaining <= 0 { throw requestTimeoutError() }
        let deadlineLimitsRequest = remaining.map { $0 <= timeout } ?? false
        let requestTimeout = min(timeout, remaining ?? timeout)
        guard requestTimeout > 0 else { throw requestTimeoutError() }
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }
        if let requestID { request.setValue(requestID, forHTTPHeaderField: "X-Request-ID") }
        if forwardDeadlineHeader, let deadlineMilliseconds {
            request.setValue(String(deadlineMilliseconds), forHTTPHeaderField: "X-Request-Deadline-Ms")
        }

        let data: Data
        let response: URLResponse
        do { (data, response) = try await loopbackSession.data(for: request) }
        catch {
            if deadlineLimitsRequest, (error as? URLError)?.code == .timedOut {
                throw requestTimeoutError()
            }
            throw HostAPIError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HostAPIError.unreachable("本机集成服务没有返回 HTTP 响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            let parsed = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let detail = parsed["error"] as? [String: Any] ?? parsed
            let message = detail["message"] as? String ?? String(data: data, encoding: .utf8) ?? "应用拒绝了请求。"
            let code = detail["code"] as? String ?? code(for: http.statusCode)
            throw HostAPIError.rejected(status: http.statusCode, code: code, message: message)
        }
        return data
    }

    private static func code(for status: Int) -> String {
        switch status {
        case 400, 413, 431: "INVALID_REQUEST"
        case 401: "UNAUTHORIZED"
        case 403: "ORIGIN_REJECTED"
        case 404: "NOT_FOUND"
        case 409: "REQUEST_CONFLICT"
        case 408: "REQUEST_TIMEOUT"
        case 501: "UNSUPPORTED_TRANSFER_ENCODING"
        case 500: "INTERNAL_ERROR"
        default: "SERVICE_UNAVAILABLE"
        }
    }

    private enum HostAPIError: Error, LocalizedError {
        case unreachable(String)
        case rejected(status: Int, code: String, message: String)

        var code: String {
            switch self {
            case .unreachable: "SERVICE_UNAVAILABLE"
            case .rejected(_, let code, _): code
            }
        }

        var message: String {
            switch self {
            case .unreachable(let message): message
            case .rejected(_, _, let message): message
            }
        }

        var errorDescription: String? { message }
    }
}
