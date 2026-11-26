import CryptoKit
import CoreFoundation
import Foundation
import Network
import Observation

public enum IntegrationError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case unauthorized
    case requestConflict
    case userDeclined
    case notFound
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): message
        case .unauthorized: "本机集成密钥无效。"
        case .requestConflict: "请求编号已用于不同内容。"
        case .userDeclined: "用户拒绝了下载请求。"
        case .notFound: "请求的任务不存在。"
        case .unavailable: "本机集成服务当前不可用。"
        }
    }
}

@MainActor
@Observable
public final class IntegrationServer {
    private struct ListenerBinding: Equatable {
        var enabled: Bool
        var port: Int
    }

    private struct AuthSettings: Equatable, Sendable {
        var requiresKey: Bool
        var keyAccount: String
    }

    private struct RequestSettings: Sendable {
        var port: Int
    }

    private struct ConnectionContext {
        var connection: NWConnection
        var generation: UInt64
        var settings: RequestSettings
        var buffer = Data()
        var timer: DispatchSourceTimer?
        var routeTask: Task<Void, Never>?
        var origin: String?
        var importRequestID: String?
        var responseStarted = false
        var isClosed = false
    }

    private struct ParsedHead {
        var method: String
        var target: String
        var headers: [String: String]
        var contentLength: Int
    }

    private enum HeadResult {
        case invalid(status: Int, code: String, message: String)
        case parsed(ParsedHead)
    }

    private enum AuthorizationDecision {
        case allowed
        case denied
        case unavailable
    }

    private enum RequestDeadline {
        case absent
        case valid(Int64)
        case invalid
    }

    private struct HTTPResponse {
        var status: Int
        var body: Data
    }

    @ObservationIgnored private weak var coordinator: TaskCoordinator?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var binding: ListenerBinding?
    @ObservationIgnored private var authSettings = AuthSettings(requiresKey: false, keyAccount: "integration-api-key")
    @ObservationIgnored private var listenerGeneration: UInt64 = 0
    @ObservationIgnored private var connections: [ObjectIdentifier: ConnectionContext] = [:]
    @ObservationIgnored private let networkQueue = DispatchQueue(label: "com.zjx.download.integration", qos: .utility)

    public private(set) var listeningPort: UInt16?
    public private(set) var lastError: String?
    public var activeListenerGeneration: UInt64 { listenerGeneration }

