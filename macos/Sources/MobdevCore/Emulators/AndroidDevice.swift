import CoreGraphics
import Foundation

/// An Android emulator or phone through adb. The screen and input go through scrcpy's server
/// (`ScrcpySession`) while it runs: a video stream, touches with real timing, any text and the
/// clipboard. Otherwise, and when it fails, `screencap` takes the pictures and `input` sends
/// touches and keys. Apps go through the package manager and logcat. Phones need USB debugging.
public final class AndroidDevice: Device, @unchecked Sendable {
    public let id: String
    public let activity: ActivityLog
    let adb: ADB
    private let details: Locked<Details>
    /// Pixels per dp from `wm density`, once read.
    private let density = Locked<Double?>(nil)
    /// The screen in device pixels as it is turned now: the coordinate space of `input` and of
    /// uiautomator's bounds.
    private let screenSize = Locked<(width: Int, height: Int)?>(nil)
    /// The size of the last picture, smaller than the screen when it came from scrcpy: what
    /// agents' coordinates refer to.
    private let frameSize = Locked<(width: Int, height: Int)?>(nil)
    private let appBackend: AndroidApps
    private let deviceSettings: AndroidSettings
    /// Nil when MOBDEV_ANDROID_SCRCPY=0.
    let scrcpy: ScrcpySession?

    struct Details: Equatable {
        var name: String
        var model: String
        var modelName: String
        var osVersion: String
        /// From `wm size`, until the first screenshot says what the screen shows.
        var width = 0
        var height = 0
    }

    /// `scrcpyServer` finds scrcpy's server; nil keeps the device on adb alone.
    init(
        serial: String, details: Details, adb: ADB, reportsFolder: URL = MobdevPaths.crashReportsFolder,
        scrcpyServer: (@Sendable () async -> Result<URL, DeveloperError>)? = AndroidDevice.defaultScrcpyServer
    ) {
        id = serial
        self.adb = adb
        let lockedDetails = Locked(details)
        self.details = lockedDetails
        if details.width > 0, details.height > 0 { screenSize.set((details.width, details.height)) }
        activity = ActivityLog(limit: 1000, file: MobdevPaths.activityFile(device: serial))
        appBackend = AndroidApps(serial: serial, adb: adb, reportsFolder: reportsFolder)
        let scrcpy = scrcpyServer.map { ScrcpySession(serial: serial, adb: adb, server: $0) }
        self.scrcpy = scrcpy
        deviceSettings = AndroidSettings(serial: serial, adb: adb, scrcpy: scrcpy) {
            serial.hasPrefix("emulator-") || lockedDetails.get().modelName == "Android Emulator"
        }
    }

    /// The pinned server, unless MOBDEV_ANDROID_SCRCPY=0.
    static var defaultScrcpyServer: (@Sendable () async -> Result<URL, DeveloperError>)? {
        guard ScrcpySession.isEnabled() else { return nil }
        return { await ScrcpyServer.file() }
    }

    /// Stops following apps and ends scrcpy's server, when the device goes away.
    func close() {
        appBackend.close()
        scrcpy?.close()
    }

    /// Reads name, model and Android version once, when the device appears.
    static func details(serial: String, listed: [String: String], adb: ADB) async -> Details {
        let text = (try? await adb.shell(serial, "getprop", timeout: 15)) ?? ""
        var properties: [String: String] = [:]
        // Lines like "[ro.product.model]: [Pixel 8]".
        for line in text.split(separator: "\n") {
            let parts = line.components(separatedBy: "]: [")
            guard parts.count == 2 else { continue }
            properties[String(parts[0].dropFirst())] = String(parts[1].dropLast(parts[1].hasSuffix("]") ? 1 : 0))
        }
        let emulator = serial.hasPrefix("emulator-") || properties["ro.kernel.qemu"] == "1"
            || properties["ro.boot.qemu"] == "1"
        var avd = properties["ro.boot.qemu.avd_name"] ?? ""
        if emulator, avd.isEmpty {
            avd = (try? await adb.run(serial, ["emu", "avd", "name"], timeout: 5))?.output
                .split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        }
        let model = properties["ro.product.model"] ?? listed["model"]?.replacingOccurrences(of: "_", with: " ") ?? "Android"
        let marketName = properties["ro.product.marketname"] ?? properties["ro.product.vendor.marketname"]
        let modelName = emulator ? "Android Emulator" : (marketName ?? model)
        let name = emulator && !avd.isEmpty ? avd.replacingOccurrences(of: "_", with: " ") : (marketName ?? model)
        let size = parseSize((try? await adb.shell(serial, "wm size", timeout: 10)) ?? "")
        return Details(
            name: name, model: model, modelName: modelName, osVersion: properties["ro.build.version.release"] ?? "",
            width: size?.width ?? 0, height: size?.height ?? 0)
    }

