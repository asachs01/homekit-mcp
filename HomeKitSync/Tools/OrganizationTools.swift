import Foundation
import HomeKit

// MARK: - Organization Domain Tools
// Covers: moving accessories between rooms (by UUID or by name).

class OrganizationTools: ToolProvider {
    private let homeManager: HMHomeManager

    init(homeManager: HMHomeManager) {
        self.homeManager = homeManager
    }

    // MARK: - Tool Definitions

    var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "set_accessory_room",
                "description": "Move an accessory to a different room using UUIDs",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accessory_uuid": ["type": "string", "description": "UUID of the accessory to move"],
                        "room_uuid": ["type": "string", "description": "UUID of the target room"]
                    ],
                    "required": ["accessory_uuid", "room_uuid"]
                ]
            ],
            [
                "name": "set_accessory_room_by_name",
                "description": "Move an accessory to a different room using names (partial match supported)",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accessory_name": ["type": "string", "description": "Name of the accessory to move"],
                        "room_name": ["type": "string", "description": "Name of the target room"]
                    ],
                    "required": ["accessory_name", "room_name"]
                ]
            ]
        ]
    }

    // MARK: - Dispatch

    func handle(toolName: String, arguments: [String: Any], request: MCPRequest) -> MCPResponse? {
        switch toolName {
        case "set_accessory_room":         return setAccessoryRoom(request, arguments: arguments)
        case "set_accessory_room_by_name": return setAccessoryRoomByName(request, arguments: arguments)
        default:                           return nil
        }
    }

    // MARK: - Handlers

    private func setAccessoryRoom(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let accessoryUUIDStr = arguments["accessory_uuid"] as? String,
              let roomUUIDStr = arguments["room_uuid"] as? String,
              let accessoryUUID = UUID(uuidString: accessoryUUIDStr),
              let roomUUID = UUID(uuidString: roomUUIDStr) else {
            return errorResponse(id: request.id, code: -32602, message: "Invalid or missing UUIDs")
        }

        var foundAccessory: HMAccessory?
        var foundRoom: HMRoom?
        var foundHome: HMHome?

        for home in homeManager.homes {
            if foundAccessory == nil, let acc = home.accessories.first(where: { $0.uniqueIdentifier == accessoryUUID }) {
                foundAccessory = acc
                foundHome = home
            }
            if foundRoom == nil, let room = home.rooms.first(where: { $0.uniqueIdentifier == roomUUID }) {
                foundRoom = room
            }
        }

        guard let accessory = foundAccessory, let room = foundRoom, let home = foundHome else {
            return errorResponse(id: request.id, message: "Accessory or room not found")
        }

        return moveAccessory(accessory, to: room, in: home, request: request)
    }

    private func setAccessoryRoomByName(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let accessoryName = arguments["accessory_name"] as? String,
              let roomName = arguments["room_name"] as? String else {
            return missingParamResponse(id: request.id, param: "accessory_name or room_name")
        }

        var foundAccessory: HMAccessory?
        var foundHome: HMHome?

        for home in homeManager.homes {
            if let acc = home.accessories.first(where: { $0.name.localizedCaseInsensitiveContains(accessoryName) }) {
                foundAccessory = acc
                foundHome = home
                break
            }
        }

        var foundRoom: HMRoom?
        for home in homeManager.homes {
            if let room = home.rooms.first(where: { $0.name.localizedCaseInsensitiveContains(roomName) }) {
                foundRoom = room
                break
            }
        }

        guard let accessory = foundAccessory, let home = foundHome else {
            return errorResponse(id: request.id, message: "Accessory '\(accessoryName)' not found")
        }
        guard let room = foundRoom else {
            return errorResponse(id: request.id, message: "Room '\(roomName)' not found")
        }

        return moveAccessory(accessory, to: room, in: home, request: request)
    }

    // MARK: - Helpers

    private func moveAccessory(_ accessory: HMAccessory, to room: HMRoom, in home: HMHome, request: MCPRequest) -> MCPResponse {
        if accessory.room?.uniqueIdentifier == room.uniqueIdentifier {
            return textResponse(id: request.id, text: "ℹ️ '\(accessory.name)' is already in '\(room.name)'")
        }

        let op = withHomeKitOperation { home.assignAccessory(accessory, to: room, completionHandler: $0) }

        if op.timedOut { return timeoutResponse(id: request.id) }
        if let error = op.error {
            return textResponse(id: request.id, text: "❌ Failed to move '\(accessory.name)' to '\(room.name)': \(error.localizedDescription)")
        }
        return textResponse(id: request.id, text: "✅ Moved '\(accessory.name)' to '\(room.name)'")
    }
}
