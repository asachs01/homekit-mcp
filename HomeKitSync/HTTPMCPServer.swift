import Foundation
import HomeKit
import Network

// MARK: - HTTP MCP Server
//
// Thin HTTP router. All HomeKit logic lives in domain-specific ToolProvider implementations:
//   AccessoryTools    — listing, finding, controlling accessories
//   RoomTools         — listing, finding, renaming rooms
//   OrganizationTools — moving accessories between rooms
//   SceneTools        — creating, activating, listing, deleting scenes

class HTTPMCPServer: NSObject, HMHomeManagerDelegate {
    private let homeManager = HMHomeManager()
    private var isReady = false
    private let port: UInt16 = 8080
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let encoder = JSONEncoder()

    private var providers: [ToolProvider] = []

    override init() {
        super.init()
        print("🚀 [MCP] Initializing HomeKit MCP Server...")
        homeManager.delegate = self
        setupHTTPServer()
    }

    // MARK: - HomeKit Delegate

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        print("🏠 [HomeKit] Homes updated. Found \(manager.homes.count) homes:")
        for home in manager.homes {
            print("   - \(home.name): \(home.accessories.count) accessories, \(home.rooms.count) rooms")
        }
        isReady = true

        // Wire up providers now that homeManager is populated
        providers = [
            AccessoryTools(homeManager: homeManager),
            RoomTools(homeManager: homeManager),
            OrganizationTools(homeManager: homeManager),
            SceneTools(homeManager: homeManager)
        ]
    }

    // MARK: - HTTP Server Setup

    private func setupHTTPServer() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                print("Failed to create port \(port)")
                return
            }
            listener = try NWListener(using: parameters, on: nwPort)
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("HTTP MCP Server listening on port \(self?.port ?? 0)")
                case .failed(let error):
                    print("HTTP Server failed: \(error)")
                default:
                    break
                }
            }
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            listener?.start(queue: .main)
        } catch {
            print("Failed to create listener: \(error)")
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveMessage(on: connection)
            case .cancelled, .failed:
                self?.connections.removeAll { $0 === connection }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let error = error {
                print("Receive error: \(error)")
                return
            }
            if let data = data, !data.isEmpty {
                self?.handleHTTPRequest(data: data, connection: connection)
            }
            if !isComplete {
                self?.receiveMessage(on: connection)
            }
        }
    }

    // MARK: - HTTP Routing

    private func handleHTTPRequest(data: Data, connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8),
              let requestLine = requestString.components(separatedBy: "\r\n").first else {
            sendHTTPError(connection: connection, status: 400, message: "Bad Request")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendHTTPError(connection: connection, status: 400, message: "Bad Request")
            return
        }

        let method = parts[0]
        let path = parts[1]
        print("📥 [HTTP] \(method) \(path)")

        switch (method, path) {
        case ("GET", "/"):
            sendHTTPResponse(connection: connection, body: welcomeHTML())
        case ("GET", "/mcp"):
            handleMCPDiscovery(connection: connection)
        case ("GET", "/events"):
            handleSSEConnection(connection: connection)
        case ("POST", "/mcp"):
            handleMCPRequest(data: data, connection: connection)
        case ("POST", "/mcp/initialize"):
            handleWithDecoding(data: data, connection: connection) { self.handleInitialize($0) }
        case ("POST", "/mcp/tools/list"):
            handleWithDecoding(data: data, connection: connection) { self.handleToolsList($0) }
        case ("POST", "/mcp/tools/call"):
            handleWithDecoding(data: data, connection: connection) { self.handleToolCall($0) }
        default:
            print("❌ [HTTP] 404 for \(method) \(path)")
            sendHTTPError(connection: connection, status: 404, message: "Not Found")
        }
    }

    // MARK: - MCP Protocol Handlers

    private func handleMCPDiscovery(connection: NWConnection) {
        let discovery: [String: Any] = [
            "version": "2024-11-05",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "homekit-mcp-server", "version": "2.0.0"]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: discovery) else { return }
        sendHTTPResponse(connection: connection, body: data)
    }

    private func handleMCPRequest(data: Data, connection: NWConnection) {
        handleWithDecoding(data: data, connection: connection) { request in
            switch request.method {
            case "tools/list": return self.handleToolsList(request)
            case "tools/call": return self.handleToolCall(request)
            case "initialize": return self.handleInitialize(request)
            default:
                return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                                   error: MCPError(code: -32601, message: "Method not found"))
            }
        }
    }

    private func handleInitialize(_ request: MCPRequest) -> MCPResponse {
        MCPResponse(jsonrpc: "2.0", id: request.id, result: [
            "protocolVersion": AnyEncodable("2024-11-05"),
            "capabilities": AnyEncodable(["tools": [:]]),
            "serverInfo": AnyEncodable(["name": "homekit-mcp-server", "version": "2.0.0"])
        ], error: nil)
    }

    private func handleToolsList(_ request: MCPRequest) -> MCPResponse {
        let tools = providers.flatMap { $0.toolDefinitions }
        return MCPResponse(jsonrpc: "2.0", id: request.id,
                           result: ["tools": AnyEncodable(tools)], error: nil)
    }

    private func handleToolCall(_ request: MCPRequest) -> MCPResponse {
        print("🔧 [MCP] Tool call received")

        guard let params = request.params,
              let toolName = params["name"]?.value as? String,
              let arguments = params["arguments"]?.value as? [String: Any] else {
            return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                               error: MCPError(code: -32602, message: "Invalid params"))
        }

        print("🔧 [MCP] Calling tool: \(toolName)")

        for provider in providers {
            if let response = provider.handle(toolName: toolName, arguments: arguments, request: request) {
                return response
            }
        }

        return MCPResponse(jsonrpc: "2.0", id: request.id, result: nil,
                           error: MCPError(code: -32601, message: "Tool '\(toolName)' not found"))
    }

    // MARK: - SSE

    private func handleSSEConnection(connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.sendSSEEvent(connection: connection, event: "server-info", data: [
                "name": "homekit-mcp-server",
                "version": "2.0.0"
            ])
        })
    }

    private func sendSSEEvent(connection: NWConnection, event: String, data: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        let message = "event: \(event)\ndata: \(jsonString)\n\n"
        connection.send(content: message.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    // MARK: - HTTP Transport Helpers

    private func handleWithDecoding(data: Data, connection: NWConnection, handler: (MCPRequest) -> MCPResponse) {
        guard let jsonData = extractJSONBody(from: data) else {
            sendHTTPError(connection: connection, status: 400, message: "Invalid request")
            return
        }
        do {
            let request = try JSONDecoder().decode(MCPRequest.self, from: jsonData)
            let response = handler(request)
            let responseData = try encoder.encode(response)
            sendHTTPResponse(connection: connection, body: responseData)
        } catch {
            print("❌ [MCP] Error: \(error)")
            sendHTTPError(connection: connection, status: 400, message: "Invalid MCP request: \(error)")
        }
    }

    private func extractJSONBody(from data: Data) -> Data? {
        guard let requestString = String(data: data, encoding: .utf8) else { return nil }
        let lines = requestString.components(separatedBy: "\r\n")
        guard let bodyStart = lines.firstIndex(of: ""), bodyStart + 1 < lines.count else { return nil }
        return lines[(bodyStart + 1)...].joined(separator: "\r\n").data(using: .utf8)
    }

    private func sendHTTPResponse(connection: NWConnection, body: Data) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        var response = Data()
        response.append(header.data(using: .utf8)!)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendHTTPResponse(connection: NWConnection, body: String) {
        sendHTTPResponse(connection: connection, body: body.data(using: .utf8) ?? Data())
    }

    private func sendHTTPError(connection: NWConnection, status: Int, message: String) {
        let response = "HTTP/1.1 \(status) \(message)\r\nContent-Type: text/plain\r\nContent-Length: \(message.count)\r\nAccess-Control-Allow-Origin: *\r\n\r\n\(message)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Welcome Page

    private func welcomeHTML() -> String {
        let toolList = providers.flatMap { $0.toolDefinitions }
            .compactMap { $0["name"] as? String }
            .map { "<li><code>\($0)</code></li>" }
            .joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <title>HomeKit MCP Server</title>
            <style>
                body { font-family: Arial, sans-serif; margin: 40px; }
                .endpoint { background: #f5f5f5; padding: 10px; margin: 10px 0; border-radius: 5px; }
                code { background: #e8e8e8; padding: 2px 4px; border-radius: 3px; }
            </style>
        </head>
        <body>
            <h1>HomeKit MCP Server v2.0</h1>
            <p>HTTP-based MCP server for HomeKit integration with Claude Code support</p>

            <h2>MCP Endpoints:</h2>
            <div class="endpoint"><strong>GET /mcp</strong> — Server discovery</div>
            <div class="endpoint"><strong>POST /mcp/initialize</strong> — Initialize MCP session</div>
            <div class="endpoint"><strong>POST /mcp/tools/list</strong> — List available tools</div>
            <div class="endpoint"><strong>POST /mcp/tools/call</strong> — Execute a tool</div>
            <div class="endpoint"><strong>GET /events</strong> — Server-Sent Events stream</div>

            <h2>Available Tools (\(providers.flatMap { $0.toolDefinitions }.count)):</h2>
            <ul>\(toolList)</ul>

            <h2>Claude Code Configuration:</h2>
            <pre><code>{
          "mcpServers": {
            "homekit": {
              "type": "http",
              "url": "http://localhost:8080/mcp"
            }
          }
        }</code></pre>
        </body>
        </html>
        """
    }
}
