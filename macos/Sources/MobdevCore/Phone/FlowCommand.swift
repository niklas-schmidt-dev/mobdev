import Foundation

/// `Mobdev flow <file> [--device <id or name>] [--artifacts <dir>] [--var NAME=value]…`: runs a
/// flow (JSON, or Maestro's YAML) on a booted iOS simulator or Android device without the app, for
/// scripts and CI. Nothing needs permission: simulators go through Xcode's frameworks and Android
/// through adb, as in the app. iPhones need the running app; there, call run_flow through MCP or
/// the HTTP API.
///
/// Prints one line per step and exits 0 when every step passed, 1 when one failed and 2 when the
/// flow could not start. With --artifacts, the directory gets a video of the run (run.mp4), the
/// activity log, copied crash reports and, after a failure, failure.png. Ctrl-C or a cancelled CI
/// job stops the flow (a wait ends at once, no further step starts) and still finishes the video.
public enum FlowCommand {
    static let usage = """
        Usage: Mobdev flow <file> [--device <id or name>] [--artifacts <dir>] [--var NAME=value]... [--no-video] [--wait <seconds>]

        Runs a flow (.json, or Maestro's .yaml) on a booted iOS simulator or Android emulator or
        phone, without the app.
          --device     the device from list_devices; needed when several are booted
          --artifacts  where to keep a video of the run (run.mp4), the activity log, crash
                       reports and failure.png
          --var        a value for ${NAME} in the steps, e.g. --var EMAIL=me@example.com; repeatable
          --no-video   do not record run.mp4
          --wait       how long to wait for the device to appear, default 120
        """

    public static func run(_ arguments: [String]) -> Never {
        CommandSupport.run { await execute(arguments, output: CommandSupport.print) }
    }

    struct Options: Equatable {
        var file: String
        var device: String?
        var artifacts: String?
        var variables: [String: String] = [:]
        var video = true
        /// On a GitHub macOS runner a simulator took 99 s to boot, and Mobdev did not list it for
        /// 30 s more (2026-10-02).
        var wait: TimeInterval = 120
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var file: String?
        var options = Options(file: "")
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--no-video": options.video = false
            case "--device", "--artifacts", "--wait", "--var":
                guard let value = rest.popFirst() else { throw ToolFailure("\(argument) needs a value.") }
                if argument == "--device" { options.device = value }
                if argument == "--artifacts" { options.artifacts = value }
                if argument == "--var" {
                    let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2, Variables.isName(String(parts[0])) else {
                        throw ToolFailure("--var needs NAME=value, like --var EMAIL=me@example.com.")
                    }
                    options.variables[String(parts[0])] = String(parts[1])
                }
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
        guard let file else { throw ToolFailure("Which flow? Pass a .json or Maestro .yaml file.") }
        options.file = file
        return options
    }

    /// "✓ 3.1. tap_element {…} (round 2) (0.4 s): Tapped …", indented by how deep the step is.
    static func line(_ result: FlowResult.StepResult) -> String {
        let text = result.passed ? (result.text.split(separator: "\n").first.map(String.init) ?? "") : result.text
        return String(repeating: "  ", count: result.depth)
            + String(format: "%@ %@ (%.1f s): %@", result.mark, result.label(0), result.seconds, text)
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
        let home = CommandSupport.home(artifacts: options.artifacts)
        defer { if home.temporary { try? FileManager.default.removeItem(at: home.url) } }

        let file = URL(fileURLWithPath: (options.file as NSString).expandingTildeInPath).absoluteURL
        let flow: Flow
        do {
            flow = try Flow.load(file)
        } catch {
            output(String(describing: error))
            return 2
        }

        guard let connection = await CommandSupport.connect(device: options.device, wait: options.wait, output: output)
        else { return 2 }
        defer { connection.emulators.stop(waiting: true) }
        let device = connection.device

        output("Running \"\(flow.name)\" (\(flow.steps.count) steps) on \(device.name) (\(device.id))")
        for note in flow.notes { output("Note: \(note)") }
        let video = options.artifacts != nil && options.video ? home.url.appendingPathComponent("run.mp4") : nil
        let result: FlowResult
        // Named baselines live next to the flow file; a failed comparison's files go to the artifacts.
        let checks = CheckContext(root: file.deletingLastPathComponent(), artifacts: options.artifacts != nil ? home.url : nil)
        do {
            result = try await CheckContext.$current.withValue(checks) {
                try await Flow.recording(device, to: video) {
                    try await connection.tools.run(flow, on: device.id, variables: options.variables, source: "cli") {
                        output(line($0))
                    }
                }
            }
        } catch {
            output(String(describing: error))
            return 2
        }
        if let line = result.videoLine { output(line) }
        if options.artifacts != nil {
            try? Data(result.markdown.utf8).write(to: home.url.appendingPathComponent(TestRunResult.summaryFileName))
        }
        if result.passed {
            output(String(format: "Passed: %d steps in %.1f s.", result.steps.count, result.seconds))
            return 0
        }
        if options.artifacts != nil, let frame = device.frame(), let image = ImageTools.encode(frame, png: true) {
            let file = home.url.appendingPathComponent("failure.png")
            if (try? image.data.write(to: file)) != nil { output("Screenshot: \(file.path)") }
        }
        output("Failed at step \(result.failedNumber ?? String(result.steps.count)) of \(flow.steps.count).")
        return 1
    }
}
