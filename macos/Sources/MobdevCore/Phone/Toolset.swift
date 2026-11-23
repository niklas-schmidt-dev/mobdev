import Foundation

/// A named group of tools. An MCP client that names some (`/mcp?tools=core,tests`, through the
/// relays too, or `Mobdev mcp --tools core,tests`) gets only their tools from `tools/list`, which
/// keeps the definitions out of an agent's context until it needs them. Every tool can still be
/// called by name, and the REST API always lists every tool.
///
/// A tool's toolset is its definition list's, set where the lists are put together
/// (`PhoneTools.definitions`, `DeviceTools.definitions`), so a tool added to a list joins it.
/// `exceptions` names the few tools that belong elsewhere.
public enum Toolset: String, CaseIterable, Sendable {
    case core, apps, settings, simulators, recording, tests, performance, network, secrets, appstore

    /// What the toolset is for, in one line of the instructions.
    public var summary: String {
        switch self {
        case .core:
            "see and control a device: devices and status, screenshots, observe, text and elements on screen, taps, typing, swipes, keys, pinch, waits, opening, installing and launching apps, logs"
        case .apps: "the rest of app handling: list, stop and uninstall apps, open links, crash reports, React Native and Expo reload and developer menu"
        case .settings:
            "set device state directly: location, permissions, push notifications, appearance, language, status bar, biometrics, an app's data, clipboard, orientation, hardware buttons, Shortcuts"
        case .simulators: "list, boot, shut down, create and delete simulators and Android emulators"
        case .recording: "record the screen as a video and save full-resolution screenshots"
        case .tests:
            "projects, tests and flows, the app's own XCTest and Gradle suites, screen checks, crawling an app, and turning recent steps into a test"
        case .performance: "CPU, memory, frames and launch time with budgets, Instruments and Perfetto traces, the device's load"
        case .network: "see and mock the requests an app makes"
        case .secrets: "type stored passwords without seeing them"
        case .appstore: "App Store Connect: apps, builds, TestFlight, versions and reviews"
        }
    }

    /// Tools in another toolset than their definition list's.
    static let exceptions: [String: Toolset] = [
        // Closing the loop for an app being built belongs to seeing and controlling it.
        "install_app": .core, "launch_app": .core, "logs": .core,
        // Development conveniences, not measurements.
        "reload_app": .apps, "dev_menu": .apps,
        // Its steps are for save_test and run_flow.
        "recent_steps": .tests,
    ]

    public static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }

    /// The toolsets a comma-separated list such as "core,tests" names, or nil for every tool when
    /// there is no list or it is empty.
    public static func selection(_ list: String?) throws -> Set<Toolset>? {
        let names = (list ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return Set(
            try names.map { name in
                guard let toolset = Toolset(rawValue: name.lowercased()) else { throw UnknownToolsetError(name: name) }
                return toolset
            })
    }

    /// The query value that selects `toolsets`, in a stable order.
    static func query(_ toolsets: Set<Toolset>) -> String {
        allCases.filter(toolsets.contains).map(\.rawValue).joined(separator: ",")
    }

    /// The server's instructions. With a selection, they add which toolsets the session lists,
    /// the others with their tools, how to call those anyway, and how to list them.
    static func instructions(for selection: Set<Toolset>?, definitions: [ToolDefinition]) -> String {
        guard let selection else { return PhoneTools.instructions }
        let others = allCases.filter { !selection.contains($0) }
        guard !others.isEmpty else { return PhoneTools.instructions }
        let listed = allCases.filter(selection.contains).map(\.rawValue).joined(separator: ", ")
        // Most MCP clients call only listed tools; the command line reaches every one.
        let command = Shell.quoted(
            (MobdevPaths.appBundle ?? URL(fileURLWithPath: "/Applications/Mobdev.app"))
                .appendingPathComponent("Contents/MacOS/Mobdev").path)
        var lines = [
            "This session lists the tools of the toolsets \(listed). The other toolsets' tools still run when called by name, also in a terminal on the Mac that runs Mobdev: `\(command) <tool> key=value` (`\(command) tools --json` shows their arguments). The other toolsets:"
        ]
        for toolset in others {
            let tools = definitions.filter { $0.toolset == toolset }.map(\.name)
            guard !tools.isEmpty else { continue }
            lines.append("- \(toolset.rawValue): \(toolset.summary) (\(tools.joined(separator: ", ")))")
        }
        lines.append(
            "To have their tools listed, the MCP configuration needs the toolsets in tools= of the URL (/mcp?tools=core,tests) or in `Mobdev mcp --tools core,tests`, or no selection for every tool; the client then reconnects."
        )
        return PhoneTools.instructions + "\n\n" + lines.joined(separator: "\n")
    }
}

public struct UnknownToolsetError: Error, CustomStringConvertible {
    public let name: String
    public var description: String { "Unknown toolset \"\(name)\". Toolsets: \(Toolset.names)." }
}

extension Array where Element == ToolDefinition {
    /// The tools of a definition list, in `toolset` unless `Toolset.exceptions` puts them elsewhere.
    func inToolset(_ toolset: Toolset) -> [ToolDefinition] {
        map { definition in
            var definition = definition
            definition.toolset = Toolset.exceptions[definition.name] ?? toolset
            return definition
        }
    }
}
