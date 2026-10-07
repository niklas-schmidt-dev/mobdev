import CryptoKit
import Foundation

/// Builds sent to this Mac from elsewhere, so `install_app` can install them there: a cloud agent
/// or CI builds an app in a container and uploads it in chunks through the HTTP API, which the
/// relays forward like any other request. Relays store nothing; the bytes land here, in
/// `uploads/<id>/` of Mobdev's folder (folders 0700, files 0600).
///
/// An upload is created with its name, size and optionally its SHA-256, receives its bytes in
/// order (each chunk's `offset` must equal what arrived so far, so a chunk whose answer got lost is
/// resumed, never written twice), and is finished: size and checksum are verified and a zip is
/// unpacked to its .app. Uploads go away 24 hours after their last use; the oldest idle ones make
/// room when the total size or the count would pass the limits.
public final class UploadStore: Sendable {
    public struct Limits: Sendable {
        /// An upload is removed this long after it last received bytes, was finished or installed.
        public var maxAge: TimeInterval = 24 * 60 * 60
        /// All uploads together, counting unpacked apps and what unfinished ones will still receive.
        public var maxTotalBytes: Int64 = 4_000_000_000
        public var maxCount = 20
        /// The most one PUT may carry. 8 MiB is about 11 MB as base64 in a relay frame, well within
        /// the relays' 16 MB per request.
        public var chunkSize = 8 << 20
        /// Uploads used this recently are never removed to make room for another.
        public var activeWindow: TimeInterval = 10 * 60
        public var maxZipEntries = 100_000

        public init() {}
    }

    /// What `install_app` gets: an .app unpacked from a zip, an .ipa or an .apk.
    public enum Kind: String, Codable, Sendable {
        case app, ipa, apk
    }

    /// The file as it arrives.
    enum Format: Equatable {
        case zip, ipa, apk
    }

    public static let shared = UploadStore(
        folder: MobdevPaths.home.appendingPathComponent("uploads", isDirectory: true))

    public let folder: URL
    public let limits: Limits
    private let now: @Sendable () -> Date
    private let state = Locked(State())

    private struct State {
        var finishing: [String: Task<Void, Error>] = [:]
        /// Why uploads were refused and removed while finishing, so asking again after a lost
        /// answer says why instead of "no such upload".
        var refused: [(id: String, reason: String)] = []
    }

