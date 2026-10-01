import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import MobdevCore

@Suite struct RunnerTests {
    // MARK: usbmuxd

    @Test func usbmuxPacketsCarryTheirHeader() throws {
        let packet = try USBMux.packet(USBMux.message("ListDevices"), tag: 7)
        func word(_ index: Int) -> UInt32 {
            packet[index * 4..<index * 4 + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }
        #expect(Int(word(0)) == packet.count)
        #expect(word(1) == 1)  // version: property lists
        #expect(word(2) == 8)  // message type: property list
        #expect(word(3) == 7)
        #expect(String(decoding: packet[16...], as: UTF8.self).hasPrefix("<?xml"))
        let (message, length) = try #require(try USBMux.message(from: packet + Data("next".utf8)))
        #expect(length == packet.count)
        #expect(message["MessageType"] as? String == "ListDevices")
        #expect(message["ProgName"] as? String == "Mobdev")
        #expect(try USBMux.message(from: packet.prefix(packet.count - 1)) == nil)
        #expect(try USBMux.message(from: packet.prefix(10)) == nil)
    }

    @Test func listedDevicesMatchUDIDsWithOrWithoutDash() {
        let reply: [String: Any] = [
            "DeviceList": [
                ["DeviceID": 4, "MessageType": "Attached",
                 "Properties": ["ConnectionType": "Network", "DeviceID": 4, "SerialNumber": "00008110-00AB12CD34EF5678"]],
                ["DeviceID": 9, "MessageType": "Attached",
                 "Properties": ["ConnectionType": "USB", "DeviceID": 9, "SerialNumber": "0000811000AB12CD34EF5678"]],
                ["MessageType": "Attached", "Properties": ["ConnectionType": "USB"]],
            ]
        ]
        let devices = USBMux.devices(from: reply)
        #expect(devices == [
            USBMux.Device(id: 4, serial: "00008110-00AB12CD34EF5678", connection: "Network"),
            USBMux.Device(id: 9, serial: "0000811000AB12CD34EF5678", connection: "USB"),
        ])
        #expect(USBMux.normalized("00008110-00ab12cd34ef5678") == USBMux.normalized(devices[1].serial))
    }

    @Test func connectPrefersUSBAndSendsThePortInNetworkByteOrder() throws {
        let fake = try FakeUSBMux(serials: [(4, "00008110-00AB12CD34EF5678", "Network"), (9, "0000811000AB12CD34EF5678", "USB")]) {
            _ in Data("pong".utf8)
        }
        defer { fake.stop() }
        let socket = try USBMux(socketPath: fake.path).connect(udid: "00008110-00AB12CD34EF5678", port: 47270)
        // After Connect the socket is the device's port itself.
        let deadline = Date().addingTimeInterval(5)
        try socket.write(Data("ping\r\n\r\n".utf8), until: deadline)
        #expect(try socket.readToEnd(until: deadline, limit: 1024) == Data("pong".utf8))
        let connect = try #require(fake.messages.get().last)
        #expect(connect.type == "Connect")
        #expect(connect.deviceID == 9)
        // 47270 is 0xB8A6; usbmuxd wants htons(port), read as a little-endian number: 0xA6B8.
        #expect(connect.port == 0xA6B8)
        #expect(fake.received.get() == Data("ping\r\n\r\n".utf8))
    }

    @Test func connectExplainsAMissingDeviceAndAClosedPort() throws {
        let fake = try FakeUSBMux(serials: [(2, "0000811000AB12CD34EF5678", "USB")], refuse: true) { _ in Data() }
        defer { fake.stop() }
        let usbmux = USBMux(socketPath: fake.path)
        #expect(throws: DeveloperError.self) { try usbmux.connect(udid: "00008030-0000000000000000", port: 47270) }
        do {
            _ = try usbmux.connect(udid: "00008110-00AB12CD34EF5678", port: 47270)
            Issue.record("connected to a closed port")
        } catch {
            #expect("\(error)".contains("Nothing listens on port 47270"))
        }
    }

    @Test func runnerClientReadsTheTreeThroughUSBMux() async throws {
        let tree: JSONValue = [
            "screen": ["width": 402, "height": 874], "apps": ["com.apple.Preferences"],
            "elements": [
                ["type": "Button", "label": "General", "identifier": "com.apple.settings.general", "value": "",
                 "placeholder": "", "frame": [16, 311, 370, 52], "enabled": true, "selected": false],
            ],
        ]
        let fake = try FakeUSBMux(serials: [(3, "0000811000AB12CD34EF5678", "USB")]) { _ in
            let body = tree.encoded()
            return Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                + body
        }
        defer { fake.stop() }
        let client = RunnerClient(
            route: .usb(udid: "00008110-00AB12CD34EF5678"), port: 47270, token: "secret",
            usbmux: USBMux(socketPath: fake.path))
        let elements = try await client.tree()
        #expect(elements.count == 1)
        #expect(elements[0].identifier == "com.apple.settings.general")
        #expect(abs(elements[0].center.x - 201.0 / 402) < 0.0001)
        let request = String(decoding: fake.received.get(), as: UTF8.self)
        #expect(request.hasPrefix("GET /tree HTTP/1.1\r\n"))
        #expect(request.contains("Authorization: Bearer secret\r\n"))
    }

    @Test func runnerErrorsAreShortened() async throws {
        let reason =
            "Failed to synthesize event: Neither element nor any descendant has keyboard focus. Event dispatch snapshot: Application, pid: 547\nElement subtree:\n …"
        let fake = try FakeUSBMux(serials: [(3, "0000811000AB12CD34EF5678", "USB")]) { _ in
            let body = JSONValue.object(["error": .string(reason)]).encoded()
            return Data("HTTP/1.1 500 Error\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        }
        defer { fake.stop() }
        let client = RunnerClient(
            route: .usb(udid: "0000811000AB12CD34EF5678"), port: 47270, token: "t", usbmux: USBMux(socketPath: fake.path))
        do {
            try await client.type("hello")
            Issue.record("typing succeeded")
        } catch {
            #expect(
                "\(error)"
                    == "Mobdev Runner: Failed to synthesize event: Neither element nor any descendant has keyboard focus.")
        }
        #expect(String(decoding: fake.received.get(), as: UTF8.self).hasSuffix("{\"text\":\"hello\"}"))
        #expect(throws: DeveloperError.self) { try RunnerClient.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{}".utf8)) }
    }

    // MARK: Tree

    @Test func treeBecomesElementsInFractionsOfTheScreen() throws {
        let json: JSONValue = [
            "screen": ["width": 400, "height": 800],
            "elements": [
                ["type": "Button", "label": "Save", "identifier": "save", "value": "", "frame": [100, 200, 200, 40],
                 "enabled": true],
                // XCTest lists some elements twice.
                ["type": "Button", "label": "Save", "identifier": "save", "value": "", "frame": [100, 200, 200, 40],
                 "enabled": true],
                // A field without a label is named by its placeholder.
                ["type": "SearchField", "label": "", "placeholder": "Search", "identifier": "", "value": "",
                 "frame": [20, 760, 360, 30], "enabled": true],
                ["type": "Switch", "label": "Wi-Fi", "identifier": "", "value": "1", "frame": [300, 300, 60, 30],
                 "enabled": false],
                // Off screen (the home screen's other page), empty, and half off the bottom.
                ["type": "Icon", "label": "Maps", "identifier": "Maps", "value": "", "frame": [-380, 90, 70, 90]],
                ["type": "Icon", "label": "Hidden", "identifier": "", "value": "", "frame": [0, 0, 0, 0]],
                ["type": "StaticText", "label": "Footer", "identifier": "", "value": "", "frame": [0, 780, 400, 40]],
            ],
        ]
        let elements = try RunnerClient.elements(fromTree: json)
        #expect(elements.map(\.label) == ["Save", "Search", "Wi-Fi", "Footer"])
        let save = elements[0]
        #expect(save.role == "Button")
        #expect(save.tappable)
        #expect(save.frame == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.05))
        #expect(elements[1].tappable)
        #expect(elements[2].value == "on")
        #expect(!elements[2].enabled)
        #expect(!elements[3].tappable)
        // Cut to what shows: 20 of its 40 points.
        #expect(elements[3].frame == CGRect(x: 0, y: 780.0 / 800, width: 1, height: 20.0 / 800))
        #expect(throws: DeveloperError.self) { try RunnerClient.elements(fromTree: ["elements": []]) }
    }

    // MARK: Teams

    /// Made with `openssl req -x509`: an Apple Development certificate of team Q1W2E3R4T5 whose
    /// common name carries another ID in parentheses, a newer one of team Z9Y8X7W6V5, and a
    /// Developer ID certificate, which does not sign development builds. Valid 2026-10-01 to 2126.
    static let certificates = """
        -----BEGIN CERTIFICATE-----
        MIICWTCCAf6gAwIBAgIUNiO1lLJiBa08nT21PWNp5IzkR0gwCgYIKoZIzj0EAwIw
        gZAxGjAYBgoJkiaJk/IsZAEBDApKQU5FVVNFUklEMTcwNQYDVQQDDC5BcHBsZSBE
        ZXZlbG9wbWVudDogSmFuZSBBcHBsZXNlZWQgKEFCQ0RFMTIzNDUpMRMwEQYDVQQL
        DApRMVcyRTNSNFQ1MRcwFQYDVQQKDA5KYW5lIEFwcGxlc2VlZDELMAkGA1UEBhMC
        VVMwIBcNMjYxMDAxMTgzNDQxWhgPMjEyNjA5MDcxODM0NDFaMIGQMRowGAYKCZIm
        iZPyLGQBAQwKSkFORVVTRVJJRDE3MDUGA1UEAwwuQXBwbGUgRGV2ZWxvcG1lbnQ6
        IEphbmUgQXBwbGVzZWVkIChBQkNERTEyMzQ1KTETMBEGA1UECwwKUTFXMkUzUjRU
        NTEXMBUGA1UECgwOSmFuZSBBcHBsZXNlZWQxCzAJBgNVBAYTAlVTMFkwEwYHKoZI
        zj0CAQYIKoZIzj0DAQcDQgAEjZpIiQj7nTCnmgN9+dMiLWjKx4VRT2fGccopiVkW
        J4F7mCVDkMxa4BeT5fHXkpi9fnZMv9rqaZZMA9XCnEtWvqMyMDAwHQYDVR0OBBYE
        FOt9vXHJZ6Umr0hLb6ttegYbZ5yiMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0E
        AwIDSQAwRgIhAPT2aGUqs/3k3UXFyH14t1c/i45Jf5zRItOdiQ85vYc/AiEA7NK1
        oTWv0K+y6JNIvBM1N6DRnmnu23qKYM+usBrv3ao=
        -----END CERTIFICATE-----
        -----BEGIN CERTIFICATE-----
        MIICGzCCAcCgAwIBAgIUJUNXPoL2dn+BaK2I2tYyLNoLtYQwCgYIKoZIzj0EAwIw
        cjE3MDUGA1UEAwwuQXBwbGUgRGV2ZWxvcG1lbnQ6IEphbmUgQXBwbGVzZWVkICha
        WVhXVjk4NzY1KTETMBEGA1UECwwKWjlZOFg3VzZWNTEVMBMGA1UECgwMRXhhbXBs
        ZSBHbWJIMQswCQYDVQQGEwJVUzAgFw0yNjEwMDExODM0NDNaGA8yMTI2MDkwNzE4
        MzQ0M1owcjE3MDUGA1UEAwwuQXBwbGUgRGV2ZWxvcG1lbnQ6IEphbmUgQXBwbGVz
        ZWVkIChaWVhXVjk4NzY1KTETMBEGA1UECwwKWjlZOFg3VzZWNTEVMBMGA1UECgwM
        RXhhbXBsZSBHbWJIMQswCQYDVQQGEwJVUzBZMBMGByqGSM49AgEGCCqGSM49AwEH
        A0IABOTv/ii0s9wtcOCin+E38hIe5lA7LPwtMJKG7HZ72Bx8Bf71Xzo4Ss9C8hbX
        GAGq63OWxL9KR3cDuTZLiR1Q9LujMjAwMB0GA1UdDgQWBBQ3K4yx82ECP2NyKz46
        EdXHujYfzjAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQCJ3wEG
        A+VJW7S9iW+UwydGVxbLPxv5TuMhmlwjAeh9agIhAItjc9ktNscwSFuNyekuqJph
        +kumWL7hBHZvo5f/EvRy
        -----END CERTIFICATE-----
        -----BEGIN CERTIFICATE-----
        MIICKzCCAdKgAwIBAgIUfHf+7EoHHs4KiUzM+mI7kP5f8VkwCgYIKoZIzj0EAwIw
        ezE+MDwGA1UEAww1RGV2ZWxvcGVyIElEIEFwcGxpY2F0aW9uOiBKYW5lIEFwcGxl
        c2VlZCAoUTFXMkUzUjRUNSkxEzARBgNVBAsMClExVzJFM1I0VDUxFzAVBgNVBAoM
        DkphbmUgQXBwbGVzZWVkMQswCQYDVQQGEwJVUzAgFw0yNjEwMDExODM0NDNaGA8y
        MTI2MDkwNzE4MzQ0M1owezE+MDwGA1UEAww1RGV2ZWxvcGVyIElEIEFwcGxpY2F0
        aW9uOiBKYW5lIEFwcGxlc2VlZCAoUTFXMkUzUjRUNSkxEzARBgNVBAsMClExVzJF
        M1I0VDUxFzAVBgNVBAoMDkphbmUgQXBwbGVzZWVkMQswCQYDVQQGEwJVUzBZMBMG
        ByqGSM49AgEGCCqGSM49AwEHA0IABBqgDA97ALlQ5dvnl+XMHdo+xaUjWJv31/kX
        f221DbzESGu7vU2LQIvpJ3dco5K1vZe/5lZIzMu3LbV54TF6kmCjMjAwMB0GA1Ud
        DgQWBBRc6Gi7f5clKj5TLIv10er0oyV++zAPBgNVHRMBAf8EBTADAQH/MAoGCCqG
        SM49BAMCA0cAMEQCIAzuGTJz72VTvif4TEHNgzZHJ7rkssgNGktx0kLrcWLRAiAy
        QHRIgu1qb7GaSVO8eO1Kvh7yqLSkzDsfyVHAKML9uQ==
        -----END CERTIFICATE-----
        """

    @Test func teamIsTheSubjectsOrganizationalUnit() throws {
        let certificates = DevelopmentTeam.certificates(fromPEM: Self.certificates)
        #expect(certificates.count == 3)
        let in2030 = Date(timeIntervalSince1970: 1_893_456_000)
        let (team, _) = try #require(DevelopmentTeam.team(of: certificates[0], now: in2030))
        // Not ABCDE12345, the certificate's own ID in its name.
        #expect(team == DevelopmentTeam(id: "Q1W2E3R4T5", name: "Jane Appleseed"))
        #expect(DevelopmentTeam.team(of: certificates[2], now: in2030) == nil)
        // The newest certificate's team comes first; Developer ID is left out.
        #expect(DevelopmentTeam.teams(in: certificates, now: in2030).map(\.id) == ["Z9Y8X7W6V5", "Q1W2E3R4T5"])
        // Not yet valid, and expired.
        #expect(DevelopmentTeam.teams(in: certificates, now: Date(timeIntervalSince1970: 1_700_000_000)).isEmpty)
        #expect(DevelopmentTeam.teams(in: certificates, now: Date(timeIntervalSince1970: 5_000_000_000)).isEmpty)
        #expect(UIRunner.isTeamID("Q1W2E3R4T5"))
        #expect(!UIRunner.isTeamID("q1w2e3r4t5"))
        #expect(!UIRunner.isTeamID("Q1W2E3R4T"))
        #expect(!UIRunner.isTeamID("Q1W2E3R4T5 OTHER=1"))
    }

    // MARK: Building and running

    @Test func xcodebuildFailuresAreSummarized() {
        let signing = """
            Command line invocation:
                /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build-for-testing -project MobdevRunner.xcodeproj
            /tmp/runner/project/MobdevRunner.xcodeproj: error: No Account for Team "Q1W2E3R4T5". Add a new account in Accounts settings or verify that your accounts have valid credentials. (in target 'MobdevRunner' from project 'MobdevRunner')
            /tmp/runner/project/MobdevRunner.xcodeproj: error: No profiles for 'dev.mobdev.runner.q1w2e3r4t5' were found (in target 'MobdevRunner' from project 'MobdevRunner')
            ** TEST BUILD FAILED **
            """
        #expect(
            UIRunner.summary(signing)
                == "No Account for Team \"Q1W2E3R4T5\". Add a new account in Accounts settings or verify that your accounts have valid credentials. No profiles for 'dev.mobdev.runner.q1w2e3r4t5' were found. Sign in to Xcode with the Apple Account of this team (in Xcode’s Settings), then try again."
        )
        let launch = """
            2026-10-01 20:23:20.000 xcodebuild[1:2] Writing error result bundle to /var/folders/x/ResultBundle.xcresult
            Testing failed:
            \tMobdevRunner-Runner encountered an error (The application could not be launched because the Developer App Certificate is not trusted.)

            ** TEST EXECUTE FAILED **
            """
        let summary = UIRunner.summary(launch) ?? ""
        #expect(summary.hasPrefix("MobdevRunner-Runner encountered an error (The application could not be launched"))
        #expect(summary.hasSuffix("trust your developer certificate, then try again."))
        #expect(UIRunner.summary("** TEST BUILD SUCCEEDED **\n") == nil)
    }

    @Test func iPhoneNeedsATeamBeforeAnythingIsBuilt() async throws {
        let commands = ScriptedCommands(build: CommandResult(status: 0, output: ""))
        let runner = UIRunner(udid: "00008110-00AB12CD34EF5678", simulator: false, folder: temporaryFolder(), commands: commands)
        defer { try? FileManager.default.removeItem(at: runner.folder) }
        runner.start(team: nil)
        let state = await wait(for: runner) { if case .failed = $0 { true } else { false } }
        #expect(state == .failed("Choose the development team to sign Mobdev Runner with."))
        #expect(commands.calls.get().isEmpty)
    }

    @Test func runnerBuildsWithTheTeamAndGivesUpAfterThreeQuickFailures() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let products = folder.appendingPathComponent("build/Build/Products")
        let commands = ScriptedCommands(build: CommandResult(status: 0, output: "** TEST BUILD SUCCEEDED **")) {
            try? FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: products.appendingPathComponent("MobdevRunner_iphoneos27.0-arm64.xctestrun").path, contents: Data())
        }
        commands.testOutput = ["Testing failed:", "\tDevice is locked (Unlock the device to continue)", "", "** TEST EXECUTE FAILED **"]
        let runner = UIRunner(
            udid: "00008110-00AB12CD34EF5678", simulator: false, folder: folder, port: 47999, commands: commands)
        runner.start(team: "Q1W2E3R4T5")
        let state = await wait(for: runner, timeout: 30) { if case .failed = $0 { true } else { false } }
        #expect(state == .failed("Device is locked (Unlock the device to continue) Unlock the iPhone and try again."))

        let calls = commands.calls.get()
        #expect(calls.count == 4)
        let build = calls[0]
        #expect(build.first == "build-for-testing")
        #expect(build.contains("-allowProvisioningUpdates"))
        #expect(build.contains("DEVELOPMENT_TEAM=Q1W2E3R4T5"))
        #expect(build.contains("PRODUCT_BUNDLE_IDENTIFIER=dev.mobdev.runner.q1w2e3r4t5"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("project/MobdevRunner.xcodeproj/project.pbxproj").path))
        let test = calls[1]
        #expect(test.first == "TEST_RUNNER_MOBDEV_RUNNER_PORT=47999")
        #expect(test[1].hasPrefix("TEST_RUNNER_MOBDEV_RUNNER_TOKEN=") && test[1].count > 40)
        #expect(test.contains("test-without-building"))
        // The folder can come back as /private/var/… for /var/….
        #expect(test.contains { $0.hasSuffix("/build/Build/Products/MobdevRunner_iphoneos27.0-arm64.xctestrun") })
        #expect(test.contains("id=00008110-00AB12CD34EF5678"))
        // Every start gets its own token.
        #expect(calls[2][1] != test[1])

        runner.stop()
        #expect(runner.state == .off)
        #expect(throws: ToolFailure.self) { try runner.client() }
    }

    @Test func settingsKeepTheRunnerChoices() throws {
        var settings = AppSettings()
        #expect(settings.runnerTeam.isEmpty && settings.runnerDevices.isEmpty)
        settings.runnerTeam = "Q1W2E3R4T5"
        settings.runnerDevices = ["00008110-00AB12CD34EF5678"]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.runnerTeam == "Q1W2E3R4T5")
        #expect(decoded.runnerDevices == ["00008110-00AB12CD34EF5678"])
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4686}"#.utf8))
        #expect(old.runnerTeam.isEmpty && old.runnerDevices.isEmpty)
    }

    // MARK: Helpers

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-runner-\(UUID().uuidString)", isDirectory: true)
    }

    private func wait(for runner: UIRunner, timeout: TimeInterval = 10, until done: (UIRunner.State) -> Bool) async
        -> UIRunner.State
    {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(runner.state), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        return runner.state
    }
}

