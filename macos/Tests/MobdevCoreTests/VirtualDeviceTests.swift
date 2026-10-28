import Foundation
import Testing
@testable import MobdevCore

/// Answers commands by the first rule whose text appears in the joined arguments, with a status,
/// and records every call.
final class FakeCommands: CommandRunning, @unchecked Sendable {
    let calls = Locked<[String]>([])
    var rules: [(match: String, status: Int32, output: String)] = []

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        let joined = ([executable.lastPathComponent] + arguments).joined(separator: " ")
        calls.withLock { $0.append(joined) }
        guard let rule = rules.first(where: { joined.contains($0.match) }) else { return CommandResult(status: 0, output: "") }
        return CommandResult(status: rule.status, output: rule.output)
    }

    func start(
        _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningCommand {
        throw ToolFailure("not used")
    }

    func runBinary(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, data: Data) {
        (0, Data())
    }
}

/// Listing, booting, shutting down, creating and deleting simulators and AVDs, with fake simctl,
/// adb and emulator.
@Suite struct VirtualDeviceTests {
    static let simctl = """
        {
          "devicetypes": [
            {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "name": "iPhone 17", "productFamily": "iPhone"},
            {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "name": "iPhone 17 Pro", "productFamily": "iPhone"},
            {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11", "name": "iPad Air 11-inch (M4)", "productFamily": "iPad"},
            {"identifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-11", "name": "Apple Watch Series 11", "productFamily": "Apple Watch"}
          ],
          "runtimes": [
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "name": "iOS 26.5", "version": "26.5", "platform": "iOS", "isAvailable": true,
             "supportedDeviceTypes": [{"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "name": "iPhone 17", "productFamily": "iPhone"}]},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "name": "iOS 27.0", "version": "27.0", "platform": "iOS", "isAvailable": true,
             "supportedDeviceTypes": [
               {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "name": "iPhone 17", "productFamily": "iPhone"},
               {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", "name": "iPhone 17 Pro", "productFamily": "iPhone"},
               {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11", "name": "iPad Air 11-inch (M4)", "productFamily": "iPad"}]},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-12-0", "name": "watchOS 12.0", "version": "12.0", "platform": "watchOS", "isAvailable": true,
             "supportedDeviceTypes": []}
          ],
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
              {"udid": "AAAAAAAA-0000-4000-8000-000000000001", "name": "iPhone 17 Pro", "state": "Shutdown", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"},
              {"udid": "AAAAAAAA-0000-4000-8000-000000000002", "name": "Checkout", "state": "Booted", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
              {"udid": "AAAAAAAA-0000-4000-8000-000000000003", "name": "Broken", "state": "Shutdown", "isAvailable": false,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
              {"udid": "AAAAAAAA-0000-4000-8000-000000000004", "name": "iPad Air 11-inch (M4)", "state": "Shutdown", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11"}
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
              {"udid": "AAAAAAAA-0000-4000-8000-000000000005", "name": "iPhone 17 Pro", "state": "Shutdown", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"}
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": [
              {"udid": "AAAAAAAA-0000-4000-8000-000000000006", "name": "Apple Watch Series 11", "state": "Booted", "isAvailable": true,
               "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.Apple-Watch-11"}
            ]
          }
        }
        """

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-virtual-\(UUID().uuidString)", isDirectory: true)
    var avdHome: URL { folder.appendingPathComponent("avd", isDirectory: true) }
    var records: URL { folder.appendingPathComponent("created-simulators.json") }

    /// A fake SDK whose adb answers "emu avd name" for running emulators.
    func makeDevices(
        _ commands: FakeCommands, running: Locked<[String]> = Locked([]),
        start: (@Sendable (String, Bool) async throws -> String)? = nil
    ) throws -> VirtualDevices {
        try FileManager.default.createDirectory(at: avdHome, withIntermediateDirectories: true)
        let adb = ADB(executable: URL(fileURLWithPath: "/sdk/platform-tools/adb"), runner: commands)
        return VirtualDevices(
            runner: commands, adb: { adb }, avdHome: avdHome, records: records, runningEmulators: { running.get() },
            startEmulator: start, pollInterval: 0.01)
    }

