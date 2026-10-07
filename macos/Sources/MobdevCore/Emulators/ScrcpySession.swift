import CoreGraphics
import Foundation

/// scrcpy's server on one Android device: the screen as an H.264 stream decoded to its newest
/// picture, and a control channel for touches with real timing and several fingers, keys, any text
/// and the clipboard. It starts on first use (a picture, a tap) and again after the server ended,
/// e.g. when the device rebooted, waiting longer after each failure. While it does not run,
/// `AndroidDevice` uses adb as before. `close` ends it for good and kills the server on the device.
/// MOBDEV_ANDROID_SCRCPY=0 turns it off.
public final class ScrcpySession: @unchecked Sendable {
    let serial: String
    private let adb: ADB
    private let server: @Sendable () async -> Result<URL, DeveloperError>
    private let state = Locked<State>(.idle)
    private let failures = Locked(0)
    /// The scid and adb forward of a server being started, so `close` can clean up before it is
    /// connected.
    private let starting = Locked<(scid: String, port: Locked<Int?>)?>(nil)

    private enum State {
        case idle
        case starting(Task<ScrcpyConnection?, Never>)
        case running(ScrcpyConnection)
        /// After a failure, adb until then.
        case resting(until: Date, reason: String)
        /// Closed, or the server is missing: adb only.
        case off(String)
    }

    /// The long edge of the video. Agents' screenshots are this size anyway.
    static let maxSize = 1280