/// Answers xcodebuild: `run` (the build) with a fixed result, `start` (the test) with lines and an
/// exit right away, as a test that cannot launch.
final class ScriptedCommands: CommandRunning, @unchecked Sendable {
    let build: CommandResult
    let onBuild: @Sendable () -> Void
    var testOutput: [String] = []
    /// Arguments of every call, without the executable; `env` calls without "/usr/bin/xcodebuild".
    let calls = Locked<[[String]]>([])

    init(build: CommandResult, onBuild: @escaping @Sendable () -> Void = {}) {
        self.build = build
        self.onBuild = onBuild
    }

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        calls.withLock { $0.append(arguments) }
        onBuild()
        return build
    }

    func start(
        _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningCommand {
        calls.withLock { $0.append(arguments.filter { $0 != "/usr/bin/xcodebuild" }) }
        let lines = testOutput
        DispatchQueue.global().async {
            for line in lines { onLine(line) }
            onExit(65)
        }
        return Stopped()
    }

    func runBinary(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, data: Data) {
        (1, Data())
    }

    private struct Stopped: RunningCommand {
        func stop() {}
    }
}

/// usbmuxd on a Unix socket in /tmp: lists the given devices, accepts Connect (or refuses it like a
/// closed port), and then serves one exchange as the device's port: what arrives goes to `answer`.
final class FakeUSBMux: @unchecked Sendable {
    struct Message: Equatable {
        var type: String
        var deviceID: Int?
        var port: Int?
    }

