import Darwin
import Foundation

/// The Unix-domain socket through which `Mobdev mcp` reaches the app. Only this user's processes
/// can listen on it or connect to it. A loopback port cannot promise that: another user can bind it
/// while the app is not running and collect the token that the next request carries.
enum LocalSocket {
    enum Failure: Error, CustomStringConvertible, Equatable {
        /// Nothing listens, and nothing was sent.
        case notRunning
        /// The socket or its directory could belong to someone else, so nothing was sent.
        case untrusted(String)
        /// Nothing was sent.
        case failed(String)
        /// The request went out, at least partly, and no complete answer came back.
        case interrupted(String)

        var description: String {
            switch self {
            case .notRunning: "Mobdev is not running."
            case .untrusted(let reason), .failed(let reason), .interrupted(let reason): reason
            }
        }
    }

    /// `sun_path` holds 104 bytes, including the terminating zero.
    static let maxPathBytes = 103

    /// Creates the socket's directory if needed, checks that only this user can write to it, and
    /// removes a socket left behind by an earlier run.
    static func prepareToListen(at url: URL) throws {
        guard url.path.utf8.count <= maxPathBytes else {
            throw Failure.failed("The socket path \(url.path) is longer than \(maxPathBytes) bytes.")
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checkPrivate(directory: directory)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else {
                throw Failure.failed("\(url.path) exists and is not a socket.")
            }
            unlink(url.path)
        }
    }

    private static func checkPrivate(directory: URL) throws {
        var info = stat()
        guard stat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.notRunning }
        guard info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw Failure.untrusted("\(directory.path) must belong to you and be writable only by you.")
        }
    }

    /// Sends one request and returns everything the server answers until it closes the connection.
    static func exchange(_ request: Data, at url: URL, timeout: TimeInterval) throws -> Data {
        guard url.path.utf8.count <= maxPathBytes else {
            throw Failure.failed("The socket path \(url.path) is longer than \(maxPathBytes) bytes.")
        }
        try checkPrivate(directory: url.deletingLastPathComponent())
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw Failure.notRunning }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
            throw Failure.untrusted("\(url.path) is not a socket of yours.")
        }

        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw Failure.failed("Could not create a socket: \(String(cString: strerror(errno))).") }
        defer { close(socket) }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: url.path.utf8.prefix(buffer.count - 1))
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            if errno == ECONNREFUSED || errno == ENOENT { throw Failure.notRunning }
            throw Failure.failed("Could not connect to Mobdev: \(String(cString: strerror(errno))).")
        }
        // The file checks above can race with a swap; the kernel's word on who listens cannot.
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0,
            credentials.cr_version == XUCRED_VERSION, credentials.cr_uid == getuid()
        else { throw Failure.untrusted("The process listening on \(url.path) does not run as you.") }

        let deadline = Date().addingTimeInterval(timeout)
        try request.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try wait(socket, for: POLLOUT, until: deadline)
                let written = Darwin.write(socket, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw Failure.interrupted("Mobdev closed the connection.") }
                offset += written
            }
        }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try wait(socket, for: POLLIN, until: deadline)
            let received = Darwin.read(socket, &chunk, chunk.count)
            if received == 0 { return response }
            guard received > 0 else { throw Failure.interrupted("Mobdev closed the connection.") }
            response.append(contentsOf: chunk[0..<received])
        }
    }

    private static func wait(_ socket: Int32, for events: Int32, until deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Failure.interrupted("Mobdev did not answer in time.") }
            var descriptor = pollfd(fd: socket, events: Int16(events), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 60) * 1000) + 1)
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw Failure.interrupted("Waiting for Mobdev failed.") }
        }
    }
}
