import Foundation
import Testing
@testable import MobdevCore

/// Answers mdfind and atos from a script and remembers every call.
final class SymbolCommands: CommandRunning, @unchecked Sendable {
    let calls = Locked<[(executable: String, arguments: [String], timeout: TimeInterval)]>([])
    let mdfind = Locked(CommandResult(status: 0, output: ""))
    let atos = Locked(CommandResult(status: 0, output: ""))
    /// How long each command takes; one longer than its timeout is killed then, as ProcessRunner does.
    let delay = Locked<TimeInterval>(0)

    func calls(to tool: String) -> [[String]] {
        calls.get().filter { ($0.arguments.first == "atos" ? "atos" : "mdfind") == tool }.map(\.arguments)
    }

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        calls.withLock { $0.append((executable.path, arguments, timeout)) }
        if arguments.first == "simctl" { return CommandResult(status: 0, output: "") }
        let delay = delay.get()
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(min(delay, max(0, timeout)) * 1_000_000_000))
            if delay > timeout { return CommandResult(status: -1, output: "") }
        }
        return arguments.first == "atos" ? atos.get() : mdfind.get()
    }

    func start(
        _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningCommand { ScriptedRunner.Stopper() }

    func runBinary(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, data: Data) {
        (1, Data())
    }
}

/// The start of Mach-O files: a header and load commands, LC_UUID among them, as `MachO` reads them.
enum MachOFixture {
    static func bytes(_ uuid: String) -> [UInt8] {
        let hex = Array(uuid.filter(\.isHexDigit))
        return stride(from: 0, to: hex.count, by: 2).map { UInt8(String(hex[$0...$0 + 1]), radix: 16)! }
    }

    /// One 64-bit arm64 slice: another load command, then the UUID.
    static func thin(_ uuid: String) -> Data {
        var data = Data()
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        for value: UInt32 in [0xfeed_facf, 0x0100_000c, 0, 0xa, 2, 16 + 24, 0, 0] { put(value) }
        for value: UInt32 in [0x26, 16, 0, 0] { put(value) }  // LC_FUNCTION_STARTS
        put(0x1b)
        put(24)
        data.append(contentsOf: bytes(uuid))
        return data
    }

    /// A universal file with one slice per UUID.
    static func fat(_ uuids: [String]) -> Data {
        var data = Data()
        func put(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        put(0xcafe_babe)
        put(UInt32(uuids.count))
        for index in uuids.indices {
            for value: UInt32 in [0x0100_000c, 0, UInt32(4096 * (index + 1)), 4096, 12] { put(value) }
        }
        for uuid in uuids {
            data.append(Data(count: data.count.isMultiple(of: 4096) ? 0 : 4096 - data.count % 4096))
            data.append(thin(uuid))
        }
        return data
    }
}

@Suite struct CrashSymbolTests {
    static let appUUID = "9C5F6B9E-3C4F-3B8A-9D4C-2E6C3F1A2B3C"
    let folder = Self.temporary.appendingPathComponent("mobdev-symbols-\(UUID().uuidString)")

    /// The real path, since folder listings give /private/var for /var and
    /// `resolvingSymlinksInPath()` takes /private off again.
    static let temporary: URL = {
        let path = FileManager.default.temporaryDirectory.path
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }()

    /// A crash of MyApp: two frames without a symbol and one with, all in its debug dylib, then
    /// one of a system library, which comes symbolicated.
    static func report(uuid: String = "9c5f6b9e-3c4f-3b8a-9d4c-2e6c3f1a2b3c", arch: String = "arm64") -> String {
        """
        {"app_name":"MyApp","timestamp":"2026-11-23 21:00:00.00 +0100","app_version":"1.0","build_version":"1","bundleID":"com.example.MyApp","bug_type":"309","os_version":"iPhone OS 27.0 (24A437)","name":"MyApp"}
        {"procName":"MyApp","exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"faultingThread":0,"threads":[{"triggered":true,"frames":[{"imageOffset":12996,"imageIndex":0},{"imageOffset":13200,"symbol":"ContentView.body.getter","symbolLocation":40,"imageIndex":0},{"imageOffset":14000,"imageIndex":0},{"imageOffset":114616,"symbol":"_dispatch_call_block_and_release","symbolLocation":32,"imageIndex":1}]}],"usedImages":[{"source":"P","arch":"\(arch)","base":4372086784,"size":65536,"uuid":"\(uuid)","path":"/private/var/containers/Bundle/Application/0A1B/MyApp.app/MyApp.debug.dylib","name":"MyApp.debug.dylib"},{"source":"P","arch":"arm64e","base":8158027776,"uuid":"6fae6738-0877-3f55-80b9-6ae42fcb8606","path":"/usr/lib/system/libdispatch.dylib","name":"libdispatch.dylib"}]}
        """
    }

