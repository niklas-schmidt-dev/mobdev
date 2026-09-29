@preconcurrency import AVFoundation
import CoreImage
import CoreMediaIO
import Foundation

public enum ScreenState: Sendable, Equatable {
    case starting
    case cameraDenied
    case searching
    case connected(name: String, width: Int, height: Int)
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .starting: "Starting screen capture"
        case .cameraDenied: "Camera access is needed to read the iPhone screen"
        case .searching: "Connect an unlocked iPhone with a USB data cable"
        case .connected(let name, let width, let height): "\(name), \(width)×\(height)"
        case .failed(let message): "Screen capture failed: \(message)"
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
    private var observers: [NSObjectProtocol] = []

    public init(onStateChange: @escaping @Sendable (ScreenState) -> Void = { _ in }) {
        self.onStateChange = onStateChange
        super.init()
    }

    public var state: ScreenState { stateBox.get() }

    /// The running session, for a live preview layer.
    public var session: AVCaptureSession? { sessionBox.get() }

    public func start(preferredDeviceID: String? = nil) {
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

    private static func allowScreenCaptureDevices() {
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
        guard let device = devices.first(where: { $0.uniqueID == preferred }) ?? devices.first else {
            setState(.searching)
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
        setState(.connected(name: device.localizedName, width: 0, height: 0))
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
        if case .connected(let name, let oldWidth, let oldHeight) = state, oldWidth != width || oldHeight != height {
            setState(.connected(name: name, width: width, height: height))
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
