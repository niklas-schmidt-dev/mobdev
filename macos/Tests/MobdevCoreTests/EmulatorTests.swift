import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// A simulator or Android device for routing tests: direct input, a fake screen, recorded calls.
final class FakeDevice: Device, @unchecked Sendable {
    let id: String
    let name: String
    let kind: DeviceKind
    let activity = ActivityLog()
    let phone: FakePhone
    let typed = Locked<[String]>([])
    let opened = Locked<[String]>([])
    let wholeText: Bool

    init(id: String, name: String, kind: DeviceKind, wholeText: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.wholeText = wholeText
        phone = FakePhone(lines: [("Hello", 400, 300)])
    }

    var info: DeviceInfo? {
        DeviceInfo(
            id: id, name: name, productType: kind == .android ? "Pixel 9" : "iPhone18,3", osVersion: "27.0",
            buildVersion: "", deviceClass: kind == .android ? "Android" : "iPhone")
    }

    func status() -> PhoneStatus {
        var status = phone.status()
        status.bluetooth = .unsupported("not needed")
        status.input = .direct(kind == .android ? "adb" : "Simulator")
        return status
    }

    func frame() -> CGImage? { phone.frame() }
    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws { try await phone.tap(at: point, hold: hold) }
    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {
        try await phone.swipe(from: start, to: end, duration: duration)
    }
    func scroll(at point: NormalizedPoint, ticks: Int) async throws { try await phone.scroll(at: point, ticks: ticks) }
    func type(_ strokes: [KeyStroke]) async throws { try await phone.type(strokes) }
    func press(_ stroke: KeyStroke) async throws { try await phone.press(stroke) }
    func press(_ button: ConsumerUsage) async throws { try await phone.press(button) }

    func openApp(named name: String) async throws -> String? {
        opened.withLock { $0.append(name) }
        return "Opened \(name)."
    }

    func typeText(_ text: String) async throws -> Bool {
        guard wholeText else { return false }
        typed.withLock { $0.append(text) }
        return true
    }
}

@Suite struct EmulatorRoutingTests {
    let simulator = FakeDevice(id: "5E1D2F3A-0000-4000-8000-000000000001", name: "iPhone 17", kind: .simulator)
    let android = FakeDevice(id: "emulator-5554", name: "Pixel 9 Pro", kind: .android, wholeText: true)

    func tools(_ devices: [any Device]) -> DeviceTools {
        DeviceTools(hub: DeviceHub(keyboardLayout: .us) {}, emulators: EmulatorHub(devices: devices), settleDelay: 0)
    }

    func call(_ tools: DeviceTools, _ name: String, _ arguments: JSONValue = [:]) async throws -> ToolOutput {
        try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
    }

    @Test func listDevicesNamesKindAndSystem() async throws {
        let output = try await call(tools([simulator, android]), "list_devices")
        #expect(output.text.contains("iPhone 17: iPhone 17 Simulator, iOS 27.0, ready."))
        #expect(output.text.contains("Pixel 9 Pro: Pixel 9, Android 27.0, ready. id: emulator-5554"))
        #expect(output.data?.arrayValue?.map { $0["kind"] } == ["simulator", "android"])
        #expect(output.data?.arrayValue?.first?["bluetooth"] == true)
    }

    @Test func aSingleEmulatorNeedsNoDeviceArgument() async throws {
        let tools = tools([android])
        let output = try await call(tools, "tap", ["x": 100, "y": 200])
        #expect(!output.isError)
        #expect(android.phone.events.get().count == 1)
        let status = try await call(tools, "status")
        #expect(status.text.contains("Input: Direct (adb)"))
        #expect(!status.text.contains("Bluetooth"))
        #expect(status.data?["input"]?["route"] == "adb")
    }

