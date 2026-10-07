import Foundation

/// Report IDs live in each Report characteristic's Report Reference descriptor (0x2908),
/// so notification payloads leave the ID byte out.
public enum ReportID: UInt8, CaseIterable, Sendable {
    case keyboard = 1
    case absolutePointer = 2
    case relativeMouse = 3
    case consumer = 4

    /// Payload length in bytes, without the report ID.
    public var length: Int {
        switch self {
        case .keyboard: 8
        case .absolutePointer: 5
        case .relativeMouse: 5
        case .consumer: 2
        }
    }

    var name: String {
        switch self {
        case .keyboard: "keyboard"
        case .absolutePointer: "pointer"
        case .relativeMouse: "click"
        case .consumer: "Home button"
        }
    }
}

/// The HID report descriptor the iPhone reads when it pairs.
///
/// iOS places the AssistiveTouch pointer directly from the absolute pointer's X and Y, so taps
/// need no calibration. It ignores that pointer's buttons, so clicks and the scroll wheel go
/// through the relative mouse. Technique documented by iphone-use (MIT) and sryo/clak.
public enum HIDReportMap {
    public static let absoluteMax = 32767

    public static let descriptor: [UInt8] = keyboard + absolutePointer + relativeMouse + consumer

    // Input: modifiers, reserved, 6 key codes. Output: 5 LED bits.
    static let keyboard: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
        0x85, ReportID.keyboard.rawValue,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x73,
        0x05, 0x07, 0x19, 0x00, 0x29, 0x73, 0x81, 0x00,
        0xC0,
    ]

    // Input: buttons, X (u16 LE), Y (u16 LE), both 0...absoluteMax.
    static let absolutePointer: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x85, ReportID.absolutePointer.rawValue,
        0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01,
        0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31,
        0x16, 0x00, 0x00, 0x26, 0xFF, 0x7F,
        0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
        0xC0, 0xC0,
    ]

    // Input: buttons, dX, dY, wheel, sideways wheel (AC Pan) (signed bytes). AC Pan in a second
    // mouse of its own scrolled sideways, but then iOS took no more drags from this one (2026-10-02).
    static let relativeMouse: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x85, ReportID.relativeMouse.rawValue,
        0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01,
        0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
        0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
        0x05, 0x0C, 0x0A, 0x38, 0x02,
        0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
        0xC0, 0xC0,
    ]

    // Input: one 16-bit consumer usage.
    static let consumer: [UInt8] = [
        0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01,
        0x85, ReportID.consumer.rawValue,
        0x15, 0x00, 0x26, 0xFF, 0x03, 0x19, 0x00, 0x2A, 0xFF, 0x03,
        0x75, 0x10, 0x95, 0x01, 0x81, 0x00,
        0xC0,
    ]

    /// Absolute pointer report for a point given as fractions of the screen (0...1, top-left origin).
    public static func absolutePointerReport(x: Double, y: Double, buttons: UInt8 = 0) -> [UInt8] {
        let max = Double(absoluteMax)
        let px = UInt16(Swift.max(0, Swift.min(max, (x * max).rounded())))
        let py = UInt16(Swift.max(0, Swift.min(max, (y * max).rounded())))
        return [buttons, UInt8(px & 0xFF), UInt8(px >> 8), UInt8(py & 0xFF), UInt8(py >> 8)]
    }

    public static func relativeMouseReport(
        buttons: UInt8, dx: Int = 0, dy: Int = 0, wheel: Int = 0, pan: Int = 0
    ) -> [UInt8] {
        [buttons, byte(dx), byte(dy), byte(wheel), byte(pan)]
    }

    private static func byte(_ value: Int) -> UInt8 { UInt8(bitPattern: Int8(Swift.max(-127, Swift.min(127, value)))) }

    public static func keyboardReport(modifiers: UInt8, usage: UInt8?) -> [UInt8] {
        [modifiers, 0, usage ?? 0, 0, 0, 0, 0, 0]
    }

    public static func consumerReport(usage: UInt16) -> [UInt8] {
        [UInt8(usage & 0xFF), UInt8(usage >> 8)]
    }
}

/// Consumer-page usages iOS responds to from a Bluetooth keyboard.
public enum ConsumerUsage: UInt16, Sendable {
    case home = 0x0223
    /// AC Search, the Spotlight key of Apple keyboards. ⌘Space does not open Spotlight on iPhone.
    case search = 0x0221
    case volumeUp = 0x00E9
    case volumeDown = 0x00EA
    case mute = 0x00E2
    case playPause = 0x00CD
    /// The side button. Only simulators and Android get it: Mobdev could not unlock an iPhone again.
    case power = 0x0030
}
