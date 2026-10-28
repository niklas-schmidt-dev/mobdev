import Foundation

/// An iOS simulator or Android Virtual Device on this Mac, running or not. `EmulatorHub` makes the
/// running ones devices for the other tools; `VirtualDevices` starts, stops, creates and deletes them.
public struct VirtualDevice: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case simulator, android
    }

    public enum State: String, Sendable {
        case shutdown = "shut down"
        case booting
        case booted
        case shuttingDown = "shutting down"
    }

    public var kind: Kind
    /// A simulator's UDID or an AVD's name.
    public var id: String
    public var name: String
    /// The device type, e.g. "iPhone 17 Pro" or "Pixel 9 Pro".
    public var model: String
    /// "iOS 27.0" or "Android 16 (API 36)".
    public var system: String
    public var state: State
    /// A running emulator's adb serial, e.g. "emulator-5554".
    public var serial: String?
    /// Made by `create_simulator`, so `delete_simulator` may delete it.
    public var createdByMobdev: Bool
    public var isTablet: Bool

    public init(
        kind: Kind, id: String, name: String, model: String, system: String, state: State, serial: String? = nil,
        createdByMobdev: Bool = false, isTablet: Bool = false
    ) {
        self.kind = kind
        self.id = id
        self.name = name
        self.model = model
        self.system = system
        self.state = state
        self.serial = serial
        self.createdByMobdev = createdByMobdev
        self.isTablet = isTablet
    }

    public var isRunning: Bool { state == .booted || state == .booting }

    /// Its id in `list_devices` and the other tools while it runs: the UDID, or the adb serial.
    public var deviceID: String? {
        guard state == .booted else { return nil }
        return kind == .simulator ? id : serial
    }

    public var json: JSONValue {
        [
            "kind": .string(kind.rawValue), "id": .string(id), "name": .string(name), "model": .string(model),
            "system": .string(system), "state": .string(state.rawValue), "device": deviceID.map(JSONValue.string) ?? .null,
            "created_by_mobdev": .bool(createdByMobdev),
        ]
    }
}

public struct VirtualDeviceList: Sendable, Equatable {
    public var devices: [VirtualDevice]
    /// Why simulators or Android are missing, e.g. no Xcode or no Android SDK.
    public var problems: [String]

    public init(devices: [VirtualDevice] = [], problems: [String] = []) {
        self.devices = devices
        self.problems = problems
    }
}

/// The simulator types and iOS versions this Mac has, for `create_simulator` and New Simulator.
public struct SimulatorCatalog: Sendable, Equatable {
    public struct DeviceType: Sendable, Equatable, Hashable, Identifiable {
        public let id: String
        public let name: String
        /// "iPhone" or "iPad".
        public let family: String
    }

    public struct Runtime: Sendable, Equatable, Hashable, Identifiable {
        public let id: String
        /// "iOS 27.0".
        public let name: String
        public let version: String
        /// The device types it runs.
        public let deviceTypes: Set<String>
    }

    /// iPhones, then iPads, each newest first as simctl lists them.
    public var deviceTypes: [DeviceType]
    /// Newest first.
    public var runtimes: [Runtime]

    public init(deviceTypes: [DeviceType] = [], runtimes: [Runtime] = []) {
        self.deviceTypes = deviceTypes
        self.runtimes = runtimes
    }

    /// The iOS versions that run a type, newest first.
    public func runtimes(for type: DeviceType) -> [Runtime] { runtimes.filter { $0.deviceTypes.contains(type.id) } }

