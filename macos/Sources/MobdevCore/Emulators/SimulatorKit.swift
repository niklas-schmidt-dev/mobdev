import AppKit
import CoreGraphics
import Foundation
import IOSurface
import ObjectiveC

/// A booted iOS Simulator as CoreSimulator lists it.
public struct BootedSimulator: Sendable, Equatable {
    public var udid: String
    public var name: String
    /// e.g. "iPhone 17".
    public var modelName: String
    /// e.g. "iPhone18,3" when the device type says; empty otherwise.
    public var modelIdentifier: String
    /// e.g. "27.0".
    public var osVersion: String
    /// "iPhone" or "iPad".
    public var deviceClass: String
}

/// Xcode's simulator frameworks, reached through the Objective-C runtime the way Simulator.app,
/// idb and AXe do: CoreSimulator lists devices and their framebuffers, SimulatorKit sends touches,
/// keys and buttons as Indigo HID messages. Loaded on first use; nil without Xcode.
final class SimulatorKit: @unchecked Sendable {
    static let shared: SimulatorKit? = {
        do {
            return try SimulatorKit()
        } catch {
            Log.info("simulators unavailable: \(error)")
            unavailableReason = String(describing: error)
            return nil
        }
    }()

    /// Why `shared` is nil, for messages such as `Mobdev flow`'s.
    nonisolated(unsafe) static var unavailableReason: String?

