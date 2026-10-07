import Foundation

/// `Mobdev flow <file.json> [--device <id or name>] [--artifacts <dir>]`: runs a flow on a booted
/// iOS simulator or Android device without the app, for scripts and CI. Nothing needs permission:
/// simulators go through Xcode's frameworks and Android through adb, as in the app. iPhones need
/// the running app; there, call run_flow through MCP or the HTTP API.
///
/// Prints one line per step and exits 0 when every step passed, 1 when one failed and 2 when the
/// flow could not start. With --artifacts, the directory gets a video of the run (run.mp4), the
/// activity log, copied crash reports and, after a failure, failure.png. Ctrl-C or a cancelled CI
/// job stops the flow (a wait ends at once, no further step starts) and still finishes the video.
public enum FlowCommand {
    static let usage = """
        Usage: Mobdev flow <file.json> [--device <id or name>] [--artifacts <dir>] [--no-video] [--wait <seconds>]

        Runs a flow on a booted iOS simulator or Android emulator or phone, without the app.
          --device     the device from list_devices; needed when several are booted
          --artifacts  where to keep a video of the run (run.mp4), the activity log, crash
                       reports and failure.png
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
        let home = CommandSupport.home(artifacts: options.artifacts)
        defer { if home.temporary { try? FileManager.default.removeItem(at: home.url) } }

        let flow: Flow
        do {
            flow = try Flow.load(URL(fileURLWithPath: (options.file as NSString).expandingTildeInPath))
        } catch {
            output(String(describing: error))
            return 2
        }

        guard let connection = await CommandSupport.connect(device: options.device, wait: options.wait, output: output)
        else { return 2 }
        defer { connection.emulators.stop() }
        let device = connection.device

        output("Running \"\(flow.name)\" (\(flow.steps.count) steps) on \(device.name) (\(device.id))")
        let video = options.artifacts != nil && options.video ? home.url.appendingPathComponent("run.mp4") : nil
        let result: FlowResult
        do {
            result = try await Flow.recording(device, to: video) {
                try await connection.tools.run(flow, on: device.id, source: "cli") { index, step, stepOutput, seconds in
                    let mark = stepOutput.isError ? "✗" : "✓"
                    let text = stepOutput.isError
                        ? stepOutput.text
                        : (stepOutput.text.split(separator: "\n").first.map(String.init) ?? "")
                    output(String(format: "%@ %d. %@ (%.1f s): %@", mark, index + 1, step.summary, seconds, text))
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
            output(String(format: "Passed: %d steps in %.1f s.", flow.steps.count, result.seconds))
            return 0
        }
        if options.artifacts != nil, let frame = device.frame(), let image = ImageTools.encode(frame, png: true) {
            let file = home.url.appendingPathComponent("failure.png")
            if (try? image.data.write(to: file)) != nil { output("Screenshot: \(file.path)") }
        }
        output("Failed at step \(result.steps.count) of \(flow.steps.count).")
        return 1
    }
}
