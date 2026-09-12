import Foundation
import Network
import Observation

enum MemoryMCPServerState: Equatable {
    case stopped
    case starting
    case listening(port: UInt16)
    case failed(String)

    var statusLabel: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .listening(let port): "Listening on 127.0.0.1:\(port)"
        case .failed(let message): message
        }
    }

    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }
}

/// Loopback Streamable HTTP MCP server exposing Sauron meeting memory tools.
@MainActor
@Observable
final class MemoryMCPServer {
    private(set) var state: MemoryMCPServerState = .stopped
    private(set) var lastToolCallAt: Date?
    private(set) var lastToolName: String?

    private var listener: NWListener?
    private var sessions: Set<String> = []
    private weak var appState: AppState?
    private var desiredPort: UInt16 = 8787

    func attach(appState: AppState) {
        self.appState = appState
        _ = KeychainStore.mcpServerToken
    }

    func syncWithSettings() {
        guard let appState else { return }
        let shouldRun = appState.settings.shouldRunMemoryMCPServer
        let port = UInt16(clamping: appState.settings.mcpServerPort)
        if shouldRun {
            if case .listening(let current) = state, current == port {
                return
            }
            restart(port: port)
        } else {
            stop()
        }
    }

    private func start(port: UInt16) {
        desiredPort = port
        state = .starting
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Prefer loopback; fall back to any-local if the interface filter fails on some Macs.
            parameters.requiredInterfaceType = .loopback
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] updated in
                Task { @MainActor in
                    guard let self else { return }
                    switch updated {
                    case .ready:
                        self.state = .listening(port: self.desiredPort)
                    case .failed(let error):
                        self.listener?.cancel()
                        self.listener = nil
                        // Retry once without interface filter (still reject non-local Origins + auth).
                        if self.shouldRetryWithoutLoopbackFilter {
                            self.shouldRetryWithoutLoopbackFilter = false
                            self.startUnfiltered(port: self.desiredPort)
                            return
                        }
                        self.state = .failed(Self.describeBindFailure(error, port: self.desiredPort))
                    case .cancelled:
                        if case .listening = self.state {
                            self.state = .stopped
                        }
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            state = .failed(Self.describeBindFailure(error, port: port))
        }
    }

    private var shouldRetryWithoutLoopbackFilter = true

    private func startUnfiltered(port: UInt16) {
        desiredPort = port
        state = .starting
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] updated in
                Task { @MainActor in
                    guard let self else { return }
                    switch updated {
                    case .ready:
                        self.state = .listening(port: self.desiredPort)
                    case .failed(let error):
                        self.listener = nil
                        self.state = .failed(Self.describeBindFailure(error, port: self.desiredPort))
                    case .cancelled:
                        if case .listening = self.state {
                            self.state = .stopped
                        }
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            state = .failed(Self.describeBindFailure(error, port: port))
        }
    }

    func restart(port: UInt16? = nil) {
        stop()
        shouldRetryWithoutLoopbackFilter = true
        guard let appState, appState.settings.shouldRunMemoryMCPServer else { return }
        let resolved = port ?? UInt16(clamping: appState.settings.mcpServerPort)
        start(port: resolved)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        sessions.removeAll()
        state = .stopped
    }

