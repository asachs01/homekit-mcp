import Foundation
import HomeKit

// MARK: - Room Domain Tools
// Covers: listing, finding, renaming rooms, and listing accessories per room.

class RoomTools: ToolProvider {
    private let homeManager: HMHomeManager

    init(homeManager: HMHomeManager) {
        self.homeManager = homeManager
    }

    // MARK: - Tool Definitions

    var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "get_all_rooms",
                "description": "Get all HomeKit rooms with their names and UUIDs",
                "inputSchema": ["type": "object", "properties": [:], "required": []]
            ],
            [
                "name": "get_room_by_name",
                "description": "Find a HomeKit room by name (partial match supported)",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Name or partial name of the room"]
                    ],
                    "required": ["name"]
                ]
            ],
            [
                "name": "get_room_accessories",
                "description": "Get all accessories in a specific room",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "room_name": ["type": "string", "description": "Name of the room"]
                    ],
                    "required": ["room_name"]
                ]
            ],
            [
                "name": "rename_room",
                "description": "Rename a HomeKit room",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "room_name": ["type": "string", "description": "Current name of the room"],
                        "new_name": ["type": "string", "description": "New name for the room"]
                    ],
                    "required": ["room_name", "new_name"]
                ]
            ]
        ]
    }

    // MARK: - Dispatch

    func handle(toolName: String, arguments: [String: Any], request: MCPRequest) -> MCPResponse? {
        switch toolName {
        case "get_all_rooms":       return getAllRooms(request)
        case "get_room_by_name":    return getRoomByName(request, arguments: arguments)
        case "get_room_accessories":return getRoomAccessories(request, arguments: arguments)
        case "rename_room":         return renameRoom(request, arguments: arguments)
        default:                    return nil
        }
    }

    // MARK: - Handlers

    private func getAllRooms(_ request: MCPRequest) -> MCPResponse {
        var rooms: [[String: Any]] = []
        for home in homeManager.homes {
            for room in home.rooms {
                rooms.append(["name": room.name, "uuid": room.uniqueIdentifier.uuidString, "home": home.name])
            }
        }
        let text = "Found \(rooms.count) rooms:\n" +
            rooms.map { "• \($0["name"]!) (UUID: \($0["uuid"]!))" }.joined(separator: "\n")
        return textResponse(id: request.id, text: text, meta: ["rooms": rooms])
    }

    private func getRoomByName(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let name = arguments["name"] as? String else {
            return missingParamResponse(id: request.id, param: "name")
        }

        var found: [[String: Any]] = []
        for home in homeManager.homes {
            for room in home.rooms where room.name.localizedCaseInsensitiveContains(name) {
                found.append(["name": room.name, "uuid": room.uniqueIdentifier.uuidString, "home": home.name])
            }
        }

        let text = found.isEmpty
            ? "No rooms found matching '\(name)'"
            : "Found \(found.count) rooms matching '\(name)':\n" +
              found.map { "• \($0["name"]!) (UUID: \($0["uuid"]!))" }.joined(separator: "\n")

        return textResponse(id: request.id, text: text, meta: ["rooms": found])
    }

    private func getRoomAccessories(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let roomName = arguments["room_name"] as? String else {
            return missingParamResponse(id: request.id, param: "room_name")
        }

        guard let (room, home) = findRoom(named: roomName) else {
            return errorResponse(id: request.id, message: "Room '\(roomName)' not found")
        }

        let roomAccessories = home.accessories
            .filter { $0.room?.uniqueIdentifier == room.uniqueIdentifier }
            .map { accessory -> [String: Any] in
                let reachable = accessory.isReachable
                return [
                    "name": accessory.name,
                    "uuid": accessory.uniqueIdentifier.uuidString,
                    "category": accessory.category.localizedDescription,
                    "reachable": reachable,
                    "firmware": firmwareVersion(of: accessory),
                    "serial_number": serialNumber(of: accessory)
                ]
            }

        let text = "Found \(roomAccessories.count) accessories in '\(room.name)':\n" +
            roomAccessories.map { acc -> String in
                let status = (acc["reachable"] as? Bool ?? false) ? "🟢" : "🔴"
                return "• \(acc["name"]!) (\(acc["category"]!)) \(status) — UUID: \(acc["uuid"]!), FW: \(acc["firmware"]!), S/N: \(acc["serial_number"]!)"
            }.joined(separator: "\n")

        return textResponse(id: request.id, text: text, meta: [
            "room": ["name": room.name, "uuid": room.uniqueIdentifier.uuidString],
            "accessories": roomAccessories
        ])
    }

    private func renameRoom(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let roomName = arguments["room_name"] as? String,
              let newName = arguments["new_name"] as? String else {
            return missingParamResponse(id: request.id, param: "room_name or new_name")
        }

        guard let (room, home) = findRoom(named: roomName) else {
            return errorResponse(id: request.id, message: "Room '\(roomName)' not found")
        }

        let op = withHomeKitOperation { room.updateName(newName, completionHandler: $0) }

        if op.timedOut { return timeoutResponse(id: request.id) }
        if let error = op.error {
            return textResponse(id: request.id, text: "❌ Failed to rename '\(roomName)': \(error.localizedDescription)")
        }
        return textResponse(id: request.id, text: "✅ Renamed room '\(roomName)' to '\(newName)'")
    }

    // MARK: - Helpers

    func findRoom(named name: String) -> (HMRoom, HMHome)? {
        for home in homeManager.homes {
            if let room = home.rooms.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                return (room, home)
            }
        }
        return nil
    }

    private func firmwareVersion(of accessory: HMAccessory) -> String {
        accessory.services
            .first(where: { $0.serviceType == HMServiceTypeAccessoryInformation })?
            .characteristics
            .first(where: { $0.characteristicType == HMCharacteristicTypeFirmwareVersion })?
            .value as? String ?? "Unknown"
    }

    private func serialNumber(of accessory: HMAccessory) -> String {
        accessory.services
            .first(where: { $0.serviceType == HMServiceTypeAccessoryInformation })?
            .characteristics
            .first(where: { $0.characteristicType == HMCharacteristicTypeSerialNumber })?
            .value as? String ?? "Unknown"
    }
}