    public var kind: DeviceKind { .android }
    public var name: String { details.get().name }
    public var apps: AppBackend? { appBackend }
    public var settings: DeviceSettings? { deviceSettings }

    public var info: DeviceInfo? {
        let details = details.get()
        return DeviceInfo(
            id: id, name: details.name, productType: details.modelName, osVersion: details.osVersion, buildVersion: "",
            deviceClass: "Android")
    }

    // MARK: Screen

    /// Never asks the device: status is read on the main thread. The size comes from `wm size` when
    /// the device appeared, then from each picture.
    public func status() -> PhoneStatus {
        let screen: ScreenState =
            (frameSize.get() ?? size()).map { .connected(name: name, width: $0.width, height: $0.height) }
            ?? .failed("The screen is not available yet")
        return PhoneStatus(
            screen: screen, bluetooth: .unsupported("not needed for Android"), keyboardLayout: .us,
            input: .direct(isStreaming ? "scrcpy" : "adb"))
    }

    /// Whether pictures come from scrcpy's video stream, many a second, rather than `screencap`.
    public var isStreaming: Bool { scrcpy?.isStreaming ?? false }

    private func size() -> (width: Int, height: Int)? { screenSize.get() }

    /// "Physical size: 1280x2856", with an "Override size" line winning when present.
    static func parseSize(_ text: String) -> (width: Int, height: Int)? {
        let lines = text.split(separator: "\n")
        let line = lines.first { $0.hasPrefix("Override size:") } ?? lines.first { $0.hasPrefix("Physical size:") }
        guard let value = line?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else { return nil }
        let parts = value.split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 && parts[0] > 0 && parts[1] > 0 ? (parts[0], parts[1]) : nil
    }

    /// `wm density` in dots per inch over Android's 160 dpi for one dp, read once, for the picture's
    /// pixels.
    public func screenScale() async -> Double? {
        var perDP = density.get()
        if perDP == nil {
            guard let text = try? await adb.shell(id, "wm density", timeout: 10), let dpi = Self.parseDensity(text) else {
                return nil
            }
            perDP = dpi / 160
            density.set(perDP)
        }
        // scrcpy's pictures can be smaller than the screen; the scale is per picture pixel.
        guard let perDP else { return nil }
        if let screen = screenSize.get(), let frame = frameSize.get(), screen.width > 0 {
            return perDP * Double(frame.width) / Double(screen.width)
        }
        return perDP
    }

    /// "Physical density: 420", with an "Override density" line winning when present.
    static func parseDensity(_ text: String) -> Double? {
        let lines = text.split(separator: "\n")
        let line = lines.first { $0.hasPrefix("Override density:") } ?? lines.first { $0.hasPrefix("Physical density:") }
        guard let value = line?.split(separator: ":").last.flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
            value > 0
        else { return nil }
        return value
    }

    /// scrcpy's newest picture while it streams, else a `screencap`, which takes a quarter of a
    /// second to over a second.
    public func frame() -> CGImage? {
        if let image = scrcpy?.frame() {
            frameSize.set((image.width, image.height))
            // A smaller picture of the same screen; its sides swap when the device turns.
            screenSize.withLock { size in
                if let current = size, (current.width > current.height) != (image.width > image.height) {
                    size = (current.height, current.width)
                }
            }
            return image
        }
        return screencap()
    }

