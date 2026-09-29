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

if CommandLine.arguments.dropFirst().first == "--version" {
    print("Mobdev \(MCPHandler.serverVersion)")
    exit(0)
}

MobdevApp.main()