    @Test func severalDevicesNeedTheDeviceArgument() async throws {
        let tools = tools([simulator, android])
        let ambiguous = try await call(tools, "home")
        #expect(ambiguous.isError)
        #expect(ambiguous.text.contains("Pass `device`"))
        let byName = try await call(tools, "home", ["device": "Pixel 9 Pro"])
        #expect(!byName.isError)
        #expect(android.phone.events.get() == [.button(.home)])
        let byPrefix = try await call(tools, "home", ["device": "5E1D2F"])
        #expect(!byPrefix.isError)
    }

    @Test func openAppAndTextUseTheDevicesOwnWays() async throws {
        let tools = tools([android])
        let opened = try await call(tools, "open_app", ["name": "Settings"])
        #expect(opened.text == "Opened Settings.")
        #expect(android.opened.get() == ["Settings"])
        #expect(android.phone.events.get().isEmpty)  // No Spotlight on Android.
        let typed = try await call(tools, "type_text", ["text": "hello world", "submit": true])
        #expect(!typed.isError)
        #expect(android.typed.get() == ["hello world"])
        #expect(android.phone.events.get() == [.key(KeyStroke(0x28))])
    }

    @Test func simulatorsTypeKeyByKey() async throws {
        let output = try await call(tools([simulator]), "type_text", ["text": "hi"])
        #expect(!output.isError)
        #expect(simulator.phone.events.get() == [.type([KeyStroke(0x0B), KeyStroke(0x0C)])])
    }
}

@Suite struct AndroidParsingTests {
    @Test func adbDeviceListKeepsReadyDevicesWithTheirProperties() {
        let devices = ADB.parseDevices(
            """
            emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
            R5CT20ABCDE            unauthorized usb:1-1 transport_id:2
            0A1B2C3D               device usb:1-2 product:husky model:Pixel_8_Pro device:husky transport_id:3
            """)
        #expect(devices.map(\.serial) == ["emulator-5554", "0A1B2C3D"])
        #expect(devices[1].properties["model"] == "Pixel_8_Pro")
        #expect(devices[0].isEmulator)
        #expect(!devices[1].isEmulator)
    }

    @Test func screenSizePrefersTheOverride() {
        #expect(AndroidDevice.parseSize("Physical size: 1280x2856\n")! == (1280, 2856))
        #expect(AndroidDevice.parseSize("Physical size: 1080x2400\nOverride size: 720x1600\n")! == (720, 1600))
        #expect(AndroidDevice.parseSize("error") == nil)
    }