    /// The type named, by name or identifier, regardless of case.
    func deviceType(_ query: String) throws -> DeviceType {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        if let type = deviceTypes.first(where: { $0.id == wanted || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return type
        }
        let names = deviceTypes.filter { $0.family == "iPhone" }.prefix(12).map(\.name)
        throw ToolFailure(
            deviceTypes.isEmpty
                ? "No simulator types are installed; install an iOS platform in Xcode › Settings › Components."
                : "No simulator type \"\(query)\". iPhones: \(names.joined(separator: ", ")); iPads too, such as \(deviceTypes.first { $0.family == "iPad" }?.name ?? "iPad Pro").")
    }

    /// "iOS 27.0", "27.0", "27" (the newest 27.x) or an identifier; without one the newest that
    /// runs the type.
    func runtime(_ query: String?, for type: DeviceType) throws -> Runtime {
        let candidates = runtimes(for: type)
        guard let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            guard let newest = candidates.first else {
                throw ToolFailure("No installed iOS version runs \(type.name); install one in Xcode › Settings › Components.")
            }
            return newest
        }
        let version = query.lowercased().hasPrefix("ios") ? String(query.dropFirst(3)).trimmingCharacters(in: .whitespaces) : query
        if let match = candidates.first(where: {
            $0.id == query || $0.name.caseInsensitiveCompare(query) == .orderedSame || $0.version == version
                || $0.version.hasPrefix(version + ".")
        }) {
            return match
        }
        let available = candidates.map(\.name)
        throw ToolFailure(
            "No iOS \(version) for \(type.name). It runs: \(available.isEmpty ? "none installed" : available.joined(separator: ", ")).")
    }
}

/// Starts, stops, creates and deletes simulators and Android Virtual Devices: what the virtual
/// device tools, the app's sidebar and `Mobdev test` share. Simulators go through `simctl`; AVDs are
/// read from the AVD folder, started with the SDK's `emulator` and stopped through adb.
public final class VirtualDevices: Sendable {
    private let runner: CommandRunning
    private let xcrun: URL
    private let adb: @Sendable () -> ADB?
    private let avdHome: URL
    private let recordsFile: URL?
    /// The serials of running emulators, or nil when no adb server runs.
    private let runningEmulators: @Sendable () -> [String]?
    /// Starts an AVD and returns its serial once Android has booted.
    private let startEmulator: @Sendable (_ avd: String, _ window: Bool) async throws -> String
    private let pollInterval: TimeInterval
    /// AVDs starting now, which the list shows as booting.
    private let starting = Locked<Set<String>>([])
    /// Serializes changes to the records file.
    private let recordsLock = Locked<Int>(0)

    public init(
        runner: CommandRunning = ProcessRunner(), xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        adb: @escaping @Sendable () -> ADB? = { ADB.find() }, avdHome: URL = VirtualDevices.defaultAVDHome(),
        records: URL? = nil,
        runningEmulators: @escaping @Sendable () -> [String]? = { ADB.devices()?.filter(\.isEmulator).map(\.serial) },
        startEmulator: (@Sendable (String, Bool) async throws -> String)? = nil, pollInterval: TimeInterval = 0.5
    ) {
        self.runner = runner
        self.xcrun = xcrun
        self.adb = adb
        self.avdHome = avdHome
        recordsFile = records
        self.runningEmulators = runningEmulators
        self.startEmulator =
            startEmulator ?? { avd, window in try await AndroidEmulators.start(avd, readOnly: false, window: window).serial }
        self.pollInterval = pollInterval
    }