    /// Nothing touches the disk until the first upload, so a store that is never used leaves no trace.
    public init(folder: URL, limits: Limits = Limits(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder
        self.limits = limits
        self.now = now
    }

    struct Record: Codable, Sendable {
        var id: String
        var name: String
        var size: Int64
        var sha256: String?
        var source: String
        var created: Date
        var updated: Date
        var finished: Finished?

        struct Finished: Codable, Sendable {
            /// Relative to the upload's folder.
            var file: String
            var kind: Kind
            var sha256: String
        }
    }

    /// An upload as the API reports it.
    public struct Info: Sendable {
        public var id: String
        public var name: String
        public var size: Int64
        public var received: Int64
        /// "receiving", "finishing" or "finished".
        public var state: String
        public var sha256: String?
        public var kind: Kind?
        /// The finished build on this Mac.
        public var path: URL?
        public var expires: Date
        public var chunkSize: Int

        public var json: JSONValue {
            var object: [String: JSONValue] = [
                "ok": true, "id": .string(id), "name": .string(name), "size": .number(Double(size)),
                "received": .number(Double(received)), "state": .string(state),
                "chunk_size": .number(Double(chunkSize)),
                "expires_at": .string(ISO8601DateFormatter().string(from: expires)),
            ]
            if let sha256 { object["sha256"] = .string(sha256) }
            if let kind { object["kind"] = .string(kind.rawValue) }
            if let path { object["path"] = .string(path.path) }
            if state == "finished" {
                object["text"] = .string(
                    "\(name) is ready on the Mac. Install it with install_app {\"upload\": \"\(id)\"}.")
            }
            return .object(object)
        }
    }

    // MARK: Operations

    /// Starts an upload. Removes expired uploads first and, when the limits would be passed, the
    /// oldest idle ones.
    public func create(name: String, size: Int64, sha256: String?, source: String) throws -> Info {
        let (stored, _) = try Self.storedName(name)
        guard size > 0 else { throw UploadError(400, "size must be the file's size in bytes, more than 0.") }
        guard size <= limits.maxTotalBytes else {
            throw UploadError(
                413, "\(stored) has \(Self.bytes(size)); an upload may have at most \(Self.bytes(limits.maxTotalBytes)).")
        }
        let checksum = try sha256.map(Self.checksum)
        return try state.withLock { state in
            try prepareFolder()
            removeExpired(&state)
            try makeRoom(for: size, state: state)
            try checkFreeSpace(for: size, name: stored)
            let id = SecretStore.randomHex(bytes: 16)
            try FileManager.default.createDirectory(
                at: directory(id), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard
                FileManager.default.createFile(
                    atPath: dataFile(id).path, contents: nil, attributes: [.posixPermissions: 0o600])
            else {
                remove(id)
                throw UploadError(500, "Could not create the upload's file on this Mac.")
            }
            let date = now()
            let record = Record(
                id: id, name: stored, size: size, sha256: checksum, source: source, created: date, updated: date)
            do {
                try save(record)
            } catch {
                remove(id)
                throw error
            }
            Log.info("Upload \(Self.short(id)): receiving \(stored), \(Self.bytes(size)), from \(source)")
            return info(record, received: 0, state: state)
        }
    }

    /// Appends one chunk. `offset` must be the number of bytes received so far; otherwise the
    /// answer is 409 with `received`, where the client continues.
    public func write(_ id: String, offset: Int64, data: Data) throws -> Info {
        try state.withLock { state in
            var record = try load(id, state: state)
            guard record.finished == nil, state.finishing[id] == nil else {
                throw UploadError(409, "\(record.name) is complete and finished; it takes no more bytes.")
            }
            let handle = try FileHandle(forWritingTo: dataFile(id))
            defer { try? handle.close() }
            let received = Int64(try handle.seekToEnd())
            guard offset == received else {
                throw UploadError(
                    409,
                    "The Mac has \(received) bytes of \(record.name), so the next chunk starts at offset \(received), not \(offset).",
                    received: received)
            }
            guard data.count <= limits.chunkSize else {
                throw UploadError(
                    413, "A chunk may have at most \(limits.chunkSize) bytes; this one has \(data.count).",
                    received: received)
            }
            guard received + Int64(data.count) <= record.size else {
                throw UploadError(
                    413, "This chunk would take \(record.name) past the \(record.size) bytes it was created with.",
                    received: received)
            }
            try handle.write(contentsOf: data)
            record.updated = now()
            try save(record)
            return info(record, received: received + Int64(data.count), state: state)
        }
    }

    public func info(_ id: String) throws -> Info {
        try state.withLock { state in
            let record = try load(id, state: state)
            return info(record, received: receivedBytes(record), state: state)
        }
    }

    /// Checks the size and checksum and unpacks a zip. Runs once: a second call while it runs waits
    /// for the same work, one afterwards returns the result. The work goes on when the caller stops
    /// waiting, as a relay does after 90 s, so asking again later finds it done.
    public func finish(_ id: String) async throws -> Info {
        let task: Task<Void, Error>? = try state.withLock { state in
            let record = try load(id, state: state)
            if record.finished != nil { return nil }
            if let running = state.finishing[id] { return running }
            let received = receivedBytes(record)
            guard received == record.size else {
                throw UploadError(
                    409, "\(record.name) has \(received) of its \(record.size) bytes; send the rest first.",
                    received: received)
            }
            let task = Task.detached(priority: .utility) { try await self.complete(record) }
            state.finishing[id] = task
            return task
        }
        try await task?.value
        return try info(id)
    }

    public func delete(_ id: String) throws {
        try state.withLock { state in
            let record = try load(id, state: state)
            guard state.finishing[id] == nil else {
                throw UploadError(409, "\(record.name) is being finished; delete it afterwards.", retryAfter: 2)
            }
            remove(id)
            Log.info("Upload \(Self.short(id)): deleted \(record.name)")
        }
    }

    /// The finished build of an upload, for `install_app`. Counts as a use, so it is kept another
    /// 24 hours.
    public func build(_ id: String) throws -> (url: URL, name: String, kind: Kind) {
        try state.withLock { state in
            var record = try load(id, state: state)
            guard let finished = record.finished else {
                if state.finishing[id] != nil {
                    throw UploadError(409, "\(record.name) is still being finished; try again in a moment.")
                }
                throw UploadError(
                    409,
                    "\(record.name) is not finished: the Mac has \(receivedBytes(record)) of its \(record.size) bytes. Send the rest, then POST /v1/uploads/\(id)/finish.")
            }
            record.updated = now()
            try? save(record)
            return (directory(id).appendingPathComponent(finished.file), record.name, finished.kind)
        }
    }

    /// Removes uploads unused for `maxAge`. Creating an upload does this too.
    public func removeExpired() {
        state.withLock { removeExpired(&$0) }
    }

    // MARK: Finishing

    private func complete(_ record: Record) async throws {
        let id = record.id
        do {
            let digest = try Self.sha256(of: dataFile(id))
            if let expected = record.sha256, expected != digest {
                throw UploadError(
                    422,
                    "\(record.name) arrived damaged: its SHA-256 is \(digest), not \(expected). Start a new upload.")
            }
            let finished: Record.Finished
            let format = try Self.storedName(record.name).format
            switch format {
            case .zip:
                let app = try await UploadArchive.unpack(
                    dataFile(id), name: record.name, into: directory(id).appendingPathComponent("unpacked"),
                    maxEntries: limits.maxZipEntries, maxBytes: UInt64(limits.maxTotalBytes))
                try? FileManager.default.removeItem(at: dataFile(id))
                finished = Record.Finished(file: "unpacked/" + app.lastPathComponent, kind: .app, sha256: digest)
            case .ipa, .apk:
                try FileManager.default.moveItem(at: dataFile(id), to: directory(id).appendingPathComponent(record.name))
                finished = Record.Finished(file: record.name, kind: format == .apk ? .apk : .ipa, sha256: digest)
            }
            try state.withLock { state in
                state.finishing[id] = nil
                var done = record
                done.finished = finished
                done.updated = now()
                try save(done)
            }
            Log.info("Upload \(Self.short(id)): finished \(record.name), ready to install as \(finished.file)")
        } catch {
            let refusal = error as? UploadError ?? UploadError(422, "Could not finish \(record.name): \(error)")
            state.withLock { state in
                state.finishing[id] = nil
                remove(id)
                state.refused.append((id, refusal.description))
                if state.refused.count > 20 { state.refused.removeFirst(state.refused.count - 20) }
            }
            Log.error("Upload \(Self.short(id)): refused \(record.name): \(refusal.description)")
            throw refusal
        }
    }

    // MARK: Storage

    private func directory(_ id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }
    private func dataFile(_ id: String) -> URL { directory(id).appendingPathComponent("data") }
    private func recordFile(_ id: String) -> URL { directory(id).appendingPathComponent("upload.json") }

    private func prepareFolder() throws {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private func save(_ record: Record) throws {
        let url = recordFile(record.id)
        try Self.encoder.encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func isID(_ text: String) -> Bool {
        text.count == 32 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Under the lock.
    private func load(_ id: String, state: State) throws -> Record {
        if let refused = state.refused.last(where: { $0.id == id }) { throw UploadError(422, refused.reason) }
        guard Self.isID(id), let data = try? Data(contentsOf: recordFile(id)),
            let record = try? Self.decoder.decode(Record.self, from: data)
        else {
            throw UploadError(
                404,
                "No upload \(id) on this Mac. Uploads are removed 24 hours after their last use; start a new one with POST /v1/uploads.")
        }
        return record
    }

    private func receivedBytes(_ record: Record) -> Int64 {
        if record.finished != nil { return record.size }
        let size = (try? FileManager.default.attributesOfItem(atPath: dataFile(record.id).path)[.size]) as? NSNumber
        return size?.int64Value ?? 0
    }

    private func info(_ record: Record, received: Int64, state: State) -> Info {
        let finished = record.finished
        return Info(
            id: record.id, name: record.name, size: record.size, received: received,
            state: finished != nil ? "finished" : state.finishing[record.id] != nil ? "finishing" : "receiving",
            sha256: finished?.sha256 ?? record.sha256, kind: finished?.kind,
            path: finished.map { directory(record.id).appendingPathComponent($0.file) },
            expires: record.updated.addingTimeInterval(limits.maxAge), chunkSize: limits.chunkSize)
    }

    private func remove(_ id: String) {
        try? FileManager.default.removeItem(at: directory(id))
    }

    /// Every upload folder with its record; nil for a folder whose record cannot be read.
    private func all() -> [(id: String, record: Record?)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(Self.isID).map { id in
            (id, (try? Data(contentsOf: recordFile(id))).flatMap { try? Self.decoder.decode(Record.self, from: $0) })
        }
    }

    private func removeExpired(_ state: inout State) {
        let date = now()
        for (id, record) in all() where state.finishing[id] == nil {
            if let record {
                guard date.timeIntervalSince(record.updated) > limits.maxAge else { continue }
                remove(id)
                Log.info("Upload \(Self.short(id)): removed \(record.name), unused for 24 hours")
            } else {
                // Left behind by a crash between creating the folder and its record.
                let modified = (try? FileManager.default.attributesOfItem(atPath: directory(id).path)[.modificationDate]) as? Date
                if date.timeIntervalSince(modified ?? .distantPast) > limits.maxAge { remove(id) }
            }
        }
    }

    /// Removes the uploads unused the longest until `size` more bytes and one more upload fit.
    /// Uploads in use, received or installed within `activeWindow` or being finished, stay.
    private func makeRoom(for size: Int64, state: State) throws {
        let date = now()
        var uploads = all().compactMap { id, record in record.map { ($0, max($0.size, Self.bytes(in: directory(id)))) } }
            .sorted { $0.0.updated < $1.0.updated }
        func used() -> Int64 { uploads.reduce(0) { $0 + $1.1 } }
        while used() + size > limits.maxTotalBytes || uploads.count >= limits.maxCount {
            guard
                let index = uploads.firstIndex(where: { record, _ in
                    state.finishing[record.id] == nil && date.timeIntervalSince(record.updated) >= limits.activeWindow
                })
            else {
                throw UploadError(
                    507,
                    "No room for \(Self.bytes(size)) more: this Mac keeps at most \(limits.maxCount) uploads with \(Self.bytes(limits.maxTotalBytes)) together, and its \(uploads.count) uploads (\(Self.bytes(used()))) were all used in the last \(Int(limits.activeWindow / 60)) minutes. Delete one with DELETE /v1/uploads/<id>, or try again later.",
                    retryAfter: 60)
            }
            let (record, _) = uploads.remove(at: index)
            remove(record.id)
            Log.info("Upload \(Self.short(record.id)): removed \(record.name) to make room")
        }
    }

    /// The upload, and for a zip its unpacked app, must fit with some room to spare.
    private func checkFreeSpace(for size: Int64, name: String) throws {
        guard
            let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        else { return }
        guard free >= size * 2 + (512 << 20) else {
            throw UploadError(
                507,
                "This Mac has \(Self.bytes(free)) free; \(name) needs room for \(Self.bytes(size)) twice, as received and unpacked, and some to spare.")
        }
    }

    // MARK: Helpers

    /// A safe file name for the upload and what it is. Folders, odd characters and leading dots go.
    static func storedName(_ raw: String) throws -> (name: String, format: Format) {
        let last = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-+()")
        var name = String(last.trimmingCharacters(in: .whitespacesAndNewlines).map { allowed.contains($0) ? $0 : "_" })
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 120 { name = String(name.suffix(120)) }
        let lower = name.lowercased()
        let format: Format
        if lower.hasSuffix(".zip") {
            format = .zip
        } else if lower.hasSuffix(".ipa") {
            format = .ipa
        } else if lower.hasSuffix(".apk") {
            format = .apk
        } else if lower.hasSuffix(".app") {
            throw UploadError(
                400,
                "Send an .app bundle as a .zip, e.g. ditto -c -k --keepParent MyApp.app MyApp.zip. Mobdev upload and mobdev-upload.sh zip it for you.")
        } else if lower.hasSuffix(".aab") {
            throw UploadError(400, "An Android App Bundle (.aab) cannot be installed; build an .apk, e.g. ./gradlew assembleDebug.")
        } else {
            throw UploadError(400, "name must end in .ipa, .apk or .zip (an .app bundle, zipped), such as MyApp.ipa.")
        }
        guard name.count > 4 else { throw UploadError(400, "name needs more than an extension, such as MyApp.ipa.") }
        return (name, format)
    }

    static func checksum(_ text: String) throws -> String {
        let lower = text.lowercased()
        guard lower.count == 64, lower.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw UploadError(400, "sha256 must be the file's SHA-256 as 64 hexadecimal digits.")
        }
        return lower
    }

    /// Reads the file in pieces, so a large build never sits in memory whole.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes of the regular files in a folder, not following symlinks.
    static func bytes(in folder: URL) -> Int64 {
        guard
            let items = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func short(_ id: String) -> String { String(id.prefix(8)) }
}

/// A refused upload request: the HTTP status and what to do about it.
public struct UploadError: Error, CustomStringConvertible, Sendable {
    public let status: Int
    public let description: String
    /// The bytes the Mac has, where a client continues.
    public var received: Int64?
    var retryAfter: Int?

    init(_ status: Int, _ description: String, received: Int64? = nil, retryAfter: Int? = nil) {
        self.status = status
        self.description = description
        self.received = received
        self.retryAfter = retryAfter
    }

    var response: HTTPResponse {
        var body: [String: JSONValue] = ["ok": false, "error": .string(description)]
        if let received { body["received"] = .number(Double(received)) }
        var response = HTTPResponse.json(.object(body), status: status)
        if let retryAfter { response.headers["Retry-After"] = String(retryAfter) }
        return response
    }
}

// MARK: HTTP API

extension UploadStore {
    /// `/v1/uploads` of the HTTP API, also reached through the relays:
    ///
    ///     POST   /v1/uploads              {"name", "size", "sha256"?} → 201 {"id", "chunk_size", …}
    ///     PUT    /v1/uploads/<id>?offset=N  raw bytes, at most chunk_size → {"received", …}
    ///     GET    /v1/uploads/<id>         → {"received", "state", …}, to resume
    ///     POST   /v1/uploads/<id>/finish  → {"path", "kind", "sha256", …}
    ///     DELETE /v1/uploads/<id>
    func respond(to request: HTTPRequest, source: String) async -> HTTPResponse {
        let tail = request.path.dropFirst("/v1/uploads".count)
        let parts = tail.isEmpty ? [] : tail.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        do {
            switch (request.method, parts.count) {
            case ("POST", 0):
                let (name, size, sha256) = try Self.creation(request.body)
                return .json(try create(name: name, size: size, sha256: sha256, source: source).json, status: 201)
            case ("GET", 1):
                return .json(try info(parts[0]).json)
            case ("PUT", 1):
                guard let text = request.query["offset"], let offset = Int64(text), offset >= 0 else {
                    throw UploadError(400, "Pass ?offset=<bytes the Mac has>; GET /v1/uploads/\(parts[0]) tells them.")
                }
                return .json(try write(parts[0], offset: offset, data: request.body).json)
            case ("DELETE", 1):
                try delete(parts[0])
                return .json(["ok": true])
            case ("POST", 2) where parts[1] == "finish":
                return .json(try await finish(parts[0]).json)
            case (_, 0):
                return Self.notAllowed("POST")
            case (_, 1):
                return Self.notAllowed("GET, PUT, DELETE")
            case (_, 2) where parts[1] == "finish":
                return Self.notAllowed("POST")
            default:
                return .error("Not found", status: 404)
            }
        } catch let error as UploadError {
            return error.response
        } catch {
            return .error(String(describing: error), status: 500)
        }
    }

    private static func creation(_ body: Data) throws -> (name: String, size: Int64, sha256: String?) {
        let usage = #"The body must be JSON such as {"name": "MyApp.ipa", "size": 1234567, "sha256": "<optional, 64 hex digits>"}."#
        guard case .object(let object)? = try? JSONValue.parse(body) else { throw UploadError(400, usage) }
        guard let name = object["name"]?.stringValue, !name.isEmpty else { throw UploadError(400, "name is missing. " + usage) }
        guard case .number(let size)? = object["size"], size.rounded() == size, size >= 0, size < 9e15 else {
            throw UploadError(400, "size must be the file's size in bytes. " + usage)
        }
        let sha256: String?
        switch object["sha256"] {
        case nil, .null?: sha256 = nil
        case .string(let text)?: sha256 = text
        default: throw UploadError(400, "sha256 must be a string of 64 hexadecimal digits.")
        }
        return (name, Int64(size), sha256)
    }

    private static func notAllowed(_ methods: String) -> HTTPResponse {
        var response = HTTPResponse.error("Use \(methods) here.", status: 405)
        response.headers["Allow"] = methods
        return response
    }
}
