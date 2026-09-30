import Foundation

/// Reads name, model and iOS version of USB-connected iPhones and iPads through usbmuxd, the way
/// Finder does. lockdownd answers these without a pairing session, so nothing is written to the
/// device and no pairing record (readable only by root on macOS) is needed.
public enum USBDevices {
    /// How long one exchange with usbmuxd or one device may take in total. Each read also times out
    /// on its own, but a device that trickles its answer must not hold up the scan for long.
    static let exchangeTimeout: TimeInterval = 5

    /// Every USB-connected device that answers. Blocking; call off the main thread.
    public static func read() -> [DeviceInfo] {
        guard let reply = try? Muxd.request(["MessageType": "ListDevices"], deadline: .now + exchangeTimeout),
            let list = reply["DeviceList"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry -> DeviceInfo? in
            guard let properties = entry["Properties"] as? [String: Any],
                properties["ConnectionType"] as? String == "USB",
                let deviceID = properties["DeviceID"] as? Int
            else { return nil }
            return try? info(deviceID: deviceID)
        }
    }

    private static func info(deviceID: Int) throws -> DeviceInfo? {
        let deadline = Date.now + exchangeTimeout
        let socket = try Muxd.connect(deviceID: deviceID, port: 62078, deadline: deadline)
        defer { close(socket) }
        let reply = try Lockdown.request(socket, ["Label": "mobdev", "Request": "GetValue"], deadline: deadline)
        guard let values = reply["Value"] as? [String: Any], let id = values["UniqueDeviceID"] as? String else {
            return nil
        }
        return DeviceInfo(
            id: id,
            name: values["DeviceName"] as? String ?? "iPhone",
            productType: values["ProductType"] as? String ?? "",
            osVersion: values["ProductVersion"] as? String ?? "",
            buildVersion: values["BuildVersion"] as? String ?? "",
            deviceClass: values["DeviceClass"] as? String ?? "iPhone",
            colorCode: values["DeviceColor"] as? String)
    }
}

enum DeviceIOError: Error {
    case socket, closed, badReply, timedOut
}

/// usbmuxd: 16-byte little-endian header (length, version 1, type 8 = plist, tag), then an XML plist.
private enum Muxd {
    static func request(_ message: [String: Any], deadline: Date) throws -> [String: Any] {
        let socket = try open()
        defer { close(socket) }
        try send(socket, message, deadline: deadline)
        return try receive(socket, deadline: deadline)
    }

    /// A socket tunnelled to a TCP port on the device.
    static func connect(deviceID: Int, port: UInt16, deadline: Date) throws -> Int32 {
        let socket = try open()
        do {
            try send(
                socket, ["MessageType": "Connect", "DeviceID": deviceID, "PortNumber": Int(port.bigEndian)],
                deadline: deadline)
            guard (try receive(socket, deadline: deadline))["Number"] as? Int == 0 else { throw DeviceIOError.badReply }
            return socket
        } catch {
            close(socket)
            throw error
        }
    }

    private static func open() throws -> Int32 {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw DeviceIOError.socket }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = "/var/run/usbmuxd"
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(socket)
            throw DeviceIOError.socket
        }
        return socket
    }

    private static func send(_ socket: Int32, _ message: [String: Any], deadline: Date) throws {
        var message = message
        message["ClientVersionString"] = "mobdev"
        message["ProgName"] = "mobdev"
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        var header = Data()
        for value in [UInt32(16 + body.count), 1, 8, 1] { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        try IO.write(socket, header + body, deadline: deadline)
    }

    private static func receive(_ socket: Int32, deadline: Date) throws -> [String: Any] {
        let header = try IO.read(socket, count: 16, deadline: deadline)
        let length = Int(header.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard length >= 16, length < 1 << 20 else { throw DeviceIOError.badReply }
        let body = try IO.read(socket, count: length - 16, deadline: deadline)
        guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw DeviceIOError.badReply
        }
        return plist
    }
}

/// lockdownd: 4-byte big-endian length, then an XML plist.
private enum Lockdown {
    static func request(_ socket: Int32, _ message: [String: Any], deadline: Date) throws -> [String: Any] {
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        try IO.write(socket, withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) } + body, deadline: deadline)
        let length = Int(
            try IO.read(socket, count: 4, deadline: deadline).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                .bigEndian)
        guard length > 0, length < 1 << 20 else { throw DeviceIOError.badReply }
        guard
            let plist = try PropertyListSerialization.propertyList(
                from: try IO.read(socket, count: length, deadline: deadline), format: nil)
            as? [String: Any]
        else { throw DeviceIOError.badReply }
        return plist
    }
}

/// Blocking reads and writes. Each call times out after 3 seconds (SO_RCVTIMEO, SO_SNDTIMEO), and
/// none continues past `deadline`.
private enum IO {
    static func write(_ socket: Int32, _ data: Data, deadline: Date) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard Date.now < deadline else { throw DeviceIOError.timedOut }
                let written = Darwin.write(socket, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw DeviceIOError.closed }
                offset += written
            }
        }
    }

    static func read(_ socket: Int32, count: Int, deadline: Date) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < count {
                guard Date.now < deadline else { throw DeviceIOError.timedOut }
                let received = Darwin.read(socket, buffer.baseAddress! + offset, count - offset)
                guard received > 0 else { throw DeviceIOError.closed }
                offset += received
            }
        }
        return data
    }
}