    /// `ANDROID_AVD_HOME`, else `avd` in `ANDROID_USER_HOME` or `ANDROID_EMULATOR_HOME`, else ~/.android/avd.
    public static func defaultAVDHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["ANDROID_AVD_HOME"], !home.isEmpty { return URL(fileURLWithPath: home, isDirectory: true) }
        for key in ["ANDROID_USER_HOME", "ANDROID_EMULATOR_HOME"] {
            if let home = environment[key], !home.isEmpty {
                return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("avd", isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/avd", isDirectory: true)
    }

    /// Simulators Mobdev made, by UDID, in Mobdev's data folder.
    private var records: URL { recordsFile ?? MobdevPaths.home.appendingPathComponent("created-simulators.json") }

    // MARK: Listing

    /// Every iOS simulator and AVD: running ones first, then by name.
    public func list() async -> VirtualDeviceList {
        async let simulators = simulatorList()
        async let avds = avdList()
        let (iOS, android) = await (simulators, avds)
        var list = VirtualDeviceList()
        switch iOS {
        case .success(let devices): list.devices += devices
        case .failure(let error): list.problems.append(String(describing: error))
        }
        switch android {
        case .success(let devices): list.devices += devices
        case .failure(let error): list.problems.append(String(describing: error))
        }
        list.devices.sort { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            if lhs.kind != rhs.kind { return lhs.kind == .simulator }
            if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            return lhs.system.compare(rhs.system, options: .numeric) == .orderedDescending
        }
        return list
    }

    /// The simulator types and iOS versions to create simulators from.
    public func catalog() async throws -> SimulatorCatalog {
        Self.catalog(try await simctlList())
    }

    private func simctlList() async throws -> SimctlList {
        let result: CommandResult
        do {
            result = try await runner.run(xcrun, ["simctl", "list", "-j", "devicetypes", "runtimes", "devices"], timeout: 60)
        } catch {
            throw ToolFailure("Simulators need Xcode: \(error)")
        }
        guard result.status == 0, let data = Self.jsonObject(in: result.output),
            let list = try? JSONDecoder().decode(SimctlList.self, from: data)
        else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("xcrun: error") {
                throw ToolFailure("Simulators need Xcode. Install it, then run sudo xcode-select -s /Applications/Xcode.app.")
            }
            throw ToolFailure("simctl could not list the simulators: \(message.isEmpty ? "status \(result.status)" : message)")
        }
        return list
    }

    /// simctl prints warnings before its JSON on some setups.
    static func jsonObject(in output: String) -> Data? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else { return nil }
        return Data(output[start...end].utf8)
    }

    static func catalog(_ list: SimctlList) -> SimulatorCatalog {
        let types = (list.devicetypes ?? []).compactMap { type -> SimulatorCatalog.DeviceType? in
            guard let family = type.productFamily, family == "iPhone" || family == "iPad" else { return nil }
            return SimulatorCatalog.DeviceType(id: type.identifier, name: type.name, family: family)
        }
        let runtimes = (list.runtimes ?? []).filter { $0.isIOS && $0.isAvailable != false }
            .map { runtime in
                SimulatorCatalog.Runtime(
                    id: runtime.identifier, name: runtime.name, version: runtime.version ?? "",
                    deviceTypes: Set((runtime.supportedDeviceTypes ?? []).map(\.identifier)))
            }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        // simctl lists types oldest first; newest first is what people pick from.
        let ordered = types.filter { $0.family == "iPhone" }.reversed() + types.filter { $0.family == "iPad" }.reversed()
        return SimulatorCatalog(deviceTypes: Array(ordered), runtimes: runtimes)
    }