    func write(_ data: Data, to path: String) throws -> URL {
        let file = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    func symbolicator(_ commands: SymbolCommands, folders: [URL] = [], budget: TimeInterval = 15) -> CrashSymbolicator {
        var symbolicator = CrashSymbolicator(runner: commands) { folders }
        symbolicator.budget = budget
        return symbolicator
    }

    @Test func parsingKeepsWhatAtosNeeds() throws {
        let report = try #require(CrashReport.parse(Self.report()))
        // The system library's frame has its symbol and no dSYM on the Mac.
        #expect(report.addresses.map(\.frame) == [0, 1, 2])
        let image = try #require(report.addresses.first?.image)
        #expect(image.uuid == Self.appUUID)
        #expect(image.arch == "arm64")
        #expect(image.base == 0x1_0498_c000)
        #expect(report.addresses.first?.address == 0x1_0498_c000 + 12996)
        #expect(report.frames[0] == "0  MyApp.debug.dylib  0x000000010498f2c4  (MyApp.debug.dylib + 12996, loaded at 0x10498c000)")

        // Nothing that could pass for an atos option or a Spotlight query gets through.
        #expect(try #require(CrashReport.parse(Self.report(arch: "arm64 -o /etc"))).addresses.first?.image.arch == "arm64")
        #expect(try #require(CrashReport.parse(Self.report(uuid: "9c5f6b9e || kMDItemFSName == *"))).addresses.isEmpty)
        #expect(CrashReport.uuid("9c5f6b9e3c4f3b8a9d4c2e6c3f1a2b3c") == Self.appUUID)
    }

    @Test func readsUUIDsOfThinAndUniversalFiles() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let thin = try write(MachOFixture.thin(Self.appUUID), to: "thin")
        #expect(MachO.uuids(of: thin) == [Self.appUUID])
        let other = "EC55921C-38BD-366A-94BA-8CB83572F80E"
        let fat = try write(MachOFixture.fat([other, Self.appUUID]), to: "fat")
        #expect(MachO.uuids(of: fat) == [other, Self.appUUID])
        let text = try write(Data("not a binary".utf8), to: "text")
        #expect(MachO.uuids(of: text).isEmpty)
        #expect(MachO.uuids(of: folder.appendingPathComponent("missing")).isEmpty)
    }

    @Test func aDSYMSpotlightFindsNamesEveryFrameOfItsImageInOneAtosCall() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let dwarf = try write(
            MachOFixture.fat(["EC55921C-38BD-366A-94BA-8CB83572F80E", Self.appUUID]),
            to: "Archive/MyApp.app.dSYM/Contents/Resources/DWARF/MyApp.debug.dylib")
        let dSYM = dwarf.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let commands = SymbolCommands()
        // A stale entry Spotlight still lists comes first.
        commands.mdfind.set(CommandResult(status: 0, output: "/nonexistent/Old.dSYM\n\(dSYM.path)\n"))
        commands.atos.set(
            CommandResult(
                status: 0,
                output: """
                    closure #1 in ContentView.body.getter (in MyApp.debug.dylib) (ContentView.swift:21)
                    atos[4242]: warning: something it says on standard error
                    ContentView.body.getter (in MyApp.debug.dylib) (ContentView.swift:18)
                    0x000000010498f6b0 (in MyApp.debug.dylib)

                    """))
        let report = try #require(CrashReport.parse(Self.report()))
        let named = await symbolicator(commands).symbolicate(report)