    func screencap() -> CGImage? {
        // The raw format is several times faster than PNG, which the phone would have to compress.
        guard let result = try? adb.runner.runBinary(adb.executable, ["-s", id, "exec-out", "screencap"], timeout: 10),
            result.status == 0, let image = Self.image(fromRaw: result.data)
        else { return nil }
        screenSize.set((image.width, image.height))
        frameSize.set((image.width, image.height))
        return image
    }

    /// `screencap` without -p: width, height and pixel format as 32-bit little-endian values (plus
    /// the color space since Android 9), then RGBA pixels.
    static func image(fromRaw data: Data) -> CGImage? {
        guard data.count >= 12 else { return nil }
        func word(_ offset: Int) -> Int {
            Int(data[data.startIndex + offset]) | Int(data[data.startIndex + offset + 1]) << 8
                | Int(data[data.startIndex + offset + 2]) << 16 | Int(data[data.startIndex + offset + 3]) << 24
        }
        let width = word(0), height = word(4), format = word(8)
        // 1: RGBA_8888, 2: RGBX_8888. Others (565) are rare on current devices.
        guard width > 0, height > 0, width < 20000, height < 20000, format == 1 || format == 2 else { return nil }
        let pixels = width * height * 4
        let header = data.count - pixels
        guard header == 12 || header == 16 else { return nil }
        guard let provider = CGDataProvider(data: data.subdata(in: data.startIndex + header..<data.endIndex) as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Input

    private func pixels(_ point: NormalizedPoint) throws -> (Int, Int) {
        guard let size = size() else { throw DeveloperError("The screen size is not known yet. Take a screenshot first.") }
        let x = Int((min(max(point.x, 0), 1) * Double(size.width - 1)).rounded())
        let y = Int((min(max(point.y, 0), 1) * Double(size.height - 1)).rounded())
        return (x, y)
    }

    private func input(_ command: String) async throws {
        _ = try await adb.shell(id, "input \(command)", timeout: 20)
    }

    /// Runs `action` over scrcpy, started first if it is not running yet. False when adb has to do
    /// it instead: scrcpy is off, failed to start, or its connection ended halfway.
    private func overScrcpy(_ what: String, _ action: (ScrcpyConnection) async throws -> Void) async -> Bool {
        guard let connection = await scrcpy?.connection() else { return false }
        do {
            try await action(connection)
            return true
        } catch {
            Log.error("scrcpy \(id): \(what) failed (\(error)); using adb")
            return false
        }
    }

    /// Why scrcpy did not do the work, for messages.
    private var scrcpyProblem: String {
        guard let scrcpy else { return "turned off with MOBDEV_ANDROID_SCRCPY=0" }
        return scrcpy.unavailableReason ?? "its connection failed; Mobdev's log says why"
    }

    public func tap(at point: NormalizedPoint, hold: TimeInterval) async throws {
        if await overScrcpy("tap", { try await $0.tap(at: point, hold: hold) }) { return }
        let (x, y) = try pixels(point)
        if hold < 0.2 {
            try await input("tap \(x) \(y)")
        } else {
            // A swipe that does not move is a long press.
            try await input("swipe \(x) \(y) \(x) \(y) \(Int(hold * 1000))")
        }
    }

    public func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {
        if await overScrcpy("swipe", { try await $0.drag([(start, end)], duration: max(duration, 0.05)) }) { return }
        let (x1, y1) = try pixels(start)
        let (x2, y2) = try pixels(end)
        try await input("swipe \(x1) \(y1) \(x2) \(y2) \(max(Int(duration * 1000), 50))")
    }

    /// As a swipe, like on the simulator (see `wheelSwipe`).
    public func scroll(at point: NormalizedPoint, ticks: Int) async throws {
        let (start, end) = wheelSwipe(at: point, ticks: ticks)
        try await swipe(from: start, to: end, duration: 0.35)
    }

    public func pan(at point: NormalizedPoint, ticks: Int) async throws {
        let (start, end) = wheelSwipe(at: point, ticks: ticks, sideways: true)
        try await swipe(from: start, to: end, duration: 0.35)
    }

    /// Two fingers side by side moving apart (`scale` above 1, zooming in) or together around
    /// `center`, the wider span 60% of the screen's width. Needs scrcpy: `input` has one finger.
    public func pinch(at center: NormalizedPoint, scale: Double, duration: TimeInterval = 0.5) async throws {
        guard scale > 0, scale != 1 else { throw DeveloperError("scale must be above 0 and not 1.") }
        let wide = 0.6
        let spans = scale > 1 ? (from: max(wide / scale, 0.04), to: wide) : (from: wide, to: max(wide * scale, 0.04))
        func fingers(_ span: Double) -> (NormalizedPoint, NormalizedPoint) {
            (
                NormalizedPoint(x: min(max(center.x - span / 2, 0.01), 0.99), y: center.y),
                NormalizedPoint(x: min(max(center.x + span / 2, 0.01), 0.99), y: center.y)
            )
        }
        let (start, end) = (fingers(spans.from), fingers(spans.to))
        guard let connection = await scrcpy?.connection() else {
            throw DeveloperError(
                "A pinch needs two fingers, which Mobdev sends through scrcpy, and scrcpy is not running: \(scrcpyProblem).")
        }
        try await connection.drag([(start.0, end.0), (start.1, end.1)], duration: duration)
    }

    public func type(_ strokes: [KeyStroke]) async throws {
        for stroke in strokes { try await press(stroke) }
    }

    public func press(_ stroke: KeyStroke) async throws {
        guard let key = Self.keycode(forUsage: stroke.usage) else {
            throw DeveloperError("That key has no Android equivalent.")
        }
        let modifiers = Self.modifierKeycodes(stroke.modifiers)
        if await overScrcpy("key", { try $0.press(key, modifiers: modifiers) }) { return }
        if modifiers.isEmpty {
            try await input("keyevent \(key)")
        } else {
            try await input("keycombination " + (modifiers + [key]).map(String.init).joined(separator: " "))
        }
    }

    public func press(_ button: ConsumerUsage) async throws {
        let key = switch button {
        case .home: 3
        case .search: 84
        case .volumeUp: 24
        case .volumeDown: 25
        case .mute: 164
        case .playPause: 85
        case .power: 26
        }
        if await overScrcpy("key", { try $0.press(key) }) { return }
        try await input("keyevent \(key)")
    }

    /// Any text over scrcpy (see `ScrcpyConnection.type`). Without it, `input text` types ASCII
    /// only: spaces become %s, the rest is quoted for the shell, and each line break presses Enter.
    public func typeText(_ text: String) async throws -> Bool {
        if await overScrcpy("typing", { try await $0.type(text) }) { return true }
        guard text.unicodeScalars.allSatisfy({ ($0.value >= 0x20 && $0.value < 0x7F) || $0 == "\n" }) else {
            throw DeveloperError(
                "Without scrcpy (\(scrcpyProblem)), Android's input command types ASCII text only. Type the other characters with the on-screen keyboard.")
        }
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var rest = Substring(line)
            while !rest.isEmpty {
                let chunk = rest.prefix(200)
                rest = rest.dropFirst(chunk.count)
                try await input("text " + ADB.quote(chunk.replacingOccurrences(of: " ", with: "%s")))
            }
            if index < lines.count - 1 { try await input("keyevent 66") }
        }
        return true
    }

    /// uiautomator's dump of the window hierarchy, in about two seconds. Its bounds are pixels of
    /// the current orientation, like the screenshot.
    public func uiTree() async throws -> [UIElement]? {
        let output = try await adb.shell(
            id, "uiautomator dump /sdcard/mobdev-ui.xml >/dev/null && cat /sdcard/mobdev-ui.xml", timeout: 30)
        guard let start = output.range(of: "<?xml") ?? output.range(of: "<hierarchy"), let size = size() else {
            let reason = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DeveloperError(
                "uiautomator could not read the screen\(reason.isEmpty ? "" : ": \(reason)"). Try again when the screen stops moving.")
        }
        guard
            let elements = AndroidHierarchyParser.parse(
                Data(output[start.lowerBound...].utf8), width: size.width, height: size.height)
        else { throw DeveloperError("uiautomator returned a hierarchy Mobdev cannot read.") }
        return elements
    }

    /// The package of the focused window, from "mCurrentFocus=Window{… u0 com.android.settings/…}".
    public func frontmostApp() async throws -> String? {
        let output = try await adb.shell(id, "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'", timeout: 10)
        return Self.focusedPackage(output)
    }

    static func focusedPackage(_ dumpsys: String) -> String? {
        for line in dumpsys.split(separator: "\n") where line.contains("mCurrentFocus") || line.contains("mFocusedApp") {
            for word in line.split(whereSeparator: { $0 == " " || $0 == "}" || $0 == "{" }) where word.contains("/") {
                let package = word.split(separator: "/").first.map(String.init) ?? ""
                if package.contains("."), package.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) {
                    return package
                }
            }
        }
        return nil
    }

