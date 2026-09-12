import Foundation

struct MCPHTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(_ status: Int, object: some Encodable, extraHeaders: [String: String] = [:]) throws -> MCPHTTPResponse {
        let data = try JSONEncoder.mcp.encode(object)
        var headers = [
            "Content-Type": "application/json",
            "Content-Length": "\(data.count)"
        ]
        for (key, value) in extraHeaders {
            headers[key] = value
        }
        return MCPHTTPResponse(status: status, headers: headers, body: data)
    }

    static func empty(_ status: Int, extraHeaders: [String: String] = [:]) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: extraHeaders, body: Data())
    }

    static func text(_ status: Int, _ message: String) -> MCPHTTPResponse {
        let data = Data(message.utf8)
        return MCPHTTPResponse(
            status: status,
            headers: [
                "Content-Type": "text/plain; charset=utf-8",
                "Content-Length": "\(data.count)"
            ],
            body: data
        )
    }

    func serialized(httpVersion: String = "HTTP/1.1") -> Data {
        let reason: String = switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 500: "Internal Server Error"
        default: "Error"
        }
        var header = "\(httpVersion) \(status) \(reason)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            header += "\(key): \(value)\r\n"
        }
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}

enum MCPJSONRPC {
    static let protocolVersion = "2025-03-26"
    static let serverName = "sauron-memory"
    static let serverVersion = "0.1.0"

    struct Envelope: Codable {
        var jsonrpc: String
        var id: MCPRequestID?
        var method: String?
        var params: AnyCodable?
        var result: AnyCodable?
        var error: RPCError?

        var isNotification: Bool { id == nil && method != nil }
        var isResponseOnly: Bool { method == nil && (result != nil || error != nil) }
    }

    struct RPCError: Codable {
        var code: Int
        var message: String
        var data: AnyCodable?
    }

    enum MCPRequestID: Codable, Equatable {
        case number(Double)
        case string(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON-RPC id")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            }
        }
    }
}

/// Minimal type-erased Codable box for JSON-RPC params/results.
struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map(AnyCodable.init))
        case let dict as [String: Any]:
            try container.encode(dict.mapValues(AnyCodable.init))
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported JSON value"))
        }
    }

    var dictionaryValue: [String: Any]? {
        value as? [String: Any]
    }
}

extension JSONEncoder {
    static let mcp: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let mcp: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum MemoryMCPHints {
    static let systemPromptAddon = """
    Sauron meeting memory is available via MCP tools: search_meetings, get_meeting, list_recent_meetings, memory_status.
    Use search_meetings when past meetings may be relevant. Do not invent meeting content.
    """
}
