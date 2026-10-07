import Darwin
import Foundation

/// A device whose traffic Mobdev sends through its own proxy and logs: Android, through adb.
public protocol NetworkProxyBackend: Sendable {
    var log: NetworkLog { get }
    /// The proxy as the device reaches it, e.g. "10.0.2.2:53211", while capturing.
    var address: String? { get }
    /// Starts the proxy and points the device at it. Returns `address`.
    func start() async throws -> String
    /// Removes the device's proxy setting and stops the proxy. False when nothing was captured.
    func stop() async throws -> Bool
    /// Canned answers for plain HTTP, newest first when several match.
    var mocks: [ResponseMock] { get }
    func addMock(_ mock: ResponseMock)
    /// Removes every mock and says how many there were.
    func clearMocks() -> Int
}

/// Android's traffic through Mobdev's proxy: `settings put global http_proxy` points the device at
/// it, `:0` removes it again. An emulator reaches the Mac's 127.0.0.1 as 10.0.2.2; a phone gets
/// `adb reverse`, so it reaches the proxy as its own 127.0.0.1.
///
/// A device left with the setting has no network, so it is removed whenever capture ends: on
/// stop_network_capture, when the device goes away or Mobdev stops looking for it, and when Mobdev
/// or a command-line run quits (`stopAll`). What a crash leaves behind is noted in a file per
/// device and removed the next time a Mobdev sees the device and the process that set it is gone.
public final class AndroidNetworkCapture: NetworkProxyBackend, @unchecked Sendable {
    let serial: String
    let adb: ADB
    public let log = NetworkLog()
    private let isEmulator: @Sendable () -> Bool
    private let records: URL
    private let mockList = Locked<[ResponseMock]>([])
    private let active = Locked<Active?>(nil)
    /// Set while starting or stopping, so two calls at once cannot start two proxies.
    private let busy = Locked(false)

    struct Active {
        var proxy: HTTPProxy
        var address: String
        /// The port `adb reverse` forwards on a phone.
        var reversePort: UInt16?
    }

    init(
        serial: String, adb: ADB, records: URL = MobdevPaths.networkCaptureRecords,
        isEmulator: @escaping @Sendable () -> Bool
    ) {
        self.serial = serial
        self.adb = adb
        self.records = records
        self.isEmulator = isEmulator
    }

    public var address: String? { active.get()?.address }
    public var mocks: [ResponseMock] { mockList.get() }

    public func addMock(_ mock: ResponseMock) {
        mockList.withLock { list in
            list.removeAll { $0.url == mock.url }
            list.append(mock)
        }
    }

    public func clearMocks() -> Int {
        mockList.withLock { list in
            defer { list = [] }
            return list.count
        }
    }

    /// Values of http_proxy that mean none.
    static func isUnset(_ value: String) -> Bool {
        ["", "null", ":0"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func claim() throws {
        guard busy.withLock({ busy in
            defer { busy = true }
            return !busy
        }) else { throw DeveloperError("Network capture is starting or stopping already. Try again in a moment.") }
    }

    public func start() async throws -> String {
        try claim()
        defer { busy.set(false) }
        if let active = active.get() { return active.address }
        let current = try await adb.shell(serial, "settings get global http_proxy", timeout: 15)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !Self.isUnset(current) {
            // Mobdev's own, left behind by a run that ended without removing it, is replaced.
            guard let record = Self.record(serial, in: records), record.address == current, !Self.isRunning(record)
            else {
                throw DeveloperError(
                    "Android already sends its traffic through the proxy \(current), which Mobdev would replace. Remove it (adb -s \(serial) shell settings put global http_proxy :0) or stop the tool that set it, then start again.")
            }
        }
        let proxy = HTTPProxy(log: log, mocks: mockList)
        try await proxy.start()
        let port = proxy.port
        var host = "10.0.2.2"
        var reversePort: UInt16?
        if !isEmulator() {
            let result = try await adb.run(serial, ["reverse", "tcp:\(port)", "tcp:\(port)"], timeout: 15)
            guard result.status == 0 else {
                proxy.stop()
                throw DeveloperError(
                    "adb reverse failed, so the phone cannot reach Mobdev's proxy: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            host = "127.0.0.1"
            reversePort = port
        }
        let address = "\(host):\(port)"
        // Noted before the setting changes, so a crash right after still leaves a way back.
        let record = Record(
            address: address, pid: getpid(), process: Self.processName(getpid()) ?? "", reversePort: reversePort)
        Self.writeRecord(record, serial, in: records)
        let started = Active(proxy: proxy, address: address, reversePort: reversePort)
        Self.running.withLock { $0[ObjectIdentifier(self)] = (serial, adb, records, started) }
        active.set(started)
        do {
            _ = try await adb.shell(serial, "settings put global http_proxy \(address)", timeout: 15)
        } catch {
            _ = try? await end()
            throw error
        }
        return address
    }

    public func stop() async throws -> Bool {
        try claim()
        defer { busy.set(false) }
        return try await end()
    }

    private func end() async throws -> Bool {
        guard let current = active.withLock({ active -> Active? in
            defer { active = nil }
            return active
        }) else { return false }
        Self.running.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(self)) }
        current.proxy.stop()
        var failure: String?
        do {
            _ = try await adb.shell(serial, "settings put global http_proxy :0", timeout: 15)
        } catch {
            failure = String(describing: error)
        }
        if let port = current.reversePort {
            _ = try? await adb.run(serial, ["reverse", "--remove", "tcp:\(port)"], timeout: 15)
        }
        if let failure {
            throw DeveloperError(
                "Mobdev stopped its proxy but could not remove it from Android's settings (\(failure)), so the device may have no network. Run adb -s \(serial) shell settings put global http_proxy :0.")
        }
        Self.removeRecord(serial, in: records)
        return true
    }

    /// When the device goes away or Mobdev stops looking for it: the proxy ends, and the setting
    /// is removed if the device still answers. If it does not, the note stays for next time.
    func close() {
        guard let current = active.withLock({ active -> Active? in
            defer { active = nil }
            return active
        }) else { return }
        Self.running.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(self)) }
        current.proxy.stop()
        Self.clearNow(serial: serial, adb: adb, records: records, reversePort: current.reversePort)
    }

