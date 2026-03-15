# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Scene management domain** (`SceneTools`): `get_all_scenes`, `activate_scene`, `create_scene`, `delete_scene`
- `ToolProvider` protocol — each domain implements it; HTTPMCPServer auto-discovers all tools via providers
- Domain-organized tool files: `AccessoryTools`, `RoomTools`, `OrganizationTools`, `SceneTools`
- Shared helper functions (`withHomeKitOperation`, `textResponse`, `errorResponse`) for clean, consistent tool implementations

### Changed
- **HTTPMCPServer** refactored from ~1400-line monolith into a thin HTTP router (~250 lines) that delegates to domain providers
- Tool registration and dispatch are now automatic — adding a new domain only requires creating a `ToolProvider` and adding it to the providers array
- Welcome page dynamically lists all tools from registered providers
- Server version bumped to 2.0.0

### Removed
- `MCPServer.swift` (defunct stdio-based server kept as dead code reference)

## [1.0.0] - Prior

### Added
- Initial HomeKit MCP Server implementation
- HTTP-based MCP protocol support with Server-Sent Events
- Three core tools: `get_all_accessories`, `get_all_rooms`, `set_accessory_room`
- Mac Catalyst app for HomeKit framework access on macOS
- Comprehensive test suite with CI-friendly Swift Package Manager tests
- SwiftLint integration for code quality
- GitHub Actions CI/CD pipeline
- Full documentation and API reference

### Features
- 🏠 Direct HomeKit integration for accessories and rooms
- 🔧 Move accessories between rooms with UUID-based targeting
- 🌐 RESTful HTTP API with JSON-RPC 2.0 protocol
- 🤖 Claude Code compatible MCP transport
- 🔒 Local-only operation for privacy and security
- 📱 Native macOS app with iOS HomeKit framework

### Technical
- Swift 5.9+ with Mac Catalyst target
- Network framework for HTTP server implementation
- SwiftUI for minimal native interface
- XCTest-based testing with cross-platform support
- SwiftLint for code style enforcement
- Makefile-based build automation

## [1.0.0] - TBD

Initial release targeting full HomeKit MCP functionality.