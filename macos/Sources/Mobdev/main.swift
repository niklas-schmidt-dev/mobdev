import AppKit
import MobdevCore

// `Mobdev mcp` runs the stdio MCP bridge instead of the app.
if CommandLine.arguments.dropFirst().first == "mcp" {
    MCPStdioBridge.run {
        // Start the app in the background if it is not running yet.
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            // Keep a custom data directory or port, so the bridge finds the app it started.
            let environment = ProcessInfo.processInfo.environment
            configuration.environment = environment.filter { $0.key == "MOBDEV_HOME" || $0.key == "MOBDEV_PORT" }
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
        }
    }
}

// `Mobdev devices` prints the USB-connected iPhones and iPads as JSON.
if CommandLine.arguments.dropFirst().first == "devices" {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write((try? encoder.encode(USBDevices.read())) ?? Data("[]".utf8))
    print()
    exit(0)
}

// `Mobdev __ui-tree <udid>` reads a simulator's UI tree in a fresh process, for the app itself.
if CommandLine.arguments.dropFirst().first == "__ui-tree", CommandLine.arguments.count == 3 {
    SimulatorAccessibility.printTree(udid: CommandLine.arguments[2])
}

// `Mobdev __text <width> <height> [query]` recognizes text in pixels from stdin in a fresh process,
// for the app itself.
if CommandLine.arguments.dropFirst().first == "__text" {
    TextRecognizer.runHelper(Array(CommandLine.arguments.dropFirst(2)))
}

// `Mobdev flow <file.json>` runs a flow on a simulator or Android device without the app, for CI.
if CommandLine.arguments.dropFirst().first == "flow" {
    FlowCommand.run(Array(CommandLine.arguments.dropFirst(2)))
}

if CommandLine.arguments.dropFirst().first == "--version" {
    print("Mobdev \(MCPHandler.serverVersion)")
    exit(0)
}

MobdevApp.main()
