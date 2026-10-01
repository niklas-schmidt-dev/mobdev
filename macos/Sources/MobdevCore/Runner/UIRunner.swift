import Foundation

/// Mobdev Runner on one iPhone or simulator: the XCUITest in `Runner/` that serves the UI tree, taps
/// and typing from inside the device, the way WebDriverAgent does. `start` builds it with Xcode for
/// the device (on an iPhone signed with the user's development team), then keeps
/// `xcodebuild test-without-building` running and starts it again when it ends. `RunnerClient`
/// talks to it. The copy of the project, its build and the logs live in `folder`.
public final class UIRunner: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case off
        case building
        case starting
        case running
        /// What went wrong, from xcodebuild's output.
        case failed(String)

        public var summary: String {
            switch self {
            case .off: "Off"
            case .building: "Building with Xcode…"
            case .starting: "Starting on the device…"
            case .running: "Running"
            case .failed: "Could not start"
            }
        }
    }

    /// The port the runner listens on inside the device.
    public static let defaultPort: UInt16 = 47270

    public let udid: String
    public let isSimulator: Bool
    let port: UInt16
    let folder: URL
    private let commands: CommandRunning
    private let onChange: @Sendable () -> Void

    private struct Current {
        var state = State.off
        var team: String?
        /// Counts starts and stops, so a run that was replaced stops touching the state.
        var generation = 0
        var process: RunningCommand?
        var token = ""
        /// The newest run, from build to the end of the test.
        var run: Task<Void, Never>?
    }

    private let current = Locked(Current())

    public init(
        udid: String, simulator: Bool, folder: URL, port: UInt16 = UIRunner.defaultPort,
        commands: CommandRunning = ProcessRunner(), onChange: @escaping @Sendable () -> Void = {}
    ) {
        self.udid = udid
        isSimulator = simulator
        self.folder = folder
        self.port = port
        self.commands = commands
        self.onChange = onChange
    }

    public var state: State { current.get().state }

    /// Builds and starts the runner. Nothing happens while it already builds or runs for this team.
    public func start(team: String?) {
        let old = current.withLock { current -> RunningCommand?? in
            if current.team == team, [.building, .starting, .running].contains(current.state) { return nil }
            current.generation += 1
            current.team = team
            current.state = .building
            let generation = current.generation
            // A run that was replaced may still be building into the same folder; this one waits.
            let previous = current.run
            current.run = Task.detached {
                await previous?.value
                await self.run(generation, team: team)
            }
            defer { current.process = nil }
            return .some(current.process)
        }
        guard let old else { return }
        old?.stop()
        onChange()
        Log.info("runner for \(udid): building")
    }

    /// Ends the test on the device.
    public func stop() {
        let process = current.withLock { current -> RunningCommand? in
            current.generation += 1
            current.state = .off
            defer { current.process = nil }
            return current.process
        }
        process?.stop()
        onChange()
    }

    // MARK: Using it

    public func elements() async throws -> [UIElement] { try await client().tree() }

    /// Types into the focused field; any characters, emoji included.
    public func type(_ text: String) async throws { try await client().type(text) }

    public func tap(at point: NormalizedPoint) async throws { try await client().tap(point) }

    /// How to reach the runner while it runs; otherwise why it cannot be reached.
    func client() throws -> RunnerClient {
        let current = self.current.get()
        switch current.state {
        case .running:
            return RunnerClient(route: isSimulator ? .loopback : .usb(udid: udid), port: port, token: current.token)
        case .building:
            throw DeveloperError("Mobdev Runner is being built for this device. The first build takes a minute or two.")
        case .starting:
            throw DeveloperError("Mobdev Runner is starting on this device. Try again in a few seconds.")
        case .failed(let reason):
            throw ToolFailure(
                "Mobdev Runner could not start: \(reason) Then click Try Again under UI Tree in the device's info in Mobdev.")
        case .off:
            throw ToolFailure("Mobdev Runner is off for this device.")
        }
    }

    // MARK: Running it

    private var buildFolder: URL { folder.appendingPathComponent("build") }

    private func run(_ generation: Int, team: String?) async {
        do {
            try await build(team: team)
        } catch {
            Log.error("runner for \(udid): \(error)")
            update(generation, .failed(String(describing: error)))
            return
        }
        var failures = 0
        while update(generation, .starting) {
            let started = Date()
            let (answered, output) = await serve(generation)
            guard isCurrent(generation) else { return }
            // A runner that served for a while and then ended (a test timeout, the iPhone restarted)
            // starts again; one that keeps failing at once stops with xcodebuild's reason.
            failures = answered && Date().timeIntervalSince(started) > 60 ? 0 : failures + 1
            Log.info("runner for \(udid): xcodebuild ended (\(failures) quick failures)")
            if failures >= 3 {
                let log = folder.appendingPathComponent("test.log")
                try? output.write(to: log, atomically: true, encoding: .utf8)
                let reason = Self.summary(output) ?? "xcodebuild ended without saying why. Its output is in \(log.path)."
                update(generation, .failed(reason))
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Builds the runner for this device with Xcode, signed with `team` on an iPhone. Unchanged
    /// sources build again in a few seconds, so it builds on every start; that also follows Xcode
    /// updates.
    private func build(team: String?) async throws {
        var signing: [String] = []
        if !isSimulator {
            guard let team, Self.isTeamID(team) else {
                throw DeveloperError("Choose the development team to sign Mobdev Runner with.")
            }
            // The bundle ID carries the team: an App ID belongs to one team, and another Mobdev user's
            // team may hold the plain one.
            signing = [
                "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "DEVELOPMENT_TEAM=\(team)",
                "PRODUCT_BUNDLE_IDENTIFIER=dev.mobdev.runner.\(team.lowercased())",
            ]
        }
        let project = try copySources()
        let arguments = [
            "build-for-testing", "-project", project.path, "-scheme", "MobdevRunner", "-destination", "id=\(udid)",
            "-derivedDataPath", buildFolder.path,
        ] + signing
        let result = try await commands.run(URL(fileURLWithPath: "/usr/bin/xcodebuild"), arguments, timeout: 900)
        let log = folder.appendingPathComponent("build.log")
        try? result.output.write(to: log, atomically: true, encoding: .utf8)
        guard result.status == 0 else {
            throw DeveloperError(
                Self.summary(result.output) ?? "xcodebuild failed with status \(result.status). Its output is in \(log.path).")
        }
    }

    /// Runs the test until xcodebuild ends, and says whether the runner answered in between.
    private func serve(_ generation: Int) async -> (answered: Bool, output: String) {
        guard let xctestrun = xctestrun() else { return (false, "error: The runner's build is missing.") }
        let token = SecretStore.randomHex(bytes: 16)
        let lines = Locked<[String]>([])
        let exited = Locked(false)
        // xcodebuild hands TEST_RUNNER_ variables to the test without the prefix.
        let arguments = [
            "TEST_RUNNER_MOBDEV_RUNNER_PORT=\(port)", "TEST_RUNNER_MOBDEV_RUNNER_TOKEN=\(token)", "/usr/bin/xcodebuild",
            "test-without-building", "-xctestrun", xctestrun.path, "-destination", "id=\(udid)",
        ]
        let process: RunningCommand
        do {
            process = try commands.start(
                URL(fileURLWithPath: "/usr/bin/env"), arguments,
                onLine: { line in
                    lines.withLock {
                        $0.append(line)
                        if $0.count > 400 { $0.removeFirst($0.count - 400) }
                    }
                },
                onExit: { _ in exited.set(true) })
        } catch {
            return (false, "error: Could not start xcodebuild: \(error)")
        }
        let kept = current.withLock { current -> Bool in
            guard current.generation == generation else { return false }
            current.process = process
            current.token = token
            return true
        }
        guard kept else {
            process.stop()
            return (false, "")
        }
        let client = RunnerClient(route: isSimulator ? .loopback : .usb(udid: udid), port: port, token: token)
        // Installing and launching takes long the first time on an iPhone, and a simulator may boot.
        let deadline = Date().addingTimeInterval(300)
        var answered = false
        while !exited.get(), isCurrent(generation) {
            if !answered {
                if (try? await client.health()) != nil {
                    answered = true
                    Log.info("runner for \(udid): running")
                    update(generation, .running)
                } else if Date() > deadline {
                    lines.withLock { $0.append("error: Mobdev Runner did not answer within 5 minutes.") }
                    process.stop()
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return (answered, lines.get().joined(separator: "\n"))
    }

    /// A copy of `Runner/` next to the build: xcodebuild writes into the project, which must not
    /// happen inside the signed app.
    private func copySources() throws -> URL {
        guard let source = Self.sourceFolder else {
            throw DeveloperError("Mobdev Runner's Xcode project is missing from this copy of Mobdev.")
        }
        let manager = FileManager.default
        let copy = folder.appendingPathComponent("project")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? manager.removeItem(at: copy)
        try manager.copyItem(at: source, to: copy)
        return copy.appendingPathComponent("MobdevRunner.xcodeproj")
    }

    /// The newest test run description of the build, for a device or a simulator.
    private func xctestrun() -> URL? {
        let products = buildFolder.appendingPathComponent("Build/Products")
        let prefix = isSimulator ? "MobdevRunner_iphonesimulator" : "MobdevRunner_iphoneos"
        let files = (try? FileManager.default.contentsOfDirectory(
            at: products, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func date(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        return files.filter { $0.pathExtension == "xctestrun" && $0.lastPathComponent.hasPrefix(prefix) }
            .max { date($0) < date($1) }
    }

    /// `Runner/` in the app's resources, or in the repository when Mobdev runs from `swift build`.
    static var sourceFolder: URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("Runner")) }
        // Sources/MobdevCore/Runner/UIRunner.swift → macos/Runner
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        candidates.append(repository.appendingPathComponent("Runner"))
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("MobdevRunner.xcodeproj/project.pbxproj").path)
        }
    }

    @discardableResult
    private func update(_ generation: Int, _ state: State) -> Bool {
        let changed = current.withLock { current -> Bool? in
            guard current.generation == generation else { return nil }
            defer { current.state = state }
            return current.state != state
        }
        if changed == true { onChange() }
        return changed != nil
    }

    private func isCurrent(_ generation: Int) -> Bool { current.get().generation == generation }

    // MARK: Explaining failures

    /// Apple team IDs: ten upper-case letters and digits.
    public static func isTeamID(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { ($0.isASCII && $0.isUppercase && $0.isLetter) || ($0.isASCII && $0.isNumber) }
    }

    /// What went wrong, from xcodebuild's output: its error lines and what follows "Testing failed:",
    /// with the fix for the usual causes. Nil when it names no error.
    static func summary(_ output: String) -> String? {
        var messages: [String] = []
        func add(_ text: String) {
            var text = text.trimmingCharacters(in: .whitespaces)
            if let range = text.range(of: " (in target '") { text = String(text[..<range.lowerBound]) }
            guard let last = text.last, !messages.contains(text) else { return }
            // Sentences in a row, and the fix after them.
            messages.append(".!?)".contains(last) ? text : text + ".")
        }
        var testingFailed = false
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "Testing failed:" {
                testingFailed = true
            } else if testingFailed {
                if line.isEmpty || line.hasPrefix("**") { testingFailed = false } else { add(line) }
            } else if let range = line.range(of: "error: ") {
                add(String(line[range.upperBound...]))
            }
        }
        guard !messages.isEmpty else { return nil }
        var text = messages.prefix(3).joined(separator: " ")
        if text.count > 600 { text = String(text.prefix(600)) + "…" }
        if let hint = hint(for: output) { text += " " + hint }
        return text
    }

    private static func hint(for output: String) -> String? {
        let hints: [(needles: [String], hint: String)] = [
            (["requires Xcode", "CommandLineTools"],
             "Install Xcode, open it once and select it: sudo xcode-select -s /Applications/Xcode.app"),
            (["No Account for Team", "No Accounts", "No signing certificate", "requires a development team"],
             "Sign in to Xcode with the Apple Account of this team (in Xcode’s Settings), then try again."),
            (["Developer Mode"],
             "Turn on Developer Mode on the iPhone: Settings › Privacy & Security › Developer Mode (it restarts)."),
            (["not trusted", "explicitly trusted", "Untrusted Developer", "invalid code signature"],
             "On the iPhone open Settings › General › VPN & Device Management, trust your developer certificate, then try again."),
            (["UI Automation", "automation mode"],
             "On the iPhone turn on Settings › Developer › Enable UI Automation, keep it unlocked, then try again."),
            (["Unable to find a destination", "is not available", "could not be found"],
             "Xcode does not see this device yet: connect and unlock it, open Xcode › Window › Devices and Simulators once, then try again."),
            (["is locked", "passcode"], "Unlock the iPhone and try again."),
        ]
        return hints.first { entry in entry.needles.contains { output.localizedCaseInsensitiveContains($0) } }?.hint
    }
}

/// One Mobdev Runner per device, shared by the app's controls and the tools.
public final class UIRunners: Sendable {
    public static let shared = UIRunners()

    private let runners = Locked<[String: UIRunner]>([:])
    private let handler = Locked<(@Sendable () -> Void)?>(nil)

    /// Called whenever a runner's state changes.
    public func onChange(_ handler: @escaping @Sendable () -> Void) { self.handler.set(handler) }

    public func runner(for udid: String) -> UIRunner? { runners.get()[udid] }

    /// The runner for a device, made the first time it is asked for.
    public func runner(for udid: String, simulator: Bool) -> UIRunner {
        let handler = self.handler
        return runners.withLock { runners in
            if let existing = runners[udid] { return existing }
            let safe = udid.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let created = UIRunner(
                udid: udid, simulator: simulator,
                folder: MobdevPaths.home.appendingPathComponent("runner", isDirectory: true).appendingPathComponent(safe),
                onChange: { handler.get()?() })
            runners[udid] = created
            return created
        }
    }

    /// Ends every runner's test, as the app quits.
    public func stopAll() {
        for runner in runners.get().values where runner.state != .off { runner.stop() }
    }
}

extension HardwareDevice {
    /// Mobdev Runner for this iPhone, once it was turned on.
    public var runner: UIRunner? { info.flatMap { UIRunners.shared.runner(for: $0.id) } }

    /// The elements on screen through Mobdev Runner. Nil while it is off: ui_tree then says how to
    /// turn it on.
    public func uiTree() async throws -> [UIElement]? {
        guard let runner, runner.state != .off else { return nil }
        return try await runner.elements()
    }

    /// The Bluetooth keyboard types what the keyboard layout has keys for. Mobdev Runner, while it
    /// runs, types the rest, such as emoji.
    public func typeText(_ text: String) async throws -> Bool {
        guard let runner, runner.state == .running, (try? status().keyboardLayout.strokes(typing: text)) == nil
        else { return false }
        try await runner.type(text)
        return true
    }
}