    /// adb does not know app names, so the name is matched against launchable packages: "Settings"
    /// opens com.android.settings, "Chrome" com.android.chrome.
    public func openApp(named name: String) async throws -> String? {
        let packages = try await appBackend.launchablePackages()
        let apps = packages.map {
            InstalledApp(bundleID: $0, name: $0, version: "", build: "", developer: false, location: nil)
        }
        let app = try AppMatcher.find(name, in: apps)
        try await appBackend.activate(app.bundleID)
        return "Opened \(app.bundleID)."
    }

    // MARK: Keys

    /// USB HID usages (page 7) to Android key codes. Escape is Back, which is what agents mean.
    static func keycode(forUsage usage: UInt8) -> Int? {
        switch usage {
        case 0x04...0x1D: 29 + Int(usage - 0x04)  // A–Z
        case 0x1E...0x26: 8 + Int(usage - 0x1E)  // 1–9
        case 0x27: 7  // 0
        case 0x28: 66  // Enter
        case 0x29: 4  // Back
        case 0x2A: 67  // Delete (backspace)
        case 0x2B: 61  // Tab
        case 0x2C: 62  // Space
        case 0x2D: 69  // -
        case 0x2E: 70  // =
        case 0x2F: 71  // [
        case 0x30: 72  // ]
        case 0x31: 73  // \
        case 0x33: 74  // ;
        case 0x34: 75  // '
        case 0x35: 68  // `
        case 0x36: 55  // ,
        case 0x37: 56  // .
        case 0x38: 76  // /
        case 0x3A...0x45: 131 + Int(usage - 0x3A)  // F1–F12
        case 0x4A: 122  // Home (line start)
        case 0x4B: 92  // Page up
        case 0x4C: 112  // Forward delete
        case 0x4D: 123  // End
        case 0x4E: 93  // Page down
        case 0x4F: 22  // Right
        case 0x50: 21  // Left
        case 0x51: 20  // Down
        case 0x52: 19  // Up
        default: nil
        }
    }

