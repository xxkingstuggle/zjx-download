import Foundation
import Network

public struct RESTQueue: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String
    public init(id: Int64, name: String) { self.id = id; self.name = name }
}

public struct RESTAddOptions: Codable, Sendable, Equatable {
    public var silentAdd: Bool
    public var silentStart: Bool
    public init(silentAdd: Bool = false, silentStart: Bool = false) { self.silentAdd = silentAdd; self.silentStart = silentStart }
    enum CodingKeys: String, CodingKey { case silentAdd, silentStart }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        silentAdd = try container.decodeIfPresent(Bool.self, forKey: .silentAdd) ?? false
        silentStart = try container.decodeIfPresent(Bool.self, forKey: .silentStart) ?? false
    }
}

/// A normalized operation passed to the host application. Keeping integration
/// flags here prevents the transport layer from silently dropping old API
/// semantics.
public struct RESTAddOperation: Sendable {
    public let request: DownloadRequest
    public let options: RESTAddOptions
    public let startQueue: Bool
    public init(request: DownloadRequest, options: RESTAddOptions = RESTAddOptions(), startQueue: Bool = false) {
        self.request = request; self.options = options; self.startQueue = startQueue
    }
}

public actor RESTService {
    public static let bindHost = "127.0.0.1"
    public typealias AddHandler = @Sendable (RESTAddOperation) async throws -> Void
    private let port: UInt16
    private let apiKey: String?
    private let addHandler: AddHandler
    private let queueProvider: @Sendable () async -> [DownloadQueue]
    private var listener: NWListener?

    public init(settings: IntegrationSettings, addHandler: @escaping AddHandler, queueProvider: @escaping @Sendable () async -> [DownloadQueue]) throws {
        guard settings.port > 0 && settings.port <= 65535 else { throw URLError(.badURL) }
        port = UInt16(settings.port); apiKey = settings.enforcedKey; self.addHandler = addHandler; self.queueProvider = queueProvider
    }

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(Self.bindHost), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters, on: .any)
        let service = self
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue(label: "ABDM.REST.connection"))
            Task { await service.receiveRequest(connection, accumulated: Data()) }
        }
        listener.stateUpdateHandler = { _ in }
        listener.start(queue: DispatchQueue(label: "ABDM.REST.listener"))
        self.listener = listener
    }

    public func stop() { listener?.cancel(); listener = nil }

    public func boundEndpoint() -> String? { listener?.parameters.requiredLocalEndpoint.map { String(describing: $0) } }

    private func receiveRequest(_ connection: NWConnection, accumulated: Data) async {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2 * 1024 * 1024 - accumulated.count) { [service = self] data, _, _, _ in
            guard let data, !data.isEmpty else { connection.cancel(); return }
            let combined = accumulated + data
            let delimiter = Data("\r\n\r\n".utf8)
            if let headerRange = combined.range(of: delimiter) {
                let header = combined.prefix(headerRange.lowerBound)
                let headerText = String(decoding: header, as: UTF8.self)
                let contentLength = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
                    .first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "0") } ?? 0
                let required = headerRange.upperBound + contentLength
                if combined.count < required {
                    Task { await service.receiveRequest(connection, accumulated: combined) }
                } else {
                    Task { await service.handle(data: combined.prefix(required), connection: connection) }
                }
            } else if combined.count < 2 * 1024 * 1024 {
                Task { await service.receiveRequest(connection, accumulated: combined) }
            } else {
                connection.cancel()
            }
        }
    }

    private func handle(data: Data, connection: NWConnection) async {
        guard let request = String(data: data, encoding: .utf8), let headerEnd = request.range(of: "\r\n\r\n") else { respond(connection, status: 400, body: "Bad Request"); return }
        let headerText = String(request[..<headerEnd.lowerBound])
        let contentLength = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).first(where: { $0.lowercased().hasPrefix("content-length:") }).flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "0") } ?? 0
        let bodyStart = headerEnd.upperBound
        let bodyData = Data(request[bodyStart...].utf8)
        let bodyText = String(data: bodyData.prefix(contentLength), encoding: .utf8) ?? ""
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { respond(connection, status: 400, body: "Bad Request"); return }
        let components = first.split(separator: " ")
        guard components.count >= 2 else { respond(connection, status: 400, body: "Bad Request"); return }
        let method = String(components[0]), path = String(components[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() { let pair = line.split(separator: ":", maxSplits: 1).map(String.init); if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) } }
        if let apiKey, headers["x-api-key"] != apiKey { respond(connection, status: 401, body: "Unauthorized"); return }
        if method == "OPTIONS" { respond(connection, status: 204, body: ""); return }
        do {
            switch (method, path) {
            case ("POST", "/ping"): respond(connection, status: 200, body: "pong")
            case ("GET", "/queues"):
                let queues = await queueProvider().map { RESTQueue(id: $0.id, name: $0.name) }
                respond(connection, status: 200, body: String(data: try JSONEncoder().encode(queues), encoding: .utf8) ?? "[]", contentType: "application/json")
            case ("POST", "/add"):
                let envelope = try decodeAddItems(bodyText)
                for operation in envelope { try await addHandler(operation) }
                respond(connection, status: 200, body: "OK")
            case ("POST", "/start-headless-download"):
                try await addHandler(decodeHeadless(bodyText))
                respond(connection, status: 200, body: "OK")
            default: respond(connection, status: 404, body: "Not Found")
            }
        } catch { respond(connection, status: 400, body: error.localizedDescription) }
    }

    private func decodeAddItems(_ text: String) throws -> [RESTAddOperation] {
        let data = Data(text.utf8)
        if let envelope = try? JSONDecoder().decode(RESTAddEnvelope.self, from: data) {
            return try envelope.items.map { try operation(for: $0, options: envelope.options) }
        }
        return try JSONDecoder().decode([RESTSource].self, from: data).map { try operation(for: $0) }
    }

    private func decodeHeadless(_ text: String) throws -> RESTAddOperation {
        let payload = try JSONDecoder().decode(RESTHeadless.self, from: Data(text.utf8))
        let request = try makeRequest(payload.downloadSource, folder: payload.folder, name: payload.name, queueID: payload.queueId, categoryID: payload.categoryId, start: payload.startDownload, enqueue: payload.startQueue, kind: payload.downloadSource.type)
        return RESTAddOperation(request: request, startQueue: payload.startQueue)
    }

    private func operation(for source: RESTSource, options: RESTAddOptions = RESTAddOptions()) throws -> RESTAddOperation {
        RESTAddOperation(request: try makeRequest(source, kind: source.type), options: options)
    }

    private func makeRequest(_ source: RESTSource, folder: String? = nil, name: String? = nil, queueID: Int64? = nil, categoryID: Int64? = nil, start: Bool = false, enqueue: Bool = false, kind: DownloadKind) throws -> DownloadRequest {
        guard let url = URL(string: source.link), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { throw DownloadEngineError.invalidURL }
        return DownloadRequest(source: DownloadSource(url: url, downloadPage: source.downloadPage, headers: source.headers ?? [:], suggestedName: source.suggestedName), folderPath: folder, fileName: name, queueID: queueID, categoryID: categoryID, kind: kind, startImmediately: start, enqueue: enqueue)
    }

    private func respond(_ connection: NWConnection, status: Int, body: String, contentType: String = "text/plain; charset=utf-8") {
        let reason = status == 200 ? "OK" : status == 204 ? "No Content" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : "Bad Request"
        let payload = body.data(using: .utf8) ?? Data()
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, X-Api-Key\r\nConnection: close\r\n\r\n".data(using: .utf8)! + payload
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private struct RESTSource: Codable { let link: String; let headers: [String: String]?; let downloadPage: String?; let suggestedName: String?; let type: DownloadKind
    enum CodingKeys: String, CodingKey { case link, headers, downloadPage, suggestedName, type }
    init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); link = try c.decode(String.self, forKey: .link); headers = try c.decodeIfPresent([String: String].self, forKey: .headers); downloadPage = try c.decodeIfPresent(String.self, forKey: .downloadPage); suggestedName = try c.decodeIfPresent(String.self, forKey: .suggestedName); type = try c.decodeIfPresent(DownloadKind.self, forKey: .type) ?? (link.lowercased().contains(".m3u8") ? .hls : .http) }
}
private struct RESTAddEnvelope: Codable {
    let items: [RESTSource]
    let options: RESTAddOptions
    enum CodingKeys: String, CodingKey { case items, options }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([RESTSource].self, forKey: .items)
        options = try c.decodeIfPresent(RESTAddOptions.self, forKey: .options) ?? RESTAddOptions()
    }
}
private struct RESTHeadless: Codable {
    let downloadSource: RESTSource; let folder: String?; let name: String?; let queueId: Int64?; let categoryId: Int64?; let startDownload: Bool; let startQueue: Bool
    enum CodingKeys: String, CodingKey { case downloadSource, folder, name, queueId, categoryId, startDownload, startQueue }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadSource = try c.decode(RESTSource.self, forKey: .downloadSource)
        folder = try c.decodeIfPresent(String.self, forKey: .folder); name = try c.decodeIfPresent(String.self, forKey: .name)
        queueId = try c.decodeIfPresent(Int64.self, forKey: .queueId); categoryId = try c.decodeIfPresent(Int64.self, forKey: .categoryId)
        startDownload = try c.decodeIfPresent(Bool.self, forKey: .startDownload) ?? false
        startQueue = try c.decodeIfPresent(Bool.self, forKey: .startQueue) ?? false
    }
}