    let path = "/tmp/mobdev-usbmux-\(UUID().uuidString.prefix(8)).sock"
    let messages = Locked<[Message]>([])
    let received = Locked(Data())
    private let listener: Int32

    init(serials: [(Int, String, String)], refuse: Bool = false, answer: @escaping @Sendable (Data) -> Data) throws {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = self.path
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw DeveloperError("bind failed") }
        let devices: [[String: Any]] = serials.map { id, serial, connection in
            ["DeviceID": id, "MessageType": "Attached",
             "Properties": ["ConnectionType": connection, "DeviceID": id, "SerialNumber": serial]]
        }
        let reply = try USBMux.packet(["DeviceList": devices], tag: 1)
        let listener = self.listener, messages = self.messages, received = self.received
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                guard let (message, _) = Self.readPacket(client) else { continue }
                let type = message["MessageType"] as? String ?? ""
                messages.withLock {
                    $0.append(
                        Message(
                            type: type, deviceID: (message["DeviceID"] as? NSNumber)?.intValue,
                            port: (message["PortNumber"] as? NSNumber)?.intValue))
                }
                if type == "ListDevices" {
                    Self.write(client, reply)
                } else if type == "Connect" {
                    Self.write(client, try! USBMux.packet(["MessageType": "Result", "Number": refuse ? 3 : 0], tag: 1))
                    if refuse { continue }
                    // Now the device's port: read one request (headers and body), answer, close.
                    var request = Data()
                    var chunk = [UInt8](repeating: 0, count: 4096)
                    while !Self.isComplete(request) {
                        let count = read(client, &chunk, chunk.count)
                        guard count > 0 else { break }
                        request.append(contentsOf: chunk[0..<count])
                    }
                    received.set(request)
                    Self.write(client, answer(request))
                }
            }
        }
    }

    func stop() {
        close(listener)
        unlink(path)
    }

    private static func readPacket(_ client: Int32) -> ([String: Any], Int)? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let message = try? USBMux.message(from: data) { return message }
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return nil }
            data.append(contentsOf: chunk[0..<count])
        }
    }

    private static func isComplete(_ request: Data) -> Bool {
        guard let end = request.firstRange(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: request[..<end.lowerBound], as: UTF8.self).lowercased()
        let length = head.components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        return request.count - end.upperBound >= length
    }

    private static func write(_ client: Int32, _ data: Data) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(client, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}
