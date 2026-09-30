import Foundation

/// An Android device the adb server lists as ready.
public struct ADBDevice: Sendable, Equatable {
    public var serial: String
    /// From `adb devices -l`, e.g. model "sdk_gphone64_arm64".
    public var properties: [String: String]

    public var isEmulator: Bool { serial.hasPrefix("emulator-") }
}

/// Android's debug bridge. Commands go through the `adb` tool of the Android SDK; the device list
/// comes straight from the adb server, so Mobdev never starts a server that is not running.
public struct ADB: Sendable {
    public let executable: URL
    public let runner: CommandRunning

    public init(executable: URL, runner: CommandRunning = ProcessRunner()) {
        self.executable = executable
        self.runner = runner
    }

    /// `ANDROID_HOME` or `ANDROID_SDK_ROOT`, then Android Studio's default SDK, then Homebrew.
    public static func find() -> ADB? {
        let environment = ProcessInfo.processInfo.environment
        var sdks = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]].compactMap { $0 }
        sdks.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk").path)
        let candidates = sdks.map { "\($0)/platform-tools/adb" } + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return ADB(executable: URL(fileURLWithPath: path))
    }

    /// The SDK's newest `aapt2`, which reads an .apk's package name.
    func aapt2() -> URL? {
        let tools = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build-tools")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: tools.path)) ?? []
        return versions.sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .map { tools.appendingPathComponent($0).appendingPathComponent("aapt2") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Commands

    /// `adb -s <serial> <arguments>`, stdout and stderr together.
    func run(_ serial: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        try await runner.run(executable, ["-s", serial] + arguments, timeout: timeout)
    }

    /// A command in the device's shell. Every value must already be quoted with `ADB.quote`.
    func shell(_ serial: String, _ command: String, timeout: TimeInterval = 30) async throws -> String {
        let result = try await run(serial, ["shell", command], timeout: timeout)
        guard result.status == 0 else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DeveloperError(message.isEmpty ? "adb failed with status \(result.status)." : "adb: \(message)")
        }
        return result.output
    }

    /// A single-quoted word for the device's shell.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Package names are letters, digits, underscores and dots, which keeps them safe in commands.
    static func checkPackage(_ name: String) throws -> String {
        let valid = !name.isEmpty && name.count <= 255
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }
        guard valid else { throw DeveloperError("\"\(name)\" is not an Android package name such as com.example.app.") }
        return name
    }

    // MARK: Device list

    /// The devices the adb server knows, or nil when no server runs on this Mac.
    public static func devices(port: UInt16 = 5037) -> [ADBDevice]? {
        guard let reply = try? hostRequest("host:devices-l", port: port) else { return nil }
        return parseDevices(reply)
    }

    /// Lines like "emulator-5554  device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 …".
    static func parseDevices(_ text: String) -> [ADBDevice] {
        text.split(separator: "\n").compactMap { line -> ADBDevice? in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            var properties: [String: String] = [:]
            for field in fields.dropFirst(2) {
                let parts = field.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { properties[parts[0]] = parts[1] }
            }
            return ADBDevice(serial: fields[0], properties: properties)
        }
    }

    /// One request of adb's host protocol: a 4-digit hex length and the request, answered with
    /// OKAY, a 4-digit hex length and the payload.
    private static func hostRequest(_ request: String, port: UInt16) throws -> String {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw DeviceIOError.socket }
        defer { close(socket) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw DeviceIOError.socket }
        let message = String(format: "%04x", request.utf8.count) + request
        try write(socket, Data(message.utf8))
        guard String(decoding: try read(socket, count: 4), as: UTF8.self) == "OKAY" else { throw DeviceIOError.badReply }
        guard let length = Int(String(decoding: try read(socket, count: 4), as: UTF8.self), radix: 16), length < 1 << 20
        else { throw DeviceIOError.badReply }
        return String(decoding: try read(socket, count: length), as: UTF8.self)
    }

    private static func write(_ socket: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(socket, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw DeviceIOError.closed }
                offset += written
            }
        }
    }

    private static func read(_ socket: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < count {
                let received = Darwin.read(socket, buffer.baseAddress! + offset, count - offset)
                guard received > 0 else { throw DeviceIOError.closed }
                offset += received
            }
        }
        return data
    }
}
