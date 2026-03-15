import Foundation
import HomeKit

// MARK: - Accessory Domain Tools
// Covers: listing, finding, renaming, and controlling (on/off/toggle) accessories.

class AccessoryTools: ToolProvider {
    private let homeManager: HMHomeManager

    init(homeManager: HMHomeManager) {
        self.homeManager = homeManager
    }

    // MARK: - Tool Definitions

    var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "get_all_accessories",
                "description": "Get all HomeKit accessories with their names, rooms, categories, and UUIDs",
                "inputSchema": ["type": "object", "properties": [:], "required": []]
            ],
            [
                "name": "get_accessory_by_name",
                "description": "Find a HomeKit accessory by name (partial match supported)",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Name or partial name of the accessory"]
                    ],
                    "required": ["name"]
                ]
            ],
            [
                "name": "rename_accessory",
                "description": "Rename a HomeKit accessory",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accessory_name": ["type": "string", "description": "Current name of the accessory"],
                        "new_name": ["type": "string", "description": "New name for the accessory"]
                    ],
                    "required": ["accessory_name", "new_name"]
                ]
            ],
            [
                "name": "accessory_on",
                "description": "Turn on an accessory (lights, switches) or open covers",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accessory_name": ["type": "string", "description": "Name of the accessory to turn on"]
                    ],
                    "required": ["accessory_name"]
                ]
            ],
            [
                "name": "accessory_off",
                "description": "Turn off an accessory (lights, switches) or close covers",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accessory_name": ["type": "string", "description": "Name of the accessory to turn off"]
                    ],
                    "required": ["accessory_name"]
                ]
            ],
            [
                "name": "accessory_toggle",
                "description": "Toggle an accessory between on/off or open/close",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "accessory_name": ["type": "string", "description": "Name of the accessory to toggle"]
                    ],
                    "required": ["accessory_name"]
                ]
            ]
        ]
    }

    // MARK: - Dispatch

    func handle(toolName: String, arguments: [String: Any], request: MCPRequest) -> MCPResponse? {
        switch toolName {
        case "get_all_accessories":   return getAllAccessories(request)
        case "get_accessory_by_name": return getAccessoryByName(request, arguments: arguments)
        case "rename_accessory":      return renameAccessory(request, arguments: arguments)
        case "accessory_on":          return controlAccessory(request, arguments: arguments, action: .turnOn)
        case "accessory_off":         return controlAccessory(request, arguments: arguments, action: .turnOff)
        case "accessory_toggle":      return controlAccessory(request, arguments: arguments, action: .toggle)
        default:                      return nil
        }
    }

    // MARK: - Handlers

    private func getAllAccessories(_ request: MCPRequest) -> MCPResponse {
        var accessories: [[String: Any]] = []

        for home in homeManager.homes {
            for accessory in home.accessories {
                accessories.append(accessoryDict(accessory, home: home))
            }
        }

        let text = "Found \(accessories.count) accessories:\n" +
            accessories.map { "• \($0["name"]!) (\($0["category"]!)) — Room: \($0["room"]!), UUID: \($0["uuid"]!)" }
                .joined(separator: "\n")

        return textResponse(id: request.id, text: text, meta: ["accessories": accessories])
    }

    private func getAccessoryByName(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let name = arguments["name"] as? String else {
            return missingParamResponse(id: request.id, param: "name")
        }

        var found: [[String: Any]] = []
        for home in homeManager.homes {
            for accessory in home.accessories where accessory.name.localizedCaseInsensitiveContains(name) {
                found.append(accessoryDict(accessory, home: home))
            }
        }

        let text = found.isEmpty
            ? "No accessories found matching '\(name)'"
            : "Found \(found.count) accessories matching '\(name)':\n" +
              found.map { "• \($0["name"]!) (\($0["category"]!)) — Room: \($0["room"]!), UUID: \($0["uuid"]!)" }
                  .joined(separator: "\n")

        return textResponse(id: request.id, text: text, meta: ["accessories": found])
    }

    private func renameAccessory(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let name = arguments["accessory_name"] as? String,
              let newName = arguments["new_name"] as? String else {
            return missingParamResponse(id: request.id, param: "accessory_name or new_name")
        }

        guard let accessory = findAccessory(named: name) else {
            return errorResponse(id: request.id, message: "Accessory '\(name)' not found")
        }

        let op = withHomeKitOperation { accessory.updateName(newName, completionHandler: $0) }

        if op.timedOut { return timeoutResponse(id: request.id) }
        if let error = op.error {
            return textResponse(id: request.id, text: "❌ Failed to rename '\(name)': \(error.localizedDescription)")
        }
        return textResponse(id: request.id, text: "✅ Renamed '\(name)' to '\(newName)'")
    }

    // MARK: - Control

    private enum AccessoryAction { case turnOn, turnOff, toggle }

    private func controlAccessory(_ request: MCPRequest, arguments: [String: Any], action: AccessoryAction) -> MCPResponse {
        guard let name = arguments["accessory_name"] as? String else {
            return missingParamResponse(id: request.id, param: "accessory_name")
        }

        guard let accessory = findAccessory(named: name) else {
            return errorResponse(id: request.id, message: "Accessory '\(name)' not found")
        }

        guard let (characteristic, charType) = findControllableCharacteristic(in: accessory) else {
            return errorResponse(id: request.id, message: "'\(accessory.name)' has no controllable characteristics")
        }

        guard let (targetValue, actionDescription) = targetValueAndDescription(
            action: action, charType: charType, characteristic: characteristic, accessoryName: accessory.name
        ) else {
            return errorResponse(id: request.id, message: "Cannot determine target state for '\(accessory.name)'")
        }

        let op = withHomeKitOperation { characteristic.writeValue(targetValue, completionHandler: $0) }

        if op.timedOut { return timeoutResponse(id: request.id) }
        if let error = op.error {
            return textResponse(id: request.id, text: "❌ Failed to \(actionDescription) '\(accessory.name)': \(error.localizedDescription)")
        }
        return textResponse(id: request.id, text: "✅ Successfully \(actionDescription) '\(accessory.name)'")
    }

    // MARK: - Helpers

    func findAccessory(named name: String) -> HMAccessory? {
        for home in homeManager.homes {
            if let match = home.accessories.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                return match
            }
        }
        return nil
    }

    private enum CharType { case power, position, door }

    private func findControllableCharacteristic(in accessory: HMAccessory) -> (HMCharacteristic, CharType)? {
        for service in accessory.services {
            if let c = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState }) {
                return (c, .power)
            }
            if let c = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeTargetPosition }) {
                return (c, .position)
            }
            if let c = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypeTargetDoorState }) {
                return (c, .door)
            }
        }
        return nil
    }

    private func targetValueAndDescription(
        action: AccessoryAction,
        charType: CharType,
        characteristic: HMCharacteristic,
        accessoryName: String
    ) -> (Any, String)? {
        switch (action, charType) {
        case (.turnOn, .power):    return (true, "turn on")
        case (.turnOff, .power):   return (false, "turn off")
        case (.turnOn, .position): return (100, "open")
        case (.turnOff, .position):return (0, "close")
        case (.turnOn, .door):     return (HMCharacteristicValueDoorState.open.rawValue, "open")
        case (.turnOff, .door):    return (HMCharacteristicValueDoorState.closed.rawValue, "close")
        case (.toggle, .power):
            guard let current = characteristic.value as? Bool else { return nil }
            return (!current, current ? "turn off" : "turn on")
        case (.toggle, .position):
            let pos = characteristic.value as? Int ?? 0
            return (pos > 50 ? 0 : 100, pos > 50 ? "close" : "open")
        case (.toggle, .door):
            let state = characteristic.value as? Int ?? HMCharacteristicValueDoorState.closed.rawValue
            let closing = state != HMCharacteristicValueDoorState.closed.rawValue
            return (closing ? HMCharacteristicValueDoorState.closed.rawValue : HMCharacteristicValueDoorState.open.rawValue,
                    closing ? "close" : "open")
        }
    }

    func accessoryDict(_ accessory: HMAccessory, home: HMHome) -> [String: Any] {
        [
            "name": accessory.name,
            "room": accessory.room?.name ?? "No Room",
            "uuid": accessory.uniqueIdentifier.uuidString,
            "home": home.name,
            "category": accessory.category.localizedDescription,
            "reachable": accessory.isReachable
        ]
    }
}
