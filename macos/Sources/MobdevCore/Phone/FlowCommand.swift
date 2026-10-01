import Foundation

/// `Mobdev flow <file.json> [--device <id or name>] [--artifacts <dir>]`: runs a flow on a booted
/// iOS simulator or Android device without the app, for scripts and CI. Nothing needs permission:
/// simulators go through Xcode's frameworks and Android through adb, as in the app. iPhones need
/// the running app; there, call run_flow through MCP or the HTTP API.
///
/// Prints one line per step and exits 0 when every step passed, 1 when one failed and 2 when the
/// flow could not start. With --artifacts, the directory gets the activity log, copied crash
/// reports and, after a failure, failure.png.
public enum FlowCommand {
    static let usage = """
        Usage: Mobdev flow <file.json> [--device <id or name>] [--artifacts <dir>] [--wait <seconds>]

        Runs a flow on a booted iOS simulator or Android emulator or phone, without the app.
          --device     the device from list_devices; needed when several are booted
          --artifacts  where to keep the activity log, crash reports and failure.png
          --wait       how long to wait for the device to appear, default 30
        """

    public static func run(_ arguments: [String]) -> Never {
        Task {
            exit(await execute(arguments, output: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }))
        }
        dispatchMain()
    }

    struct Options: Equatable {
        var file: String
        var device: String?
        var artifacts: String?
        var wait: TimeInterval = 30
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var file: String?
        var options = Options(file: "")
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--device", "--artifacts", "--wait":
                guard let value = rest.popFirst() else { throw ToolFailure("\(argument) needs a value.") }
                if argument == "--device" { options.device = value }
                if argument == "--artifacts" { options.artifacts = value }
                if argument == "--wait" {
                    guard let seconds = TimeInterval(value), seconds >= 0 else {
                        throw ToolFailure("--wait needs a number of seconds.")
                    }
                    options.wait = seconds
                }
            case "-h", "--help": throw ToolFailure("")
            default:
                guard !argument.hasPrefix("-"), file == nil else { throw ToolFailure("Unexpected \(argument).") }
                file = argument
            }
        }
        guard let file else { throw ToolFailure("Which flow? Pass a .json file.") }
        options.file = file
        return options
    }

    static func execute(_ arguments: [String], output: @escaping @Sendable (String) -> Void) async -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            let message = String(describing: error)
            output(message.isEmpty ? usage : "\(message)\n\n\(usage)")
            return 2
        }
        // Keep the app's own logs and files out of it: activity and crash reports go to the
        // artifacts directory, or a temporary one.
        let home =
            options.artifacts.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "mobdev-flow-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { if options.artifacts == nil { try? FileManager.default.removeItem(at: home) } }
        setenv("MOBDEV_HOME", home.path, 1)

        let flow: Flow
        do {
            flow = try Flow.load(URL(fileURLWithPath: (options.file as NSString).expandingTildeInPath))
        } catch {
            output(String(describing: error))
            return 2
        }

        let emulators = EmulatorHub(adb: ADB.find()) {}
        let tools = DeviceTools(hub: DeviceHub(keyboardLayout: .us) {}, emulators: emulators, settleDelay: 0.3)
        emulators.start()
        defer { emulators.stop() }
        let deadline = Date().addingTimeInterval(options.wait)
        // Waits for the named device, or without a name for any; several booted without a name is
        // a mistake to report at once.
        var device: (any Device)?
        var lastError = ""
        while device == nil {
            do {
                device = try tools.phone(for: options.device) as? any Device
            } catch {
                lastError = String(describing: error)
                let ambiguous = options.device == nil && !emulators.devices.isEmpty
                guard Date() < deadline, !ambiguous else { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard let device else {
            output(lastError.isEmpty ? "No booted simulator or Android device." : lastError)
            return 2
        }

        output("Running \"\(flow.name)\" (\(flow.steps.count) steps) on \(device.name) (\(device.id))")
        let result: FlowResult
        do {
            result = try await tools.run(flow, on: device.id, source: "cli") { index, step, stepOutput, seconds in
                let mark = stepOutput.isError ? "✗" : "✓"
                let text = stepOutput.isError
                    ? stepOutput.text
                    : (stepOutput.text.split(separator: "\n").first.map(String.init) ?? "")
                output(String(format: "%@ %d. %@ (%.1f s): %@", mark, index + 1, step.summary, seconds, text))
            }
        } catch {
            output(String(describing: error))
            return 2
        }
        if result.passed {
            output(String(format: "Passed: %d steps in %.1f s.", flow.steps.count, result.seconds))
            return 0
        }
        if options.artifacts != nil, let frame = device.frame(), let image = ImageTools.encode(frame, png: true) {
            let file = home.appendingPathComponent("failure.png")
            if (try? image.data.write(to: file)) != nil { output("Screenshot: \(file.path)") }
        }
        output("Failed at step \(result.steps.count) of \(flow.steps.count).")
        return 1
    }
}
