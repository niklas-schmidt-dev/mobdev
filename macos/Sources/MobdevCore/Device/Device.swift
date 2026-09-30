import Foundation

/// What kind of device the tools drive.
public enum DeviceKind: String, Sendable, Codable {
    /// A real iPhone or iPad: its screen over USB, input over Bluetooth.
    case iPhone
    /// A booted iOS Simulator on this Mac.
    case simulator
    /// An Android emulator or phone reached through adb.
    case android

    /// "iPhone", "Simulator", "Android": what `list_devices` and the app call it.
    public var label: String {
        switch self {
        case .iPhone: "iPhone"
        case .simulator: "Simulator"
        case .android: "Android"
        }
    }
}

/// Any device the tools can drive, with its own activity log.
public protocol Device: PhoneBackend, AnyObject {
    /// Stable across launches: the UDID for iPhones and simulators, the adb serial for Android.
    var id: String { get }
    var name: String { get }
    var info: DeviceInfo? { get }
    var kind: DeviceKind { get }
    var activity: ActivityLog { get }
}

extension HardwareDevice: Device {
    public var kind: DeviceKind { .iPhone }
}
