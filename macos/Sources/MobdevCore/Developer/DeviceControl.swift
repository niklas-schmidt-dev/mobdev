import Foundation

/// An app on the device, from `devicectl device info apps`.
public struct InstalledApp: Sendable, Equatable {
    public var bundleID: String
    public var name: String
    public var version: String
    public var build: String
    /// Installed from Xcode or `install_app` rather than the App Store or the system.
    public var developer: Bool
    /// Where the app bundle lives on the device, e.g. "file:///private/var/containers/Bundle/Application/…/My.app/".
    public var location: String?

    public init(bundleID: String, name: String, version: String, build: String, developer: Bool, location: String?) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.build = build
        self.developer = developer
        self.location = location
    }

    init?(_ json: JSONValue) {
        guard let bundleID = json["bundleIdentifier"]?.stringValue else { return nil }
        self.init(
            bundleID: bundleID, name: json["name"]?.stringValue ?? bundleID,
            version: json["version"]?.stringValue ?? "", build: json["bundleVersion"]?.stringValue ?? "",
            developer: json["builtByDeveloper"]?.boolValue ?? false, location: json["url"]?.stringValue)
    }

    /// "My App 1.2 (7)".
    public var title: String {
        [name, version.isEmpty ? nil : version, build.isEmpty ? nil : "(\(build))"].compactMap { $0 }
            .joined(separator: " ")
    }

    public var json: JSONValue {
        [
            "bundle_id": .string(bundleID), "name": .string(name), "version": .string(version),
            "build": .string(build), "developer": .bool(developer),
        ]
    }
}

/// Output of apps started with `launch_app`, numbered so agents can ask for newer lines only.
public final class AppLogs: Sendable {
    public struct Line: Sendable, Equatable {
        public let number: Int
        public let app: String
        public let text: String
    }

    /// One read: the lines, the cursor to pass as `after` next time, whether more lines are
    /// waiting after the cursor, and how many lines after `after` were already dropped.
    public struct Page: Sendable, Equatable {
        public let lines: [Line]
        public let cursor: Int
        public let more: Bool
        public let dropped: Int
    }

    private struct State {
        var lines: [Line] = []
        var next = 1
        /// Per bundle ID: "running", or how the app ended.
        var status: [String: String] = [:]
    }

    /// Longer lines are cut, so one runaway print cannot fill memory or a relay response.
    static let maxLineLength = 4000
    private let state = Locked(State())
    private let limit: Int

    public init(limit: Int = 5000) { self.limit = limit }

    func append(app: String, text: String) {
        let text = text.count > Self.maxLineLength ? String(text.prefix(Self.maxLineLength)) + "…" : text
        state.withLock { state in
            state.lines.append(Line(number: state.next, app: app, text: text))
            state.next += 1
            if state.lines.count > limit { state.lines.removeFirst(state.lines.count - limit) }
        }
    }

    func setStatus(_ status: String, for app: String) {
        state.withLock { $0.status[app] = status }
    }

    public func status(for app: String) -> String? { state.get().status[app] }

    /// Without `after`, the newest `limit` lines. With it, the oldest `limit` lines after it, so
    /// paging with the returned cursor never skips a line. Optionally for one app, containing some text.
    public func read(app: String?, after: Int?, limit: Int, contains: String?) -> Page {
        let current = state.get()
        let last = current.next - 1
        // A cursor from before Mobdev restarted is newer than anything here: start over.
        let after = after.flatMap { $0 > last ? nil : $0 }
        let matching = current.lines.filter { line in
            (app == nil || line.app == app) && line.number > (after ?? 0)
                && (contains.map { line.text.localizedCaseInsensitiveContains($0) } ?? true)
        }
        guard let after else { return Page(lines: Array(matching.suffix(limit)), cursor: last, more: false, dropped: 0) }
        let page = Array(matching.prefix(limit))
        let more = matching.count > limit
        let oldest = current.lines.first?.number ?? current.next
        return Page(
            lines: page, cursor: more ? page.last!.number : last, more: more, dropped: max(0, oldest - 1 - after))
    }