    private static let allowedExtensionOrigin = "chrome-extension://ikfafcgjoghicpkoolbofdaoonendhak"
    private static let maximumHeaderBytes = 32 * 1024
    private static let maximumBodyBytes = 2 * 1024 * 1024
    private static let maximumConnections = 32
    private static let maximumImportItems = 1_000
    private static let maximumReceiptErrorBytes = 160
    private static let requestTimeout: TimeInterval = 15
    private static let importTimeout: TimeInterval = 125
    private static let singleValueHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "origin", "x-api-key",
        "x-request-id", "x-request-deadline-ms", "authorization", "content-type"
    ]

    public init(coordinator: TaskCoordinator) { self.coordinator = coordinator }

    public func restart(settings: AppSettings) {
        authSettings = AuthSettings(requiresKey: settings.apiRequiresKey, keyAccount: settings.apiKeyAccount)
        let nextBinding = ListenerBinding(enabled: settings.apiEnabled, port: settings.apiPort)
        if nextBinding == binding, (!nextBinding.enabled || listener != nil) {
            return
        }

        listenerGeneration &+= 1
        closeOwnedConnections()
        listener?.cancel()
        listener = nil
        binding = nextBinding
        listeningPort = nil
        lastError = nil

        guard nextBinding.enabled else { return }
        guard (1024...65_535).contains(nextBinding.port), let port = NWEndpoint.Port(rawValue: UInt16(nextBinding.port)) else {
            lastError = "本机集成端口必须在 1024 到 65535 之间。"
            binding = nil
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: port)
            // The port is already part of requiredLocalEndpoint. Passing it again
            // through the listener initializer asks Network.framework to override it.
            let nextListener = try NWListener(using: parameters)
            let generation = listenerGeneration
            let requestSettings = RequestSettings(port: nextBinding.port)
            nextListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection, generation: generation, settings: requestSettings)
                }
            }
            nextListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in self?.listenerStateChanged(state, generation: generation, port: port.rawValue) }
            }
            listener = nextListener
            nextListener.start(queue: networkQueue)
        } catch {
            lastError = listenerErrorDescription(error, port: port.rawValue)
            binding = nil
        }
    }

    public func retryListening() {
        guard let settings = coordinator?.data.settings else { return }
        binding = nil
        restart(settings: settings)
    }

    public func stop() {
        listenerGeneration &+= 1
        binding = nil
        listener?.cancel()
        listener = nil
        listeningPort = nil
        closeOwnedConnections()
    }

    private func listenerStateChanged(_ state: NWListener.State, generation: UInt64, port: UInt16) {
        guard generation == listenerGeneration else { return }
        switch state {
        case .ready:
            listeningPort = port
            lastError = nil
        case .failed(let error):
            lastError = listenerErrorDescription(error, port: port)
            listeningPort = nil
            listenerGeneration &+= 1
            listener?.cancel()
            listener = nil
            binding = nil
            closeOwnedConnections()
        default:
            break
        }
    }

    private func listenerErrorDescription(_ error: any Error, port: UInt16) -> String {
        "本机集成服务无法绑定 127.0.0.1:\(port)：\(error.localizedDescription)"
    }

    private func accept(_ connection: NWConnection, generation: UInt64, settings: RequestSettings) {
        guard generation == listenerGeneration, listener != nil else {
            connection.cancel()
            return
        }
        let activeCount = connections.values.reduce(0) { $0 + ($1.isClosed ? 0 : 1) }
        guard activeCount < Self.maximumConnections else {
            connection.cancel()
            return
        }

        let identifier = ObjectIdentifier(connection)
        connections[identifier] = ConnectionContext(connection: connection, generation: generation, settings: settings)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.connectionStateChanged(state, identifier: identifier, generation: generation)
            }
        }
        installDeadline(for: identifier, after: Self.requestTimeout)
        connection.start(queue: networkQueue)
        receiveNext(for: identifier)
    }

    private func connectionStateChanged(_ state: NWConnection.State, identifier: ObjectIdentifier, generation: UInt64) {
        guard let context = connections[identifier], context.generation == generation, !context.isClosed else { return }
        switch state {
        case .failed, .cancelled:
            closeConnection(identifier)
        default:
            break
        }
    }

    private func receiveNext(for identifier: ObjectIdentifier) {
        guard let context = connections[identifier], !context.isClosed else { return }
        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, connection = context.connection] bytes, _, done, error in
            Task { @MainActor [weak self] in
                self?.received(bytes, done: done, error: error, connection: connection, identifier: identifier)
            }
        }
    }

    private func received(_ bytes: Data?, done: Bool, error: NWError?, connection: NWConnection,
                          identifier: ObjectIdentifier) {
        guard var context = connections[identifier], !context.isClosed,
              context.connection === connection, context.generation == listenerGeneration else { return }
        if error != nil {
            closeConnection(identifier)
            return
        }
        if let bytes, !bytes.isEmpty {
            guard context.buffer.count <= Self.maximumHeaderBytes + Self.maximumBodyBytes - bytes.count else {
                respond(identifier, status: 413, body: Self.errorBody("REQUEST_TOO_LARGE", "请求总长度超出限制。"))
                return
            }
            context.buffer.append(bytes)
            connections[identifier] = context
        }

        guard let boundary = context.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if context.buffer.count > Self.maximumHeaderBytes {
                respond(identifier, status: 431, body: Self.errorBody("HEADERS_TOO_LARGE", "请求头超出限制。"))
            } else if done {
                respond(identifier, status: 400, body: Self.errorBody("INVALID_REQUEST", "HTTP 请求头不完整。"))
            } else {
                receiveNext(for: identifier)
            }
            return
        }

        guard boundary.lowerBound <= Self.maximumHeaderBytes else {
            respond(identifier, status: 431, body: Self.errorBody("HEADERS_TOO_LARGE", "请求头超出限制。"))
            return
        }
        let headData = Data(context.buffer[..<boundary.lowerBound])
        let headResult = Self.parseHead(headData)
        guard case .parsed(let parsedHead) = headResult else {
            if case .invalid(let status, let code, let message) = headResult {
                let bodyStart = boundary.upperBound
                let requestID = Self.requestID(in: Data(context.buffer.dropFirst(bodyStart)))
                respond(identifier, status: status, body: Self.errorBody(code, message, requestID: requestID))
            }
            return
        }

        let bodyStart = boundary.upperBound
        let availableLength = context.buffer.count - bodyStart
        guard availableLength <= parsedHead.contentLength else {
            let requestID = Self.requestID(in: Data(context.buffer.dropFirst(bodyStart)))
            respond(identifier, status: 400, body: Self.errorBody("INVALID_REQUEST", "不支持在同一连接中发送额外请求数据。", requestID: requestID))
            return
        }
        guard availableLength == parsedHead.contentLength else {
            if done {
                let requestID = Self.requestID(in: Data(context.buffer.dropFirst(bodyStart)))
                respond(identifier, status: 400, body: Self.errorBody("INVALID_REQUEST", "请求体长度与 Content-Length 不一致。", requestID: requestID))
            } else {
                receiveNext(for: identifier)
            }
            return
        }

        let body = Data(context.buffer[bodyStart...])
        let requestID = Self.requestID(in: body) ?? parsedHead.headers["x-request-id"].flatMap {
            Self.isValidRequestID($0) ? $0 : nil
        }
        guard Self.isValidLoopbackHost(parsedHead.headers["host"], port: context.settings.port) else {
            respond(identifier, status: 403, body: Self.errorBody("INVALID_HOST", "只接受发往本机集成端口的请求。", requestID: requestID))
            return
        }
        if let origin = parsedHead.headers["origin"], origin != Self.allowedExtensionOrigin {
            respond(identifier, status: 403, body: Self.errorBody("ORIGIN_REJECTED", "请求来源不受信任。", requestID: requestID))
            return
        }

        context.origin = parsedHead.headers["origin"]
        context.buffer.removeAll(keepingCapacity: false)
        connections[identifier] = context
        var request = ParsedRequest(method: parsedHead.method, target: parsedHead.target,
                                    headers: parsedHead.headers, body: body,
                                    requestID: requestID,
                                    deadlineMilliseconds: nil)
        let routePath = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target
        let isImportRoute = request.method == "POST" && (routePath == "/add" || routePath == "/start-headless-download")
        if isImportRoute, request.requestID == nil { request.requestID = UUID().uuidString }
        if request.method == "POST", routePath == "/add" {
            switch Self.requestDeadline(in: body, headers: parsedHead.headers) {
            case .absent:
                break
            case .invalid:
                respond(identifier, status: 400,
                        body: Self.errorBody("INVALID_REQUEST", "requestDeadlineMs 必须是与请求一致的有限毫秒整数。", requestID: request.requestID))
                return
            case .valid(let deadline):
                guard deadline > Self.nowMilliseconds() else {
                    respond(identifier, status: 408,
                            body: Self.errorBody("REQUEST_TIMEOUT", "下载请求已超过调用方截止时间。", requestID: request.requestID))
                    return
                }
                request.deadlineMilliseconds = deadline
            }
        }
        startRoute(request, identifier: identifier)
    }

    private struct ParsedRequest {
        var method: String
        var target: String
        var headers: [String: String]
        var body: Data
        var requestID: String?
        var deadlineMilliseconds: Int64?
    }

    private func startRoute(_ request: ParsedRequest, identifier: ObjectIdentifier) {
        guard var context = connections[identifier], !context.isClosed,
              context.generation == listenerGeneration else {
            closeConnection(identifier)
            return
        }
        context.timer?.cancel()
        context.timer = nil
        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target
        context.importRequestID = request.method == "POST" &&
            (path == "/add" || path == "/start-headless-download") ? request.requestID : nil
        connections[identifier] = context
        var timeout = context.importRequestID == nil ? Self.requestTimeout : Self.importTimeout
        if let deadline = request.deadlineMilliseconds {
            let remaining = Double(deadline) / 1_000 - Date.now.timeIntervalSince1970
            guard remaining > 0 else {
                respond(identifier, status: 408,
                        body: Self.errorBody("REQUEST_TIMEOUT", "下载请求已超过调用方截止时间。", requestID: request.requestID))
                return
            }
            timeout = min(timeout, remaining)
        }
        installDeadline(for: identifier, after: timeout)
        let generation = context.generation
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.route(request)
            self.routeCompleted(result, identifier: identifier, generation: generation)
        }
        connections[identifier]?.routeTask = work
    }

    private func routeCompleted(_ response: HTTPResponse, identifier: ObjectIdentifier, generation: UInt64) {
        guard var context = connections[identifier] else { return }
        context.routeTask = nil
        connections[identifier] = context
        guard !context.isClosed, generation == listenerGeneration else {
            closeConnection(identifier)
            return
        }
        guard !context.responseStarted else { return }
        context.timer?.cancel()
        context.timer = nil
        connections[identifier] = context
        respond(identifier, status: response.status, body: response.body)
    }

    private func installDeadline(for identifier: ObjectIdentifier, after seconds: TimeInterval) {
        guard var context = connections[identifier], !context.isClosed else { return }
        context.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        let generation = context.generation
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.deadlineReached(identifier, generation: generation) }
        }
        context.timer = timer
        connections[identifier] = context
        timer.resume()
    }

    private func deadlineReached(_ identifier: ObjectIdentifier, generation: UInt64) {
        guard let context = connections[identifier], context.generation == generation, !context.isClosed else { return }
        if context.routeTask != nil {
            var updated = context
            updated.timer?.cancel()
            updated.timer = nil
            updated.routeTask?.cancel()
            if let requestID = updated.importRequestID {
                coordinator?.cancelImportRequest(requestID: requestID)
            }
            connections[identifier] = updated
            respond(identifier, status: 408,
                    body: Self.errorBody("REQUEST_TIMEOUT", "请求超时。", requestID: updated.importRequestID))
            return
        }
        let requestID: String? = context.buffer.range(of: Data("\r\n\r\n".utf8)).flatMap { boundary in
            if let bodyID = Self.requestID(in: Data(context.buffer.dropFirst(boundary.upperBound))) { return bodyID }
            guard case .parsed(let head) = Self.parseHead(Data(context.buffer[..<boundary.lowerBound])),
                  let headerID = head.headers["x-request-id"], Self.isValidRequestID(headerID) else { return nil }
            return headerID
        }
        respond(identifier, status: 408, body: Self.errorBody("REQUEST_TIMEOUT", "请求超时。", requestID: requestID))
    }

    private func respond(_ identifier: ObjectIdentifier, status: Int, body: Data) {
        guard var context = connections[identifier], !context.isClosed else {
            closeConnection(identifier)
            return
        }
        guard !context.responseStarted else { return }
        context.responseStarted = true
        context.timer?.cancel()
        context.timer = nil
        connections[identifier] = context
        let origin = context.origin
        let reason = Self.reasonPhrase(status)
        let contentType = Self.isTextResponse(body) ? "text/plain; charset=utf-8" : "application/json; charset=utf-8"
        var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if origin == Self.allowedExtensionOrigin {
            header += "Access-Control-Allow-Origin: \(Self.allowedExtensionOrigin)\r\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, X-API-Key, X-Request-ID, X-Request-Deadline-Ms\r\nVary: Origin\r\n"
        }
        header += "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        context.connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in self?.closeConnection(identifier) }
        })
    }

    private func closeConnection(_ identifier: ObjectIdentifier) {
        guard var context = connections[identifier] else { return }
        context.timer?.cancel()
        context.timer = nil
        context.connection.stateUpdateHandler = nil
        context.connection.cancel()
        if context.routeTask != nil {
            context.routeTask?.cancel()
            if let requestID = context.importRequestID {
                coordinator?.cancelImportRequest(requestID: requestID)
            }
            context.isClosed = true
            connections[identifier] = context
        } else {
            connections.removeValue(forKey: identifier)
        }
    }

    private func closeOwnedConnections() {
        for identifier in Array(connections.keys) {
            guard var context = connections[identifier] else { continue }
            context.timer?.cancel()
            context.timer = nil
            context.connection.stateUpdateHandler = nil
            context.connection.cancel()
            if context.routeTask != nil {
                context.routeTask?.cancel()
                if let requestID = context.importRequestID {
                    coordinator?.cancelImportRequest(requestID: requestID)
                }
                context.isClosed = true
                connections[identifier] = context
            } else {
                connections.removeValue(forKey: identifier)
            }
        }
    }

    private func route(_ request: ParsedRequest) async -> HTTPResponse {
        guard let coordinator else { return HTTPResponse(status: 503, body: Self.errorBody("SERVICE_UNAVAILABLE", "应用服务不可用。")) }
        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target
        let method = request.method
        if method == "OPTIONS" {
            return HTTPResponse(status: 204, body: Data())
        }
        switch Self.authorization(request.headers, auth: authSettings, coordinator: coordinator) {
        case .allowed:
            break
        case .denied:
            return HTTPResponse(status: 401, body: Self.errorBody("UNAUTHORIZED", "缺少或错误的集成密钥。", requestID: request.requestID))
        case .unavailable:
            return HTTPResponse(status: 503, body: Self.errorBody("CREDENTIAL_UNAVAILABLE", "本机集成密钥暂时不可用。", requestID: request.requestID))
        }

        if method == "POST", path == "/ping" { return HTTPResponse(status: 200, body: Data("pong".utf8)) }
        if method == "GET", path == "/status" {
            let tasks = coordinator.data.tasks
            let liveState = coordinator.liveState
            let activeCount = tasks.filter { $0.status.isActive }.count
            let queuedCount = tasks.filter { $0.status == .queued }.count
            let completedCount = tasks.filter { $0.status == .completed }.count
            let aggregateSpeed = tasks.reduce(Int64(0)) { partial, task in
                guard task.status.isActive else { return partial }
                return partial + Int64(max(0, liveState.metrics[task.id]?.bytesPerSecond ?? 0))
            }
            var statusPayload: [String: Any] = [
                "ok": true,
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.5",
                "apiRequiresKey": authSettings.requiresKey,
                "activeCount": activeCount,
                "queuedCount": queuedCount,
                "completedCount": completedCount,
                "totalCount": tasks.count,
                "aggregateSpeedBytesPerSecond": aggregateSpeed,
                "pendingImports": coordinator.pendingImportCount
            ]
            if let listeningPort { statusPayload["listeningPort"] = Int(listeningPort) }
            return HTTPResponse(status: 200, body: Self.jsonData(statusPayload))
        }
        if method == "POST", path == "/quit" {
            NotificationCenter.default.post(name: .zjxQuitRequested, object: nil)
            return HTTPResponse(status: 200, body: Data("OK".utf8))
        }
        if method == "POST", path.hasPrefix("/queues/"), path.hasSuffix("/start") {
            let parts = path.split(separator: "/")
            guard parts.count == 3, let id = Int64(parts[1]), coordinator.data.queues.contains(where: { $0.id == id }) else {
                return HTTPResponse(status: 404, body: Self.errorBody("NOT_FOUND", "队列不存在。"))
            }
            coordinator.startQueue(id)
            return HTTPResponse(status: 200, body: Self.jsonData(["ok": true, "queueID": id]))
        }
        if method == "GET", path == "/queues" {
            return HTTPResponse(status: 200, body: Self.jsonData(coordinator.queueList()))
        }
        if method == "GET", path == "/tasks" {
            let formatter = ISO8601DateFormatter()
            let liveState = coordinator.liveState
            let tasks = coordinator.data.tasks.map { task -> [String: Any] in
                let metric = liveState.metrics[task.id]
                let received = liveState.receivedBytes[task.id] ?? task.receivedBytes
                let total = liveState.totalBytes[task.id] ?? task.totalBytes
                let speed = task.status.isActive ? Int64(max(0, metric?.bytesPerSecond ?? 0)) : 0
                let averageSpeed = task.status.isActive ? Int64(max(0, metric?.averageBytesPerSecond ?? 0)) : 0
                var result: [String: Any] = [
                    "id": task.id,
                    "kind": task.kind.rawValue,
                    "status": task.status.rawValue,
                    "name": task.displayName,
                    "link": task.sourceURL,
                    "folder": task.destinationDirectory,
                    "receivedBytes": received,
                    "speedBytesPerSecond": speed,
                    "averageSpeedBytesPerSecond": averageSpeed,
                    "createdAt": formatter.string(from: task.createdAt)
                ]
                if let total {
                    result["totalBytes"] = total
                    if total > 0 {
                        result["progress"] = min(1.0, max(0.0, Double(received) / Double(total)))
                        if speed > 0, total > received {
                            result["etaSeconds"] = Int((total - received) / speed)
                        }
                    }
                } else if task.status == .completed {
                    result["progress"] = 1.0
                }
                if let lastError = task.lastError { result["lastError"] = lastError }
                if let queueID = task.queueID { result["queueId"] = queueID }
                if let categoryID = task.categoryID { result["categoryId"] = categoryID }
                if let completedAt = task.completedAt { result["completedAt"] = formatter.string(from: completedAt) }
                return result
            }
            return HTTPResponse(status: 200, body: Self.jsonData(tasks))
        }
        if method == "GET", path == "/settings/extension" {
            let value = coordinator.data.settings.extensionSettings
            let object: [String: Any] = ["autoCapture": value.autoCapture, "showPageWidgets": value.showPageWidgets,
                "sendRequestHeaders": value.sendRequestHeaders, "silentAdd": value.silentAdd, "silentStart": value.silentStart,
                "closeCapturedTab": value.closeCapturedTab, "bypassKey": value.bypassKey, "minimumSizeKB": value.minimumSizeKB,
                "extensions": value.extensions, "ignoredPatterns": value.ignoredPatterns, "apiPort": coordinator.data.settings.apiPort,
                "apiRequiresKey": coordinator.data.settings.apiRequiresKey]
            return HTTPResponse(status: 200, body: Self.jsonData(object))
        }
        if method == "PUT", path == "/settings/extension" {
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                return HTTPResponse(status: 400, body: Self.errorBody("INVALID_REQUEST", "设置需要 JSON 对象。"))
            }
            let previous = coordinator.data.settings.extensionSettings
            var expected = previous
            Self.applyExtensionSettings(object, to: &expected)
            coordinator.updateSettings { settings in Self.applyExtensionSettings(object, to: &settings.extensionSettings) }
            guard coordinator.data.settings.extensionSettings == expected else {
                return HTTPResponse(status: 500, body: Self.errorBody("PERSISTENCE_FAILED", "设置未能保存。"))
            }
            return HTTPResponse(status: 200, body: Data("OK".utf8))
        }

        if let taskEndpoint = Self.taskEndpoint(path) {
            guard let task = coordinator.data.tasks.first(where: { $0.id == taskEndpoint.id }) else {
                return HTTPResponse(status: 404, body: Self.errorBody("NOT_FOUND", "任务不存在。"))
            }
            switch (method, taskEndpoint.action) {
            case ("POST", "start"), ("POST", "resume"):
                coordinator.start([taskEndpoint.id])
                return HTTPResponse(status: 200, body: Self.jsonData(["ok": true, "taskID": taskEndpoint.id]))
            case ("POST", "pause"):
                coordinator.pause([taskEndpoint.id])
                return HTTPResponse(status: 200, body: Self.jsonData(["ok": true, "taskID": taskEndpoint.id]))
            case ("POST", "cancel"):
                let wasCancelable = task.status != .completed && task.status != .cancelled
                coordinator.cancel([taskEndpoint.id])
                if wasCancelable, coordinator.data.tasks.first(where: { $0.id == taskEndpoint.id })?.status != .cancelled {
                    return HTTPResponse(status: 500, body: Self.errorBody("PERSISTENCE_FAILED", "取消操作未能保存。"))
                }
                return HTTPResponse(status: 200, body: Self.jsonData(["ok": true, "taskID": taskEndpoint.id]))
            case ("DELETE", "remove"):
                let removeFiles = Self.queryFlag("removeFiles", in: request.target)
                let errors = coordinator.remove([taskEndpoint.id], removeCompletedFiles: removeFiles)
                guard errors.isEmpty else {
                    return HTTPResponse(status: 500, body: Self.errorBody("PERSISTENCE_FAILED", errors.joined(separator: " ")))
                }
                return HTTPResponse(status: 200, body: Self.jsonData(["ok": true, "taskID": taskEndpoint.id]))
            default:
                break
            }
        }
        if method == "POST", path == "/add" {
            return await add(request, coordinator: coordinator)
        }
        if method == "POST", path == "/start-headless-download" {
            return await startHeadlessDownload(request, coordinator: coordinator)
        }
        return HTTPResponse(status: 404, body: Self.errorBody("NOT_FOUND", "未找到该接口。"))
    }

    private func add(_ request: ParsedRequest, coordinator: TaskCoordinator) async -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) else {
            return HTTPResponse(status: 400, body: Self.errorBody("INVALID_REQUEST", "请求需要有效 JSON。", requestID: request.requestID))
        }
        var payload: [String: Any]
        if let value = object as? [String: Any] {
            payload = value
        } else if let values = object as? [[String: Any]] {
            payload = ["items": values]
        } else {
            return HTTPResponse(status: 400, body: Self.errorBody("INVALID_REQUEST", "JSON 顶层必须是对象或数组。", requestID: request.requestID))
        }
        if payload["items"] == nil, let item = payload["item"] as? [String: Any] { payload["items"] = [item] }
        let bodyRequestID: String?
        if let raw = payload["requestId"] {
            guard let value = raw as? String else {
                return HTTPResponse(status: 400, body: Self.errorBody("INVALID_REQUEST", "requestId 必须是字符串。", requestID: request.requestID))
            }
            bodyRequestID = value
        } else {
            bodyRequestID = nil
        }
        let headerRequestID = request.headers["x-request-id"]
        if let bodyRequestID, !Self.isValidRequestID(bodyRequestID) {
            return HTTPResponse(status: 400, body: Self.errorBody("INVALID_REQUEST", "requestId 格式无效。", requestID: request.requestID))
        }
        if let headerRequestID, !Self.isValidRequestID(headerRequestID) {
            return HTTPResponse(status: 400, body: Self.errorBody("INVALID_REQUEST", "X-Request-ID 格式无效。", requestID: bodyRequestID))
        }
        if let bodyRequestID, let headerRequestID, bodyRequestID != headerRequestID {
            return HTTPResponse(status: 400, body: Self.errorBody("INVALID_REQUEST", "X-Request-ID 必须与 body.requestId 一致。", requestID: bodyRequestID))
        }
        let requestID = bodyRequestID ?? headerRequestID ?? request.requestID ?? UUID().uuidString
        payload["requestId"] = requestID
        let items = payload["items"] as? [[String: Any]] ?? []
        guard !items.isEmpty else {
            return HTTPResponse(status: 400, body: Self.errorBody("INVALID_REQUEST", "items 不能为空。", requestID: requestID))
        }
        guard items.count <= Self.maximumImportItems else {
            return HTTPResponse(status: 413, body: Self.errorBody("REQUEST_TOO_LARGE", "单次最多接收 \(Self.maximumImportItems) 个任务。", requestID: requestID))
        }
        let cleanPayload = Self.withoutTransportOptions(payload)
        guard let digest = Self.canonicalDigest(payload) else {
            return HTTPResponse(status: 400, body: Self.errorBody("INVALID_REQUEST", "无法规范化下载请求。", requestID: requestID))
        }
        do {
            let deadline = request.deadlineMilliseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
            let result = try await coordinator.importRequestDetailed(cleanPayload, requestID: requestID,
                                                                       digest: digest, deadline: deadline)
            return HTTPResponse(status: 200, body: Self.receipt(requestID: requestID, result: result))
        } catch let error as IntegrationError {
            return Self.importError(error, requestID: requestID, itemCount: items.count)
        } catch {
            return HTTPResponse(status: 500, body: Self.errorBody("INTERNAL_ERROR", error.localizedDescription, requestID: requestID))
        }
    }

    private func startHeadlessDownload(_ request: ParsedRequest, coordinator: TaskCoordinator) async -> HTTPResponse {
        guard let value = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let source = value["downloadSource"] as? [String: Any] else {
            return HTTPResponse(status: 400, body: Self.errorBody("INVALID_REQUEST", "缺少 downloadSource。", requestID: request.requestID))
        }
        var item = source
        if let folder = value["folder"] as? String { item["folder"] = folder }
        if let name = value["name"] as? String { item["suggestedName"] = name }
        if let queue = value["queueId"] { item["queueId"] = queue }
        if let category = value["categoryId"] { item["categoryId"] = category }
        var options: [String: Any] = ["silentAdd": true, "silentStart": value["startDownload"] as? Bool ?? false,
            "startQueue": value["startQueue"] as? Bool ?? false]
        if let queueID = (value["queueId"] as? NSNumber)?.int64Value { options["queueId"] = queueID }
        let requestID = request.headers["x-request-id"] ?? request.requestID ?? UUID().uuidString
        guard Self.isValidRequestID(requestID) else {
            return HTTPResponse(status: 400, body: Self.errorBody("INVALID_REQUEST", "X-Request-ID 格式无效。"))
        }
        let payload: [String: Any] = ["requestId": requestID, "items": [item], "options": options]
        guard let digest = Self.canonicalDigest(payload) else {
            return HTTPResponse(status: 400, body: Self.errorBody("INVALID_REQUEST", "无法规范化下载请求。", requestID: requestID))
        }
        do {
            let result = try await coordinator.importRequestDetailed(payload, requestID: requestID, digest: digest)
            return HTTPResponse(status: 200, body: Self.receipt(requestID: requestID, result: result))
        } catch let error as IntegrationError {
            return Self.importError(error, requestID: requestID, itemCount: 1)
        } catch {
            return HTTPResponse(status: 500, body: Self.errorBody("INTERNAL_ERROR", error.localizedDescription, requestID: requestID))
        }
    }

    private static func authorization(_ headers: [String: String], auth: AuthSettings,
                                      coordinator: TaskCoordinator) -> AuthorizationDecision {
        guard auth.requiresKey else { return .allowed }
        guard !auth.keyAccount.isEmpty else { return .unavailable }
        let expected: String?
        do { expected = try coordinator.credentials.read(account: auth.keyAccount) }
        catch { return .unavailable }
        guard let expected else { return .unavailable }
        guard let supplied = headers["x-api-key"], !supplied.isEmpty,
              NetworkConfiguration.constantTimeEqual(Data(supplied.utf8), Data(expected.utf8)) else { return .denied }
        return .allowed
    }

    private static func queryFlag(_ name: String, in target: String) -> Bool {
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
              let raw = components.queryItems?.first(where: { $0.name == name })?.value?.lowercased() else {
            return false
        }
        return raw == "true" || raw == "1"
    }

    private static func applyExtensionSettings(_ object: [String: Any], to settings: inout ExtensionSettings) {
        if let value = object["autoCapture"] as? Bool { settings.autoCapture = value }
        if let value = object["showPageWidgets"] as? Bool { settings.showPageWidgets = value }
        if let value = object["sendRequestHeaders"] as? Bool { settings.sendRequestHeaders = value }
        if let value = object["silentAdd"] as? Bool { settings.silentAdd = value }
        if let value = object["silentStart"] as? Bool { settings.silentStart = value }
        if let value = object["closeCapturedTab"] as? Bool { settings.closeCapturedTab = value }
        if let value = object["bypassKey"] as? String { settings.bypassKey = value }
        if let value = object["minimumSizeKB"] as? Int { settings.minimumSizeKB = max(0, value) }
        if let value = object["extensions"] as? [String] {
            settings.extensions = value.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        }
        if let value = object["ignoredPatterns"] as? [String] { settings.ignoredPatterns = value }
    }

    private static func taskEndpoint(_ path: String) -> (id: Int64, action: String)? {
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "tasks", let id = Int64(parts[1]), id > 0 else { return nil }
        return (id, String(parts[2]))
    }

    private static func parseHead(_ data: Data) -> HeadResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return .invalid(status: 400, code: "INVALID_REQUEST", message: "请求头不是有效 UTF-8。")
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .invalid(status: 400, code: "INVALID_REQUEST", message: "HTTP 请求行缺失。")
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/"), parts[2] == "HTTP/1.1",
              parts[0].utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
            return .invalid(status: 400, code: "INVALID_REQUEST", message: "HTTP 请求行无效。")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, line.first != " " && line.first != "\t", let colon = line.firstIndex(of: ":") else {
                return .invalid(status: 400, code: "INVALID_REQUEST", message: "HTTP 请求头格式无效。")
            }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy(Self.isHeaderNameByte) else {
                return .invalid(status: 400, code: "INVALID_REQUEST", message: "HTTP 请求头名称无效。")
            }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                guard !Self.singleValueHeaders.contains(name) else {
                    return .invalid(status: 400, code: "INVALID_REQUEST", message: "关键 HTTP 请求头不允许重复。")
                }
                headers[name] = "\(existing), \(value)"
            } else {
                headers[name] = value
            }
        }
        guard headers["host"] != nil else {
            return .invalid(status: 400, code: "INVALID_REQUEST", message: "缺少 Host 请求头。")
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(status: 501, code: "UNSUPPORTED_TRANSFER_ENCODING", message: "不支持 Transfer-Encoding 或 chunked 请求。")
        }
        let contentLength: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(raw) else {
                return .invalid(status: 400, code: "INVALID_CONTENT_LENGTH", message: "Content-Length 必须是非负十进制整数。")
            }
            guard value <= maximumBodyBytes else {
                return .invalid(status: 413, code: "REQUEST_TOO_LARGE", message: "请求体超出限制。")
            }
            contentLength = value
        } else {
            contentLength = 0
        }
        return .parsed(ParsedHead(method: String(parts[0]), target: String(parts[1]), headers: headers,
                                  contentLength: contentLength))
    }

    private static func isHeaderNameByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) ||
            [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains(byte)
    }

    private static func isValidLoopbackHost(_ rawHost: String?, port: Int) -> Bool {
        guard let rawHost, let components = URLComponents(string: "http://\(rawHost)"),
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, components.path.isEmpty,
              let host = components.host?.lowercased(), components.port == port else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    private static func requestID(in body: Data) -> String? {
        guard body.count <= maximumBodyBytes,
              let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = value["requestId"] as? String, isValidRequestID(id) else { return nil }
        return id
    }

    private static func requestDeadline(in body: Data, headers: [String: String]) -> RequestDeadline {
        let headerDeadline: Int64?
        if let rawHeader = headers["x-request-deadline-ms"] {
            guard !rawHeader.isEmpty, rawHeader.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int64(rawHeader), value > 0 else { return .invalid }
            headerDeadline = value
        } else {
            headerDeadline = nil
        }

        var bodyDeadline: Int64?
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let options = object["options"] as? [String: Any],
           let rawValue = options["requestDeadlineMs"] {
            guard let number = rawValue as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue > 0,
                  number.doubleValue < Double(Int64.max),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else { return .invalid }
            let value = number.int64Value
            guard value > 0, Double(value) == number.doubleValue else { return .invalid }
            bodyDeadline = value
        }

        if let headerDeadline, let bodyDeadline, headerDeadline != bodyDeadline { return .invalid }
        if let value = headerDeadline ?? bodyDeadline { return .valid(value) }
        return .absent
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date.now.timeIntervalSince1970 * 1_000)
    }

    private static func isValidRequestID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 128 &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func withoutTransportOptions(_ payload: [String: Any]) -> [String: Any] {
        var result = payload
        guard var options = result["options"] as? [String: Any] else { return result }
        options.removeValue(forKey: "apiKey")
        options.removeValue(forKey: "apiPort")
        options.removeValue(forKey: "requestDeadlineMs")
        if options.isEmpty { result.removeValue(forKey: "options") }
        else { result["options"] = options }
        return result
    }

    private static func canonicalDigest(_ payload: [String: Any]) -> String? {
        let value = withoutTransportOptions(payload)
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func receipt(requestID: String, result: ImportRequestResult) -> Data {
        let items: [[String: Any]] = result.items.sorted { $0.index < $1.index }.map { item in
            let taskID: Any = item.taskID.map { NSNumber(value: $0) as Any } ?? NSNull()
            let error: Any = item.error.map { safeReceiptError($0) as Any } ?? NSNull()
            return ["index": item.index, "taskID": taskID, "error": error]
        }
        let object: [String: Any] = ["requestId": requestID, "accepted": result.accepted,
            "acceptedCount": result.acceptedCount, "acceptedTaskIDs": result.acceptedTaskIDs, "items": items]
        return jsonData(object)
    }

    private static func safeReceiptError(_ value: String) -> String {
        let flattened = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let bytes = Array(flattened.utf8.prefix(maximumReceiptErrorBytes))
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func importError(_ error: IntegrationError, requestID: String, itemCount: Int) -> HTTPResponse {
        switch error {
        case .userDeclined:
            let items = (0..<max(0, itemCount)).map { ImportRequestItemResult(index: $0, error: "用户拒绝了此请求。") }
            let result = ImportRequestResult(items: items)
            var object = (try? JSONSerialization.jsonObject(with: receipt(requestID: requestID, result: result))) as? [String: Any] ?? [:]
            object["declined"] = true
            return HTTPResponse(status: 200, body: jsonData(object))
        case .invalidRequest(let message):
            return HTTPResponse(status: 400, body: errorBody("INVALID_REQUEST", message, requestID: requestID))
        case .unauthorized:
            return HTTPResponse(status: 401, body: errorBody("UNAUTHORIZED", error.localizedDescription, requestID: requestID))
        case .requestConflict:
            return HTTPResponse(status: 409, body: errorBody("REQUEST_CONFLICT", error.localizedDescription, requestID: requestID))
        case .notFound:
            return HTTPResponse(status: 404, body: errorBody("NOT_FOUND", error.localizedDescription, requestID: requestID))
        case .unavailable:
            return HTTPResponse(status: 503, body: errorBody("SERVICE_UNAVAILABLE", error.localizedDescription, requestID: requestID))
        }
    }

    private static func errorBody(_ code: String, _ message: String, requestID: String? = nil) -> Data {
        var value: [String: Any] = ["error": ["code": code, "message": safeReceiptError(message)],
            "accepted": false, "acceptedCount": 0, "acceptedTaskIDs": [], "items": []]
        if let requestID { value["requestId"] = requestID }
        return jsonData(value)
    }

    private static func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])) ?? Data("{}".utf8)
    }

    private static func isTextResponse(_ body: Data) -> Bool {
        body.isEmpty || body == Data("OK".utf8) || body == Data("pong".utf8)
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 408: "Request Timeout"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }

}

public extension Notification.Name {
    static let zjxQuitRequested = Notification.Name("zjx.download.quit.requested")
}
