import Foundation
import HomeKit

// MARK: - Scene Domain Tools
// Covers: listing, activating, creating, and deleting HomeKit scenes.
//
// HomeKit models scenes as HMActionSet objects. User-created scenes have
// actionSetType == HMActionSetTypeUserDefined.
// Each "action" in a scene is an HMCharacteristicWriteAction targeting a
// specific characteristic on an accessory (e.g., PowerState = false).

class SceneTools: ToolProvider {
    private let homeManager: HMHomeManager

    init(homeManager: HMHomeManager) {
        self.homeManager = homeManager
    }

    // MARK: - Tool Definitions

    var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "get_all_scenes",
                "description": "List all HomeKit scenes (user-defined action sets) across all homes",
                "inputSchema": ["type": "object", "properties": [:], "required": []]
            ],
            [
                "name": "activate_scene",
                "description": "Activate (execute) a HomeKit scene by name",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "scene_name": ["type": "string", "description": "Name or partial name of the scene to activate"]
                    ],
                    "required": ["scene_name"]
                ]
            ],
            [
                "name": "create_scene",
                "description": "Create a new HomeKit scene with specified accessory states. Each action sets an accessory's power state (true = on, false = off).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Name for the new scene"],
                        "actions": [
                            "type": "array",
                            "description": "List of accessory state changes for this scene",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "accessory_name": ["type": "string", "description": "Name of the accessory"],
                                    "power": ["type": "boolean", "description": "true = on, false = off"]
                                ],
                                "required": ["accessory_name", "power"]
                            ]
                        ]
                    ],
                    "required": ["name", "actions"]
                ]
            ],
            [
                "name": "delete_scene",
                "description": "Delete a user-defined HomeKit scene by name",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "scene_name": ["type": "string", "description": "Name or partial name of the scene to delete"]
                    ],
                    "required": ["scene_name"]
                ]
            ]
        ]
    }

    // MARK: - Dispatch

    func handle(toolName: String, arguments: [String: Any], request: MCPRequest) -> MCPResponse? {
        switch toolName {
        case "get_all_scenes":  return getAllScenes(request)
        case "activate_scene":  return activateScene(request, arguments: arguments)
        case "create_scene":    return createScene(request, arguments: arguments)
        case "delete_scene":    return deleteScene(request, arguments: arguments)
        default:                return nil
        }
    }

    // MARK: - Handlers

    private func getAllScenes(_ request: MCPRequest) -> MCPResponse {
        var scenes: [[String: Any]] = []

        for home in homeManager.homes {
            for actionSet in home.actionSets where actionSet.actionSetType == HMActionSetTypeUserDefined {
                scenes.append([
                    "name": actionSet.name,
                    "uuid": actionSet.uniqueIdentifier.uuidString,
                    "home": home.name,
                    "action_count": actionSet.actions.count
                ])
            }
        }

        let text = scenes.isEmpty
            ? "No user-defined scenes found"
            : "Found \(scenes.count) scenes:\n" +
              scenes.map { "• \($0["name"]!) — \($0["action_count"]!) actions, UUID: \($0["uuid"]!)" }
                  .joined(separator: "\n")

        return textResponse(id: request.id, text: text, meta: ["scenes": scenes])
    }

    private func activateScene(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let sceneName = arguments["scene_name"] as? String else {
            return missingParamResponse(id: request.id, param: "scene_name")
        }

        guard let (actionSet, home) = findScene(named: sceneName) else {
            return errorResponse(id: request.id, message: "Scene '\(sceneName)' not found")
        }

        let op = withHomeKitOperation { home.executeActionSet(actionSet, completionHandler: $0) }

        if op.timedOut { return timeoutResponse(id: request.id) }
        if let error = op.error {
            return textResponse(id: request.id, text: "❌ Failed to activate '\(actionSet.name)': \(error.localizedDescription)")
        }
        return textResponse(id: request.id, text: "✅ Activated scene '\(actionSet.name)'")
    }

    private func createScene(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let name = arguments["name"] as? String else {
            return missingParamResponse(id: request.id, param: "name")
        }
        guard let rawActions = arguments["actions"] as? [[String: Any]], !rawActions.isEmpty else {
            return missingParamResponse(id: request.id, param: "actions")
        }

        // Use the primary home (first available)
        guard let home = homeManager.homes.first else {
            return errorResponse(id: request.id, message: "No HomeKit homes found")
        }

        // Step 1: Create the action set
        var newActionSet: HMActionSet?
        let createOp = withHomeKitOperation { completion in
            home.addActionSet(withName: name) { actionSet, error in
                newActionSet = actionSet
                completion(error)
            }
        }

        if createOp.timedOut { return timeoutResponse(id: request.id) }
        if let error = createOp.error {
            return textResponse(id: request.id, text: "❌ Failed to create scene '\(name)': \(error.localizedDescription)")
        }
        guard let actionSet = newActionSet else {
            return errorResponse(id: request.id, message: "Scene created but reference lost — unexpected error")
        }

        // Step 2: Add a write action for each accessory
        var addedActions: [String] = []
        var failedActions: [String] = []

        for actionSpec in rawActions {
            guard let accessoryName = actionSpec["accessory_name"] as? String,
                  let power = actionSpec["power"] as? Bool else {
                failedActions.append("Invalid action spec: \(actionSpec)")
                continue
            }

            guard let (characteristic, _) = findPowerCharacteristic(accessoryName: accessoryName, in: home) else {
                failedActions.append("'\(accessoryName)' not found or has no power characteristic")
                continue
            }

            guard let writeAction = HMCharacteristicWriteAction(
                characteristic: characteristic,
                targetValue: power as NSNumber
            ) else {
                failedActions.append("Could not create write action for '\(accessoryName)'")
                continue
            }

            let addOp = withHomeKitOperation { home.addAction(writeAction, to: actionSet, completionHandler: $0) }

            if addOp.timedOut {
                failedActions.append("⏰ Timed out adding action for '\(accessoryName)'")
            } else if let error = addOp.error {
                failedActions.append("'\(accessoryName)': \(error.localizedDescription)")
            } else {
                addedActions.append("\(accessoryName) → \(power ? "on" : "off")")
            }
        }

        var summary = "✅ Created scene '\(name)' with \(addedActions.count) action(s)"
        if !addedActions.isEmpty {
            summary += "\n  Added: " + addedActions.joined(separator: ", ")
        }
        if !failedActions.isEmpty {
            summary += "\n  ⚠️ Failed: " + failedActions.joined(separator: "; ")
        }

        return textResponse(id: request.id, text: summary, meta: [
            "scene": ["name": name, "uuid": actionSet.uniqueIdentifier.uuidString],
            "added_actions": addedActions,
            "failed_actions": failedActions
        ])
    }

    private func deleteScene(_ request: MCPRequest, arguments: [String: Any]) -> MCPResponse {
        guard let sceneName = arguments["scene_name"] as? String else {
            return missingParamResponse(id: request.id, param: "scene_name")
        }

        guard let (actionSet, home) = findScene(named: sceneName) else {
            return errorResponse(id: request.id, message: "Scene '\(sceneName)' not found")
        }

        let op = withHomeKitOperation { home.removeActionSet(actionSet, completionHandler: $0) }

        if op.timedOut { return timeoutResponse(id: request.id) }
        if let error = op.error {
            return textResponse(id: request.id, text: "❌ Failed to delete '\(actionSet.name)': \(error.localizedDescription)")
        }
        return textResponse(id: request.id, text: "✅ Deleted scene '\(actionSet.name)'")
    }

    // MARK: - Helpers

    private func findScene(named name: String) -> (HMActionSet, HMHome)? {
        for home in homeManager.homes {
            if let actionSet = home.actionSets.first(where: {
                $0.actionSetType == HMActionSetTypeUserDefined &&
                $0.name.localizedCaseInsensitiveContains(name)
            }) {
                return (actionSet, home)
            }
        }
        return nil
    }

    /// Finds the PowerState characteristic for an accessory by name within a home.
    private func findPowerCharacteristic(accessoryName: String, in home: HMHome) -> (HMCharacteristic, HMService)? {
        guard let accessory = home.accessories.first(where: { $0.name.localizedCaseInsensitiveContains(accessoryName) }) else {
            return nil
        }
        for service in accessory.services {
            if let characteristic = service.characteristics.first(where: { $0.characteristicType == HMCharacteristicTypePowerState }) {
                return (characteristic, service)
            }
        }
        return nil
    }
}