    static func modifierKeycodes(_ modifiers: UInt8) -> [Int] {
        var keys: [Int] = []
        if modifiers & KeyStroke.control != 0 { keys.append(113) }
        if modifiers & KeyStroke.shift != 0 { keys.append(59) }
        if modifiers & KeyStroke.option != 0 { keys.append(57) }
        if modifiers & KeyStroke.command != 0 { keys.append(117) }
        return keys
    }
}

// MARK: - Apps

/// Apps on an Android device through adb: the package manager, activity manager and logcat.
final class AndroidApps: AppBackend, @unchecked Sendable {
    let serial: String
    let adb: ADB
    let logs = AppLogs()
    private let reportsFolder: URL
    /// Each launched app's logcat and the task that notices when the app ends.
    private let sessions = Locked<[String: (command: RunningCommand, watcher: Task<Void, Never>)]>([:])

    init(serial: String, adb: ADB, reportsFolder: URL) {
        self.serial = serial
        self.adb = adb
        self.reportsFolder = reportsFolder
    }

    deinit { close() }

    /// Stops every logcat and watcher, when the device goes away. `logcat --pid` would otherwise run
    /// for as long as the device stays connected.
    func close() {
        for session in sessions.withLock({ current -> [(command: RunningCommand, watcher: Task<Void, Never>)] in
            defer { current = [:] }
            return Array(current.values)
        }) {
            session.watcher.cancel()
            session.command.stop()
        }
    }

    var platform: AppPlatform { .android }