    private func simulatorList() async -> Result<[VirtualDevice], Error> {
        do {
            let list = try await simctlList()
            let created = Set(readRecords())
            let types = Dictionary((list.devicetypes ?? []).map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            let runtimes = Dictionary((list.runtimes ?? []).map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
            var devices: [VirtualDevice] = []
            for (runtimeID, entries) in list.devices ?? [:] {
                // Mobdev drives iOS simulators only; watchOS, tvOS and visionOS ones are left out.
                let runtime = runtimes[runtimeID]
                guard runtime?.isIOS ?? runtimeID.contains(".iOS-") else { continue }
                for entry in entries where entry.isAvailable != false {
                    let type = entry.deviceTypeIdentifier.flatMap { types[$0] }
                    devices.append(
                        VirtualDevice(
                            kind: .simulator, id: entry.udid, name: entry.name, model: type?.name ?? entry.name,
                            system: runtime?.name ?? Self.systemName(runtimeID: runtimeID), state: Self.state(entry.state),
                            createdByMobdev: created.contains(entry.udid), isTablet: type?.productFamily == "iPad"))
                }
            }
            pruneRecords(keeping: Set((list.devices ?? [:]).values.joined().map(\.udid)))
            return .success(devices)
        } catch {
            return .failure(error)
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS 27.0", for a runtime that is gone.
    static func systemName(runtimeID: String) -> String {
        guard let last = runtimeID.split(separator: ".").last else { return runtimeID }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return runtimeID }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }

    static func state(_ simctl: String) -> VirtualDevice.State {
        switch simctl {
        case "Booted": .booted
        case "Booting": .booting
        case "Shutting Down": .shuttingDown
        default: .shutdown
        }
    }

    private func avdList() async -> Result<[VirtualDevice], Error> {
        let avds = Self.readAVDs(in: avdHome)
        guard !avds.isEmpty || adb() != nil else {
            // No SDK and no AVDs: nothing to report unless someone looks for Android.
            return .success([])
        }
        let running = await runningAVDs()
        let starting = starting.get()
        return .success(
            avds.map { avd in
                var device = avd
                if let serial = running[avd.id] {
                    device.state = .booted
                    device.serial = serial
                } else if starting.contains(avd.id) {
                    device.state = .booting
                }
                return device
            })
    }

    /// AVD name → serial for every running emulator, asking each which AVD it runs. Asked every
    /// time: a port another emulator used before may run a different AVD now.
    private func runningAVDs() async -> [String: String] {
        guard let serials = runningEmulators(), let adb = adb() else { return [:] }
        var known: [String: String] = [:]
        for serial in serials {
            guard let result = try? await adb.run(serial, ["emu", "avd", "name"], timeout: 10), result.status == 0 else {
                continue
            }
            // "Pixel_9_Pro" then "OK".
            let name = result.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && $0 != "OK" }
            if let name { known[serial] = name }
        }
        return Dictionary(known.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    }

    /// The AVDs in the AVD folder: one `<name>.ini` each, pointing at its folder with `config.ini`.
    static func readAVDs(in home: URL) -> [VirtualDevice] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return files.filter { $0.hasSuffix(".ini") }.compactMap { file -> VirtualDevice? in
            let name = String(file.dropLast(4))
            guard AndroidEmulators.isName(name) else { return nil }
            let pointer = iniValues(at: home.appendingPathComponent(file))
            let folder =
                pointer["path"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent("\(name).avd", isDirectory: true)
            let config = iniValues(at: folder.appendingPathComponent("config.ini"))
            guard !config.isEmpty else { return nil }
            let display = config["avd.ini.displayname"].flatMap { $0.isEmpty ? nil : $0 } ?? name.replacingOccurrences(of: "_", with: " ")
            let hardware = config["hw.device.name"] ?? ""
            let api = apiLevel(config["target"] ?? pointer["target"] ?? config["image.sysdir.1"] ?? "")
            return VirtualDevice(
                kind: .android, id: name, name: display,
                model: hardware.isEmpty ? "Android Emulator" : prettyHardwareName(hardware),
                system: api.map(androidName) ?? "Android", state: .shutdown,
                isTablet: hardware.contains("tablet"))
        }
    }

    static func iniValues(at file: URL) -> [String: String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            values[key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// 36 from "android-36" or "system-images/android-36/google_apis/arm64-v8a/".
    static func apiLevel(_ text: String) -> Int? {
        guard let range = text.range(of: "android-") else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }

    /// "Android 16 (API 36)".
    static func androidName(api: Int) -> String {
        let versions = [36: "16", 35: "15", 34: "14", 33: "13", 32: "12L", 31: "12", 30: "11", 29: "10", 28: "9"]
        guard let version = versions[api] else { return "Android API \(api)" }
        return "Android \(version) (API \(api))"
    }

    /// "pixel_9_pro" → "Pixel 9 Pro".
    static func prettyHardwareName(_ name: String) -> String {
        name.split(separator: "_").map { word in word.prefix(1).uppercased() + word.dropFirst() }.joined(separator: " ")
    }

    // MARK: Finding one

    /// A UDID, an AVD's name, a running emulator's serial, or a name only one device has.
    public func device(_ query: String) async throws -> VirtualDevice {
        try Self.resolve(query, in: await list())
    }

    static func resolve(_ query: String, in list: VirtualDeviceList) throws -> VirtualDevice {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { throw ToolFailure("id must be a simulator or AVD from list_virtual_devices.") }
        let devices = list.devices
        if let exact = devices.first(where: {
            $0.id.caseInsensitiveCompare(wanted) == .orderedSame || $0.serial == wanted
        }) {
            return exact
        }
        let named = devices.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            let choices = named.map { "\($0.name), \($0.system) (\($0.id))" }.joined(separator: "; ")
            throw ToolFailure("\"\(query)\" names several devices: \(choices). Pass the id.")
        }
        let problems = list.problems.isEmpty ? "" : " " + list.problems.joined(separator: " ")
        throw ToolFailure(
            "No simulator or AVD \"\(query)\". list_virtual_devices lists them."
                + (devices.isEmpty ? " There are none on this Mac." : "") + problems)
    }

    // MARK: Starting and stopping

    /// Boots a simulator or starts an AVD, and returns once it has finished booting. An AVD starts
    /// as Android Studio starts it, keeping what happens on it. `window` shows Simulator or the
    /// emulator's window; Mobdev shows the screen itself without one.
    public func boot(_ device: VirtualDevice, window: Bool = false) async throws -> VirtualDevice {
        var booted = device
        switch device.kind {
        case .simulator:
            if device.state != .booted {
                let result = try await runner.run(xcrun, ["simctl", "bootstatus", device.id, "-b"], timeout: 600)
                guard result.status == 0 else {
                    throw ToolFailure("\(device.name) did not boot: \(Self.lastLines(result.output))")
                }
            }
            if window {
                _ = try? await runner.run(
                    URL(fileURLWithPath: "/usr/bin/open"), ["-a", "Simulator", "--args", "-CurrentDeviceUDID", device.id],
                    timeout: 30)
            }
        case .android:
            if device.isRunning { return device }
            let inserted = starting.withLock { $0.insert(device.id).inserted }
            guard inserted else { throw ToolFailure("\(device.name) is starting already.") }
            defer { starting.withLock { _ = $0.remove(device.id) } }
            let serial = try await startEmulator(device.id, window)
            booted.serial = serial
        }
        booted.state = .booted
        return booted
    }

    /// Shuts a simulator down or asks an emulator to quit, and waits until it has.
    public func shutdown(_ device: VirtualDevice) async throws -> VirtualDevice {
        var stopped = device
        switch device.kind {
        case .simulator:
            if device.state != .shutdown {
                let result = try await runner.run(xcrun, ["simctl", "shutdown", device.id], timeout: 120)
                // Shutting down one that is down already fails; that is fine.
                guard result.status == 0 || result.output.contains("current state: Shutdown") else {
                    throw ToolFailure("\(device.name) did not shut down: \(Self.lastLines(result.output))")
                }
            }
        case .android:
            guard let serial = device.serial else { return device }
            guard let adb = adb() else { throw ToolFailure("adb is missing; install the Android SDK, e.g. with Android Studio.") }
            _ = try await adb.run(serial, ["emu", "kill"], timeout: 30)
            let deadline = Date().addingTimeInterval(60)
            while runningEmulators()?.contains(serial) == true {
                guard Date() < deadline else { throw ToolFailure("\(device.name) did not quit within a minute.") }
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
            stopped.serial = nil
        }
        stopped.state = .shutdown
        return stopped
    }

    // MARK: Creating and deleting simulators

    /// Creates an iOS simulator of a type, on an iOS version (the newest that runs it without one),
    /// and remembers that Mobdev made it. Not booted.
    public func createSimulator(type query: String, runtime: String? = nil, name: String? = nil) async throws
        -> VirtualDevice
    {
        let catalog = try await catalog()
        let type = try catalog.deviceType(query)
        let runtime = try catalog.runtime(runtime, for: type)
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? type.name
        // simctl would read a name starting with a dash as an option.
        guard !name.hasPrefix("-") else { throw ToolFailure("A simulator's name cannot start with \"-\".") }
        let udid = try await Simulators.create(name: name, type: type.id, runtime: runtime.id, runner: runner, xcrun: xcrun)
        recordsLock.withLock { _ in
            var records = readRecords()
            records.append(udid)
            writeRecords(records)
        }
        return VirtualDevice(
            kind: .simulator, id: udid, name: name, model: type.name, system: runtime.name, state: .shutdown,
            createdByMobdev: true, isTablet: type.family == "iPad")
    }

    /// Deletes a simulator Mobdev made, shutting it down first. Others are refused: they are the
    /// user's, with their apps and data.
    public func deleteSimulator(_ device: VirtualDevice) async throws {
        guard device.kind == .simulator else {
            throw ToolFailure("\(device.name) is an Android Virtual Device; delete AVDs in Android Studio's Device Manager.")
        }
        guard device.createdByMobdev else {
            throw ToolFailure(
                "\(device.name) was not made by Mobdev, so Mobdev leaves it alone. Delete it in Xcode's device window, or with xcrun simctl delete.")
        }
        if device.state != .shutdown { _ = try await shutdown(device) }
        let result = try await runner.run(xcrun, ["simctl", "delete", device.id], timeout: 120)
        guard result.status == 0 else { throw ToolFailure("\(device.name) was not deleted: \(Self.lastLines(result.output))") }
        recordsLock.withLock { _ in writeRecords(readRecords().filter { $0 != device.id }) }
    }

    private func readRecords() -> [String] {
        guard let data = try? Data(contentsOf: records) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func writeRecords(_ udids: [String]) {
        guard let data = try? JSONEncoder().encode(udids) else { return }
        try? FileManager.default.createDirectory(at: records.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: records, options: .atomic)
    }

    /// Forgets simulators that were deleted elsewhere, so a new one cannot inherit the mark.
    private func pruneRecords(keeping existing: Set<String>) {
        recordsLock.withLock { _ in
            let records = readRecords()
            let kept = records.filter(existing.contains)
            if kept.count != records.count { writeRecords(kept) }
        }
    }

    static func lastLines(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.suffix(3).joined(separator: " ")
    }
}

/// What `xcrun simctl list -j devicetypes runtimes devices` prints.
struct SimctlList: Decodable {
    struct DeviceType: Decodable {
        let identifier: String
        let name: String
        let productFamily: String?
    }

    struct Runtime: Decodable {
        let identifier: String
        let name: String
        let version: String?
        let platform: String?
        let isAvailable: Bool?
        let supportedDeviceTypes: [DeviceType]?

        var isIOS: Bool { platform.map { $0 == "iOS" } ?? identifier.contains(".iOS-") }
    }

    struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let deviceTypeIdentifier: String?
    }

    let devicetypes: [DeviceType]?
    let runtimes: [Runtime]?
    let devices: [String: [Device]]?
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Simulators that `Mobdev test --simulator` makes for one run and deletes afterwards, and what
/// `create_simulator` shares with it.
enum Simulators {
    /// "iPhone 17" or "iPhone 17,<runtime identifier>": creates, boots and waits until booted.
    static func create(_ spec: String) async throws -> String {
        let parts = spec.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let type = parts.first, !type.isEmpty else {
            throw ToolFailure("--simulator needs a simulator type, such as \"iPhone 17\" or \"iPhone 17,<runtime identifier>\".")
        }
        let runner = ProcessRunner()
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        let udid = try await create(name: "Mobdev \(type)", type: type, runtime: parts.count > 1 ? parts[1] : nil, runner: runner, xcrun: xcrun)
        let booted = try await runner.run(xcrun, ["simctl", "bootstatus", udid, "-b"], timeout: 600)
        guard booted.status == 0 else {
            delete(udid)
            throw ToolFailure("It did not boot: \(booted.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return udid
    }

    /// `simctl create`, returning the new UDID. A simulator made but reported as failed is deleted.
    static func create(name: String, type: String, runtime: String?, runner: CommandRunning, xcrun: URL) async throws
        -> String
    {
        let made = try await runner.run(xcrun, ["simctl", "create", name, type] + (runtime.map { [$0] } ?? []), timeout: 60)
        // simctl also prints which runtime it picked, so the UDID is the line that is one.
        guard let udid = createdUDID(made.output) else {
            throw ToolFailure(made.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard made.status == 0 else {
            delete(udid)
            throw ToolFailure(made.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return udid
    }

    /// The UDID in what `simctl create` printed, e.g. after "No runtime specified, using …".
    static func createdUDID(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last { UUID(uuidString: $0) != nil }
    }

    /// Shuts the simulator down and deletes it, waiting until it is gone.
    static func delete(_ udid: String) {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        for arguments in [["simctl", "shutdown", udid], ["simctl", "delete", udid]] {
            let process = Process()
            process.executableURL = xcrun
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}

/// Starting Android Virtual Devices: read-only copies for one `Mobdev test --emulator` run, so
/// several copies of one AVD run at once and nothing they do is saved to it, or the AVD itself for
/// `boot_device`.
enum AndroidEmulators {
    struct Started: Sendable {
        let avd: String
        let serial: String
        let process: Process
    }

    /// AVD names are letters, digits, dots, dashes and underscores.
    static func isName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// The SDK's `emulator` next to its `platform-tools/adb`.
    static func emulatorTool(nextTo adb: URL) -> URL {
        adb.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("emulator/emulator")
    }

    /// The first console port from 5554 whose pair (console, adb) is free and that no listed device uses.
    static func freePort(taken serials: Set<String>, isFree: (Int) -> Bool = AndroidEmulators.canBind) -> Int? {
        stride(from: 5554, through: 5682, by: 2).first { port in
            !serials.contains("emulator-\(port)") && isFree(port) && isFree(port + 1)
        }
    }

    static func canBind(_ port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// The emulator's arguments. Read-only copies save nothing; the AVD itself keeps its state
    /// and quick-boot snapshot as in Android Studio.
    static func arguments(avd: String, port: Int, readOnly: Bool, window: Bool) -> [String] {
        ["-avd", avd]
            + (readOnly ? ["-read-only", "-no-snapshot-save"] : [])
            + (window ? [] : ["-no-window", "-no-audio"])
            + ["-no-boot-anim", "-port", "\(port)"]
    }

    /// Starts the AVD and waits until Android has finished booting.
    static func start(_ avd: String, readOnly: Bool = true, window: Bool = false, timeout: TimeInterval = 600)
        async throws -> Started
    {
        guard let adb = ADB.find() else { throw ToolFailure("adb is missing; install the Android SDK, e.g. with Android Studio.") }
        let tool = emulatorTool(nextTo: adb.executable)
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw ToolFailure("The Android emulator is missing at \(tool.path); install it in Android Studio's SDK Manager.")
        }
        let listed = try await adb.runner.run(tool, ["-list-avds"], timeout: 30)
        let avds = listed.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard avds.contains(avd) else {
            throw ToolFailure("There is no AVD named \(avd). AVDs: \(avds.isEmpty ? "none" : avds.joined(separator: ", ")).")
        }
        let devices = try await adb.runner.run(adb.executable, ["devices"], timeout: 30)
        let serials = Set(devices.output.split(whereSeparator: \.isNewline).compactMap { $0.split(separator: "\t").first.map(String.init) })
        guard let port = freePort(taken: serials) else { throw ToolFailure("No free emulator port between 5554 and 5682.") }

        let log = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-emulator-\(port).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments(avd: avd, port: port, readOnly: readOnly, window: window)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let started = Started(avd: avd, serial: "emulator-\(port)", process: process)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // A caller that stops waiting, such as a relay after 90 s, ends the emulator too.
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                stop(started)
                throw error
            }
            guard process.isRunning else {
                let tail = (try? String(contentsOf: log, encoding: .utf8))?.split(whereSeparator: \.isNewline).suffix(3)
                    .joined(separator: " ") ?? ""
                // The AVD itself runs once: a second start fails with "Running multiple emulators
                // with the same AVD".
                throw ToolFailure("It quit while booting. \(tail)")
            }
            if Task.isCancelled { break }
            let booted = try? await adb.run(started.serial, ["shell", "getprop", "sys.boot_completed"], timeout: 10)
            if booted?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return started }
        }
        stop(started)
        throw ToolFailure("It did not finish booting within \(Int(timeout)) s.")
    }

    /// Asks the emulator to quit through adb and ends its process if it has not after 30 s.
    static func stop(_ started: Started) {
        if let adb = ADB.find() {
            let kill = Process()
            kill.executableURL = adb.executable
            kill.arguments = ["-s", started.serial, "emu", "kill"]
            kill.standardOutput = FileHandle.nullDevice
            kill.standardError = FileHandle.nullDevice
            try? kill.run()
            kill.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(30)
        while started.process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        if started.process.isRunning { started.process.terminate() }
    }
}
