import Foundation
import HomeKit

// MARK: - Tool Provider Protocol

/// Each domain (accessories, rooms, scenes) implements this protocol.
/// HTTPMCPServer collects all providers and delegates tool listing/dispatch to them.
protocol ToolProvider {
    /// JSON schema definitions for all tools in this domain (used in tools/list response)
    var toolDefinitions: [[String: Any]] { get }

    /// Handle a tool call. Return nil if the tool name doesn't belong to this provider.
    func handle(toolName: String, arguments: [String: Any], request: MCPRequest) -> MCPResponse?
}

// MARK: - Shared Helpers

/// Wraps a HomeKit async callback into a synchronous result with a 5-second timeout.
func withHomeKitCallback<T>(
    timeout: Double = 5.0,
    block: (@escaping (T?, Error?) -> Void) -> Void
) -> (result: T?, error: Error?, timedOut: Bool) {
    let group = DispatchGroup()
    var resultValue: T?
    var resultError: Error?
    var completed = false

    group.enter()
    block { value, error in
        guard !completed else { return }
        completed = true
        resultValue = value
        resultError = error
        group.leave()
    }

    let waitResult = group.wait(timeout: .now() + timeout)
    return (resultValue, resultError, waitResult == .timedOut)
}

/// Simpler variant for callbacks that only return an optional Error.
func withHomeKitOperation(
    timeout: Double = 5.0,
    block: (@escaping (Error?) -> Void) -> Void
) -> (error: Error?, timedOut: Bool) {
    let group = DispatchGroup()
    var resultError: Error?
    var completed = false

    group.enter()
    block { error in
        guard !completed else { return }
        completed = true
        resultError = error
        group.leave()
    }

    let waitResult = group.wait(timeout: .now() + timeout)
    return (resultError, waitResult == .timedOut)
}

// MARK: - Response Builders

func textResponse(id: Int?, text: String, meta: [String: Any]? = nil) -> MCPResponse {
    var result: [String: AnyEncodable] = [
        "content": AnyEncodable([["type": "text", "text": text]])
    ]
    if let meta = meta {
        result["_meta"] = AnyEncodable(meta)
    }
    return MCPResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
}

func errorResponse(id: Int?, code: Int = -32603, message: String) -> MCPResponse {
    MCPResponse(jsonrpc: "2.0", id: id, result: nil,
                error: MCPError(code: code, message: message))
}

func missingParamResponse(id: Int?, param: String) -> MCPResponse {
    errorResponse(id: id, code: -32602, message: "Missing '\(param)' parameter")
}

func timeoutResponse(id: Int?) -> MCPResponse {
    textResponse(id: id, text: "⏰ Operation timed out after 5 seconds — HomeKit may be busy. Try again.")
}