        #expect(commands.calls(to: "mdfind") == [["com_apple_xcode_dsym_uuids == \(Self.appUUID)"]])
        #expect(
            commands.calls(to: "atos") == [
                [
                    "atos", "-arch", "arm64", "-o", dwarf.path, "-l", "0x10498c000", "0x10498f2c4", "0x10498f390",
                    "0x10498f6b0",
                ]
            ])
        #expect(named.frames[0] == "0  MyApp.debug.dylib  0x000000010498f2c4  closure #1 in ContentView.body.getter (ContentView.swift:21)")
        #expect(named.frames[1] == "1  MyApp.debug.dylib  0x000000010498f390  ContentView.body.getter (ContentView.swift:18)")
        // An address atos could not name stays as it was.
        #expect(named.frames[2] == report.frames[2])
        #expect(named.frames[3] == report.frames[3])
        #expect(named.symbolFiles == [dSYM.path])
        #expect(named.summary.hasSuffix("\nSymbols from \(dSYM.path)"))
        #expect(named.json["symbol_files"] == .array([.string(dSYM.path)]))
    }

    @Test func withoutSymbolsTheReportStaysAsItWas() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        // A build of another version has the name but not the UUID.
        let stale = try write(MachOFixture.thin("EC55921C-38BD-366A-94BA-8CB83572F80E"), to: "Products/MyApp.app/MyApp.debug.dylib")
        let commands = SymbolCommands()
        let report = try #require(CrashReport.parse(Self.report()))
        let named = await symbolicator(commands, folders: [stale.deletingLastPathComponent().deletingLastPathComponent()])
            .symbolicate(report)
        #expect(named == report)
        #expect(commands.calls(to: "atos").isEmpty)
        #expect(!named.summary.contains("Symbols from"))
    }

    @Test func aFailingAtosLeavesTheFrames() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let dwarf = try write(MachOFixture.thin(Self.appUUID), to: "MyApp.app.dSYM/Contents/Resources/DWARF/MyApp.debug.dylib")
        let commands = SymbolCommands()
        commands.mdfind.set(CommandResult(status: 0, output: folder.appendingPathComponent("MyApp.app.dSYM").path))
        let report = try #require(CrashReport.parse(Self.report()))

        commands.atos.set(CommandResult(status: 1, output: "atos cannot load symbols for the file \(dwarf.path) for architecture arm64."))
        #expect(await symbolicator(commands).symbolicate(report) == report)
        // One answer short: which line belongs to which frame is unknown.
        commands.atos.set(CommandResult(status: 0, output: "main (in MyApp.debug.dylib) (main.swift:3)\n"))
        #expect(await symbolicator(commands).symbolicate(report) == report)
        #expect(commands.calls(to: "atos").count == 2)
    }

    @Test func derivedDataAndDebugBuildsWithoutADSYM() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let developer = folder.appendingPathComponent("Developer")
        let products = "Developer/Xcode/DerivedData/MyApp-abc/Build/Products"
        _ = try write(MachOFixture.thin("EC55921C-38BD-366A-94BA-8CB83572F80E"), to: "\(products)/Release-iphoneos/MyApp.app/MyApp.debug.dylib")
        let binary = try write(MachOFixture.thin(Self.appUUID), to: "\(products)/Debug-iphoneos/MyApp.app/MyApp.debug.dylib")
        let folders = CrashSymbolicator.productFolders(developer: developer, simulator: nil)
        #expect(Set(folders.map(\.lastPathComponent)) == ["Debug-iphoneos", "Release-iphoneos"])

        let commands = SymbolCommands()
        commands.mdfind.set(CommandResult(status: 0, output: ""))
        commands.atos.set(CommandResult(status: 0, output: "a (in MyApp.debug.dylib) (A.swift:1)\nb (in MyApp.debug.dylib) + 4\nc (in MyApp.debug.dylib) (C.swift:3)\n"))
        let report = try #require(CrashReport.parse(Self.report()))
        let named = await symbolicator(commands, folders: folders).symbolicate(report)
        #expect(commands.calls(to: "atos").first?[4] == binary.path)
        #expect(named.frames[1] == "1  MyApp.debug.dylib  0x000000010498f390  b + 4")
        #expect(named.symbolFiles == [binary.path])

        // A dSYM next to the build comes before the binary.
        let dwarf = try write(
            MachOFixture.thin(Self.appUUID), to: "\(products)/Debug-iphoneos/MyApp.app.dSYM/Contents/Resources/DWARF/MyApp.debug.dylib")
        _ = await symbolicator(commands, folders: folders).symbolicate(report)
        #expect(commands.calls(to: "atos").last?[4] == dwarf.path)
    }

    @Test func itStopsWithinItsBudget() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let commands = SymbolCommands()
        commands.delay.set(30)
        let report = try #require(CrashReport.parse(Self.report()))
        let started = Date()
        let named = await symbolicator(commands, budget: 0.5).symbolicate(report)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(named == report)
        #expect(commands.calls.get().allSatisfy { $0.timeout <= 0.5 })
        #expect(commands.calls(to: "atos").isEmpty)
    }

    @Test func crashReportsOfASimulatorUseItsInstalledBuild() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let udid = "6A4C2B1E-0000-4000-8000-1234567890AB"
        let developer = folder.appendingPathComponent("Developer")
        _ = try write(
            MachOFixture.thin(Self.appUUID),
            to: "Developer/CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/F00D/MyApp.app/MyApp.debug.dylib")
        let reports = folder.appendingPathComponent("DiagnosticReports")
        let text = Self.report()
            .replacingOccurrences(of: "\"bug_type\":\"309\"", with: "\"bug_type\":\"309\",\"platform\":7")
            .replacingOccurrences(of: "/private/var/containers/Bundle/Application/0A1B/", with: "/Users/USER/*/\(udid)/data/Containers/Bundle/Application/0A1B/")
        _ = try write(Data(text.utf8), to: "DiagnosticReports/MyApp-2026-11-23-210000.ips")

        let commands = SymbolCommands()
        commands.mdfind.set(CommandResult(status: 1, output: ""))
        commands.atos.set(CommandResult(status: 0, output: "a (in MyApp.debug.dylib) (A.swift:1)\nb (in MyApp.debug.dylib) (B.swift:2)\nc (in MyApp.debug.dylib) (C.swift:3)\n"))
        let control = DeviceControl(
            udid: udid, runner: commands, devicectl: URL(fileURLWithPath: "/usr/bin/true"), reportsFolder: folder,
            simulator: true, simctl: false, localReports: reports, developerFolder: developer)
        let tools = PhoneTools(phone: FakePhone(lines: [], apps: control), activity: ActivityLog(), settleDelay: 0)
        let output = try await tools.call(
            "crash_reports", arguments: ["name": "MyApp-2026-11-23-210000.ips"], source: "test", screenshotByDefault: false)
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("\n0  MyApp.debug.dylib  0x000000010498f2c4  a (A.swift:1)\n"))
        #expect(output.text.contains("\n2  MyApp.debug.dylib  0x000000010498f6b0  c (C.swift:3)\n"))
        #expect(output.text.contains("Symbols from \(developer.path)/CoreSimulator/Devices/\(udid)/data/Containers/Bundle/Application/F00D/MyApp.app/MyApp.debug.dylib"))
        #expect(output.data?["report"]?["symbol_files"]?.arrayValue?.count == 1)
    }

    @Test func theFolderABuildWasInstalledFromIsSearchedToo() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let udid = "6A4C2B1E-0000-4000-8000-1234567890AB"
        // Built with -derivedDataPath into the project, outside DerivedData.
        let app = folder.appendingPathComponent("project/build/Build/Products/Debug-iphonesimulator/MyApp.app")
        let binary = try write(MachOFixture.thin(Self.appUUID), to: "project/build/Build/Products/Debug-iphonesimulator/MyApp.app/MyApp.debug.dylib")
        try (["CFBundleIdentifier": "com.example.MyApp"] as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        let text = Self.report().replacingOccurrences(of: "\"bug_type\":\"309\"", with: "\"bug_type\":\"309\",\"platform\":7,\"udid\":\"\(udid)\"")
        _ = try write(Data(text.utf8), to: "DiagnosticReports/MyApp-2026-11-23-210000.ips")

        let commands = SymbolCommands()
        commands.atos.set(CommandResult(status: 0, output: "a (in MyApp.debug.dylib) (A.swift:1)\nb (in MyApp.debug.dylib) (B.swift:2)\nc (in MyApp.debug.dylib) (C.swift:3)\n"))
        let control = DeviceControl(
            udid: udid, runner: commands, devicectl: URL(fileURLWithPath: "/usr/bin/true"), reportsFolder: folder,
            simulator: true, simctl: true, localReports: folder.appendingPathComponent("DiagnosticReports"),
            developerFolder: folder.appendingPathComponent("Developer"))
        let before = try await control.crashReport(named: "MyApp-2026-11-23-210000.ips")
        #expect(before.report?.symbolFiles == [])
        _ = try await control.install(at: app)
        let after = try await control.crashReport(named: "MyApp-2026-11-23-210000.ips")
        #expect(after.report?.symbolFiles == [binary.path])
        #expect(after.report?.frames.first?.hasSuffix("  a (A.swift:1)") == true)
    }
}