    @Test func rawScreenshotsWithBothHeaderSizes() throws {
        for header in [12, 16] {
            var data = Data()
            for value in [2, 3, 1, 1].prefix(header / 4) {
                withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) }
            }
            data.append(contentsOf: [UInt8](repeating: 0x80, count: 2 * 3 * 4))
            let image = try #require(AndroidDevice.image(fromRaw: data))
            #expect(image.width == 2)
            #expect(image.height == 3)
        }
        #expect(AndroidDevice.image(fromRaw: Data([1, 2, 3])) == nil)
    }

    @Test func keysMapToAndroidKeyCodes() {
        #expect(AndroidDevice.keycode(forUsage: 0x04) == 29)  // A
        #expect(AndroidDevice.keycode(forUsage: 0x1D) == 54)  // Z
        #expect(AndroidDevice.keycode(forUsage: 0x27) == 7)  // 0
        #expect(AndroidDevice.keycode(forUsage: 0x28) == 66)  // Enter
        #expect(AndroidDevice.keycode(forUsage: 0x29) == 4)  // Escape is Back
        #expect(AndroidDevice.keycode(forUsage: 0x52) == 19)  // Up
        #expect(AndroidDevice.modifierKeycodes(KeyStroke.command | KeyStroke.shift) == [59, 117])
    }

    @Test func packageListsWithVersions() {
        let packages = AndroidApps.packages("package:com.example.app versionCode:12\npackage:org.other versionCode:3\n")
        #expect(packages.map(\.name) == ["com.example.app", "org.other"])
        #expect(packages.map(\.version) == ["12", "3"])
    }

    @Test func packageNamesAreCheckedBeforeTheShellSeesThem() throws {
        #expect(try ADB.checkPackage("com.example.app_2") == "com.example.app_2")
        #expect(throws: DeveloperError.self) { try ADB.checkPackage("com.example; reboot") }
        #expect(throws: DeveloperError.self) { try ADB.checkPackage("") }
        #expect(ADB.quote("it's") == "'it'\\''s'")
    }

    @Test func javaAndNativeCrashesFromTheCrashBuffer() {
        let crashes = AndroidApps.parseCrashes(
            """
            --------- beginning of crash
            2026-09-30 18:41:48.287  1124  1124 E AndroidRuntime: FATAL EXCEPTION: main
            2026-09-30 18:41:48.287  1124  1124 E AndroidRuntime: Process: com.example.app, PID: 1124
            2026-09-30 18:41:48.287  1124  1124 E AndroidRuntime: java.lang.IllegalStateException: boom
            2026-09-30 18:41:48.287  1124  1124 E AndroidRuntime: \tat com.example.app.MainActivity.onCreate(MainActivity.kt:12)
            2026-09-30 18:41:48.287  1124  1124 E AndroidRuntime: \tat android.app.Activity.performCreate(Activity.java:9002)
            2026-09-30 18:45:01.100  2300  2300 F DEBUG   : *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
            2026-09-30 18:45:01.100  2300  2300 F DEBUG   : Build fingerprint: 'google/sdk/emu64a:16/BP2A/1:user/release-keys'
            2026-09-30 18:45:01.100  2300  2300 F DEBUG   : pid: 2200, tid: 2200, name: native.app  >>> com.example.native <<<
            2026-09-30 18:45:01.100  2300  2300 F DEBUG   : signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0
            2026-09-30 18:45:01.100  2300  2300 F DEBUG   :       #00 pc 0000000000001234  /data/app/lib/arm64/libnative.so (crash+8)
            2026-09-30 18:46:00.000   900   900 F DEBUG   : *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
            2026-09-30 18:46:00.000   900   900 F DEBUG   : pid: 610, tid: 610, name: surfaceflinger  >>> /system/bin/surfaceflinger <<<
            """)
        #expect(crashes.count == 3)
        #expect(crashes[0].process == "com.example.app")
        #expect(crashes[0].exception == "java.lang.IllegalStateException: boom")
        #expect(crashes[0].lines.count == 5)
        #expect(crashes[0].name == "com.example.app-2026-09-30-184148-1124")
        // crash_dump logs a native crash; the app is the pid in the tombstone.
        #expect(crashes[1].process == "com.example.native")
        #expect(crashes[1].pid == 2200)
        #expect(crashes[1].exception == "signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0")
        #expect(crashes[2].name == "_system_bin_surfaceflinger-2026-09-30-184600-610")
    }
}

@Suite struct StuckCaptureTests {
    /// Reads a connected iPhone's USB configuration. Opt-in: MOBDEV_TEST_USB_UDID=<udid>.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOBDEV_TEST_USB_UDID"] != nil))
    func usbProbeFindsTheIPhone() throws {
        let udid = ProcessInfo.processInfo.environment["MOBDEV_TEST_USB_UDID"]!
        let state = try #require(USBProbe.screenState(udid: udid))
        print("USB configuration \(state.configuration), screen interface: \(state.hasScreenInterface)")
        #expect(state.configuration > 0)
        #expect(USBProbe.screenState(udid: "00000000-0000000000000000") == nil)
    }

    /// macOS's screen capture helper can keep a stale iPhone: connected, but never a picture.
    @Test func noPictureIsConnectedButNotReadyAndSaysHowToFixIt() {
        let status = PhoneStatus(
            screen: .noPicture(name: "iPhone"), bluetooth: .connected(hosts: 1), keyboardLayout: .us)
        #expect(status.screen.isConnected)
        #expect(status.frameSize == nil)
        #expect(!status.isReady)
        #expect(status.screen.summary.contains("Restart Screen Capture"))
        #expect(status.screen.summary.contains("sudo killall iOSScreenCaptureAssistant"))
    }

