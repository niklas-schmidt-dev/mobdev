import Darwin
import Foundation

/// A client for usbmuxd, the Mac's daemon for connections to iOS devices over USB, used the way
/// `iproxy` uses it. Each message is a 16-byte header (total length, version 1, type 8 for a
/// property list, a tag, all little-endian) followed by an XML property list. After a successful
/// `Connect` the socket is a plain TCP stream to a port on the device.
struct USBMux: Sendable {
    struct Device: Sendable, Equatable {
        /// usbmuxd's number for the device while it stays attached.
        var id: Int
        /// The UDID. usbmuxd leaves out the dash of newer ones ("00008120000639440C13C01E").
        var serial: String
        /// "USB", or "Network" for a device paired over Wi-Fi.
        var connection: String
    }

    var socketPath = "/var/run/usbmuxd"

    /// Every device usbmuxd knows.
    func devices(timeout: TimeInterval = 5) throws -> [Device] {
        let socket = try StreamSocket.unix(socketPath, purpose: "usbmuxd")
        let deadline = Date().addingTimeInterval(timeout)
        let reply = try exchange(Self.message("ListDevices"), on: socket, until: deadline)
        return Self.devices(from: reply)
    }

    /// A socket connected to `port` on the device with this UDID, over USB where it can.
    func connect(udid: String, port: UInt16, timeout: TimeInterval = 5) throws -> StreamSocket {
        let wanted = Self.normalized(udid)
        let matches = try devices(timeout: timeout).filter { Self.normalized($0.serial) == wanted }
        guard let device = matches.first(where: { $0.connection == "USB" }) ?? matches.first else {
            throw DeveloperError("usbmuxd does not see the iPhone \(udid). Connect it with a USB cable and unlock it.")
        }
        let socket = try StreamSocket.unix(socketPath, purpose: "usbmuxd")
        let reply = try exchange(
            Self.message("Connect", ["DeviceID": device.id, "PortNumber": Int(port.bigEndian)]), on: socket,
            until: Date().addingTimeInterval(timeout))
        let result = (reply["Number"] as? NSNumber)?.intValue ?? -1
        guard result == 0 else {
            throw DeveloperError(
                result == 3
                    ? "Nothing listens on port \(port) of the iPhone."
                    : "usbmuxd could not connect to port \(port) of the iPhone (result \(result)).")
        }
        return socket
    }

    private func exchange(_ message: [String: Any], on socket: StreamSocket, until deadline: Date) throws -> [String: Any] {
        try socket.write(try Self.packet(message, tag: 1), until: deadline)
        let header = try socket.read(exactly: 16, until: deadline)
        let length = Int(Self.uint32(header, at: 0))
        guard length >= 16, length < 16 * 1024 * 1024 else { throw DeveloperError("usbmuxd sent a message Mobdev cannot read.") }
        let body = try socket.read(exactly: length - 16, until: deadline)
        guard let message = try Self.message(from: header + body)?.message else {
            throw DeveloperError("usbmuxd sent a message Mobdev cannot read.")
        }
        return message
    }

    // MARK: Messages

    /// A request with the fields every client sends.
    static func message(_ type: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var message = fields
        message["MessageType"] = type
        message["ClientVersionString"] = "mobdev"
        message["ProgName"] = "Mobdev"
        message["kLibUSBMuxVersion"] = 3
        return message
    }

    /// A message with its header.
    static func packet(_ message: [String: Any], tag: UInt32) throws -> Data {
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        var header = Data()
        for value in [UInt32(body.count + 16), 1, 8, tag] {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        return header + body
    }

    /// The first message in `data` and its length with the header; nil while it is incomplete.
    static func message(from data: Data) throws -> (message: [String: Any], length: Int)? {
        guard data.count >= 16 else { return nil }
        let length = Int(uint32(data, at: 0))
        guard length >= 16 else { throw DeveloperError("usbmuxd sent a message Mobdev cannot read.") }
        guard data.count >= length else { return nil }
        let body = data.subdata(in: data.startIndex + 16..<data.startIndex + length)
        guard let message = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw DeveloperError("usbmuxd sent a message Mobdev cannot read.")
        }
        return (message, length)
    }

