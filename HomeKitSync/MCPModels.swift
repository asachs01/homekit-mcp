import Foundation

// MARK: - MCP Protocol Models
// Shared types used by HTTPMCPServer and all ToolProvider implementations.

struct MCPRequest: Codable {
    let jsonrpc: String
    let id: Int?
    let method: String
    let params: [String: AnyEncodable]?
}

struct MCPResponse: Codable {
    let jsonrpc: String
    let id: Int?
    let result: [String: AnyEncodable]?
    let error: MCPError?
}

struct MCPError: Codable {
    let code: Int
    let message: String
}

struct AnyEncodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? String           { try container.encode(v) }
        else if let v = value as? Int         { try container.encode(v) }
        else if let v = value as? Bool        { try container.encode(v) }
        else if let v = value as? Double      { try container.encode(v) }
        else if let v = value as? [Any]       { try container.encode(v.map { AnyEncodable($0) }) }
        else if let v = value as? [String: Any] { try container.encode(v.mapValues { AnyEncodable($0) }) }
        else                                  { try container.encodeNil() }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self)              { value = v }
        else if let v = try? container.decode(Bool.self)           { value = v }
        else if let v = try? container.decode(Int.self)            { value = v }
        else if let v = try? container.decode(Double.self)         { value = v }
        else if let v = try? container.decode([AnyEncodable].self) { value = v.map { $0.value } }
        else if let v = try? container.decode([String: AnyEncodable].self) { value = v.mapValues { $0.value } }
        else                                                       { value = NSNull() }
    }
}