    /// A locked iPhone also sends no picture, but keeps its USB screen interface (seen 2026-10-01);
    /// restarting the helper would not help it, so it is told apart.
    @Test func noPictureWithTheScreenInterfaceMeansLocked() {
        let stuck = ScreenState.noPicture(name: "iPhone")
        let locked = HardwareDevice.screenState(
            stuck, name: "iPhone", usb: USBScreenState(configuration: 7, hasScreenInterface: true))
        #expect(locked == .locked(name: "iPhone"))
        #expect(locked.isConnected)
        #expect(locked.summary.contains("Unlock"))
        #expect(!locked.summary.contains("killall"))
        #expect(
            HardwareDevice.screenState(stuck, name: "iPhone", usb: USBScreenState(configuration: 6, hasScreenInterface: false))
                == stuck)
        #expect(HardwareDevice.screenState(stuck, name: "iPhone", usb: nil) == stuck)
        #expect(!PhoneStatus(screen: locked, bluetooth: .connected(hosts: 1), keyboardLayout: .us).isReady)
    }
}

@Suite struct SimulatorHelperTests {
    @Test func keyboardLayoutFollowsTheSimulatorsKeyboard() {
        #expect(SimulatorDevice.layout(forKeyboard: "de_DE@sw=QWERTZ-German;hw=Automatic") == .german)
        #expect(SimulatorDevice.layout(forKeyboard: "en_US@sw=QWERTY;hw=Automatic") == .us)
        #expect(SimulatorDevice.layout(forKeyboard: "de_DE@sw=QWERTZ-German;hw=U.S.") == .us)
        #expect(SimulatorDevice.layout(forKeyboard: "en_US@sw=QWERTY;hw=German") == .german)
        #expect(SimulatorDevice.layout(forKeyboard: "en_US") == .us)
    }

    @Test func appNamesMatchNameBundleIDOrItsLastPart() throws {
        let apps = [
            InstalledApp(bundleID: "com.android.settings", name: "com.android.settings", version: "", build: "", developer: false, location: nil),
            InstalledApp(bundleID: "com.android.settings.intelligence", name: "com.android.settings.intelligence", version: "", build: "", developer: false, location: nil),
            InstalledApp(bundleID: "com.apple.mobilesafari", name: "Safari", version: "", build: "", developer: false, location: nil),
            InstalledApp(bundleID: "dev.mobdev.fixture", name: "Mobdev Fixture", version: "", build: "", developer: true, location: nil),
            InstalledApp(bundleID: "com.example.notes", name: "Notes", version: "", build: "", developer: true, location: nil),
            InstalledApp(bundleID: "com.example.notebook", name: "Notebook", version: "", build: "", developer: true, location: nil),
        ]
        #expect(try AppMatcher.find("Settings", in: apps).bundleID == "com.android.settings")
        #expect(try AppMatcher.find("safari", in: apps).bundleID == "com.apple.mobilesafari")
        #expect(try AppMatcher.find("Mobdev", in: apps).bundleID == "dev.mobdev.fixture")
        #expect(try AppMatcher.find("notes", in: apps).bundleID == "com.example.notes")
        #expect(throws: DeveloperError.self) { try AppMatcher.find("note", in: apps) }
        #expect(throws: DeveloperError.self) { try AppMatcher.find("Mail", in: apps) }
    }

    @Test func androidFormFactorAndSystemName() {
        let info = DeviceInfo(id: "x", name: "Pixel", productType: "Pixel 9", osVersion: "16", buildVersion: "", deviceClass: "Android")
        #expect(info.formFactor == .android)
        #expect(info.systemName == "Android 16")
        #expect(info.modelName == "Pixel 9")
    }
}
