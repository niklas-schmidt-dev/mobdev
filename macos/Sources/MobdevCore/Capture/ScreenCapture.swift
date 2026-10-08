@preconcurrency import AVFoundation
import CoreImage
import CoreMediaIO
import Foundation

public enum ScreenState: Sendable, Equatable {
    case starting
    case cameraDenied
    case searching
    case connected(name: String, width: Int, height: Int)
    /// Connected, but no picture arrives however often the capture starts again. macOS's screen
    /// capture helper (iOSScreenCaptureAssistant) can keep a stale device after Apple's USB
    /// service restarts, for example after a macOS or Xcode update; restarting the helper fixes it.
    case noPicture(name: String)
    /// Connected without a picture because the iPhone is locked. It keeps its USB screen interface
    /// then, which a stuck helper leaves it without, so `HardwareDevice` tells the two apart.
    case locked(name: String)
    case failed(String)

    public var isConnected: Bool {
        switch self {
        case .connected, .noPicture, .locked: true
        default: false
        }
    }

    public var summary: String {
        switch self {
        case .starting: "Starting screen capture"
        case .cameraDenied: "Camera access is needed to read the iPhone screen"
        case .searching: "Connect an unlocked iPhone with a USB data cable"
        case .connected(let name, let width, let height): "\(name), \(width)×\(height)"
        case .noPicture(let name):
            "\(name) is connected, but macOS delivers no picture. Its screen capture helper is stuck: click Restart Screen Capture in Mobdev, or run `sudo killall iOSScreenCaptureAssistant`"
        case .locked(let name): "\(name) is locked. Unlock it to see its screen; Mobdev cannot enter the passcode"
        case .failed(let message): "Screen capture failed: \(message)"
        }
    }

    /// The same state for the device called `name`.
    func named(_ name: String) -> ScreenState {
        switch self {
        case .connected(_, let width, let height): .connected(name: name, width: width, height: height)
        case .noPicture: .noPicture(name: name)
        case .locked: .locked(name: name)
        default: self
        }
    }
}

public struct CaptureDeviceInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
}