    /// The devices in a `ListDevices` answer.
    static func devices(from reply: [String: Any]) -> [Device] {
        ((reply["DeviceList"] as? [[String: Any]]) ?? []).compactMap { entry in
            let properties = entry["Properties"] as? [String: Any] ?? [:]
            guard let id = (properties["DeviceID"] as? NSNumber ?? entry["DeviceID"] as? NSNumber)?.intValue,
                let serial = properties["SerialNumber"] as? String
            else { return nil }
            return Device(id: id, serial: serial, connection: properties["ConnectionType"] as? String ?? "")
        }
    }

    /// Upper case without dashes, so a UDID matches usbmuxd's serial number either way.
    static func normalized(_ udid: String) -> String { udid.uppercased().filter { $0.isLetter || $0.isNumber } }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + offset + $1]) << (8 * UInt32($1)) }
    }
}

/// A connected stream socket with deadlines on every read and write. Closed when released.
final class StreamSocket: @unchecked Sendable {
    let descriptor: Int32
    private let purpose: String

    private init(_ descriptor: Int32, purpose: String) {
        self.descriptor = descriptor
        self.purpose = purpose
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(descriptor) }

    static func unix(_ path: String, purpose: String) throws -> StreamSocket {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DeveloperError("Could not create a socket: \(String(cString: strerror(errno))).") }
        let socket = StreamSocket(descriptor, purpose: purpose)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw DeveloperError("Could not connect to \(purpose) at \(path): \(String(cString: strerror(errno))).")
        }
        return socket
    }

    /// 127.0.0.1, where a simulator's runner listens.
    static func loopback(port: UInt16, purpose: String) throws -> StreamSocket {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DeveloperError("Could not create a socket: \(String(cString: strerror(errno))).") }
        let socket = StreamSocket(descriptor, purpose: purpose)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw DeveloperError("Could not connect to \(purpose) on port \(port): \(String(cString: strerror(errno))).")
        }
        return socket
    }

    func write(_ data: Data, until deadline: Date) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try wait(for: POLLOUT, until: deadline)
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw DeveloperError("\(purpose) closed the connection.") }
                offset += written
            }
        }
    }

    func read(exactly count: Int, until deadline: Date) throws -> Data {
        var data = Data()
        while data.count < count {
            let chunk = try read(upTo: count - data.count, until: deadline)
            guard !chunk.isEmpty else { throw DeveloperError("\(purpose) closed the connection.") }
            data.append(chunk)
        }
        return data
    }

    /// Everything until the other side closes, at most `limit` bytes.
    func readToEnd(until deadline: Date, limit: Int) throws -> Data {
        var data = Data()
        while true {
            let chunk = try read(upTo: 64 * 1024, until: deadline)
            if chunk.isEmpty { return data }
            data.append(chunk)
            guard data.count <= limit else { throw DeveloperError("\(purpose) sent more than \(limit / 1_048_576) MB.") }
        }
    }

    /// Up to `count` bytes; empty once the other side closed.
    private func read(upTo count: Int, until deadline: Date) throws -> Data {
        try wait(for: POLLIN, until: deadline)
        var buffer = [UInt8](repeating: 0, count: count)
        let received = Darwin.read(descriptor, &buffer, count)
        guard received >= 0 else { throw DeveloperError("Reading from \(purpose) failed: \(String(cString: strerror(errno))).") }
        return Data(buffer[0..<received])
    }

    private func wait(for events: Int32, until deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw DeveloperError("\(purpose) did not answer in time.") }
            var descriptor = pollfd(fd: self.descriptor, events: Int16(events), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 60) * 1000) + 1)
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw DeveloperError("Waiting for \(purpose) failed.") }
        }
    }
}