    /// Every app with captured output and how it is doing, sorted by bundle ID.
    public var statuses: [(app: String, status: String)] {
        state.get().status.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

public enum LaunchOutcome: Sendable, Equatable {
    /// A new launch with its output captured, unless the app already ran and was not restarted.
    case launched
    /// It already ran with its output captured and was only brought to the front.
    case broughtToFront
}

/// A problem with developer tools, explained so the agent or user can fix it.
public struct DeveloperError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// What builds a device runs, so a path is checked before the device sees it.
public enum AppPlatform: Sendable, Equatable {
    /// .app or .ipa built for iOS devices.
    case iPhone
    /// .app built for the iOS Simulator.
    case simulator
    /// .apk.
    case android
}

/// App development on a device: install, launch and stop apps, open links, read what apps print
/// and their crash reports. `DeviceControl` implements it with Xcode's `devicectl` for iPhones and
/// simulators, `AndroidDevice` with adb.
public protocol AppBackend: Sendable {
    var logs: AppLogs { get }
    var platform: AppPlatform { get }
    /// iOS may ask "Open in “App”?" when this backend opens a custom URL scheme, as it does for
    /// simctl; the tools then wait longer for the prompt.
    var mayPromptToOpenURL: Bool { get }
    /// Brings an installed app to the front, starting it if needed, without capturing its output.
    func activate(_ bundleID: String) async throws
    /// Developer apps, or every app with `all`.
    func apps(all: Bool) async throws -> [InstalledApp]
    /// Any installed app by bundle ID.
    func app(_ bundleID: String) async throws -> InstalledApp?
    /// Installs an .app or .ipa from the Mac and returns what was installed.
    func install(at path: URL) async throws -> InstalledApp
    /// Removes a developer app. Refuses App Store and system apps.
    func uninstall(_ bundleID: String) async throws -> InstalledApp
    /// Launches an app and captures its output into `logs`.
    func launch(_ bundleID: String, arguments: [String], environment: [String: String], restart: Bool)
        async throws -> LaunchOutcome
    /// Stops an app; false when it was not running.
    func stop(_ bundleID: String) async throws -> Bool
    func open(_ url: URL) async throws
    /// Crash and hang reports, newest first.
    func crashReports() async throws -> [CrashReportFile]
    /// Copies a report to the Mac and parses it.
    func crashReport(named name: String) async throws -> (report: CrashReport?, file: URL)
}

extension AppBackend {
    public var mayPromptToOpenURL: Bool { false }
}

/// Xcode's `devicectl` for one device. Needs Xcode on the Mac and Developer Mode on an iPhone.
/// Simulators need nothing; they stop apps with `simctl` and keep crash reports on the Mac.
public final class DeviceControl: AppBackend, @unchecked Sendable {
    public let udid: String
    public let logs = AppLogs()
    public let isSimulator: Bool
    let runner: CommandRunning
    private let reportsFolder: URL
    /// Where macOS writes simulator crash reports.
    private let localReports: URL
    private let executable: Locked<URL?>
    /// Simulators go through `simctl` where `devicectl` does not know them.
    let usesSimctl: Bool
    /// The console of each app launched with log capture, by bundle ID.
    private let consoles = Locked<[String: (command: RunningCommand, launch: ConsoleLaunch)]>([:])

    /// `devicectl` is found through `xcode-select` unless given.
    public init(
        udid: String, runner: CommandRunning = ProcessRunner(), devicectl: URL? = nil, reportsFolder: URL,
        simulator: Bool = false, simctl: Bool? = nil,
        localReports: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
    ) {
        self.udid = udid
        self.runner = runner
        self.reportsFolder = reportsFolder
        isSimulator = simulator
        usesSimctl = simulator && (simctl ?? !Self.devicectlDrivesSimulators)
        self.localReports = localReports
        executable = Locked(devicectl)
    }

    public var platform: AppPlatform { isSimulator ? .simulator : .iPhone }

    /// Xcode 27's devicectl installs, lists and launches apps on simulators too; Xcode 26's says
    /// "The specified device was not found" (GitHub's macos-26 runners, 2026-10-01), so simulators
    /// use `simctl` there. MOBDEV_SIMULATOR_APPS=simctl forces it, e.g. to test it.
    static let devicectlDrivesSimulators: Bool = {
        if ProcessInfo.processInfo.environment["MOBDEV_SIMULATOR_APPS"] == "simctl" { return false }
        let version = SimulatorKit.developerDirectory().deletingLastPathComponent().appendingPathComponent("version.plist")
        guard let info = NSDictionary(contentsOf: version), let short = info["CFBundleShortVersionString"] as? String,
            let major = short.split(separator: ".").first.flatMap({ Int($0) })
        else { return true }
        return major >= 27
    }()

    /// Whether Developer Mode is on, from Xcode's device list: true, false, or nil when Xcode or the
    /// device cannot tell (no Xcode, or never trusted in Xcode).
    public func developerModeEnabled() async -> Bool? {
        guard let result = try? await call(["list", "devices"], forDevice: false, timeout: 15) else { return nil }
        let device = (result["devices"]?.arrayValue ?? []).first {
            $0["hardwareProperties"]?["udid"]?.stringValue == udid
        }
        switch device?["deviceProperties"]?["developerModeStatus"]?.stringValue {
        case "enabled": return true
        case "disabled": return false
        default: return nil
        }
    }

    public func activate(_ bundleID: String) async throws {
        if usesSimctl {
            _ = try await simctl(["launch", udid, bundleID])
            return
        }
        _ = try await call(["device", "process", "launch"], arguments: [bundleID])
    }

    // MARK: Apps

    public func apps(all: Bool) async throws -> [InstalledApp] {
        if usesSimctl {
            return try await simctlApps().filter { all || $0.developer }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let result = try await call(["device", "info", "apps"], options: all ? ["--include-all-apps"] : [])
        return (result["apps"]?.arrayValue ?? []).compactMap(InstalledApp.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func app(_ bundleID: String) async throws -> InstalledApp? {
        try await app(bundleID, timeout: 30)
    }

    /// Developer apps first: that list is short, and `--include-all-apps` ignores `--bundle-id`.
    private func app(_ bundleID: String, timeout: TimeInterval) async throws -> InstalledApp? {
        if usesSimctl { return try await simctlApps().first { $0.bundleID == bundleID } }
        for options in [["--bundle-id", bundleID], ["--include-all-apps"]] {
            let result = try await call(["device", "info", "apps"], options: options, timeout: timeout)
            if let app = (result["apps"]?.arrayValue ?? []).compactMap(InstalledApp.init).first(where: {
                $0.bundleID == bundleID
            }) {
                return app
            }
        }
        return nil
    }

    public func install(at path: URL) async throws -> InstalledApp {
        if usesSimctl {
            guard let info = NSDictionary(contentsOf: path.appendingPathComponent("Info.plist")),
                let bundleID = info["CFBundleIdentifier"] as? String
            else { throw DeveloperError("\(path.lastPathComponent) has no Info.plist with a bundle identifier.") }
            // A freshly booted simulator on a GitHub runner took over 60 s once (2026-10-02); 75 s
            // and the lookup below still fit the relays' 90 s request timeout.
            _ = try await simctl(["install", udid, path.path], timeout: Self.simctlInstallTimeout)
            return (try? await app(bundleID, timeout: 10))
                ?? InstalledApp(bundleID: bundleID, name: bundleID, version: "", build: "", developer: true, location: nil)
        }
        // Leaves a typical install room within the relays' 90 s request timeout.
        let result = try await call(["device", "install", "app"], arguments: [path.path], timeout: 60)
        guard let bundleID = result["installedApplications"]?.arrayValue?.first?["bundleID"]?.stringValue else {
            throw DeveloperError("devicectl did not report what it installed.")
        }
        return (try? await app(bundleID, timeout: 10))
            ?? InstalledApp(bundleID: bundleID, name: bundleID, version: "", build: "", developer: true, location: nil)
    }

    public func uninstall(_ bundleID: String) async throws -> InstalledApp {
        guard let app = try await app(bundleID) else { throw DeveloperError("\(bundleID) is not installed.") }
        guard app.developer else {
            throw DeveloperError(
                "\(app.name) (\(bundleID)) was not installed for development. Mobdev only removes apps installed from Xcode or with install_app, never App Store or system apps.")
        }
        detach(bundleID)
        if usesSimctl {
            // As long as an install: a GitHub simulator took over 30 s to remove the example app.
            _ = try await simctl(["uninstall", udid, bundleID], timeout: Self.simctlInstallTimeout)
        } else {
            _ = try await call(["device", "uninstall", "app"], arguments: [bundleID])
        }
        logs.setStatus("uninstalled", for: bundleID)
        return app
    }

    // MARK: Running apps

    public func launch(_ bundleID: String, arguments: [String], environment: [String: String], restart: Bool)
        async throws -> LaunchOutcome
    {
        if usesSimctl { return try await launchWithSimctl(bundleID, arguments: arguments, environment: environment, restart: restart) }
        let executable = try await devicectl()
        if !restart, let session = consoles.get()[bundleID], !session.launch.hasEnded {
            // A new console would capture nothing from a running app; keep the one that does.
            _ = try await call(["device", "process", "launch"], arguments: [bundleID] + arguments)
            return .broughtToFront
        }
        detach(bundleID)
        // Makes os_log and Logger messages appear on the console, as they do in Xcode.
        let environment = ["OS_ACTIVITY_DT_MODE": "YES"].merging(environment) { $1 }
        var command = ["device", "process", "launch", "--device", udid, "--console"]
        if restart { command.append("--terminate-existing") }
        command += ["--environment-variables", JSONValue.object(environment.mapValues(JSONValue.string)).compactString]
        command += ["--", bundleID] + arguments

        let launch = ConsoleLaunch(app: bundleID, logs: logs)
        let console = try runner.start(executable, command, onLine: launch.receive, onExit: launch.exited)
        guard await launch.started(timeout: 45) else {
            launch.detach()
            console.stop()
            let reason = launch.failure
                ?? (launch.hasEnded
                    ? "devicectl ended before the app started. \(launch.lastLines)"
                    : "The app did not start within 45 seconds.")
            throw DeveloperError(await explain(reason))
        }
        let replaced = consoles.withLock { consoles -> (command: RunningCommand, launch: ConsoleLaunch)? in
            // The console ends when the app does; keep it only while it runs.
            if launch.hasEnded { return nil }
            let old = consoles[bundleID]
            consoles[bundleID] = (console, launch)
            return old
        }
        replaced?.launch.detach()
        replaced?.command.stop()
        return .launched
    }

    public func stop(_ bundleID: String) async throws -> Bool {
        guard let app = try await app(bundleID) else { throw DeveloperError("\(bundleID) is not installed.") }
        if isSimulator { return try await stopOnSimulator(bundleID) }
        let processes = try await call(["device", "info", "processes"])
        let pids = (processes["runningProcesses"]?.arrayValue ?? []).compactMap { process -> Int? in
            // The app's own executable, not its extensions in PlugIns/.
            guard let location = app.location, let executable = process["executable"]?.stringValue,
                executable.hasPrefix(location), !executable.dropFirst(location.count).contains("/")
            else { return nil }
            return process["processIdentifier"]?.doubleValue.map(Int.init)
        }
        let captured = detach(bundleID)
        var stopped = false
        var failure: Error?
        for pid in pids {
            do {
                _ = try await call(["device", "process", "terminate"], options: ["--pid", String(pid)])
                stopped = true
            } catch {
                failure = error
            }
        }
        if !stopped, let failure { throw failure }
        if stopped || captured { logs.setStatus("stopped", for: bundleID) }
        return stopped
    }

    /// Simulator crash reports land on the Mac. A report belongs to this simulator when its header
    /// says iOS Simulator (platform 7) and the process path near the top names this UDID.
    private func simulatorReports() -> [CrashReportFile] {
        let manager = FileManager.default
        guard
            let names = try? manager.contentsOfDirectory(atPath: localReports.path)
        else { return [] }
        return names.filter { $0.hasSuffix(".ips") }.compactMap { name -> CrashReportFile? in
            let url = localReports.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let head = String(decoding: (try? handle.read(upToCount: 8192)) ?? Data(), as: UTF8.self)
            guard let headerLine = head.split(separator: "\n", maxSplits: 1).first,
                let header = try? JSONValue.parse(Data(headerLine.utf8)),
                header["platform"]?.doubleValue == 7, head.contains(udid)
            else { return nil }
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            return CrashReportFile(
                name: name,
                process: header["app_name"]?.stringValue ?? header["name"]?.stringValue
                    ?? CrashReportFile.process(fromName: name) ?? name,
                date: attributes?[.modificationDate] as? Date,
                size: (attributes?[.size] as? NSNumber)?.intValue ?? 0)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// devicectl cannot signal simulator processes (their pids are the Mac's), so `simctl` stops them.
    private func stopOnSimulator(_ bundleID: String) async throws -> Bool {
        let result = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/xcrun"), ["simctl", "terminate", udid, bundleID], timeout: 20)
        let captured = detach(bundleID)
        let stopped = result.status == 0
        if !stopped, !result.output.contains("found nothing to terminate") {
            throw DeveloperError(
                "Could not stop \(bundleID): "
                    + (result.output.split(separator: "\n").first.map(String.init) ?? "simctl failed"))
        }
        if stopped || captured { logs.setStatus("stopped", for: bundleID) }
        return stopped
    }

    /// Stops capturing an app's output. The app keeps running. True if it was being captured.
    @discardableResult
    private func detach(_ bundleID: String) -> Bool {
        guard let session = consoles.withLock({ $0.removeValue(forKey: bundleID) }) else { return false }
        let running = !session.launch.hasEnded
        session.launch.detach()
        session.command.stop()
        return running
    }

    public func open(_ url: URL) async throws {
        if usesSimctl {
            _ = try await simctl(["openurl", udid, url.absoluteString])
            return
        }
        _ = try await call(["device", "process", "openURL"], arguments: [url.absoluteString])
    }

    /// `simctl openurl` makes iOS ask before a custom scheme opens; devicectl's openURL does not.
    public var mayPromptToOpenURL: Bool { usesSimctl }

    // MARK: simctl

    static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    /// Runs `xcrun simctl` and returns what it printed; its first line explains a failure.
    @discardableResult
    func simctl(_ arguments: [String], timeout: TimeInterval = 30) async throws -> String {
        let result = try await runner.run(Self.xcrun, ["simctl"] + arguments, timeout: timeout)
        guard result.status == 0 else {
            let reason = result.output.split(separator: "\n").map(String.init)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "status \(result.status)"
            throw DeveloperError("simctl \(arguments.first ?? "") failed: \(reason)")
        }
        return result.output
    }

    /// `simctl listapps` prints an old-style property list keyed by bundle ID.
    private func simctlApps() async throws -> [InstalledApp] {
        Self.simctlApps(from: try await simctl(["listapps", udid]))
    }

    static func simctlApps(from output: String) -> [InstalledApp] {
        guard let data = output.data(using: .utf8),
            let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        return list.compactMap { bundleID, value -> InstalledApp? in
            guard let info = value as? [String: Any] else { return nil }
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID
            return InstalledApp(
                bundleID: bundleID, name: name, version: info["CFBundleShortVersionString"] as? String ?? "",
                build: info["CFBundleVersion"] as? String ?? "", developer: info["ApplicationType"] as? String == "User",
                location: info["Path"] as? String)
        }
    }

    /// `simctl launch --console-pty` runs while the app does and passes on what it prints; it says
    /// nothing when the launch worked, so the app counts as started with its first line or after
    /// two seconds without a failure. Environment variables reach the app as SIMCTL_CHILD_<name>.
    private func launchWithSimctl(
        _ bundleID: String, arguments: [String], environment: [String: String], restart: Bool
    ) async throws -> LaunchOutcome {
        if !restart, let session = consoles.get()[bundleID], !session.launch.hasEnded {
            try await simctl(["launch", udid, bundleID] + arguments)
            return .broughtToFront
        }
        detach(bundleID)
        // The old instance ends before the new one starts: left to `--terminate-running-process`
        // alone, simctl now and then printed nothing for 90 seconds on GitHub's simulators while
        // the old console was still going away (2026-10-07).
        if restart { _ = try? await stopOnSimulator(bundleID) }
        let environment = ["OS_ACTIVITY_DT_MODE": "YES"].merging(environment) { $1 }
        let variables = environment.sorted { $0.key < $1.key }.map { "SIMCTL_CHILD_\($0.key)=\($0.value)" }
        // Into a pipe, simctl passes the app's output on in blocks, late; `script` gives it a terminal,
        // so each line arrives as it is printed.
        var command = variables + ["/usr/bin/script", "-q", "/dev/null", Self.xcrun.path, "simctl", "launch", "--console-pty"]
        if restart { command.append("--terminate-running-process") }
        command += [udid, bundleID] + arguments
        // simctl does not say how the app ended; a fresh crash report of its executable does.
        let started = Date()
        let executable = (try? await app(bundleID, timeout: 10))?.location.flatMap { path in
            NSDictionary(contentsOfFile: path + "/Info.plist")?["CFBundleExecutable"] as? String
        }
        for attempt in 1...Self.simctlLaunchAttempts {
            let launch = ConsoleLaunch(app: bundleID, logs: logs, startsWithOutput: true)
            let onExit: @Sendable (Int32) -> Void = { [weak self] status in
                launch.exited(status)
                guard let self, let executable, !launch.isDetached else { return }
                // The report is written a few seconds after the crash.
                for second in 1...15 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(second)) {
                        guard !launch.isDetached, self.logs.status(for: bundleID)?.hasPrefix("crashed") != true,
                            self.simulatorReports().contains(where: { $0.process == executable && ($0.date ?? .distantPast) >= started })
                        else { return }
                        self.logs.setStatus("crashed. Call crash_reports for the report.", for: bundleID)
                    }
                }
            }
            let console = try runner.start(URL(fileURLWithPath: "/usr/bin/env"), command, onLine: launch.receive, onExit: onExit)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { launch.markStarted() }
            guard await launch.started(timeout: 45) else {
                launch.detach()
                console.stop()
                throw DeveloperError(launch.lastLines.isEmpty ? "The app did not start within 45 seconds." : launch.lastLines)
            }
            // The app has launched once simctl prints its "<bundle>: <pid>" line. On GitHub's slow
            // simulators that takes a while right after an install, and now and then simctl
            // refuses the launch instead: it prints why and exits before the line (2026-10-07).
            // Such a launch is tried again; one that never gets there is not "Launched".
            // The pid line goes through the terminal `script` gives simctl, which lost simctl's
            // and the app's stdout once on GitHub (2026-10-07) while stderr came through; the
            // simulator's launchd knows whether the app runs either way. A launch that shows no
            // sign of life in its share of the wait is asked for again: right after an install,
            // SpringBoard on GitHub's simulators ignored the first request for minutes.
            let deadline = Date().addingTimeInterval(Self.simctlStartWait / Double(Self.simctlLaunchAttempts))
            var polls = 0
            while !launch.sawStart, !launch.hasEnded, Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                polls += 1
                if polls % 8 == 0, await appRunsOnSimulator(bundleID) {
                    launch.noteStart()
                    break
                }
            }
            if !launch.sawStart {
                launch.detach()
                console.stop()
                logs.setStatus("did not start", for: bundleID)
                let reason = logs.read(app: bundleID, after: nil, limit: 2, contains: nil).lines.map(\.text)
                    .joined(separator: " ")
                if attempt < Self.simctlLaunchAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(Self.simctlRetryPause * 1_000_000_000))
                    continue
                }
                guard launch.hasEnded else {
                    throw DeveloperError(
                        "The app did not start within \(Int(Self.simctlStartWait)) seconds and \(attempt) launches: simctl reported no process.")
                }
                throw DeveloperError(
                    "simctl could not launch \(bundleID) in \(attempt) tries\(reason.isEmpty ? "." : ": \(reason)")")
            }
            let replaced = consoles.withLock { consoles -> (command: RunningCommand, launch: ConsoleLaunch)? in
                if launch.hasEnded { return nil }
                let old = consoles[bundleID]
                consoles[bundleID] = (console, launch)
                return old
            }
            replaced?.launch.detach()
            replaced?.command.stop()
            return .launched
        }
        throw DeveloperError("simctl could not launch \(bundleID).")
    }

    /// Whether the simulator's launchd lists the app's process: "12345  0  UIKitApplication:<bundle>[…]".
    private func appRunsOnSimulator(_ bundleID: String) async -> Bool {
        guard let result = try? await runner.run(Self.xcrun, ["simctl", "spawn", udid, "launchctl", "list"], timeout: 15),
            result.status == 0
        else { return false }
        return result.output.split(separator: "\n").contains { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3, let pid = Int(columns[0].trimmingCharacters(in: .whitespaces)), pid > 0 else { return false }
            return columns[2].hasPrefix("UIKitApplication:\(bundleID)[")
        }
    }

    /// How often a launch is asked for, how long all tries together wait for a sign of the app
    /// (its pid line or its process), and the pause between tries. A healthy simulator shows it
    /// within a second; GitHub's took over 45 seconds on a bad day (2026-10-07), so the wait is
    /// generous, and a request SpringBoard sat on is replaced after its share of it.
    static let simctlLaunchAttempts = 3
    static let simctlStartWait: TimeInterval = 90
    static let simctlRetryPause: TimeInterval = 2
    /// Installing and removing an app: GitHub's simulators took over 75 seconds for the example app.
    static let simctlInstallTimeout: TimeInterval = 180

    // MARK: Crash reports

    public func crashReports() async throws -> [CrashReportFile] {
        if isSimulator { return simulatorReports() }
        let result = try await call(["device", "info", "files"], options: ["--domain-type", "systemCrashLogs"])
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        func date(_ text: String) -> Date? { fractional.date(from: text) ?? whole.date(from: text) }
        return (result["files"]?.arrayValue ?? []).compactMap { file -> CrashReportFile? in
            guard file["resources"]?["isDirectory"]?.boolValue != true,
                let name = file["relativePath"]?.stringValue ?? file["name"]?.stringValue,
                let process = CrashReportFile.process(fromName: name)
            else { return nil }
            let metadata = file["metadata"]
            return CrashReportFile(
                name: name, process: process,
                date: metadata?["lastModDate"]?.stringValue.flatMap(date),
                size: metadata?["size"]?.doubleValue.map(Int.init) ?? 0)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    public func crashReport(named name: String) async throws -> (report: CrashReport?, file: URL) {
        // Only names the device listed, so a name cannot reach outside the crash log folder.
        guard try await crashReports().contains(where: { $0.name == name }) else {
            throw DeveloperError("No crash report named \"\(name)\". Call crash_reports without name to list them.")
        }
        if isSimulator {
            let file = localReports.appendingPathComponent(name)
            return (CrashReport.parse((try? String(contentsOf: file, encoding: .utf8)) ?? ""), file)
        }
        let folder = reportsFolder.appendingPathComponent(udid.filter { $0.isLetter || $0.isNumber || $0 == "-" })
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name.split(separator: "/").last.map(String.init) ?? name)
        try? FileManager.default.removeItem(at: file)
        _ = try await call(
            ["device", "copy", "from"],
            options: ["--domain-type", "systemCrashLogs", "--source", name, "--destination", file.path])
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return (CrashReport.parse(text), file)
    }

    // MARK: devicectl

    /// Runs a devicectl command for this device and returns the `result` of its JSON output.
    func call(
        _ command: [String], options: [String] = [], arguments: [String] = [], forDevice: Bool = true,
        timeout: TimeInterval = 30
    ) async throws -> JSONValue {
        let executable = try await devicectl()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobdev-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        var full = command + (forDevice ? ["--device", udid] : []) + options
        full += ["--timeout", String(Int(timeout)), "--quiet", "--json-output", output.path]
        if !arguments.isEmpty { full += ["--"] + arguments }
        let result = try await runner.run(executable, full, timeout: timeout + 10)
        guard let data = try? Data(contentsOf: output), let json = try? JSONValue.parse(data) else {
            let message = Self.message(fromConsole: result.output)
                ?? "devicectl failed with status \(result.status)."
            throw DeveloperError(forDevice ? await explain(message) : message)
        }
        if json["info"]?["outcome"]?.stringValue == "success" { return json["result"] ?? .null }
        let message = Self.message(fromError: json["error"]) ?? "devicectl failed."
        throw DeveloperError(forDevice ? await explain(message) : message)
    }

    /// Adds what is most likely wrong when devicectl's own message does not say.
    private func explain(_ message: String) async -> String {
        guard let result = try? await call(["list", "devices"], forDevice: false, timeout: 10) else { return message }
        let device = (result["devices"]?.arrayValue ?? []).first {
            $0["hardwareProperties"]?["udid"]?.stringValue == udid
        }
        guard let device else {
            return message
                + " Xcode does not know this device yet: with it connected and unlocked, open Xcode > Window > Devices and Simulators once and trust this Mac on the device."
        }
        if device["deviceProperties"]?["developerModeStatus"]?.stringValue == "disabled" {
            return message
                + " Developer Mode is off on this device: turn it on in Settings > Privacy & Security > Developer Mode (the device restarts), then try again."
        }
        return message
    }

    /// The `devicectl` Xcode selected with `xcode-select`, falling back to /Applications/Xcode.app.
    func devicectl() async throws -> URL {
        if let known = executable.get() { return known }
        var candidates: [URL] = []
        if let selected = try? await runner.run(
            URL(fileURLWithPath: "/usr/bin/xcode-select"), ["--print-path"], timeout: 10), selected.status == 0
        {
            let folder = selected.output.trimmingCharacters(in: .whitespacesAndNewlines)
            candidates.append(URL(fileURLWithPath: folder).appendingPathComponent("usr/bin/devicectl"))
        }
        candidates.append(URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/devicectl"))
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw DeveloperError(
                "Developer tools need Xcode on this Mac. Install the current Xcode, open it once, and select it with `sudo xcode-select -s /Applications/Xcode.app`.")
        }
        executable.set(found)
        return found
    }

    /// devicectl's error from its JSON output: description, reason and suggestion.
    static func message(fromError error: JSONValue?) -> String? {
        guard let info = error?["userInfo"] else { return nil }
        var parts: [String] = []
        for key in ["NSLocalizedDescription", "NSLocalizedFailureReason", "NSLocalizedRecoverySuggestion"] {
            if let text = info[key]?["string"]?.stringValue, !parts.contains(text) { parts.append(text) }
        }
        if parts.count < 2, let underlying = message(fromError: info["NSUnderlyingError"]?["error"]) {
            parts.append(underlying)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// devicectl's error from what it printed: "ERROR: …" and the reason and suggestion below it, or
    /// an argument error such as "Error: Unknown option '--console'" from an older Xcode.
    static func message(fromConsole output: String) -> String? {
        var parts: [String] = []
        for line in output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.uppercased().hasPrefix("ERROR:"), parts.isEmpty {
                var text = line.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces)
                // Drops " (com.apple.dt.CoreDeviceError error 10002 (0x2712))".
                if let range = text.range(of: " (com.apple.", options: .backwards) { text = String(text[..<range.lowerBound]) }
                parts.append(text)
            } else if !parts.isEmpty, parts.count < 3,
                let value = ["NSLocalizedFailureReason = ", "NSLocalizedRecoverySuggestion = "]
                    .lazy.compactMap({ line.hasPrefix($0) ? String(line.dropFirst($0.count)) : nil }).first
            {
                parts.append(value)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Follows one `devicectl device process launch --console`: waits for the launch, then files the
/// app's output under its bundle ID and notes how it ended.
private final class ConsoleLaunch: Sendable {
    private struct State {
        var started: Bool?
        var ended = false
        /// Set when Mobdev stops listening; the app's later lines and ending are no longer this console's.
        var detached = false
        var reportedEnding = false
        /// simctl printed its "<bundle>: <pid>" line: the app really ran.
        var sawStart = false
        /// What devicectl printed before the launch, to explain a failure.
        var failure: [String] = []
        var waiter: CheckedContinuation<Bool, Never>?
    }

    let app: String
    let logs: AppLogs
    /// simctl prints no launch line: its first line is already the app's.
    let startsWithOutput: Bool
    private let state = Locked(State())

    init(app: String, logs: AppLogs, startsWithOutput: Bool = false) {
        self.app = app
        self.logs = logs
        self.startsWithOutput = startsWithOutput
    }

    /// For simctl: started unless it already ended.
    func markStarted() {
        let current = state.get()
        guard current.started == nil, !current.ended, !current.detached else { return }
        logs.setStatus("running", for: app)
        resolve(true)
    }

    var hasEnded: Bool { state.get().ended }
    var isDetached: Bool { state.get().detached }
    var sawStart: Bool { state.get().sawStart }

    /// The app runs, known from elsewhere than simctl's pid line (launchd lists it).
    func noteStart() {
        state.withLock { $0.sawStart = true }
        markStarted()
    }
    var failure: String? { DeviceControl.message(fromConsole: state.get().failure.joined(separator: "\n")) }
    var lastLines: String { state.get().failure.suffix(3).joined(separator: " ") }

    func detach() { state.withLock { $0.detached = true } }

    /// True once devicectl reports the launch; false if it exits or times out first.
    func started(timeout: TimeInterval) async -> Bool {
        let box = self
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.resolve(false) }
        return await withCheckedContinuation { continuation in
            let resolved = state.withLock { state -> Bool? in
                if let started = state.started { return started }
                state.waiter = continuation
                return nil
            }
            if let resolved { continuation.resume(returning: resolved) }
        }
    }

    private func resolve(_ started: Bool) {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.started == nil else { return nil }
            state.started = started
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: started)
    }

    func receive(_ line: String) {
        let current = state.get()
        if current.detached { return }
        if startsWithOutput, Self.isSimctlStart(line, app: app) {
            state.withLock { $0.sawStart = true }
            markStarted()
            return
        }
        if current.started != true {
            if startsWithOutput {
                markStarted()
                logs.append(app: app, text: line)
                return
            }
            if line.hasPrefix("Launched application") || line.hasPrefix("Waiting for the application to terminate") {
                logs.setStatus("running", for: app)
                resolve(true)
            } else {
                state.withLock { $0.failure.append(String(line.prefix(AppLogs.maxLineLength))) }
            }
            return
        }
        if line.hasPrefix("Waiting for the application to terminate") { return }
        if let ending = Self.ending(line) {
            state.withLock { $0.reportedEnding = true }
            logs.setStatus(ending, for: app)
            return
        }
        logs.append(app: app, text: line)
    }

    func exited(_ status: Int32) {
        let current = state.withLock { state -> State in
            state.ended = true
            return state
        }
        if current.started != true {
            resolve(false)
        } else if !current.detached, !current.reportedEnding {
            // Cable pulled or CoreDevice gave up: devicectl ended without saying how the app did.
            logs.setStatus("output capture ended (status \(status)); the app may have exited or still be running", for: app)
        }
    }

    /// simctl's "dev.mobdev.fixture: 12345" once the app runs. The terminal `script` gives it
    /// sometimes puts control characters in front (an end-of-transmission and backspaces were
    /// seen on GitHub's runners, 2026-10-07), so those do not count.
    static func isSimctlStart(_ line: String, app: String) -> Bool {
        let cleaned = line.drop { character in
            character.isWhitespace || character.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) }
        }
        guard cleaned.hasPrefix(app + ": ") else { return false }
        let pid = cleaned.dropFirst(app.count + 2).trimmingCharacters(in: .whitespacesAndNewlines)
        return !pid.isEmpty && pid.allSatisfy(\.isNumber)
    }

    /// "The app terminated with the exit code 3." → "exited with code 3";
    /// "App terminated due to signal 5." → "crashed: signal 5 (SIGTRAP)…".
    static func ending(_ line: String) -> String? {
        let digits = line.filter(\.isNumber)
        if line.hasPrefix("The app terminated with the exit code"), let code = Int(digits) {
            return "exited with code \(code)"
        }
        if line.hasPrefix("App terminated due to signal"), let signal = Int32(digits) {
            let name = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS",
                        11: "SIGSEGV", 15: "SIGTERM"][Int(signal)].map { " (\($0))" } ?? ""
            let crash: Set<Int32> = [4, 5, 6, 8, 10, 11]
            return crash.contains(signal)
                ? "crashed: signal \(signal)\(name). Call crash_reports for the report."
                : "terminated by signal \(signal)\(name)"
        }
        return nil
    }
}
