import Foundation

/// The wire format of scrcpy's server, for the version in `ScrcpyServer`: control messages from the
/// Mac, device messages back, and the headers of the video stream. All numbers are big-endian. The
/// layouts follow scrcpy 3.3.4's app/src/control_msg.c, app/src/device_msg.c and the server's
/// ControlMessageReader, DeviceMessageWriter and Streamer; scrcpy calls the protocol internal and
/// changes it between versions, so it is pinned together with the server.
enum ScrcpyProtocol {
    // MARK: Control messages

    enum ControlType: UInt8 {
        case injectKeycode = 0
        case injectText = 1
        case injectTouchEvent = 2
        case getClipboard = 8
        case setClipboard = 9
        case resetVideo = 17
    }

    /// Android's KeyEvent actions.
    enum KeyAction: UInt8 {
        case down = 0
        case up = 1
    }

    /// Android's MotionEvent actions. The server turns a second finger's down and up into
    /// ACTION_POINTER_DOWN and ACTION_POINTER_UP itself.
    enum TouchAction: UInt8 {
        case down = 0
        case up = 1
        case move = 2
    }

    /// The pointer ids scrcpy uses for a finger and for the second finger of its pinch gesture.
    static let finger = UInt64(bitPattern: -2)
    static let secondFinger = UInt64(bitPattern: -3)

    /// INJECT_TEXT carries at most this many bytes of UTF-8.
    static let injectTextMaxLength = 300
    /// A control message is at most 256 KiB: type, sequence, paste flag and length come first.
    static let clipboardTextMaxLength = (1 << 18) - 14

    static func injectKeycode(_ action: KeyAction, keycode: Int, repeat: Int = 0, metaState: Int = 0) -> Data {
        var data = Data([ControlType.injectKeycode.rawValue, action.rawValue])
        data.append32(UInt32(truncatingIfNeeded: keycode))
        data.append32(UInt32(truncatingIfNeeded: `repeat`))
        data.append32(UInt32(truncatingIfNeeded: metaState))
        return data
    }

    /// Text the server turns into key events through the virtual keyboard's key map. Characters
    /// without a key there are dropped by the server, so callers send printable ASCII only.
    static func injectText(_ text: String) -> Data {
        var data = Data([ControlType.injectText.rawValue])
        data.appendString(text, maxLength: injectTextMaxLength)
        return data
    }

    /// One finger at (x, y) in the pixels of the current video frame, whose size goes along: the
    /// server ignores events made for another size, e.g. from before a rotation.
    static func injectTouch(
        _ action: TouchAction, pointer: UInt64, x: Int, y: Int, width: Int, height: Int, pressure: Float,
        actionButton: UInt32 = 0, buttons: UInt32 = 0
    ) -> Data {
        var data = Data([ControlType.injectTouchEvent.rawValue, action.rawValue])
        data.append64(pointer)
        data.append32(UInt32(truncatingIfNeeded: x))
        data.append32(UInt32(truncatingIfNeeded: y))
        data.append16(UInt16(clamping: width))
        data.append16(UInt16(clamping: height))
        data.append16(unsignedFixedPoint(pressure))
        data.append32(actionButton)
        data.append32(buttons)
        return data
    }

    /// Asks for the device's clipboard. `copyKey` 1 presses Copy first, 2 Cut; 0 neither.
    static func getClipboard(copyKey: UInt8 = 0) -> Data {
        Data([ControlType.getClipboard.rawValue, copyKey])
    }

    /// Sets the device's clipboard, then presses Paste when `paste` is set. A sequence other than
    /// 0 asks for an acknowledgement carrying it.
    static func setClipboard(sequence: UInt64, text: String, paste: Bool) -> Data {
        var data = Data([ControlType.setClipboard.rawValue])
        data.append64(sequence)
        data.append(paste ? 1 : 0)
        data.appendString(text, maxLength: clipboardTextMaxLength)
        return data
    }

    /// Restarts the encoder, which then sends its parameter sets and a key frame again.
    static func resetVideo() -> Data { Data([ControlType.resetVideo.rawValue]) }

    /// scrcpy's sc_float_to_u16fp: 0…1 in 16 bits, 1 as 0xffff.
    static func unsignedFixedPoint(_ value: Float) -> UInt16 {
        let scaled = UInt32(min(max(value, 0), 1) * 65536)
        return scaled >= 0xffff ? 0xffff : UInt16(scaled)
    }

    /// The length of the longest prefix of `bytes` within `maxLength` that does not end inside a
    /// character, as scrcpy's sc_str_utf8_truncation_index.
    static func utf8Prefix(_ bytes: [UInt8], maxLength: Int) -> Int {
        guard bytes.count > maxLength else { return bytes.count }
        var length = maxLength
        // Continuation bytes are 10xxxxxx; the character they belong to starts before them.
        while length > 0, bytes[length] & 0xC0 == 0x80 { length -= 1 }
        return length
    }