/// Reads the iPhone screen over USB. A trusted iPhone shows up as a muxed capture device once
/// screen-capture devices are allowed, the same switch QuickTime flips.
public final class ScreenCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.mobdev.capture")
    private let onStateChange: @Sendable (ScreenState) -> Void
    private let stateBox = Locked<ScreenState>(.starting)
    private let latest = Locked<CVPixelBuffer?>(nil)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let preferredID = Locked<String?>(nil)
    private let sessionBox = Locked<AVCaptureSession?>(nil)
    private let started = Locked(false)
    private let onlyDeviceID: String?
    private var observers: [NSObjectProtocol] = []
    // Only touched on `queue`.
    private var retryScheduled = false
    private var stopped = false
    private var frameWait: TimeInterval = 5

    /// The capture device this capture is pinned to, if any.
    public var pinnedDeviceID: String? { onlyDeviceID }

    /// `onlyDeviceID` pins the capture to one device; without it the preferred or first iPhone is used.
    public init(onlyDeviceID: String? = nil, onStateChange: @escaping @Sendable (ScreenState) -> Void = { _ in }) {
        self.onlyDeviceID = onlyDeviceID
        self.onStateChange = onStateChange
        super.init()
    }

    /// iPhones and iPads that can be captured right now.
    public static func devices() -> [CaptureDeviceInfo] {
        allowScreenCaptureDevices()
        return phoneDevices().map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    public var state: ScreenState { stateBox.get() }

    /// The running session, for a live preview layer.
    public var session: AVCaptureSession? { sessionBox.get() }

    /// Starts watching for the iPhone. Later calls do nothing.
    public func start(preferredDeviceID: String? = nil) {
        guard !started.withLock({ let was = $0; $0 = true; return was }) else { return }
        preferredID.set(preferredDeviceID)
        Self.allowScreenCaptureDevices()
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) {
                [weak self] _ in
                guard let self else { return }
                self.queue.async { self.connect() }
            })
        observers.append(
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) {
                [weak self] note in
                guard let self else { return }
                let id = (note.object as? AVCaptureDevice)?.uniqueID
                self.queue.async { self.disconnect(id) }
            })

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async { self.connect() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.queue.async { granted ? self.connect() : self.setState(.cameraDenied) }
            }
        default:
            setState(.cameraDenied)
        }
        // A device can take a few seconds to appear after the screen-capture switch flips.
        queue.asyncAfter(deadline: .now() + 2) { self.connect() }
    }

    public func select(deviceID: String?) {
        preferredID.set(deviceID)
        queue.async {
            self.stopSession()
            self.connect()
        }
    }

    /// Starts the capture again now, e.g. after macOS's screen capture helper was restarted.
    public func restart() {
        queue.async {
            guard !self.stopped else { return }
            self.frameWait = 5
            self.stopSession()
            self.connect()
        }
    }

    /// Stops capturing and watching; used when a device's entry is replaced.
    public func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        queue.async {
            self.stopped = true
            self.stopSession()
        }
    }

    public func availableDevices() -> [CaptureDeviceInfo] {
        Self.phoneDevices().map { CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The most recent frame at full resolution.
    public func frame() -> CGImage? {
        guard let buffer = latest.get() else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent)
    }

    // MARK: Session

    static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    private static func phoneDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
            .devices
            .filter { $0.modelID.contains("iOS") || $0.localizedName.localizedCaseInsensitiveContains("iphone") }
    }

    private func connect() {
        guard sessionBox.get() == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            if AVCaptureDevice.authorizationStatus(for: .video) != .notDetermined { setState(.cameraDenied) }
            return
        }
        let devices = Self.phoneDevices()
        let preferred = preferredID.get()
        let candidate: AVCaptureDevice?
        if let onlyDeviceID {
            candidate = devices.first { $0.uniqueID == onlyDeviceID }
        } else {
            candidate = devices.first { $0.uniqueID == preferred } ?? devices.first
        }
        guard let device = candidate else {
            setState(.searching)
            retryLater()
            return
        }
        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CaptureError.rejected("input") }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw CaptureError.rejected("output") }
            session.addOutput(output)
        } catch {
            setState(.failed(String(describing: error)))
            return
        }
        session.startRunning()
        sessionBox.set(session)
        Log.info("capturing \(device.localizedName) (\(device.modelID))")
        // Once restarts have not helped, keep saying so while trying again.
        if case .noPicture = state {
            setState(.noPicture(name: device.localizedName))
        } else {
            setState(.connected(name: device.localizedName, width: 0, height: 0))
        }
        expectFrame(from: session)
    }

    /// A session can run without ever delivering a frame. Without a first frame in time, the
    /// session is started again, after 5, 10, 20 and then every 30 seconds until a frame arrives.
    /// After the second try the state becomes `noPicture`: then macOS's screen capture helper is
    /// usually stuck, which only restarting the helper fixes.
    private func expectFrame(from session: AVCaptureSession) {
        let delay = frameWait
        queue.asyncAfter(deadline: .now() + delay) {
            guard !self.stopped, self.sessionBox.get() === session else { return }
            let name: String
            switch self.state {
            case .connected(let connected, 0, 0): name = connected
            case .noPicture(let stalled): name = stalled
            default: return
            }
            Log.info("no frame after \(Int(delay)) s, starting the screen capture again")
            if delay >= 10 { self.setState(.noPicture(name: name)) }
            self.frameWait = min(delay * 2, 30)
            self.stopSession()
            self.connect()
        }
    }

    /// A locked iPhone offers no screen, and a running app is not always told when it is unlocked
    /// later, so look again every few seconds until the screen appears.
    private func retryLater() {
        guard !retryScheduled, !stopped else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + 3) {
            self.retryScheduled = false
            guard !self.stopped, self.sessionBox.get() == nil else { return }
            Self.allowScreenCaptureDevices()
            self.connect()
        }
    }

    private func disconnect(_ deviceID: String?) {
        guard let session = sessionBox.get() else { return }
        let inUse = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device.uniqueID }
        guard deviceID == nil || inUse.contains(deviceID ?? "") else { return }
        stopSession()
        setState(.searching)
        connect()
    }

    private func stopSession() {
        sessionBox.get()?.stopRunning()
        sessionBox.set(nil)
        latest.set(nil)
    }

    public func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latest.set(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        switch state {
        case .connected(let name, let oldWidth, let oldHeight) where oldWidth != width || oldHeight != height:
            frameWait = 5
            setState(.connected(name: name, width: width, height: height))
        case .noPicture(let name):
            Log.info("pictures arrive again")
            frameWait = 5
            setState(.connected(name: name, width: width, height: height))
        default:
            break
        }
    }

    private func setState(_ state: ScreenState) {
        let changed = stateBox.withLock { current -> Bool in
            guard current != state else { return false }
            current = state
            return true
        }
        if changed { onStateChange(state) }
    }

    enum CaptureError: Error, CustomStringConvertible {
        case rejected(String)
        var description: String {
            switch self {
            case .rejected(let what): "the capture session rejected the \(what)"
            }
        }
    }
}