    // MARK: Every capture of this process

    private static let running = Locked<[ObjectIdentifier: (serial: String, adb: ADB, records: URL, active: Active)]>([:])

    /// Removes every proxy setting this process made, waiting for adb. Called when Mobdev quits and
    /// before a command-line run exits, which `close()` on a background queue would not outlive.
    public static func stopAll() {
        let all = running.withLock { running in
            defer { running = [:] }
            return Array(running.values)
        }
        for capture in all {
            capture.active.proxy.stop()
            clearNow(
                serial: capture.serial, adb: capture.adb, records: capture.records,
                reversePort: capture.active.reversePort)
        }
    }

    /// Removes the setting with adb, blocking at most a few seconds; the note goes once it worked.
    private static func clearNow(serial: String, adb: ADB, records: URL, reversePort: UInt16?) {
        let result = try? adb.runner.runBinary(
            adb.executable, ["-s", serial, "shell", "settings put global http_proxy :0"], timeout: 5)
        if let port = reversePort {
            _ = try? adb.runner.runBinary(adb.executable, ["-s", serial, "reverse", "--remove", "tcp:\(port)"], timeout: 5)
        }
        if result?.status == 0 {
            removeRecord(serial, in: records)
        } else {
            Log.info("could not remove Mobdev's proxy from \(serial) now; it is removed when the device is back")
        }
    }

    // MARK: What a crash leaves behind

    struct Record: Codable, Equatable {
        var address: String
        var pid: Int32
        /// The process's name, so a reused process id is not mistaken for Mobdev.
        var process: String
        var reversePort: UInt16?
    }

    /// Run when a device appears: removes a proxy setting a Mobdev left on it, once the process that
    /// set it is gone. A process that still runs, this one included, keeps its own.
    static func clearLeftover(serial: String, adb: ADB, records: URL = MobdevPaths.networkCaptureRecords) async {
        guard let record = record(serial, in: records), !isRunning(record) else { return }
        guard let current = try? await adb.shell(serial, "settings get global http_proxy", timeout: 10) else { return }
        if current.trimmingCharacters(in: .whitespacesAndNewlines) == record.address {
            guard (try? await adb.shell(serial, "settings put global http_proxy :0", timeout: 10)) != nil else { return }
            Log.info("removed the proxy setting \(record.address) a Mobdev left on \(serial)")
        }
        if let port = record.reversePort {
            _ = try? await adb.run(serial, ["reverse", "--remove", "tcp:\(port)"], timeout: 10)
        }
        removeRecord(serial, in: records)
    }

    /// Whether the process that wrote the note still captures: this one while its capture runs,
    /// another one while a process of that name has its id.
    static func isRunning(_ record: Record) -> Bool {
        if record.pid == getpid() { return running.get().values.contains { $0.active.address == record.address } }
        guard kill(record.pid, 0) == 0 || errno == EPERM else { return false }
        return processName(record.pid) == record.process
    }

    static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func file(_ serial: String, in folder: URL) -> URL {
        let safe = String(serial.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
        return folder.appendingPathComponent("\(safe).json")
    }

    static func record(_ serial: String, in folder: URL) -> Record? {
        guard let data = try? Data(contentsOf: file(serial, in: folder)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func writeRecord(_ record: Record, _ serial: String, in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(record).write(to: file(serial, in: folder), options: .atomic)
    }

    private static func removeRecord(_ serial: String, in folder: URL) {
        try? FileManager.default.removeItem(at: file(serial, in: folder))
    }
}