    // MARK: Device messages

    enum DeviceMessage: Equatable {
        case clipboard(String)
        case clipboardAcknowledged(UInt64)
        case uhidOutput(id: UInt16, data: Data)
    }

    /// The first message in `buffer` and how many bytes it took, or nil until it is complete.
    static func deviceMessage(in buffer: Data) throws -> (message: DeviceMessage, length: Int)? {
        let bytes = [UInt8](buffer.prefix(5))
        guard let type = bytes.first else { return nil }
        switch type {
        case 0:
            guard bytes.count >= 5 else { return nil }
            let length = Int(read32(bytes, 1))
            guard buffer.count >= 5 + length else { return nil }
            let start = buffer.startIndex + 5
            return (.clipboard(String(decoding: buffer[start..<start + length], as: UTF8.self)), 5 + length)
        case 1:
            guard buffer.count >= 9 else { return nil }
            let sequence = [UInt8](buffer.prefix(9)).dropFirst().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return (.clipboardAcknowledged(sequence), 9)
        case 2:
            guard bytes.count >= 5 else { return nil }
            let id = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
            let size = Int(bytes[3]) << 8 | Int(bytes[4])
            guard buffer.count >= 5 + size else { return nil }
            let start = buffer.startIndex + 5
            return (.uhidOutput(id: id, data: Data(buffer[start..<start + size])), 5 + size)
        default:
            throw DeveloperError("scrcpy sent an unknown device message (type \(type)).")
        }
    }

    // MARK: Video

    /// "h264" as the 32-bit codec id the server sends.
    static let h264: UInt32 = 0x6832_3634

    /// The 12 bytes the video socket starts with: the codec and the size of the first frames.
    struct VideoHeader: Equatable {
        var codec: UInt32
        var width: Int
        var height: Int
    }

    static func videoHeader(_ data: Data) throws -> VideoHeader {
        let bytes = [UInt8](data)
        guard bytes.count == 12 else { throw DeveloperError("scrcpy's video header is incomplete.") }
        let codec = read32(bytes, 0)
        // In place of a codec, 0 means the device turned the stream off and 1 that it failed.
        if codec == 0 { throw DeveloperError("The device turned the video stream off.") }
        if codec == 1 { throw DeveloperError("The device could not encode its screen (see the server's log).") }
        return VideoHeader(codec: codec, width: Int(read32(bytes, 4)), height: Int(read32(bytes, 8)))
    }

    /// The 12 bytes before each packet: flags and timestamp, then the packet's size.
    struct PacketHeader: Equatable {
        /// Parameter sets (SPS and PPS for H.264) rather than a picture.
        var config: Bool
        var keyFrame: Bool
        /// Microseconds; 0 for config packets.
        var pts: UInt64
        var size: Int
    }

    static func packetHeader(_ data: Data) -> PacketHeader {
        let bytes = [UInt8](data)
        let value = bytes[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return PacketHeader(
            config: value & (1 << 63) != 0, keyFrame: value & (1 << 62) != 0, pts: value & ((1 << 62) - 1),
            size: Int(read32(bytes, 8)))
    }

    /// The NAL units of an H.264 packet in Annex B form (each after a 00 00 01 or 00 00 00 01 start
    /// code), without their start codes.
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(code: Int, payload: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                let code = index > 0 && bytes[index - 1] == 0 ? index - 1 : index
                starts.append((code, index + 3))
                index += 3
            } else {
                index += 1
            }
        }
        return starts.enumerated().compactMap { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1].code : bytes.count
            return end > start.payload ? Data(bytes[start.payload..<end]) : nil
        }
    }

    // MARK: Starting the server

    /// The arguments after the class name: the version first (the server refuses another), then
    /// options. The device listens (`tunnel_forward`), there is no audio, the device's clipboard
    /// is sent only when asked for, and the screen stays as it is.
    static func serverArguments(version: String, scid: String, maxSize: Int) -> [String] {
        [
            version, "scid=\(scid)", "log_level=info", "tunnel_forward=true", "audio=false", "control=true",
            "video_codec=h264", "max_size=\(maxSize)", "clipboard_autosync=false", "power_on=false",
        ]
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}

extension Data {
    fileprivate mutating func append16(_ value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)])
    }

    fileprivate mutating func append32(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    fileprivate mutating func append64(_ value: UInt64) {
        append32(UInt32(value >> 32))
        append32(UInt32(value & 0xffff_ffff))
    }

    /// A 32-bit length, then the UTF-8 bytes, cut at a character boundary to `maxLength`.
    fileprivate mutating func appendString(_ text: String, maxLength: Int) {
        let bytes = Array(text.utf8)
        let length = ScrcpyProtocol.utf8Prefix(bytes, maxLength: maxLength)
        append32(UInt32(length))
        append(contentsOf: bytes[0..<length])
    }
}