    func writeAVD(_ name: String, display: String, device: String, target: String) throws {
        let avd = avdHome.appendingPathComponent("\(name).avd", isDirectory: true)
        try FileManager.default.createDirectory(at: avd, withIntermediateDirectories: true)
        try "avd.ini.encoding=UTF-8\npath=\(avd.path)\ntarget=\(target)\n"
            .write(to: avdHome.appendingPathComponent("\(name).ini"), atomically: true, encoding: .utf8)
        try "avd.ini.displayname=\(display)\nhw.device.name=\(device)\nimage.sysdir.1=system-images/\(target)/google_apis/arm64-v8a/\n"
            .write(to: avd.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
    }

    func simctlCommands() -> FakeCommands {
        let commands = FakeCommands()
        commands.rules = [("simctl list -j", 0, Self.simctl)]
        return commands
    }

    @Test func listsIOSSimulatorsAndAVDsRunningFirst() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let commands = simctlCommands()
        commands.rules.append(("emu avd name", 0, "Pixel_9_Pro\r\nOK\r\n"))
        let devices = try makeDevices(commands, running: Locked(["emulator-5554"]))
        try writeAVD("Pixel_9_Pro", display: "Pixel 9 Pro", device: "pixel_9_pro", target: "android-36")
        try writeAVD("Small_Phone", display: "", device: "small_phone", target: "android-34")
        try Data("not an avd".utf8).write(to: avdHome.appendingPathComponent("stray.txt"))

        let list = await devices.list()
        #expect(list.problems.isEmpty)
        // No watch, and nothing simctl marks unavailable.
        #expect(list.devices.map(\.name) == [
            "Checkout", "Pixel 9 Pro", "iPad Air 11-inch (M4)", "iPhone 17 Pro", "iPhone 17 Pro", "Small Phone",
        ])
        let checkout = try #require(list.devices.first)
        #expect(checkout.state == .booted && checkout.deviceID == checkout.id && checkout.model == "iPhone 17")
        #expect(checkout.system == "iOS 27.0")
        let pixel = list.devices[1]
        #expect(pixel.kind == .android && pixel.id == "Pixel_9_Pro" && pixel.state == .booted)
        #expect(pixel.serial == "emulator-5554" && pixel.deviceID == "emulator-5554")
        #expect(pixel.system == "Android 16 (API 36)" && pixel.model == "Pixel 9 Pro")
        // The newer iOS first between two of the same name.
        #expect(list.devices[3].system == "iOS 27.0" && list.devices[4].system == "iOS 26.5")
        #expect(list.devices[2].isTablet)
        let small = list.devices[5]
        #expect(small.state == .shutdown && small.deviceID == nil && small.system == "Android 14 (API 34)")

        // A serial's AVD is asked once.
        _ = await devices.list()
        #expect(commands.calls.get().filter { $0.contains("emu avd name") }.count == 1)
    }

    @Test func withoutXcodeTheListSaysWhy() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let commands = FakeCommands()
        commands.rules = [("simctl", 1, "xcrun: error: unable to find utility \"simctl\", not a developer tool or in PATH")]
        let list = await (try makeDevices(commands)).list()
        #expect(list.devices.isEmpty)
        #expect(list.problems == ["Simulators need Xcode. Install it, then run sudo xcode-select -s /Applications/Xcode.app."])
    }

    @Test func findsDevicesByIdSerialOrUniqueName() throws {
        let list = VirtualDeviceList(devices: [
            VirtualDevice(kind: .simulator, id: "AAAA-1", name: "iPhone 17 Pro", model: "iPhone 17 Pro", system: "iOS 27.0", state: .shutdown),
            VirtualDevice(kind: .simulator, id: "AAAA-2", name: "iPhone 17 Pro", model: "iPhone 17 Pro", system: "iOS 26.5", state: .shutdown),
            VirtualDevice(kind: .simulator, id: "AAAA-3", name: "Checkout", model: "iPhone 17", system: "iOS 27.0", state: .booted),
            VirtualDevice(
                kind: .android, id: "Pixel_9_Pro", name: "Pixel 9 Pro", model: "Pixel 9 Pro", system: "Android 16 (API 36)",
                state: .booted, serial: "emulator-5554"),
        ])
        #expect(try VirtualDevices.resolve("aaaa-3", in: list).name == "Checkout")
        #expect(try VirtualDevices.resolve("checkout", in: list).id == "AAAA-3")
        #expect(try VirtualDevices.resolve("emulator-5554", in: list).id == "Pixel_9_Pro")
        #expect(try VirtualDevices.resolve("Pixel 9 Pro", in: list).id == "Pixel_9_Pro")
        #expect(throws: ToolFailure.self) { try VirtualDevices.resolve("iPhone 17 Pro", in: list) }
        do {
            _ = try VirtualDevices.resolve("iPhone 17 Pro", in: list)
        } catch {
            #expect(String(describing: error).contains("names several devices: iPhone 17 Pro, iOS 27.0 (AAAA-1); iPhone 17 Pro, iOS 26.5 (AAAA-2)"))
        }
        #expect(throws: ToolFailure.self) { try VirtualDevices.resolve("Galaxy", in: list) }
    }

    @Test func createsOnTheNewestFittingIOSAndRemembersIt() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let commands = simctlCommands()
        commands.rules.insert(("simctl create", 0, "BBBBBBBB-0000-4000-8000-000000000009\n"), at: 0)
        let devices = try makeDevices(commands)

        let created = try await devices.createSimulator(type: "iphone 17 pro")
        #expect(created.id == "BBBBBBBB-0000-4000-8000-000000000009" && created.createdByMobdev)
        #expect(created.name == "iPhone 17 Pro" && created.system == "iOS 27.0" && created.state == .shutdown)
        #expect(commands.calls.get().contains(
            "xcrun simctl create iPhone 17 Pro com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0"))
        let saved = try JSONDecoder().decode([String].self, from: Data(contentsOf: records))
        #expect(saved == ["BBBBBBBB-0000-4000-8000-000000000009"])

        // "26" picks iOS 26.5, and a name of its own.
        let older = try await devices.createSimulator(type: "iPhone 17", runtime: "26", name: "Old iOS")
        #expect(older.system == "iOS 26.5" && older.name == "Old iOS")
        #expect(commands.calls.get().last?.hasSuffix("create Old iOS com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-26-5") == true)
    }

    @Test func unknownTypesAndVersionsSayWhatThereIs() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let devices = try makeDevices(simctlCommands())
        await #expect {
            try await devices.createSimulator(type: "iPhone 3G")
        } throws: { error in
            String(describing: error) == "No simulator type \"iPhone 3G\". iPhones: iPhone 17 Pro, iPhone 17; iPads too, such as iPad Air 11-inch (M4)."
        }
        await #expect {
            try await devices.createSimulator(type: "iPhone 17 Pro", runtime: "26.5")
        } throws: { error in
            String(describing: error) == "No iOS 26.5 for iPhone 17 Pro. It runs: iOS 27.0."
        }
    }

    @Test func deletesOnlySimulatorsMobdevMade() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let commands = simctlCommands()
        let devices = try makeDevices(commands)
        let theirs = try await devices.device("Checkout")
        await #expect {
            try await devices.deleteSimulator(theirs)
        } throws: { error in
            String(describing: error).hasPrefix("Checkout was not made by Mobdev, so Mobdev leaves it alone.")
        }
        #expect(!commands.calls.get().contains { $0.contains("simctl delete") || $0.contains("simctl shutdown") })

        // Marked as made by Mobdev, and booted: shut down, then deleted, then forgotten.
        try JSONEncoder().encode(["AAAAAAAA-0000-4000-8000-000000000002"]).write(to: records)
        let ours = try await devices.device("Checkout")
        #expect(ours.createdByMobdev)
        try await devices.deleteSimulator(ours)
        let calls = commands.calls.get().filter { $0.contains("shutdown") || $0.contains("delete") }
        #expect(calls == [
            "xcrun simctl shutdown AAAAAAAA-0000-4000-8000-000000000002", "xcrun simctl delete AAAAAAAA-0000-4000-8000-000000000002",
        ])
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: records)).isEmpty)
    }

    @Test func recordsOfSimulatorsDeletedElsewhereAreDropped() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let devices = try makeDevices(simctlCommands())
        try JSONEncoder().encode(["AAAAAAAA-0000-4000-8000-000000000001", "GONE"]).write(to: records)
        let list = await devices.list()
        #expect(list.devices.first { $0.id == "AAAAAAAA-0000-4000-8000-000000000001" }?.createdByMobdev == true)
        #expect(try JSONDecoder().decode([String].self, from: Data(contentsOf: records)) == ["AAAAAAAA-0000-4000-8000-000000000001"])
    }

    @Test func bootsAndShutsDownSimulators() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let commands = simctlCommands()
        let devices = try makeDevices(commands)
        let simulator = try await devices.device("AAAAAAAA-0000-4000-8000-000000000001")
        let booted = try await devices.boot(simulator, window: true)
        #expect(booted.state == .booted && booted.deviceID == simulator.id)
        #expect(commands.calls.get().suffix(2) == [
            "xcrun simctl bootstatus AAAAAAAA-0000-4000-8000-000000000001 -b",
            "open -a Simulator --args -CurrentDeviceUDID AAAAAAAA-0000-4000-8000-000000000001",
        ])
        let stopped = try await devices.shutdown(booted)
        #expect(stopped.state == .shutdown)
        #expect(commands.calls.get().last == "xcrun simctl shutdown AAAAAAAA-0000-4000-8000-000000000001")

        commands.rules.insert(("bootstatus", 164, "Unable to boot: no space left"), at: 0)
        await #expect {
            try await devices.boot(simulator)
        } throws: { error in
            String(describing: error) == "iPhone 17 Pro did not boot: Unable to boot: no space left"
        }
    }

    @Test func startsAndStopsAVDs() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let commands = simctlCommands()
        let running = Locked<[String]>([])
        let started = Locked<[String]>([])
        let devices = try makeDevices(commands, running: running) { avd, window in
            started.withLock { $0.append("\(avd) window: \(window)") }
            running.set(["emulator-5556"])
            return "emulator-5556"
        }
        try writeAVD("Pixel_9_Pro", display: "Pixel 9 Pro", device: "pixel_9_pro", target: "android-36")
        let avd = try await devices.device("Pixel_9_Pro")
        #expect(avd.state == .shutdown)
        let booted = try await devices.boot(avd)
        #expect(booted.serial == "emulator-5556" && booted.deviceID == "emulator-5556")
        #expect(started.get() == ["Pixel_9_Pro window: false"])
        // The serial is known without asking the emulator.
        #expect(try await devices.device("Pixel_9_Pro").state == .booted)
        #expect(!commands.calls.get().contains { $0.contains("emu avd name") })

        // emu kill, then waiting until adb no longer lists it.
        let quits = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            running.set([])
        }
        defer { quits.cancel() }
        let stopped = try await devices.shutdown(booted)
        #expect(stopped.state == .shutdown && stopped.serial == nil)
        #expect(commands.calls.get().contains("adb -s emulator-5556 emu kill"))
        #expect(try await devices.device("Pixel_9_Pro").state == .shutdown)
    }

    @Test func emulatorArgumentsKeepTheAVDOrCopyIt() {
        #expect(AndroidEmulators.arguments(avd: "Pixel_9_Pro", port: 5556, readOnly: false, window: false) == [
            "-avd", "Pixel_9_Pro", "-no-window", "-no-audio", "-no-boot-anim", "-port", "5556",
        ])
        #expect(AndroidEmulators.arguments(avd: "Pixel_9_Pro", port: 5554, readOnly: true, window: true) == [
            "-avd", "Pixel_9_Pro", "-read-only", "-no-snapshot-save", "-no-boot-anim", "-port", "5554",
        ])
    }

    @Test func avdHomeFollowsTheSDKsVariables() {
        #expect(VirtualDevices.defaultAVDHome(environment: ["ANDROID_AVD_HOME": "/x/avd"]).path == "/x/avd")
        #expect(VirtualDevices.defaultAVDHome(environment: ["ANDROID_USER_HOME": "/y"]).path == "/y/avd")
        #expect(VirtualDevices.defaultAVDHome(environment: [:]).path.hasSuffix("/.android/avd"))
    }

    // MARK: Tools

    func tools(_ devices: VirtualDevices, running: [any Device] = []) -> DeviceTools {
        DeviceTools(
            hub: DeviceHub(keyboardLayout: .us) {}, emulators: EmulatorHub(devices: running), settleDelay: 0,
            virtualDevices: devices)
    }

    func call(_ tools: DeviceTools, _ name: String, _ arguments: JSONValue = [:]) async throws -> ToolOutput {
        try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
    }

    @Test func toolsListAndCreateWithoutADevice() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let commands = simctlCommands()
        commands.rules.insert(("simctl create", 0, "BBBBBBBB-0000-4000-8000-000000000009\n"), at: 0)
        let tools = tools(try makeDevices(commands))
        for name in VirtualDeviceTools.names { #expect(tools.definitions.contains { $0.name == name }) }

        let list = try await call(tools, "list_virtual_devices")
        #expect(!list.isError)
        #expect(list.text.hasPrefix("Checkout: iPhone 17, iOS 27.0, booted. id: AAAAAAAA-0000-4000-8000-000000000002\n"))
        #expect(list.data?["devices"]?.arrayValue?.count == 4)

        let created = try await call(tools, "create_simulator", ["device_type": "iPhone 17 Pro", "boot": false])
        #expect(created.text == "Created iPhone 17 Pro (iPhone 17 Pro, iOS 27.0).")
        #expect(created.data?["created_by_mobdev"]?.boolValue == true)

        let booted = try await call(tools, "create_simulator", ["device_type": "iPhone 17 Pro"])
        #expect(booted.text.hasPrefix(
            "Created iPhone 17 Pro and booted it (iPhone 17 Pro, iOS 27.0). Its device id: BBBBBBBB-0000-4000-8000-000000000009. Mobdev does not show simulators"))

        let missing = try await call(tools, "boot_device", ["id": "Galaxy"])
        #expect(missing.isError && missing.text.hasPrefix("No simulator or AVD \"Galaxy\"."))
    }

    @Test func shuttingDownADeviceARunHoldsIsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let commands = simctlCommands()
        let running = FakeDevice(id: "AAAAAAAA-0000-4000-8000-000000000002", name: "Checkout", kind: .simulator)
        let tools = tools(try makeDevices(commands), running: [running])
        let phoneTools = tools.tools(for: running)
        let release = Locked(false)
        let run = Task {
            try await phoneTools.holding("a flow", source: "local") {
                while !release.get() { try await Task.sleep(nanoseconds: 10_000_000) }
            }
        }
        while phoneTools.hold.get() == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let refused = try await call(tools, "shutdown_device", ["id": "Checkout"])
        #expect(refused.isError && refused.text.hasPrefix("Busy: a flow from local is running on this device."))
        #expect(!commands.calls.get().contains { $0.contains("simctl shutdown") })
        release.set(true)
        try await run.value

        let done = try await call(tools, "shutdown_device", ["id": "Checkout"])
        #expect(done.text == "Checkout is shut down (iPhone 17, iOS 27.0).", "\(done.text)")
        #expect(commands.calls.get().contains("xcrun simctl shutdown AAAAAAAA-0000-4000-8000-000000000002"))
    }
}