    private typealias MouseMessage = @convention(c) (
        UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<CGPoint>?, UInt32, UInt, CGSize, UInt
    ) -> UnsafeMutableRawPointer?
    private typealias KeyMessage = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias ButtonMessage = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias SendMessage = @convention(c) (
        AnyObject, Selector, UnsafeMutableRawPointer, Bool, AnyObject?, AnyObject?
    ) -> Void
    /// `init…` returns its object retained, so the result is taken as +1.
    private typealias InitClient = @convention(c) (
        AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> Unmanaged<AnyObject>?

    private let deviceSet: NSObject
    private let mouse: MouseMessage
    private let key: KeyMessage
    private let button: ButtonMessage
    private let clientClass: AnyClass
    private let lock = NSLock()
    private var clients: [String: AnyObject] = [:]

    private init() throws {
        let developer = Self.developerDirectory()
        guard let simulatorKit = Self.simulatorKitBinary(developer: developer) else {
            throw DeveloperError("This Xcode (\(developer.deletingLastPathComponent().deletingLastPathComponent().path)) has no SimulatorKit.")
        }
        for path in ["/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", simulatorKit] {
            guard dlopen(path, RTLD_NOW) != nil else {
                throw DeveloperError("Could not load \(path): \(String(cString: dlerror()))")
            }
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
                throw DeveloperError("This Xcode has no \(name).")
            }
            return unsafeBitCast(pointer, to: type)
        }
        mouse = try symbol("IndigoHIDMessageForMouseNSEvent", as: MouseMessage.self)
        key = try symbol("IndigoHIDMessageForKeyboardArbitrary", as: KeyMessage.self)
        button = try symbol("IndigoHIDMessageForButton", as: ButtonMessage.self)
        guard let contextClass = NSClassFromString("SimServiceContext"),
            let clientClass = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient")
        else { throw DeveloperError("This Xcode's simulator frameworks are not supported.") }
        self.clientClass = clientClass

        typealias ContextFn = @convention(c) (
            AnyClass, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> AnyObject?
        let contextSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let contextMethod = class_getClassMethod(contextClass, contextSelector) else {
            throw DeveloperError("CoreSimulator has no service context.")
        }
        var error: NSError?
        let context = unsafeBitCast(method_getImplementation(contextMethod), to: ContextFn.self)(
            contextClass, contextSelector, developer.path as NSString, &error)
        guard let context else { throw DeveloperError("CoreSimulator: \(error?.localizedDescription ?? "no context")") }

        typealias SetFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        let setSelector = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let setMethod = class_getMethodImplementation(object_getClass(context), setSelector),
            let deviceSet = unsafeBitCast(setMethod, to: SetFn.self)(context, setSelector, &error) as? NSObject
        else { throw DeveloperError("CoreSimulator: \(error?.localizedDescription ?? "no device set")") }
        self.deviceSet = deviceSet
    }

    /// SimulatorKit's binary: where the framework's bundle says, else its usual places. On GitHub's
    /// macOS 26 runner, Xcode 26.6 had the framework without a binary at the top of it (2026-10-01).
    static func simulatorKitBinary(developer: URL) -> String? {
        let xcode = developer.deletingLastPathComponent()
        let frameworks = [
            xcode.appendingPathComponent("SharedFrameworks/SimulatorKit.framework"),
            developer.appendingPathComponent("Library/PrivateFrameworks/SimulatorKit.framework"),
            URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/SimulatorKit.framework"),
        ]
        for framework in frameworks {
            let candidates: [String?] = [
                Bundle(url: framework)?.executableURL?.path,
                framework.appendingPathComponent("SimulatorKit").path,
                framework.appendingPathComponent("Versions/A/SimulatorKit").path,
                framework.appendingPathComponent("Versions/Current/SimulatorKit").path,
            ]
            if let found = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0) }) {
                return found
            }
        }
        return nil
    }

    /// `DEVELOPER_DIR`, else the Xcode chosen with `xcode-select`, else /Applications/Xcode.app.
    /// Command Line Tools have no simulators, so they fall back to Xcode too.
    static func developerDirectory() -> URL {
        var candidates: [String] = []
        if let custom = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !custom.isEmpty { candidates.append(custom) }
        if let selected = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            candidates.append(selected)
        }
        candidates.append("/Applications/Xcode.app/Contents/Developer")
        let found = candidates.first { simulatorKitBinary(developer: URL(fileURLWithPath: $0)) != nil }
        return URL(fileURLWithPath: found ?? candidates.last!)
    }

    // MARK: Devices

    /// Booted iOS and iPadOS simulators.
    func bootedSimulators() -> [BootedSimulator] {
        let devices = (deviceSet.value(forKey: "devices") as? [NSObject]) ?? []
        return devices.compactMap { device -> BootedSimulator? in
            // SimDeviceState: 3 is Booted.
            guard (device.value(forKey: "state") as? NSNumber)?.intValue == 3,
                let udid = (device.value(forKey: "UDID") as? NSUUID)?.uuidString
            else { return nil }
            let runtime = device.value(forKey: "runtime") as? NSObject
            let runtimeName = runtime?.value(forKey: "name") as? String ?? ""
            guard runtimeName.hasPrefix("iOS") || runtimeName.hasPrefix("iPadOS") else { return nil }
            let type = device.value(forKey: "deviceType") as? NSObject
            let modelName = type?.value(forKey: "name") as? String ?? "iPhone"
            let identifier =
                type.flatMap { $0.responds(to: NSSelectorFromString("modelIdentifier")) ? $0.value(forKey: "modelIdentifier") as? String : nil }
                ?? ""
            return BootedSimulator(
                udid: udid, name: device.value(forKey: "name") as? String ?? modelName, modelName: modelName,
                modelIdentifier: identifier, osVersion: runtime?.value(forKey: "versionString") as? String ?? "",
                deviceClass: modelName.hasPrefix("iPad") ? "iPad" : "iPhone")
        }
    }

    private func device(_ udid: String) -> NSObject? {
        let devices = (deviceSet.value(forKey: "devices") as? [NSObject]) ?? []
        return devices.first { ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid }
    }

    /// The frontmost app's accessibility elements. Blocks for a few seconds.
    func elements(_ udid: String) throws -> [UIElement] {
        if let helper = SimulatorAccessibility.helper { return try SimulatorAccessibility.elements(udid, helper: helper) }
        return try elementsInProcess(udid)
    }

    /// Reads the tree in this process. The translator keeps what it first learned about an app
    /// instance, so an app that restarted while this process runs can stay empty; `Mobdev` uses a
    /// short-lived helper process instead (`SimulatorAccessibility.helper`).
    func elementsInProcess(_ udid: String) throws -> [UIElement] {
        guard let device = device(udid) else { throw DeveloperError("The simulator \(udid) is not booted.") }
        return try SimulatorAccessibility.shared.get().elements(of: device, udid: udid)
    }

    /// The frontmost app's name, in a helper process like the tree.
    func frontmostApp(_ udid: String) throws -> String {
        if let helper = SimulatorAccessibility.helper { return try SimulatorAccessibility.frontmost(udid, helper: helper) }
        return try frontmostAppInProcess(udid)
    }

    func frontmostAppInProcess(_ udid: String) throws -> String {
        guard let device = device(udid) else { throw DeveloperError("The simulator \(udid) is not booted.") }
        return try SimulatorAccessibility.shared.get().frontmostName(of: device)
    }

    // MARK: Screen

    /// The simulator's main display as an image, read from its framebuffer surface.
    func frame(_ udid: String) -> CGImage? {
        guard let surface = framebuffer(udid) else { return nil }
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let row = IOSurfaceGetBytesPerRow(surface)
        guard width > 0, height > 0, IOSurfaceGetPixelFormat(surface) == 0x4247_5241 /* BGRA */ else { return nil }
        let data = Data(bytes: IOSurfaceGetBaseAddress(surface), count: row * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The display's size in pixels without copying it.
    func screenSize(_ udid: String) -> (width: Int, height: Int)? {
        guard let surface = framebuffer(udid) else { return nil }
        let size = (IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface))
        return size.0 > 0 && size.1 > 0 ? size : nil
    }

    /// The first IO port whose descriptor renders to an IOSurface: the main screen.
    private func framebuffer(_ udid: String) -> IOSurfaceRef? {
        guard let device = device(udid), let io = device.value(forKey: "io") as? NSObject else { return nil }
        for port in (io.value(forKey: "ioPorts") as? [NSObject]) ?? [] {
            // Ports are remote proxies: plain messages work, key-value coding does not.
            guard let descriptor = port.perform(NSSelectorFromString("descriptor"))?.takeUnretainedValue() as? NSObject,
                descriptor.responds(to: NSSelectorFromString("framebufferSurface")),
                let surface = descriptor.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue(),
                CFGetTypeID(surface) == IOSurfaceGetTypeID()
            else { continue }
            return unsafeDowncast(surface, to: IOSurfaceRef.self)
        }
        return nil
    }

    // MARK: Input

    enum Touch { case down, drag, up }

    /// One touch event at a point given as fractions of the screen.
    func touch(_ udid: String, _ phase: Touch, at point: NormalizedPoint) throws {
        let type: NSEvent.EventType = switch phase {
        case .down: .leftMouseDown
        case .drag: .leftMouseDragged
        case .up: .leftMouseUp
        }
        var location = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        // 0x32 is the digitizer. SimulatorKit drops drags less than 16 ms apart and returns nil.
        guard let message = mouse(&location, nil, 0x32, UInt(type.rawValue), CGSize(width: 1, height: 1), 0) else {
            return
        }
        try send(udid, message)
    }

    /// A key by its USB HID usage (page 7).
    func key(_ udid: String, usage: UInt32, down: Bool) throws {
        guard let message = key(usage, down ? 1 : 2) else { throw DeveloperError("Could not build a key event.") }
        try send(udid, message)
    }

    enum Button: UInt32 {
        case home = 0x0
        case lock = 0x1
    }

    func button(_ udid: String, _ button: Button, down: Bool) throws {
        // 0x33 targets the hardware buttons.
        guard let message = self.button(button.rawValue, down ? 1 : 2, 0x33) else {
            throw DeveloperError("Could not build a button event.")
        }
        try send(udid, message)
    }

    private struct NoAnswer: Error {}

    /// Sends a message SimulatorKit allocated, then frees it. Retries once with a new client, since
    /// a simulator that rebooted invalidates the old one.
    private func send(_ udid: String, _ message: UnsafeMutableRawPointer) throws {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                try deliver(message, with: try hidClient(udid, fresh: attempt > 0))
                free(message)
                return
            } catch is NoAnswer {
                // Not freed: SimulatorKit may still read it. The next event gets a new client.
                forget(udid)
                throw DeveloperError("The simulator did not answer.")
            } catch {
                lastError = error
            }
        }
        free(message)
        throw lastError ?? DeveloperError("Could not reach the simulator.")
    }

    private func deliver(_ message: UnsafeMutableRawPointer, with client: AnyObject) throws {
        let selector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let method = class_getMethodImplementation(clientClass, selector) else {
            throw DeveloperError("This Xcode's HID client cannot send messages.")
        }
        let done = DispatchSemaphore(value: 0)
        let failure = Locked<Error?>(nil)
        let completion: @convention(block) (NSError?) -> Void = { error in
            failure.set(error)
            done.signal()
        }
        unsafeBitCast(method, to: SendMessage.self)(
            client, selector, message, false, DispatchQueue.global(), completion as AnyObject)
        guard done.wait(timeout: .now() + 5) == .success else { throw NoAnswer() }
        if let error = failure.get() { throw error }
    }

    private func hidClient(_ udid: String, fresh: Bool) throws -> AnyObject {
        lock.lock()
        defer { lock.unlock() }
        if !fresh, let existing = clients[udid] { return existing }
        guard let device = device(udid) else { throw DeveloperError("The simulator \(udid) is not booted.") }
        let selector = NSSelectorFromString("initWithDevice:error:")
        guard let method = class_getMethodImplementation(clientClass, selector),
            let allocated = (clientClass as? NSObject.Type)?.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        else { throw DeveloperError("This Xcode's HID client cannot be created.") }
        var error: NSError?
        guard let client = unsafeBitCast(method, to: InitClient.self)(allocated, selector, device, &error)?.takeRetainedValue()
        else {
            throw DeveloperError("Could not connect to the simulator: \(error?.localizedDescription ?? "unknown error")")
        }
        clients[udid] = client
        return client
    }

    /// Drops a simulator's HID client, after it stopped answering or the simulator shut down.
    func forget(_ udid: String) {
        lock.lock()
        clients[udid] = nil
        lock.unlock()
    }
}
