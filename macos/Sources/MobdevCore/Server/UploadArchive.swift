import Darwin
import Foundation

/// Unpacks a zipped .app that someone sent over the network, refusing zips that would write
/// outside their folder. The zip's central directory is read first, so `../` paths, absolute
/// paths, paths through one of the zip's own symlinks, more than one top-level .app and sizes
/// beyond the limit are refused before anything is written. After `ditto` unpacked it into a fresh
/// folder, every symlink must stay inside that folder, special files are refused and setuid bits
/// dropped.
enum UploadArchive {
    struct Entry: Equatable {
        var name: String
        var isDirectory: Bool
        var isSymlink: Bool
        /// Uncompressed, as the zip claims.
        var size: UInt64
    }

    /// Checks `zip` and unpacks it into `destination`, which is replaced. Returns the .app.
    static func unpack(_ zip: URL, name: String, into destination: URL, maxEntries: Int, maxBytes: UInt64)
        async throws -> URL
    {
        let app = try check(try entries(of: zip, name: name, maxEntries: maxEntries), name: name, maxBytes: maxBytes)
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        try manager.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, destination.path], timeout: 600)
        guard result.status == 0 else {
            try? manager.removeItem(at: destination)
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            throw UploadError(422, "\(name) could not be unpacked\(detail.isEmpty ? "" : ": \(detail)").")
        }
        do {
            return try checkTree(destination, app: app, name: name)
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    // MARK: The zip's directory

    /// The entries of the zip's central directory, zip64 included.
    static func entries(of url: URL, name: String, maxEntries: Int) throws -> [Entry] {
        let notZip = UploadError(422, "\(name) is not a zip file, or it is damaged.")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length >= 22 else { throw notZip }
        // The end record is in the last 22 bytes plus a comment of up to 64 KiB; a zip64 locator
        // comes right before it.
        let tailLength = min(length, 22 + 0xFFFF + 20)
        try handle.seek(toOffset: length - tailLength)
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        var end: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail.le32(index) == 0x0605_4b50 {
                end = index
                break
            }
            index -= 1
        }
        guard let end, var count = tail.le16(end + 10).map(UInt64.init), var size = tail.le32(end + 12),
            var offset = tail.le32(end + 16)
        else { throw notZip }
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            guard end >= 20, tail.le32(end - 20) == 0x0706_4b50, let recordOffset = tail.le64(end - 12),
                length >= 56, recordOffset <= length - 56
            else { throw notZip }
            try handle.seek(toOffset: recordOffset)
            let record = try handle.read(upToCount: 56) ?? Data()
            guard record.le32(0) == 0x0606_4b50, let count64 = record.le64(32), let size64 = record.le64(40),
                let offset64 = record.le64(48)
            else { throw notZip }
            (count, size, offset) = (count64, size64, offset64)
        }
        guard count <= UInt64(maxEntries) else {
            throw UploadError(422, "\(name) has \(count) entries; at most \(maxEntries) are allowed.")
        }
        guard size <= 256 << 20, offset <= length, size <= length - offset else { throw notZip }
        try handle.seek(toOffset: offset)
        let directory = try handle.read(upToCount: Int(size)) ?? Data()
        guard directory.count == Int(size) else { throw notZip }

        var entries: [Entry] = []
        var position = 0
        for _ in 0..<count {
            guard directory.le32(position) == 0x0201_4b50, let madeBy = directory.le16(position + 4),
                var uncompressed = directory.le32(position + 24), let nameLength = directory.le16(position + 28),
                let extraLength = directory.le16(position + 30), let commentLength = directory.le16(position + 32),
                let attributes = directory.le32(position + 38),
                position + 46 + nameLength + extraLength + commentLength <= directory.count
            else { throw notZip }
            let nameStart = directory.startIndex + position + 46
            let entryName = String(decoding: directory[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            if uncompressed == 0xFFFF_FFFF {
                // The zip64 extra field holds the real size, first.
                var extra = position + 46 + nameLength
                let extraEnd = extra + extraLength
                while extra + 4 <= extraEnd, let tag = directory.le16(extra), let fieldLength = directory.le16(extra + 2) {
                    if tag == 0x0001, fieldLength >= 8, let real = directory.le64(extra + 4) {
                        uncompressed = real
                        break
                    }
                    extra += 4 + fieldLength
                }
            }
            // Unix permissions sit in the upper half of the external attributes when the zip was
            // made on Unix (3) or macOS (19).
            let host = madeBy >> 8
            let mode = host == 3 || host == 19 ? (attributes >> 16) & 0o170000 : 0
            entries.append(
                Entry(
                    name: entryName, isDirectory: entryName.hasSuffix("/") || mode == 0o040000, isSymlink: mode == 0o120000,
                    size: uncompressed))
            position += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// The one .app at the top of the zip. Throws when an entry would leave the folder or the zip
    /// holds no app, several, or more than `maxBytes` unpacked.
    static func check(_ entries: [Entry], name: String, maxBytes: UInt64) throws -> String {
        func unsafe(_ entry: String, _ why: String) -> UploadError {
            UploadError(422, "\(name) is not safe to unpack: \(entry) \(why).")
        }
        let symlinks = Set(entries.filter(\.isSymlink).map { trimmingSlashes($0.name) })
        var total: UInt64 = 0
        var top = Set<String>()
        var folders = Set<String>()
        var linkedTop = Set<String>()
        for entry in entries {
            let path = entry.name
            guard !path.isEmpty else { throw unsafe("an entry", "has no name") }
            guard !path.hasPrefix("/") else { throw unsafe(path, "is an absolute path") }
            guard !path.contains("\\"), !path.contains("\0") else { throw unsafe(path, "contains a backslash or a zero byte") }
            let components = path.split(separator: "/").map(String.init).filter { $0 != "." }
            guard !components.contains("..") else { throw unsafe(path, "leaves the folder with ..") }
            guard let first = components.first else { continue }
            for depth in 1..<max(components.count, 1) {
                let parent = components[0..<depth].joined(separator: "/")
                if symlinks.contains(parent) { throw unsafe(path, "goes through the symlink \(parent)") }
            }
            total = total.addingReportingOverflow(entry.size).overflow ? .max : total + entry.size
            if first == "__MACOSX" || first == ".DS_Store" { continue }
            top.insert(first)
            if components.count > 1 || entry.isDirectory { folders.insert(first) }
            if components.count == 1, entry.isSymlink { linkedTop.insert(first) }
        }
        guard total <= maxBytes else {
            throw UploadError(
                422,
                "\(name) would unpack to \(UploadStore.bytes(Int64(clamping: total))); at most \(UploadStore.bytes(Int64(clamping: maxBytes))) are allowed.")
        }
        let apps = top.filter { $0.lowercased().hasSuffix(".app") }.sorted()
        guard apps.count <= 1 else {
            throw UploadError(422, "\(name) holds several apps (\(apps.joined(separator: ", "))); upload one at a time.")
        }
        guard top.count == 1, let app = apps.first, folders.contains(app), !linkedTop.contains(app) else {
            let found = top.sorted().prefix(5).joined(separator: ", ")
            throw UploadError(
                422,
                "\(name) must hold one .app folder at its top, as ditto -c -k --keepParent MyApp.app MyApp.zip makes it\(found.isEmpty ? "; it is empty" : "; it holds \(found)").")
        }
        return app
    }

    private static func trimmingSlashes(_ path: String) -> String {
        path.split(separator: "/").map(String.init).filter { $0 != "." }.joined(separator: "/")
    }

    // MARK: The unpacked folder

    /// After unpacking: one .app with an Info.plist, every symlink inside the folder, only files,
    /// folders and symlinks, no setuid, setgid or sticky bits.
    static func checkTree(_ destination: URL, app: String, name: String) throws -> URL {
        let manager = FileManager.default
        // AppleDouble files from Finder's Compress, which ditto has merged back into the files.
        try? manager.removeItem(at: destination.appendingPathComponent("__MACOSX"))
        try? manager.removeItem(at: destination.appendingPathComponent(".DS_Store"))
        guard let root = realPath(destination.path) else { throw UploadError(500, "The unpacked folder is gone.") }
        let top = try manager.contentsOfDirectory(atPath: root)
        guard top == [app] else {
            throw UploadError(422, "\(name) did not unpack to one .app; it holds \(top.sorted().prefix(5).joined(separator: ", ")).")
        }
        try walk(root, root: root, name: name)
        let path = root + "/" + app
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw UploadError(422, "\(app) in \(name) is not a folder.")
        }
        guard manager.fileExists(atPath: path + "/Info.plist") else {
            throw UploadError(422, "\(app) in \(name) has no Info.plist. Zip the .app bundle as Xcode built it.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func walk(_ folder: String, root: String, name: String) throws {
        for item in try FileManager.default.contentsOfDirectory(atPath: folder) {
            let path = folder + "/" + item
            let shown = String(path.dropFirst(root.count + 1))
            var info = stat()
            guard lstat(path, &info) == 0 else { throw UploadError(422, "\(shown) in \(name) cannot be read.") }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                dropSpecialBits(path, info.st_mode)
                try walk(path, root: root, name: name)
            case S_IFREG:
                dropSpecialBits(path, info.st_mode)
            case S_IFLNK:
                try checkLink(path, shown: shown, root: root, name: name)
            default:
                throw UploadError(422, "\(name) holds \(shown), which is neither a file, a folder nor a symlink.")
            }
        }
    }

    private static func dropSpecialBits(_ path: String, _ mode: mode_t) {
        if mode & 0o7000 != 0 { chmod(path, mode & 0o777) }
    }

    /// A symlink must point inside the folder, both read as written and resolved on disk.
    private static func checkLink(_ path: String, shown: String, root: String, name: String) throws {
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
        let refusal = UploadError(422, "\(name) is not safe to unpack: the symlink \(shown) points to \(target), outside the app.")
        guard !target.hasPrefix("/") else { throw refusal }
        let parent = (path as NSString).deletingLastPathComponent
        guard inside(normalized(parent + "/" + target), root) else { throw refusal }
        if let resolved = realPath(path), !inside(resolved, root) { throw refusal }
    }

    private static func inside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// An absolute path with `.` and `..` worked out as written, without asking the disk (unlike
    /// `standardizedFileURL`, which also drops a leading /private).
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." {
                _ = parts.popLast()
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

extension Data {
    fileprivate func le16(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let start = startIndex + offset
        return Int(self[start]) | Int(self[start + 1]) << 8
    }

    fileprivate func le32(_ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let start = startIndex + offset
        return (0..<4).reduce(UInt64(0)) { $0 | UInt64(self[start + $1]) << (8 * UInt64($1)) }
    }

    fileprivate func le64(_ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        let start = startIndex + offset
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[start + $1]) << (8 * UInt64($1)) }
    }
}