    /// Off with MOBDEV_ANDROID_SCRCPY=0.
    public static func isEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["MOBDEV_ANDROID_SCRCPY"] != "0"
    }

    init(
        serial: String, adb: ADB,
        server: @escaping @Sendable () async -> Result<URL, DeveloperError> = { await ScrcpyServer.file() }
    ) {
        self.serial = serial
        self.adb = adb
        self.server = server
        Self.sessions.withLock { $0[ObjectIdentifier(self)] = Weak(self) }
    }

    deinit {
        let id = ObjectIdentifier(self)
        Self.sessions.withLock { $0[id] = nil }
    }

    // MARK: Use

    /// The newest picture while the server streams. Otherwise nil, and the server starts.
    func frame() -> CGImage? {
        guard case .ready(let connection) = next() else { return nil }
        return connection.decoder.image()
    }

    /// Whether pictures come from the stream right now.
    var isStreaming: Bool {
        guard case .running(let connection) = state.get() else { return false }
        return connection.isAlive && connection.decoder.frameCount > 0
    }

    /// The running connection, once the server started if it was not running. Nil while it cannot
    /// run: adb does the work then.
    func connection() async -> ScrcpyConnection? {
        switch next() {
        case .ready(let connection): return connection
        case .wait(let task): return await task.value
        case .none: return nil
        }
    }

    /// Why the session does not run, for messages; nil while it runs or may start.
    var unavailableReason: String? {
        switch state.get() {
        case .off(let reason): reason
        case .resting(let until, let reason) where until > Date(): reason
        default: nil
        }
    }

    private enum Next {
        case ready(ScrcpyConnection)
        case wait(Task<ScrcpyConnection?, Never>)
        case none
    }

    private func next() -> Next {
        state.withLock { state in
            switch state {
            case .running(let connection) where connection.isAlive: return .ready(connection)
            case .starting(let task): return .wait(task)
            case .off: return .none
            case .resting(let until, _) where until > Date(): return .none
            case .idle, .running, .resting:
                let task = Task.detached(priority: .userInitiated) { await self.launch() }
                state = .starting(task)
                return .wait(task)
            }
        }
    }

    // MARK: Lifecycle

    private func launch() async -> ScrcpyConnection? {
        let file: URL
        switch await server() {
        case .success(let url): file = url
        case .failure(let error):
            // Without the server there is nothing to try again.
            state.withLock { if case .starting = $0 { $0 = .off(error.description) } }
            Log.error("scrcpy is off for \(serial): \(error.description)")
            return nil
        }
        let scid = String(format: "%08x", UInt32.random(in: 1...0x7fff_ffff))
        let port = Locked<Int?>(nil)
        starting.set((scid, port))
        defer { starting.set(nil) }
        do {
            let connection = try await ScrcpyConnection.open(
                serial: serial, adb: adb, server: file, scid: scid, maxSize: Self.maxSize, forwarded: port
            ) { [weak self] connection in self?.ended(connection) }
            let kept = state.withLock { state -> Bool in
                guard case .starting = state else { return false }
                state = .running(connection)
                return true
            }
            guard kept else {
                connection.close()
                return nil
            }
            Log.info("scrcpy streams \(serial) at \(connection.header.width)×\(connection.header.height)")
            return connection
        } catch {
            rest(String(describing: error))
            return nil
        }
    }

    /// The server ended on its own: start again on the next use, soon if it ran a while.
    private func ended(_ connection: ScrcpyConnection) {
        if Date().timeIntervalSince(connection.started) > 30 { failures.set(0) }
        rest("the server ended")
    }

    private func rest(_ reason: String) {
        let count = failures.withLock { count -> Int in
            count += 1
            return count
        }
        let delay = min(pow(2, Double(count - 1)), 30)
        let changed = state.withLock { state -> Bool in
            switch state {
            case .starting, .running:
                state = .resting(until: Date() + delay, reason: reason)
                return true
            default: return false
            }
        }
        if changed { Log.error("scrcpy on \(serial): \(reason). adb takes over; next try in \(Int(delay)) s") }
    }

    /// Ends the server and keeps it off, e.g. when the device went away.
    func close() {
        let previous = state.withLock { state -> State in
            defer { state = .off("Mobdev stopped scrcpy on this device.") }
            return state
        }
        if case .running(let connection) = previous { connection.close() }
        // A server still starting is killed here and its forward removed, in case Mobdev quits
        // before the start fails; its connection, if it comes, closes itself.
        if let pending = starting.get() {
            ScrcpyConnection.kill(pending.scid, serial: serial, adb: adb)
            if let port = pending.port.get() {
                _ = try? adb.runner.runBinary(adb.executable, ["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 5)
            }
        }
    }

    private struct Weak {
        weak var session: ScrcpySession?
        init(_ session: ScrcpySession) { self.session = session }
    }

    private static let sessions = Locked<[ObjectIdentifier: Weak]>([:])

    /// Ends every server, when Mobdev quits.
    public static func closeAll() {
        let all = sessions.get().values.compactMap(\.session)
        DispatchQueue.concurrentPerform(iterations: all.count) { all[$0].close() }
    }
}

/// One run of scrcpy's server: its adb shell, the video and control sockets and the decoder.
final class ScrcpyConnection: @unchecked Sendable {
    let serial: String
    let scid: String
    let header: ScrcpyProtocol.VideoHeader
    let decoder = H264Decoder()
    let started = Date()
    private let adb: ADB
    private let process: RunningCommand
    private let video: Int32
    private let control: Int32
    private let onEnd: @Sendable (ScrcpyConnection) -> Void
    private let alive = Locked(true)
    /// Writes to the control socket, and closing it.
    private let writing = NSLock()
    /// The two reader threads; the last one to finish closes the sockets.
    private let readers = Locked(2)
    private let clipboardReplies = Locked<[Reply<String>]>([])
    private let acknowledgements = Locked<[UInt64: Reply<Bool>]>([:])
    private let sequence = Locked<UInt64>(0)
    private let lastPaste = Locked(Date.distantPast)
    private let lastReset = Locked(Date.distantPast)

    private init(
        serial: String, scid: String, header: ScrcpyProtocol.VideoHeader, adb: ADB, process: RunningCommand,
        video: Int32, control: Int32, onEnd: @escaping @Sendable (ScrcpyConnection) -> Void
    ) {
        self.serial = serial
        self.scid = scid
        self.header = header
        self.adb = adb
        self.process = process
        self.video = video
        self.control = control
        self.onEnd = onEnd
    }

    var isAlive: Bool { alive.get() }

    // MARK: Starting

    /// The shell command that runs the server. A watchdog kills it if nobody connected within 15
    /// seconds (its socket still listens), so a Mobdev that quit while starting leaves nothing behind.
    static func command(remote: String, scid: String, maxSize: Int) -> String {
        // SIGTERM ends the Java server, and with it the shell; the watchdog then ends too.
        let watchdog =
            "(sleep 15; grep -q ' 00010000 0001 01 .*@scrcpy_\(scid)$' /proc/net/unix && pkill -f '\(pattern(scid))') >/dev/null 2>&1 &"
        let arguments = ScrcpyProtocol.serverArguments(version: ScrcpyServer.version, scid: scid, maxSize: maxSize)
        return "\(watchdog) CLASSPATH=\(remote) app_process / com.genymobile.scrcpy.Server \(arguments.joined(separator: " "))"
    }

    /// The scid with its first digit in brackets, so it does not match the shell that looks for it.
    private static func pattern(_ scid: String) -> String { "scid=[\(scid.prefix(1))]\(scid.dropFirst())" }

    /// SIGKILL for everything started with this scid: the server, its shell and the watchdog, a
    /// shell subprocess that ignores SIGTERM. (toybox's `pkill -9` also kills the shell running it.)
    static func killCommand(_ scid: String) -> String {
        "kill -9 $(pgrep -f '\(pattern(scid))') 2>/dev/null"
    }

    /// Kills the server with this scid and what it started. Blocks for the adb call.
    static func kill(_ scid: String, serial: String, adb: ADB) {
        _ = try? adb.runner.runBinary(adb.executable, ["-s", serial, "shell", killCommand(scid)], timeout: 5)
    }

    /// Pushes and starts the server and connects as scrcpy's client does with a forward tunnel: the
    /// video socket first, which receives a byte once the server listens, then the control socket.
    /// The video socket then carries the device's name and the codec header.
    /// `forwarded` holds the local port while the adb forward exists.
    static func open(
        serial: String, adb: ADB, server: URL, scid: String, maxSize: Int, forwarded: Locked<Int?> = Locked(nil),
        onEnd: @escaping @Sendable (ScrcpyConnection) -> Void
    ) async throws -> ScrcpyConnection {
        // The server deletes its own copy once it runs.
        let remote = "/data/local/tmp/mobdev-scrcpy-\(scid).jar"
        var process: RunningCommand?
        let log = Locked<[String]>([])
        let exited = Locked<Int32?>(nil)
        let sockets = Locked<[Int32]>([])
        do {
            let pushed = try await adb.run(serial, ["push", server.path, remote], timeout: 30)
            guard pushed.status == 0 else { throw DeveloperError("adb push failed: \(pushed.output.trimmed)") }
            let forward = try await adb.run(serial, ["forward", "tcp:0", "localabstract:scrcpy_\(scid)"], timeout: 10)
            guard forward.status == 0, let port = Int(forward.output.trimmed), port > 0 else {
                throw DeveloperError("adb forward failed: \(forward.output.trimmed)")
            }
            forwarded.set(port)
            let tag = serial
            let started = try adb.runner.start(
                adb.executable, ["-s", serial, "shell", command(remote: remote, scid: scid, maxSize: maxSize)],
                onLine: { line in
                    guard !line.isEmpty else { return }
                    log.withLock { lines in
                        lines.append(line)
                        if lines.count > 20 { lines.removeFirst() }
                    }
                    Log.info("scrcpy \(tag): \(line)")
                }, onExit: { status in exited.set(status) })
            process = started
            let (video, control, header) = try await offThread {
                let video = try connectToServer(port: port, until: Date() + 10, exited: exited)
                sockets.withLock { $0.append(video) }
                let control = try connect(port: port)
                sockets.withLock { $0.append(control) }
                _ = try ADB.read(video, count: 64)  // The device's name.
                let header = try ScrcpyProtocol.videoHeader(ADB.read(video, count: 12))
                return (video, control, header)
            }
            guard header.codec == ScrcpyProtocol.h264 else { throw DeveloperError("The server sent another codec than H.264.") }
            _ = try? await adb.run(serial, ["forward", "--remove", "tcp:\(port)"], timeout: 10)
            forwarded.set(nil)
            // From now on reads wait as long as the screen stays still.
            var forever = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(video, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(control, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))
            var on: Int32 = 1
            setsockopt(control, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            let connection = ScrcpyConnection(
                serial: serial, scid: scid, header: header, adb: adb, process: started, video: video, control: control,
                onEnd: onEnd)
            connection.startReading()
            return connection
        } catch {
            sockets.get().forEach { Darwin.close($0) }
            process?.stop()
            if let port = forwarded.get() {
                _ = try? await adb.run(serial, ["forward", "--remove", "tcp:\(port)"], timeout: 10)
                forwarded.set(nil)
            }
            kill(scid, serial: serial, adb: adb)
            _ = try? await adb.run(serial, ["shell", "rm -f \(remote)"], timeout: 10)
            let lines = log.get().filter { $0.contains("ERROR") || $0.contains("Exception") }.suffix(3)
            throw DeveloperError(
                String(describing: error) + (lines.isEmpty ? "" : " The server said: " + lines.joined(separator: " ")))
        }
    }

    /// adb accepts the connection at once and closes it again until the server listens; the server
    /// then sends one byte.
    private static func connectToServer(port: Int, until deadline: Date, exited: Locked<Int32?>) throws -> Int32 {
        while true {
            if let status = exited.get() { throw DeveloperError("The server exited (status \(status)) before it listened.") }
            if let socket = try? connect(port: port) {
                if let byte = try? ADB.read(socket, count: 1), byte == Data([0]) { return socket }
                Darwin.close(socket)
            }
            guard Date() < deadline else { throw DeveloperError("The server did not listen within 10 seconds.") }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func connect(port: Int) throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw DeviceIOError.socket }
        var on: Int32 = 1
        // A write to a closed socket fails instead of ending Mobdev with SIGPIPE.
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(socket)
            throw DeviceIOError.socket
        }
        return socket
    }

    // MARK: Reading

    private func startReading() {
        Thread.detachNewThread { [self] in
            Thread.current.name = "scrcpy video \(serial)"
            readVideo()
            finishReading()
        }
        Thread.detachNewThread { [self] in
            Thread.current.name = "scrcpy control \(serial)"
            readControl()
            finishReading()
        }
    }

    /// Packets go to the decoder as they come, so only the newest picture is kept.
    private func readVideo() {
        while isAlive {
            guard let head = try? ADB.read(video, count: 12) else { return }
            let header = ScrcpyProtocol.packetHeader(head)
            guard header.size > 0, header.size < 64 << 20, let packet = try? ADB.read(video, count: header.size) else {
                return
            }
            if !decoder.decode(packet, config: header.config, keyFrame: header.keyFrame) { requestKeyFrame() }
        }
    }

    private func readControl() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while isAlive {
            let count = Darwin.read(control, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            do {
                while let (message, length) = try ScrcpyProtocol.deviceMessage(in: buffer) {
                    buffer = Data(buffer.dropFirst(length))
                    handle(message)
                }
            } catch {
                Log.error("scrcpy \(serial): \(error)")
                return
            }
        }
    }

    private func handle(_ message: ScrcpyProtocol.DeviceMessage) {
        switch message {
        case .clipboard(let text):
            let reply = clipboardReplies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            reply?.resolve(text)
        case .clipboardAcknowledged(let sequence):
            acknowledgements.withLock { $0.removeValue(forKey: sequence) }?.resolve(true)
        case .uhidOutput:
            break
        }
    }

    /// Asks for a new key frame after the decoder lost track, at most every two seconds.
    private func requestKeyFrame() {
        let due = lastReset.withLock { last -> Bool in
            guard Date().timeIntervalSince(last) > 2 else { return false }
            last = Date()
            return true
        }
        if due { try? send(ScrcpyProtocol.resetVideo()) }
    }

    private func finishReading() {
        end(notify: true)
        let last = readers.withLock { count -> Bool in
            count -= 1
            return count == 0
        }
        guard last else { return }
        writing.withLock {
            Darwin.close(video)
            Darwin.close(control)
        }
    }

    /// The first call stops everything: the sockets (which wakes the readers), the adb shell, and
    /// every caller waiting for an answer. When the server ended on its own (`notify`), it is
    /// killed for certain in the background and the session hears of it.
    private func end(notify: Bool) {
        let wasAlive = alive.withLock { alive -> Bool in
            defer { alive = false }
            return alive
        }
        guard wasAlive else { return }
        writing.withLock {
            shutdown(video, SHUT_RDWR)
            shutdown(control, SHUT_RDWR)
        }
        clipboardReplies.withLock { replies in
            defer { replies = [] }
            return replies
        }.forEach { $0.resolve(nil) }
        acknowledgements.withLock { replies in
            defer { replies = [:] }
            return Array(replies.values)
        }.forEach { $0.resolve(nil) }
        process.stop()
        guard notify else { return }
        let (scid, serial, adb) = (scid, serial, adb)
        // The server stops when its sockets close; this makes sure.
        DispatchQueue.global().async { Self.kill(scid, serial: serial, adb: adb) }
        onEnd(self)
    }

    /// Stops the server and waits until it is killed on the device. The server first gets up to a
    /// second to handle what it received, such as text just typed: the control socket closes for
    /// writing, and the server ends once it read everything.
    func close() {
        writing.withLock { if isAlive { shutdown(control, SHUT_WR) } }
        for _ in 0..<20 where isAlive { Thread.sleep(forTimeInterval: 0.05) }
        end(notify: false)
        Self.kill(scid, serial: serial, adb: adb)
    }

    // MARK: Control

    func send(_ message: Data) throws {
        try writing.withLock {
            guard isAlive else { throw DeveloperError("The scrcpy connection ended.") }
            try ADB.write(control, message)
        }
    }

    /// A point on the screen in the video's pixels, with the size the server checks them against.
    private func touch(_ action: ScrcpyProtocol.TouchAction, pointer: UInt64, at point: NormalizedPoint) throws {
        let size = decoder.size ?? (header.width, header.height)
        let x = Int((min(max(point.x, 0), 1) * Double(size.width - 1)).rounded())
        let y = Int((min(max(point.y, 0), 1) * Double(size.height - 1)).rounded())
        try send(
            ScrcpyProtocol.injectTouch(
                action, pointer: pointer, x: x, y: y, width: size.width, height: size.height,
                pressure: action == .up ? 0 : 1))
    }

    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws {
        try touch(.down, pointer: ScrcpyProtocol.finger, at: point)
        try? await Task.sleep(for: .seconds(max(hold, 0.03)))
        try touch(.up, pointer: ScrcpyProtocol.finger, at: point)
    }

    /// Fingers that touch down together, move in straight lines over `duration`, about 120 times
    /// a second, and lift together, e.g. one for a swipe and two for a pinch.
    func drag(_ paths: [(from: NormalizedPoint, to: NormalizedPoint)], duration: TimeInterval) async throws {
        let pointers = paths.indices.map { index -> UInt64 in
            switch index {
            case 0: ScrcpyProtocol.finger
            case 1: ScrcpyProtocol.secondFinger
            default: UInt64(index)
            }
        }
        for (pointer, path) in zip(pointers, paths) { try touch(.down, pointer: pointer, at: path.from) }
        let clock = ContinuousClock()
        let start = clock.now
        let steps = max(Int((duration / 0.008).rounded()), 1)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            // Cancelling still lifts the fingers; a finger left down would hold the screen.
            try? await Task.sleep(until: start + .seconds(duration * t), clock: clock)
            for (pointer, path) in zip(pointers, paths) {
                let point = NormalizedPoint(
                    x: path.from.x + (path.to.x - path.from.x) * t, y: path.from.y + (path.to.y - path.from.y) * t)
                try touch(.move, pointer: pointer, at: point)
            }
        }
        for (pointer, path) in zip(pointers, paths).reversed() { try touch(.up, pointer: pointer, at: path.to) }
    }

    /// A key with modifier keys (Android key codes) held around it.
    func press(_ keycode: Int, modifiers: [Int] = []) throws {
        var meta = 0
        for modifier in modifiers {
            meta |= Self.metaState(modifier)
            try send(ScrcpyProtocol.injectKeycode(.down, keycode: modifier, metaState: meta))
        }
        try send(ScrcpyProtocol.injectKeycode(.down, keycode: keycode, metaState: meta))
        try send(ScrcpyProtocol.injectKeycode(.up, keycode: keycode, metaState: meta))
        for modifier in modifiers.reversed() {
            meta &= ~Self.metaState(modifier)
            try send(ScrcpyProtocol.injectKeycode(.up, keycode: modifier, metaState: meta))
        }
    }

    /// KeyEvent's META_* flags for the left modifier keys.
    static func metaState(_ keycode: Int) -> Int {
        switch keycode {
        case 59: 0x1 | 0x40  // Shift
        case 57: 0x2 | 0x10  // Alt
        case 113: 0x1000 | 0x2000  // Ctrl
        case 117: 0x10000 | 0x20000  // Meta
        default: 0
        }
    }

    /// Printable ASCII becomes key events on the device. Other text goes through the clipboard and
    /// Paste, as the server's key map has no keys for it. Each line break presses Enter.
    func type(_ text: String) async throws {
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if Self.typesAsKeys(line) {
                var rest = Substring(line)
                while !rest.isEmpty {
                    let chunk = rest.prefix(ScrcpyProtocol.injectTextMaxLength)
                    rest = rest.dropFirst(chunk.count)
                    try send(ScrcpyProtocol.injectText(String(chunk)))
                }
            } else {
                try await setClipboard(line, paste: true)
            }
            if index < lines.count - 1 { try press(66) }
        }
    }

    static func typesAsKeys(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
    }

    /// The device's clipboard. The server answers only when it holds text, so no answer within
    /// two seconds means an empty clipboard.
    func clipboard() async throws -> String {
        let reply = Reply<String>()
        clipboardReplies.withLock { $0.append(reply) }
        do {
            try send(ScrcpyProtocol.getClipboard())
        } catch {
            clipboardReplies.withLock { $0.removeAll { $0 === reply } }
            throw error
        }
        let text = await reply.wait(timeout: 2)
        clipboardReplies.withLock { $0.removeAll { $0 === reply } }
        guard isAlive else { throw DeveloperError("The scrcpy connection ended.") }
        return text ?? ""
    }

    /// Sets the clipboard and waits until the device confirms it; with `paste`, presses Paste.
    func setClipboard(_ text: String, paste: Bool) async throws {
        guard text.utf8.count <= ScrcpyProtocol.clipboardTextMaxLength else {
            throw DeveloperError("That is too long for Android's clipboard over scrcpy; send at most 256 KB.")
        }
        // The app reads the clipboard when it handles Paste, after the device confirmed: changing
        // the clipboard again right away could paste the newer text.
        let since = Date().timeIntervalSince(lastPaste.get())
        if since < 0.3 { try? await Task.sleep(for: .seconds(0.3 - since)) }
        let number = sequence.withLock { value -> UInt64 in
            value += 1
            return value
        }
        let reply = Reply<Bool>()
        acknowledgements.withLock { $0[number] = reply }
        do {
            try send(ScrcpyProtocol.setClipboard(sequence: number, text: text, paste: paste))
        } catch {
            acknowledgements.withLock { $0[number] = nil }
            throw error
        }
        let confirmed = await reply.wait(timeout: 5)
        acknowledgements.withLock { $0[number] = nil }
        guard confirmed == true else { throw DeveloperError("Android did not confirm the clipboard.") }
        if paste { lastPaste.set(Date()) }
    }
}

/// An answer that arrives on another thread, or nil after a timeout.
final class Reply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Value??
    private var continuation: CheckedContinuation<Value?, Never>?

    func resolve(_ value: Value?) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = .some(value)
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }

    func wait(timeout: TimeInterval) async -> Value? {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in resolve(nil) }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// Runs blocking work, such as socket reads with timeouts, off Swift's cooperative threads.
private func offThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try body() }) }
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