    func apps(all: Bool) async throws -> [InstalledApp] {
        let thirdParty = Set(Self.packages(try await adb.shell(serial, "pm list packages -3")).map(\.name))
        let listed = Self.packages(try await adb.shell(serial, "pm list packages --show-versioncode"))
        return listed.filter { all || thirdParty.contains($0.name) }.map { package in
            InstalledApp(
                bundleID: package.name, name: package.name, version: "", build: package.version,
                developer: thirdParty.contains(package.name), location: nil)
        }
        .sorted { $0.bundleID < $1.bundleID }
    }

    /// "package:com.example versionCode:12" lines.
    static func packages(_ text: String) -> [(name: String, version: String)] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            guard let first = fields.first, first.hasPrefix("package:") else { return nil }
            let version = fields.first { $0.hasPrefix("versionCode:") }.map { String($0.dropFirst("versionCode:".count)) }
            return (String(first.dropFirst("package:".count)), version ?? "")
        }
    }

    func app(_ bundleID: String) async throws -> InstalledApp? {
        let package = try ADB.checkPackage(bundleID)
        let text = try await adb.shell(serial, "dumpsys package \(package)")
        guard text.contains("Package [\(package)]") else { return nil }
        func value(_ key: String) -> String {
            text.split(separator: "\n").lazy.compactMap { line -> String? in
                guard let range = line.range(of: "\(key)=") else { return nil }
                return line[range.upperBound...].split(separator: " ").first.map(String.init)
            }.first ?? ""
        }
        let flags = text.split(separator: "\n").first { $0.contains("pkgFlags=[") } ?? ""
        return InstalledApp(
            bundleID: package, name: package, version: value("versionName"), build: value("versionCode"),
            developer: !flags.contains(" SYSTEM "), location: nil)
    }

    func install(at path: URL) async throws -> InstalledApp {
        let result = try await adb.run(serial, ["install", "-r", "-t", path.path], timeout: 70)
        guard result.status == 0, result.output.contains("Success") else {
            let failure = result.output.split(separator: "\n").last { $0.contains("Failure") || $0.contains("rror") }
            throw DeveloperError("adb install failed: \(failure.map(String.init) ?? result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let aapt2 = adb.aapt2(),
            let dump = try? await adb.runner.run(aapt2, ["dump", "packagename", path.path], timeout: 20), dump.status == 0,
            let package = dump.output.split(separator: "\n").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
            let app = try? await app(package)
        {
            return app
        }
        let name = path.deletingPathExtension().lastPathComponent
        return InstalledApp(bundleID: name, name: name, version: "", build: "", developer: true, location: nil)
    }

    func uninstall(_ bundleID: String) async throws -> InstalledApp {
        guard let app = try await app(bundleID) else { throw DeveloperError("\(bundleID) is not installed.") }
        guard app.developer else {
            throw DeveloperError(
                "\(bundleID) is a system app. Mobdev only removes apps you installed, never system apps.")
        }
        detach(app.bundleID)
        let result = try await adb.run(serial, ["uninstall", app.bundleID], timeout: 30)
        guard result.output.contains("Success") else {
            throw DeveloperError("adb uninstall failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        logs.setStatus("uninstalled", for: app.bundleID)
        return app
    }

    /// Packages with an activity in the launcher.
    func launchablePackages() async throws -> [String] {
        let text = try await adb.shell(
            serial, "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER")
        let packages = text.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let slash = trimmed.firstIndex(of: "/"), !trimmed.contains(" ") else { return nil }
            return String(trimmed[..<slash])
        }
        return Array(Set(packages)).sorted()
    }

    /// The app's launcher activity, e.g. "com.android.settings/.Settings".
    func launcherActivity(_ package: String) async throws -> String {
        let text = try await adb.shell(
            serial,
            "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \(package)"
        )
        guard let component = text.split(separator: "\n").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
            component.hasPrefix(package + "/")
        else { throw DeveloperError("\(package) is not installed or has no launcher activity.") }
        return component
    }

    func activate(_ bundleID: String) async throws {
        let package = try ADB.checkPackage(bundleID)
        let component = try await launcherActivity(package)
        let output = try await adb.shell(serial, "am start -n \(ADB.quote(component))")
        if output.contains("Error:") { throw DeveloperError(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func pid(_ package: String) async -> Int? {
        guard let text = try? await adb.shell(serial, "pidof \(package)", timeout: 10) else { return nil }
        return text.split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
    }

    func launch(_ bundleID: String, arguments: [String], environment: [String: String], restart: Bool) async throws
        -> LaunchOutcome
    {
        let package = try ADB.checkPackage(bundleID)
        if !restart, sessions.get()[package] != nil, await pid(package) != nil {
            try await activate(package)
            return .broughtToFront
        }
        let component = try await launcherActivity(package)
        detach(package)
        if restart { _ = try await adb.shell(serial, "am force-stop \(package)") }
        let output = try await adb.shell(serial, "am start -W -n \(ADB.quote(component))", timeout: 45)
        if output.contains("Error:") { throw DeveloperError(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var pid: Int?
        for _ in 0..<20 {
            pid = await self.pid(package)
            if pid != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let pid else { throw DeveloperError("\(package) started but exited right away. Call crash_reports.") }
        capture(package, pid: pid)
        return .launched
    }

    /// Follows the process's logcat lines and notices when it ends and why. A crash counts as soon
    /// as its first line appears: after one, Android can keep the process around for a while.
    private func capture(_ package: String, pid: Int) {
        logs.setStatus("running", for: package)
        let logs = self.logs
        let crashSeen = Locked(false)
        let command: RunningCommand =
            (try? adb.runner.start(
                adb.executable, ["-s", serial, "logcat", "-v", "threadtime", "--pid=\(pid)"],
                onLine: { line in
                    if line.hasPrefix("--------- beginning of") { return }
                    // Java crashes log FATAL EXCEPTION, native ones "Fatal signal" from libc.
                    if line.contains("FATAL EXCEPTION") || line.contains("Fatal signal") { crashSeen.set(true) }
                    logs.append(app: package, text: line)
                }, onExit: { _ in })) ?? Finished()
        let watcher = Task { [weak self] in
            // Whatever ends the watch also ends the logcat.
            defer { command.stop() }
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                tick += 1
                guard !Task.isCancelled, let self else { return }
                // A crash line counts at once; whether the process still runs is asked every 2 s.
                if crashSeen.get() {
                    try? await Task.sleep(nanoseconds: 500_000_000)  // Let the crash buffer fill.
                } else {
                    guard tick % 4 == 0 else { continue }
                    if await self.pid(package) == pid { continue }
                }
                let crash = (try? await self.crashes())?.last { $0.pid == pid }
                guard !Task.isCancelled else { return }
                logs.setStatus(
                    crash.map { "crashed: \($0.exception). Call crash_reports for the report." } ?? "exited", for: package)
                self.sessions.withLock { $0.removeValue(forKey: package) }
                return
            }
        }
        sessions.withLock { $0[package] = (command, watcher) }
    }

    private struct Finished: RunningCommand {
        func stop() {}
    }

    /// Stops following an app. True if it was being followed.
    @discardableResult
    private func detach(_ package: String) -> Bool {
        guard let session = sessions.withLock({ $0.removeValue(forKey: package) }) else { return false }
        session.watcher.cancel()
        session.command.stop()
        return true
    }

    func stop(_ bundleID: String) async throws -> Bool {
        let package = try ADB.checkPackage(bundleID)
        guard try await app(package) != nil else { throw DeveloperError("\(package) is not installed.") }
        let running = await pid(package) != nil
        let captured = detach(package)
        _ = try await adb.shell(serial, "am force-stop \(package)")
        if running || captured { logs.setStatus("stopped", for: package) }
        return running
    }

    func open(_ url: URL) async throws {
        let output = try await adb.shell(
            serial, "am start -a android.intent.action.VIEW -d \(ADB.quote(url.absoluteString))")
        if output.contains("Error:") { throw DeveloperError(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    // MARK: Crashes

    struct Crash: Equatable {
        /// The crashed app's process. For a native crash that is the "pid: N" in the tombstone, not
        /// crash_dump's, which logs it.
        var pid: Int
        /// The process that logged the crash, to keep its lines together.
        var logger: Int
        var process: String
        var date: Date?
        var exception: String
        var lines: [String]

        /// "com.example.app-2026-09-30-184148-1124". Process names come from the device and may
        /// be paths such as /system/bin/surfaceflinger, so only safe characters are kept.
        var name: String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let safe = String(process.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") ? $0 : "_" })
            return "\(safe.prefix(100))-\(date.map(formatter.string(from:)) ?? "unknown")-\(pid)"
        }
    }

    /// Crashes in the crash log buffer, oldest first.
    func crashes() async throws -> [Crash] {
        Self.parseCrashes(try await adb.shell(serial, "logcat -b crash -d -v threadtime -v year", timeout: 20))
    }

    /// Lines like "2026-09-30 18:41:48.287  1124  1124 E AndroidRuntime: FATAL EXCEPTION: main" (logcat
    /// pads short tags: "DEBUG   : …"). A Java crash starts with FATAL EXCEPTION and names its
    /// exception two lines later; a native one starts with the tombstone's "*** *** ***" line and
    /// names its signal.
    static func parseCrashes(_ text: String) -> [Crash] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let pattern = /^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d\.\d+)\s+(\d+)\s+\d+\s+[VDIWEFA]\s+.*?: (.*)$/
        var crashes: [Crash] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let match = String(raw).firstMatch(of: pattern), let pid = Int(match.3) else { continue }
            let message = String(match.4)
            let starts = message.hasPrefix("FATAL EXCEPTION") || message.hasPrefix("*** *** ***")
            if starts {
                crashes.append(
                    Crash(
                        pid: pid, logger: pid, process: "", date: formatter.date(from: "\(match.1) \(match.2)"),
                        exception: "", lines: []))
            } else if crashes.last?.logger != pid {
                continue
            }
            var crash = crashes[crashes.count - 1]
            crash.lines.append(message)
            let native = crash.lines.first?.hasPrefix("***") ?? false
            if message.hasPrefix("Process: ") {
                crash.process = String(message.dropFirst("Process: ".count).split(separator: ",").first ?? "")
            } else if let start = message.range(of: ">>> "), let end = message.range(of: " <<<"),
                start.upperBound <= end.lowerBound
            {
                crash.process = String(message[start.upperBound..<end.lowerBound])
                // "pid: 2200, tid: 2200, name: … >>> com.example <<<": the app, not crash_dump.
                if message.hasPrefix("pid: "), let appPid = Int(message.dropFirst(5).prefix { $0.isNumber }) {
                    crash.pid = appPid
                }
            } else if native {
                if message.hasPrefix("signal ") || (message.hasPrefix("Abort message: ") && crash.exception.isEmpty) {
                    crash.exception = message
                }
            } else if crash.exception.isEmpty, crash.lines.count >= 3, !message.hasPrefix("\t"), !message.hasPrefix("at ") {
                crash.exception = message
            }
            crashes[crashes.count - 1] = crash
        }
        return crashes.map { crash in
            var crash = crash
            if crash.process.isEmpty { crash.process = "pid\(crash.pid)" }
            if crash.exception.isEmpty { crash.exception = crash.lines.first ?? "crash" }
            return crash
        }
    }

    func crashReports() async throws -> [CrashReportFile] {
        try await crashes().reversed().map { crash in
            CrashReportFile(
                name: crash.name, process: crash.process, date: crash.date,
                size: crash.lines.reduce(0) { $0 + $1.utf8.count + 1 })
        }
    }

    func crashReport(named name: String) async throws -> (report: CrashReport?, file: URL) {
        guard let crash = try await crashes().last(where: { $0.name == name }) else {
            throw DeveloperError("No crash report named \"\(name)\". Call crash_reports without name to list them.")
        }
        let folder = reportsFolder.appendingPathComponent(serial.filter { $0.isLetter || $0.isNumber || $0 == "-" })
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(crash.name).txt")
        try Data(crash.lines.joined(separator: "\n").utf8).write(to: file)
        let frames = crash.lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("at ") || $0.hasPrefix("#") }
        let date = crash.date.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        return (
            CrashReport(
                app: crash.process, bundleID: crash.process, version: "", date: date, osVersion: "",
                exception: crash.exception, reasons: [], frames: Array(frames.prefix(30))),
            file
        )
    }
}