    private static func describeBindFailure(_ error: Error, port: UInt16) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("address already in use")
            || text.localizedCaseInsensitiveContains("in use") {
            return "Port \(port) is already in use. Pick another port in Memory settings."
        }
        return "Failed to bind 127.0.0.1:\(port) — \(text)"
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveHTTP(on: connection, buffer: Data())
    }

    private func receiveHTTP(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                if let error {
                    connection.cancel()
                    _ = error
                    return
                }
                var next = buffer
                if let data, !data.isEmpty {
                    next.append(data)
                }
                if let request = HTTPRequest.parse(from: next) {
                    let response = await self.handle(request: request)
                    connection.send(content: response.serialized(), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
                if isComplete {
                    connection.cancel()
                    return
                }
                if next.count > 1_000_000 {
                    connection.cancel()
                    return
                }
                self.receiveHTTP(on: connection, buffer: next)
            }
        }
    }

    private func handle(request: HTTPRequest) async -> MCPHTTPResponse {
        guard isAllowedOrigin(request.headers["origin"]) else {
            return .text(403, "Forbidden origin")
        }

        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        guard path == "/mcp" || path == "/mcp/" else {
            return .text(404, "Not found")
        }

        guard let appState else {
            return .text(503, "Sauron is not ready")
        }

        let expected = KeychainStore.mcpServerToken
        let auth = request.headers["authorization"] ?? ""
        guard auth.caseInsensitiveCompare("Bearer \(expected)") == .orderedSame else {
            return .text(401, "Unauthorized")
        }

        switch request.method {
        case "GET":
            return .text(405, "SSE GET not required; use POST JSON responses")
        case "DELETE":
            if let session = request.headers["mcp-session-id"] {
                sessions.remove(session)
            }
            return .empty(200)
        case "POST":
            return await handlePOST(body: request.body, sessionHeader: request.headers["mcp-session-id"], appState: appState)
        default:
            return .text(405, "Method not allowed")
        }
    }

    private func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin, !origin.isEmpty else { return true }
        let lowered = origin.lowercased()
        if lowered == "null" { return true }
        return lowered.hasPrefix("http://127.0.0.1")
            || lowered.hasPrefix("http://localhost")
            || lowered.hasPrefix("https://127.0.0.1")
            || lowered.hasPrefix("https://localhost")
    }

    private func handlePOST(body: Data, sessionHeader: String?, appState: AppState) async -> MCPHTTPResponse {
        let decoder = JSONDecoder.mcp
        if let batch = try? decoder.decode([MCPJSONRPC.Envelope].self, from: body) {
            var responses: [MCPJSONRPC.Envelope] = []
            var sessionToReturn: String?
            for item in batch {
                let (envelope, session) = await process(envelope: item, sessionHeader: sessionHeader, appState: appState)
                if let envelope { responses.append(envelope) }
                if let session { sessionToReturn = session }
            }
            if responses.isEmpty {
                return .empty(202)
            }
            var headers: [String: String] = [:]
            if let sessionToReturn {
                headers["Mcp-Session-Id"] = sessionToReturn
            }
            do {
                return try MCPHTTPResponse.json(200, object: responses, extraHeaders: headers)
            } catch {
                return .text(500, error.localizedDescription)
            }
        }

        guard let envelope = try? decoder.decode(MCPJSONRPC.Envelope.self, from: body) else {
            return .text(400, "Invalid JSON-RPC body")
        }

        if envelope.isResponseOnly || (envelope.isNotification && envelope.method != "notifications/initialized" && envelope.method?.hasPrefix("notifications/") == true) {
            // Accept client responses/notifications we don't need to answer.
            if envelope.method == "notifications/initialized" || envelope.isResponseOnly || envelope.isNotification {
                return .empty(202)
            }
        }

        let (response, newSession) = await process(envelope: envelope, sessionHeader: sessionHeader, appState: appState)
        if let response {
            var headers: [String: String] = [:]
            if let newSession {
                headers["Mcp-Session-Id"] = newSession
            }
            do {
                return try MCPHTTPResponse.json(200, object: response, extraHeaders: headers)
            } catch {
                return .text(500, error.localizedDescription)
            }
        }
        return .empty(202)
    }

    private func process(
        envelope: MCPJSONRPC.Envelope,
        sessionHeader: String?,
        appState: AppState
    ) async -> (MCPJSONRPC.Envelope?, String?) {
        guard let method = envelope.method else {
            return (nil, nil)
        }

        if method == "notifications/initialized" || method.hasPrefix("notifications/") {
            return (nil, nil)
        }

        guard let id = envelope.id else {
            return (nil, nil)
        }

        switch method {
        case "initialize":
            let session = UUID().uuidString
            sessions.insert(session)
            let result: [String: Any] = [
                "protocolVersion": MCPJSONRPC.protocolVersion,
                "capabilities": [
                    "tools": [:] as [String: Any]
                ],
                "serverInfo": [
                    "name": MCPJSONRPC.serverName,
                    "version": MCPJSONRPC.serverVersion
                ]
            ]
            return (
                MCPJSONRPC.Envelope(
                    jsonrpc: "2.0",
                    id: id,
                    method: nil,
                    params: nil,
                    result: AnyCodable(result),
                    error: nil
                ),
                session
            )

        case "ping":
            return (
                MCPJSONRPC.Envelope(jsonrpc: "2.0", id: id, method: nil, params: nil, result: AnyCodable([:] as [String: Any]), error: nil),
                nil
            )

        case "tools/list":
            let tools = MemoryMCPHandlers.tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "inputSchema": tool.inputSchema.mapValues(\.value)
                ]
            }
            return (
                MCPJSONRPC.Envelope(
                    jsonrpc: "2.0",
                    id: id,
                    method: nil,
                    params: nil,
                    result: AnyCodable(["tools": tools]),
                    error: nil
                ),
                nil
            )

        case "tools/call":
            let params = envelope.params?.dictionaryValue ?? [:]
            let name = MemoryMCPHandlers.stringArg(params["name"]) ?? ""
            let arguments = (params["arguments"] as? [String: Any]) ?? [:]
            lastToolCallAt = .now
            lastToolName = name
            let toolResult = await MemoryMCPHandlers.callTool(name: name, arguments: arguments, appState: appState)
            do {
                let data = try JSONEncoder.mcp.encode(toolResult)
                let object = try JSONSerialization.jsonObject(with: data)
                return (
                    MCPJSONRPC.Envelope(
                        jsonrpc: "2.0",
                        id: id,
                        method: nil,
                        params: nil,
                        result: AnyCodable(object),
                        error: nil
                    ),
                    nil
                )
            } catch {
                return (
                    MCPJSONRPC.Envelope(
                        jsonrpc: "2.0",
                        id: id,
                        method: nil,
                        params: nil,
                        result: nil,
                        error: .init(code: -32603, message: error.localizedDescription, data: nil)
                    ),
                    nil
                )
            }

        default:
            return (
                MCPJSONRPC.Envelope(
                    jsonrpc: "2.0",
                    id: id,
                    method: nil,
                    params: nil,
                    result: nil,
                    error: .init(code: -32601, message: "Method not found: \(method)", data: nil)
                ),
                nil
            )
        }
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    static func parse(from data: Data) -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let available = data.count - bodyStart
        guard available >= contentLength else { return nil }
        let body = contentLength > 0
            ? data.subdata(in: bodyStart..<(bodyStart + contentLength))
            : Data()
        return HTTPRequest(
            method: String(parts[0]).uppercased(),
            path: String(parts[1]),
            headers: headers,
            body: body
        )
    }
}
