import CryptoKit
import Foundation
import Testing
@testable import MobdevCore

/// A folder for one test, removed when the test's value goes away.
final class TemporaryFolder: @unchecked Sendable {
    let url: URL

    init(_ label: String = "mobdev-uploads") {
        // Short: the app's socket path must stay within 103 bytes.
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, _ data: Data) throws -> URL {
        let file = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    /// A folder that looks like an app bundle built for the given platform.
    func app(_ name: String = "Fixture.app", platform: String = "iPhoneSimulator") throws -> URL {
        let app = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": "dev.mobdev.fixture", "CFBundleSupportedPlatforms": [platform]]
        try info.write(to: app.appendingPathComponent("Info.plist"))
        try Data("binary".utf8).write(to: app.appendingPathComponent("Fixture"))
        return app
    }
}

final class TestClock: @unchecked Sendable {
    let date = Locked(Date(timeIntervalSince1970: 1_790_000_000))
    func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

/// Writes zips by hand, the malicious kinds no tool makes included. Entries are stored uncompressed.
enum ZipWriter {
    struct Item {
        var name: String
        var data = Data()
        var mode: UInt32 = 0o100644
        /// The uncompressed size the central directory claims, if not the real one.
        var claimedSize: UInt32?

        static func folder(_ name: String) -> Item { Item(name: name.hasSuffix("/") ? name : name + "/", mode: 0o040755) }
        static func file(_ name: String, _ text: String = "x") -> Item { Item(name: name, data: Data(text.utf8)) }
        static func link(_ name: String, to target: String) -> Item { Item(name: name, data: Data(target.utf8), mode: 0o120777) }
    }

    static func zip(_ items: [Item]) -> Data {
        var archive = Data()
        var directory = Data()
        for item in items {
            let name = Data(item.name.utf8)
            let crc = crc32(item.data)
            let offset = UInt32(archive.count)
            archive.append(le32(0x0403_4b50))
            archive.append(le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21))
            archive.append(le32(crc) + le32(UInt32(item.data.count)) + le32(UInt32(item.data.count)))
            archive.append(le16(UInt16(name.count)) + le16(0) + name + item.data)
            directory.append(le32(0x0201_4b50))
            directory.append(le16(0x031E) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21))
            directory.append(le32(crc) + le32(UInt32(item.data.count)) + le32(item.claimedSize ?? UInt32(item.data.count)))
            directory.append(le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0))
            directory.append(le32(item.mode << 16) + le32(offset) + name)
        }
        let start = UInt32(archive.count)
        archive.append(directory)
        archive.append(le32(0x0605_4b50) + le16(0) + le16(0) + le16(UInt16(items.count)) + le16(UInt16(items.count)))
        archive.append(le32(UInt32(directory.count)) + le32(start) + le16(0))
        return archive
    }

    static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    static func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }) }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    /// An app that would pass: a folder with an Info.plist built for the simulator.
    static func app(_ name: String = "Fixture.app", extra: [Item] = []) -> [Item] {
        let info = try! PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "dev.mobdev.fixture", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]],
            format: .xml, options: 0)
        return [.folder(name), Item(name: "\(name)/Info.plist", data: info), .file("\(name)/Fixture", "binary")] + extra
    }
}

func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func randomData(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
}

@Suite struct UploadStoreTests {
    let temporary = TemporaryFolder()
    let clock = TestClock()

    func store(_ configure: (inout UploadStore.Limits) -> Void = { _ in }) -> UploadStore {
        var limits = UploadStore.Limits()
        limits.chunkSize = 1000
        configure(&limits)
        let clock = clock
        return UploadStore(folder: temporary.url.appendingPathComponent("uploads"), limits: limits) { clock.date.get() }
    }

    func status(_ body: () throws -> Any) -> Int? {
        do {
            _ = try body()
            return nil
        } catch {
            return (error as? UploadError)?.status
        }
    }

    @Test func receivesChunksInOrderAndResumesWhereTheMacsCopyEnds() async throws {
        let uploads = store()
        let data = randomData(2500)
        let created = try uploads.create(name: "app-debug.apk", size: 2500, sha256: sha256(data), source: "relay")
        #expect(created.received == 0 && created.state == "receiving" && created.chunkSize == 1000)
        _ = try uploads.write(created.id, offset: 0, data: data[0..<1000])
        // The answer got lost and the client sends the same chunk again: refused, with where to go on.
        do {
            _ = try uploads.write(created.id, offset: 0, data: data[0..<1000])
            Issue.record("A chunk at the wrong offset was taken.")
        } catch let error as UploadError {
            #expect(error.status == 409 && error.received == 1000)
        }
        #expect(try uploads.info(created.id).received == 1000)
        _ = try uploads.write(created.id, offset: 1000, data: data[1000..<2000])
        let last = try uploads.write(created.id, offset: 2000, data: data[2000...])
        #expect(last.received == 2500)
        let finished = try await uploads.finish(created.id)
        #expect(finished.state == "finished" && finished.kind == .apk && finished.sha256 == sha256(data))
        let path = try #require(finished.path)
        #expect(path.lastPathComponent == "app-debug.apk")
        #expect(try Data(contentsOf: path) == data)
        // Finishing again, as after a lost answer, returns the same.
        #expect(try await uploads.finish(created.id).path == path)
        let build = try uploads.build(created.id)
        #expect(build.url == path && build.kind == .apk && build.name == "app-debug.apk")
        // No more bytes once finished.
        #expect(status { try uploads.write(created.id, offset: 2500, data: Data([1])) } == 409)
    }

    @Test func refusesChunksThatDoNotFit() throws {
        let uploads = store()
        let id = try uploads.create(name: "App.ipa", size: 1500, sha256: nil, source: "local").id
        #expect(status { try uploads.write(id, offset: 0, data: Data(count: 1001)) } == 413)
        _ = try uploads.write(id, offset: 0, data: Data(count: 1000))
        #expect(status { try uploads.write(id, offset: 1000, data: Data(count: 501)) } == 413)
        #expect(status { try uploads.write(id, offset: 1500, data: Data(count: 1)) } == 409)
        #expect(status { try uploads.write("0123456789abcdef0123456789abcdef", offset: 0, data: Data()) } == 404)
        #expect(status { try uploads.write("../../etc", offset: 0, data: Data()) } == 404)
    }

    @Test func finishChecksTheSizeAndTheChecksum() async throws {
        let uploads = store()
        let data = Data("not what was announced".utf8)
        let id = try uploads.create(name: "App.ipa", size: Int64(data.count), sha256: sha256(Data("other".utf8)), source: "relay").id
        _ = try uploads.write(id, offset: 0, data: data.prefix(5))
        await #expect(throws: UploadError.self) { try await uploads.finish(id) }  // Incomplete.
        #expect(try uploads.info(id).received == 5)
        _ = try uploads.write(id, offset: 5, data: data.dropFirst(5))
        do {
            _ = try await uploads.finish(id)
            Issue.record("A damaged upload was finished.")
        } catch let error as UploadError {
            #expect(error.status == 422 && error.description.contains("arrived damaged"))
        }
        // Gone, and asking again tells why.
        #expect(!FileManager.default.fileExists(atPath: uploads.folder.appendingPathComponent(id).path))
        do {
            _ = try uploads.info(id)
        } catch let error as UploadError {
            #expect(error.status == 422 && error.description.contains("arrived damaged"))
        }
    }

    @Test func refusesNamesSizesAndChecksumsItCannotUse() throws {
        let uploads = store()
        #expect(status { try uploads.create(name: "MyApp.app", size: 10, sha256: nil, source: "test") } == 400)
        #expect(status { try uploads.create(name: "app.aab", size: 10, sha256: nil, source: "test") } == 400)
        #expect(status { try uploads.create(name: "notes.txt", size: 10, sha256: nil, source: "test") } == 400)
        #expect(status { try uploads.create(name: ".zip", size: 10, sha256: nil, source: "test") } == 400)
        #expect(status { try uploads.create(name: "App.ipa", size: 0, sha256: nil, source: "test") } == 400)
        #expect(status { try uploads.create(name: "App.ipa", size: 5 << 30, sha256: nil, source: "test") } == 413)
        #expect(status { try uploads.create(name: "App.ipa", size: 10, sha256: "abc", source: "test") } == 400)
        // A path and odd characters are cut down to a safe name.
        let created = try uploads.create(name: "../../build/My \"App\";$(id).IPA", size: 10, sha256: nil, source: "test")
        #expect(created.name == "My _App___(id).IPA")
        #expect(try UploadStore.storedName("C:\\builds\\.hidden.apk").name == "hidden.apk")
    }

    @Test func keepsFilesPrivate() throws {
        let uploads = store()
        let id = try uploads.create(name: "App.ipa", size: 4, sha256: nil, source: "test").id
        _ = try uploads.write(id, offset: 0, data: Data("abcd".utf8))
        func mode(_ url: URL) throws -> Int {
            try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        #expect(try mode(uploads.folder) == 0o700)
        #expect(try mode(uploads.folder.appendingPathComponent(id)) == 0o700)
        #expect(try mode(uploads.folder.appendingPathComponent(id).appendingPathComponent("data")) == 0o600)
        #expect(try mode(uploads.folder.appendingPathComponent(id).appendingPathComponent("upload.json")) == 0o600)
    }

    @Test func removesUploadsUnusedForADay() async throws {
        let uploads = store()
        let old = try uploads.create(name: "Old.ipa", size: 1, sha256: nil, source: "test").id
        _ = try uploads.write(old, offset: 0, data: Data([1]))
        _ = try await uploads.finish(old)
        clock.advance(20 * 60 * 60)
        let used = try uploads.create(name: "Used.ipa", size: 1, sha256: nil, source: "test").id
        _ = try uploads.write(used, offset: 0, data: Data([1]))
        _ = try await uploads.finish(used)
        clock.advance(5 * 60 * 60)
        _ = try uploads.build(used)  // Installing counts as a use.
        clock.advance(20 * 60 * 60)
        uploads.removeExpired()
        #expect((try? uploads.info(old)) == nil)
        #expect(try uploads.info(used).state == "finished")
        clock.advance(5 * 60 * 60)
        _ = try uploads.create(name: "New.ipa", size: 1, sha256: nil, source: "test")  // Cleans up too.
        #expect((try? uploads.info(used)) == nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: uploads.folder.path)
        #expect(left.count == 1)
    }

    @Test func makesRoomByRemovingTheOldestIdleUploads() throws {
        let uploads = store {
            $0.maxTotalBytes = 3000
            $0.maxCount = 3
        }
        let first = try uploads.create(name: "A.ipa", size: 1000, sha256: nil, source: "test").id
        clock.advance(20 * 60)
        let second = try uploads.create(name: "B.ipa", size: 1000, sha256: nil, source: "test").id
        clock.advance(20 * 60)
        // 2000 + 1500 > 3000: the oldest idle one goes.
        let third = try uploads.create(name: "C.ipa", size: 1500, sha256: nil, source: "test").id
        #expect((try? uploads.info(first)) == nil)
        #expect(try uploads.info(second).state == "receiving")
        // B is idle and C was just created: B goes; then the count is 2 of 3.
        _ = try uploads.create(name: "D.ipa", size: 1000, sha256: nil, source: "test")
        #expect((try? uploads.info(second)) == nil)
        #expect(try uploads.info(third).state == "receiving")
        // Everything left was used in the last ten minutes: no room, and nothing is removed.
        #expect(status { try uploads.create(name: "E.ipa", size: 1000, sha256: nil, source: "test") } == 507)
        #expect(try uploads.info(third).state == "receiving")
    }

    @Test func finishesOnceForCallsAtTheSameTime() async throws {
        let uploads = store()
        let id = try uploads.create(name: "App.ipa", size: 3, sha256: nil, source: "test").id
        _ = try uploads.write(id, offset: 0, data: Data("abc".utf8))
        async let one = uploads.finish(id)
        async let two = uploads.finish(id)
        let results = try await [one, two]
        #expect(results.map(\.state) == ["finished", "finished"])
        #expect(results[0].path == results[1].path)
    }
}

@Suite struct UploadArchiveTests {
    let temporary = TemporaryFolder()

    /// Unpacks into a fresh folder of the temporary folder; the error's message when refused.
    func unpack(_ data: Data) async -> Result<URL, UploadError> {
        let zip = temporary.url.appendingPathComponent("upload-\(UUID().uuidString).zip")
        try? data.write(to: zip)
        do {
            return .success(
                try await UploadArchive.unpack(
                    zip, name: "Fixture.zip", into: temporary.url.appendingPathComponent("unpacked-\(UUID().uuidString)"),
                    maxEntries: 1000, maxBytes: 1 << 20))
        } catch let error as UploadError {
            return .failure(error)
        } catch {
            return .failure(UploadError(500, "\(error)"))
        }
    }

    func refusal(_ items: [ZipWriter.Item]) async -> String {
        switch await unpack(ZipWriter.zip(items)) {
        case .success(let app): "unpacked \(app.path)"
        case .failure(let error): error.description
        }
    }

    /// Nothing may appear next to the folders the tests unpack into.
    func outsideIsUntouched() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: temporary.url.path)
        #expect(names.allSatisfy { $0.hasPrefix("upload-") || $0.hasPrefix("unpacked-") }, "\(names)")
        #expect(!FileManager.default.fileExists(atPath: temporary.url.deletingLastPathComponent().appendingPathComponent("evil").path))
    }

    @Test func unpacksAnAppWithSymlinksInsideIt() async throws {
        let items = ZipWriter.app(extra: [
            .folder("Fixture.app/Frameworks/Kit.framework/Versions/A"),
            .file("Fixture.app/Frameworks/Kit.framework/Versions/A/Kit"),
            .link("Fixture.app/Frameworks/Kit.framework/Versions/Current", to: "A"),
            .link("Fixture.app/Frameworks/Kit.framework/Kit", to: "Versions/Current/Kit"),
            ZipWriter.Item(name: "Fixture.app/tool", data: Data("#!/bin/sh".utf8), mode: 0o104755),
        ])
        let app = try await unpack(ZipWriter.zip(items)).get()
        #expect(app.lastPathComponent == "Fixture.app")
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Info.plist").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: app.appendingPathComponent("Frameworks/Kit.framework/Kit").path) == "Versions/Current/Kit")
        let folder = app.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Fixture.app"])
        // The setuid bit is gone, the executable bit stays.
        let mode = try (FileManager.default.attributesOfItem(atPath: app.appendingPathComponent("tool").path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o755)
    }

    @Test func unpacksWhatDittoAndZipMake() async throws {
        let app = try temporary.app()
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Link").path, withDestinationPath: "Fixture")
        // An extended attribute, which ditto --sequesterRsrc keeps in __MACOSX as Finder's Compress does.
        let attribute = Process()
        attribute.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        attribute.arguments = ["-w", "dev.mobdev.test", "1", app.appendingPathComponent("Fixture").path]
        _ = try await attribute.runToExit(timeout: 60)
        for (tool, arguments) in [
            ("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path]),
            ("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path]),
            ("/usr/bin/zip", ["-qry"]),
        ] {
            let zip = temporary.url.appendingPathComponent("upload-\(UUID().uuidString).zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = tool.hasSuffix("zip") ? arguments + [zip.path, "Fixture.app"] : arguments + [zip.path]
            process.currentDirectoryURL = temporary.url
            _ = try await process.runToExit(timeout: 120)
            let unpacked = try await unpack(try Data(contentsOf: zip)).get()
            #expect(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("Info.plist").path), "\(tool)")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: unpacked.appendingPathComponent("Link").path) == "Fixture")
        }
    }

    @Test func refusesPathsThatLeaveTheFolder() async throws {
        #expect(await refusal(ZipWriter.app(extra: [.file("../evil")])).contains("leaves the folder"))
        #expect(await refusal(ZipWriter.app(extra: [.file("Fixture.app/../../evil")])).contains("leaves the folder"))
        #expect(await refusal(ZipWriter.app(extra: [.file("/tmp/evil")])).contains("absolute path"))
        #expect(await refusal(ZipWriter.app(extra: [.file("Fixture.app\\..\\..\\evil")])).contains("backslash"))
        try outsideIsUntouched()
    }

    @Test func refusesWritingThroughItsOwnSymlinks() async throws {
        let outside = temporary.url.deletingLastPathComponent().path
        let message = await refusal(
            ZipWriter.app(extra: [.link("Fixture.app/out", to: outside), .file("Fixture.app/out/evil")]))
        #expect(message.contains("goes through the symlink Fixture.app/out"))
        try outsideIsUntouched()
    }

    @Test func refusesSymlinksThatPointOutside() async throws {
        #expect(await refusal(ZipWriter.app(extra: [.link("Fixture.app/passwd", to: "/etc/passwd")])).contains("outside the app"))
        #expect(await refusal(ZipWriter.app(extra: [.link("Fixture.app/up", to: "../../..")])).contains("outside the app"))
        // Each link looks harmless alone; resolved on disk, the second leaves the folder.
        let chained = ZipWriter.app(extra: [
            .folder("Fixture.app/a"), .link("Fixture.app/a/up", to: ".."), .link("Fixture.app/escape", to: "a/up/../.."),
        ])
        #expect(await refusal(chained).contains("outside the app"))
        try outsideIsUntouched()
    }

    @Test func refusesZipsWithoutExactlyOneApp() async throws {
        #expect(await refusal([.file("Info.plist"), .file("Fixture")]).contains("one .app folder at its top"))
        #expect(await refusal(ZipWriter.app() + ZipWriter.app("Other.app")).contains("several apps"))
        #expect(await refusal(ZipWriter.app() + [.file("README.md")]).contains("one .app folder at its top"))
        #expect(await refusal([.link("Fixture.app", to: "/Applications/Safari.app")]).contains("one .app folder"))
        #expect(await refusal([.folder("Fixture.app"), .file("Fixture.app/Fixture")]).contains("no Info.plist"))
        #expect(await refusal([]).contains("it is empty"))
    }

    @Test func refusesZipsThatClaimTooMuch() async throws {
        var bomb = ZipWriter.app()
        bomb.append(ZipWriter.Item(name: "Fixture.app/big", data: Data("x".utf8), claimedSize: 0xF000_0000))
        #expect(await refusal(bomb).contains("would unpack to"))
        switch await unpack(Data("PK but no zip at all".utf8)) {
        case .success: Issue.record("Not a zip, but unpacked.")
        case .failure(let error): #expect(error.description.contains("not a zip file"))
        }
    }
}

/// Talks to an API router in this process, as a relay would deliver the requests.
struct RouterTransport: UploadTransport {
    let router: APIRouter

    func send(_ method: String, _ path: String, body: Data, contentType: String?) async throws -> (status: Int, body: Data) {
        let components = URLComponents(string: "http://mac" + path)!
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let request = HTTPRequest(
            method: method, path: components.path, query: query,
            headers: contentType.map { ["Content-Type": $0] } ?? [:], body: body)
        let response = await router.handle(request, from: .relay)
        return (response.status, response.body)
    }
}

/// Loses answers and requests on purpose, by call number from 1.
final class FlakyTransport: UploadTransport, @unchecked Sendable {
    let inner: any UploadTransport
    /// The request arrives; its answer does not.
    let lostAnswers: Set<Int>
    /// The request never arrives.
    let lostRequests: Set<Int>
    /// The relay is busy.
    let busy: Set<Int>
    let calls = Locked<[String]>([])

    init(_ inner: any UploadTransport, lostAnswers: Set<Int> = [], lostRequests: Set<Int> = [], busy: Set<Int> = []) {
        self.inner = inner
        self.lostAnswers = lostAnswers
        self.lostRequests = lostRequests
        self.busy = busy
    }

    func send(_ method: String, _ path: String, body: Data, contentType: String?) async throws -> (status: Int, body: Data) {
        let number = calls.withLock { calls -> Int in
            calls.append("\(method) \(path)")
            return calls.count
        }
        if lostRequests.contains(number) { throw URLError(.networkConnectionLost) }
        if busy.contains(number) { return (429, Data(#"{"ok":false,"error":"busy"}"#.utf8)) }
        let answer = try await inner.send(method, path, body: body, contentType: contentType)
        if lostAnswers.contains(number) { throw URLError(.timedOut) }
        return answer
    }
}

@Suite struct UploadAPITests {
    let temporary = TemporaryFolder()

    func uploads(chunkSize: Int = 1000) -> UploadStore {
        var limits = UploadStore.Limits()
        limits.chunkSize = chunkSize
        return UploadStore(folder: temporary.url.appendingPathComponent("uploads"), limits: limits)
    }

    func call(_ router: APIRouter, _ method: String, _ path: String, query: [String: String] = [:], body: Data = Data(),
              from origin: APIRouter.Origin = .relay) async throws -> (Int, JSONValue)
    {
        let headers = ["Host": "127.0.0.1:4686", "Authorization": "Bearer secret"]
        let response = await router.handle(
            HTTPRequest(method: method, path: path, query: query, headers: headers, body: body), from: origin)
        return (response.status, (try? JSONValue.parse(response.body)) ?? .null)
    }

    @Test func uploadsInChunksAndInstallsTheApp() async throws {
        let store = uploads()
        let apps = FakeApps(platform: .simulator)
        let tools = PhoneTools(phone: FakePhone(lines: [], apps: apps), activity: ActivityLog(), settleDelay: 0, uploads: store)
        let router = APIRouter(tools: tools, uploads: store, token: { "secret" }, port: { 4686 })
        let zip = ZipWriter.zip(ZipWriter.app(extra: [ZipWriter.Item(name: "Fixture.app/Assets.car", data: randomData(1500))]))

        let (created, info) = try await call(
            router, "POST", "/v1/uploads",
            body: JSONValue(["name": "Fixture.app.zip", "size": .number(Double(zip.count)), "sha256": .string(sha256(zip))]).encoded(),
            from: .local)
        #expect(created == 201, "\(info)")
        let id = try #require(info["id"]?.stringValue)
        #expect(info["chunk_size"] == 1000)
        var offset = 0
        while offset < zip.count {
            let end = min(offset + 1000, zip.count)
            let (status, answer) = try await call(
                router, "PUT", "/v1/uploads/\(id)", query: ["offset": String(offset)], body: zip[offset..<end], from: .local)
            #expect(status == 200, "\(answer)")
            offset = Int(answer["received"]?.doubleValue ?? 0)
        }
        let (wrong, refused) = try await call(router, "PUT", "/v1/uploads/\(id)", query: ["offset": "0"], body: Data([1]))
        #expect(wrong == 409 && refused["received"] == .number(Double(zip.count)))
        #expect(try await call(router, "PUT", "/v1/uploads/\(id)", body: Data([1])).0 == 400)  // No offset.
        let (_, status) = try await call(router, "GET", "/v1/uploads/\(id)")
        #expect(status["received"] == .number(Double(zip.count)) && status["state"] == "receiving")

        let (done, finished) = try await call(router, "POST", "/v1/uploads/\(id)/finish")
        #expect(done == 200, "\(finished)")
        #expect(finished["kind"] == "app" && finished["sha256"] == .string(sha256(zip)))
        let path = try #require(finished["path"]?.stringValue)
        #expect(path.hasSuffix("/unpacked/Fixture.app"))

        let installed = try await tools.call(
            "install_app", arguments: ["upload": .string(id)], source: "relay", screenshotByDefault: false)
        #expect(!installed.isError, "\(installed.text)")
        #expect(installed.text == "Installed dev.mobdev.fixture 1.0 (1) as dev.mobdev.fixture from the upload Fixture.app.zip. Start it with launch_app.")
        #expect(apps.installed.get().map(\.path) == [path])

        #expect(try await call(router, "DELETE", "/v1/uploads/\(id)").0 == 200)
        #expect(try await call(router, "GET", "/v1/uploads/\(id)").0 == 404)
        #expect(try await call(router, "PATCH", "/v1/uploads/\(id)").0 == 405)
        #expect(try await call(router, "GET", "/v1/uploads/\(id)/other").0 == 404)
    }

    @Test func localRequestsNeedTheToken() async throws {
        let router = APIRouter(
            tools: PhoneTools(phone: FakePhone(lines: []), activity: ActivityLog(), settleDelay: 0), uploads: uploads(),
            token: { "secret" }, port: { 4686 })
        let request = HTTPRequest(
            method: "POST", path: "/v1/uploads", headers: ["Host": "127.0.0.1:4686"],
            body: Data(#"{"name":"App.ipa","size":3}"#.utf8))
        #expect(await router.handle(request, from: .local).status == 401)
        #expect(await router.handle(request, from: .socket).status == 401)
        #expect(!FileManager.default.fileExists(atPath: temporary.url.appendingPathComponent("uploads").path))
    }

    @Test func installAppChecksTheUploadFitsTheDevice() async throws {
        let store = uploads()
        func upload(_ name: String, _ data: Data) async throws -> String {
            let id = try store.create(name: name, size: Int64(data.count), sha256: nil, source: "test").id
            _ = try store.write(id, offset: 0, data: data)
            _ = try await store.finish(id)
            return id
        }
        func install(_ arguments: JSONValue, on platform: AppPlatform) async throws -> ToolOutput {
            let tools = PhoneTools(
                phone: FakePhone(lines: [], apps: FakeApps(platform: platform)), activity: ActivityLog(), settleDelay: 0,
                uploads: store)
            return try await tools.call("install_app", arguments: arguments, source: "test", screenshotByDefault: false)
        }
        let apk = try await upload("app-debug.apk", Data("apk".utf8))
        let ipa = try await upload("App.ipa", Data("ipa".utf8))
        var deviceBuild = ZipWriter.app()
        deviceBuild[1].data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "dev.mobdev.fixture", "CFBundleSupportedPlatforms": ["iPhoneOS"]],
            format: .xml, options: 0)
        let zipped = ZipWriter.zip(deviceBuild)
        let deviceApp = try await upload("Device.zip", zipped)

        #expect(try await install(["upload": .string(apk)], on: .simulator).text.contains("is an .apk; a simulator installs an .app"))
        #expect(try await install(["upload": .string(ipa)], on: .simulator).text.contains("is an .ipa"))
        #expect(try await install(["upload": .string(ipa)], on: .android).text.contains("Android installs an .apk"))
        #expect(try await install(["upload": .string(apk)], on: .iPhone).text.contains("an iPhone installs an .ipa"))
        #expect(try await install(["upload": .string(deviceApp)], on: .simulator).text.contains("built for devices"))
        #expect(!(try await install(["upload": .string(apk)], on: .android).isError))
        #expect(!(try await install(["upload": .string(ipa)], on: .iPhone).isError))
        #expect(!(try await install(["upload": .string(deviceApp)], on: .iPhone).isError))

        let unknown = try await install(["upload": "0123456789abcdef0123456789abcdef"], on: .android)
        #expect(unknown.isError && unknown.text.contains("No upload"))
        let unfinished = try store.create(name: "Late.apk", size: 10, sha256: nil, source: "test").id
        #expect(try await install(["upload": .string(unfinished)], on: .android).text.contains("is not finished"))
        #expect(try await install(["upload": .string(apk), "path": "/tmp/x.apk"], on: .android).text == "Pass path or upload, not both.")
        #expect(try await install([:], on: .android).text.hasPrefix("Pass path, a build on the Mac"))
    }
}

@Suite struct UploadClientTests {
    let temporary = TemporaryFolder()

    func setup(chunkSize: Int = 1000) -> (UploadStore, APIRouter) {
        var limits = UploadStore.Limits()
        limits.chunkSize = chunkSize
        let store = UploadStore(folder: temporary.url.appendingPathComponent("uploads"), limits: limits)
        let tools = PhoneTools(phone: FakePhone(lines: [], apps: FakeApps()), activity: ActivityLog(), settleDelay: 0, uploads: store)
        return (store, APIRouter(tools: tools, uploads: store, token: { "secret" }, port: { 0 }))
    }

    @Test func resumesAfterLostAnswersAndRequests() async throws {
        let (_, router) = setup()
        let data = randomData(4321)
        let file = try temporary.file("app-debug.apk", data)
        // 1 create, 2 PUT 0 (answer lost), 3 GET, 4 PUT 1000 (never arrives), 5 GET, 6 PUT 1000 (busy),
        // 7 GET, 8 PUT 1000, …
        let transport = FlakyTransport(RouterTransport(router: router), lostAnswers: [2], lostRequests: [4], busy: [6])
        let client = UploadClient(transport: transport, pause: { _ in })
        let result = try await client.upload(file, name: "app-debug.apk")
        #expect(result["state"] == "finished" && result["sha256"] == .string(sha256(data)))
        let path = try #require(result["path"]?.stringValue)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
        let puts = transport.calls.get().filter { $0.hasPrefix("PUT") }
        #expect(puts.first == "PUT /v1/uploads/\(result["id"]?.stringValue ?? "")?offset=0")
        #expect(puts.filter { $0.hasSuffix("offset=0") }.count == 1)  // Resumed at 1000, not sent twice.
    }

    @Test func givesUpWhenTheMacRefuses() async throws {
        let (_, router) = setup()
        let file = try temporary.file("notes.ipa", Data("ipa".utf8))
        let client = UploadClient(
            transport: FlakyTransport(RouterTransport(router: router), lostRequests: Set(1...20)), attempts: 3, pause: { _ in })
        do {
            _ = try await client.upload(file, name: "notes.ipa")
            Issue.record("Uploaded without a connection.")
        } catch let failure as UploadClient.Failure {
            #expect(!failure.refused && failure.description.hasPrefix("Gave up after 3 tries"))
        }
        let refusing = UploadClient(transport: RouterTransport(router: router), pause: { _ in })
        do {
            _ = try await refusing.upload(file, name: "notes.txt")
            Issue.record("A text file was taken.")
        } catch let failure as UploadClient.Failure {
            #expect(failure.refused && failure.description.contains("must end in .ipa, .apk or .zip"))
        }
    }

    /// `Mobdev upload` without --url talks to the app over its socket, as `Mobdev call` does.
    @Test func uploadsOverTheAppSocket() async throws {
        let (_, router) = setup(chunkSize: 8 << 20)
        let socket = temporary.url.appendingPathComponent("s.sock")
        let server = HTTPServer(socket: socket) { await router.handle($0, from: .socket) }
        try await server.start()
        defer { server.stop() }
        let data = randomData(9 << 20)  // Two chunks, one of them 8 MiB.
        let file = try temporary.file("big.apk", data)
        let client = UploadClient(transport: SocketUploadTransport(socket: socket, token: "secret"), pause: { _ in })
        let result = try await client.upload(file, name: "big.apk")
        let path = try #require(result["path"]?.stringValue)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)

        let wrongToken = UploadClient(transport: SocketUploadTransport(socket: socket, token: "wrong"), pause: { _ in })
        await #expect(throws: UploadClient.Failure.self) { try await wrongToken.upload(file, name: "big.apk") }
    }

    @Test func commandZipsAppFoldersAndChecksFiles() async throws {
        let app = try temporary.app("My App.app")
        let prepared = try await UploadCommand.prepare(app.path) { _ in }
        defer { if let folder = prepared.temporary { try? FileManager.default.removeItem(at: folder) } }
        #expect(prepared.name == "My App.app.zip")
        let entries = try UploadArchive.entries(of: prepared.file, name: prepared.name, maxEntries: 100)
        #expect(entries.contains { $0.name == "My App.app/Info.plist" })
        #expect(!entries.contains { $0.name.contains("__MACOSX") || $0.name.contains("/._") })
        #expect(try await UploadCommand.prepare(try temporary.file("App.ipa", Data()).path) { _ in }.temporary == nil)
        await #expect(throws: ToolFailure.self) { try await UploadCommand.prepare(self.temporary.url.path) { _ in } }
        await #expect(throws: ToolFailure.self) { try await UploadCommand.prepare(try self.temporary.file("a.txt", Data()).path) { _ in } }

        #expect(try UploadCommand.parse(["App.ipa", "--url", "https://relay.mobdev.sh/h/studio"], environment: ["MOBDEV_KEY": "mdc_x"])
            == UploadCommand.Options(file: "App.ipa", url: "https://relay.mobdev.sh/h/studio", key: "mdc_x"))
        #expect(throws: ToolFailure.self) { try UploadCommand.parse(["a.ipa", "b.ipa"], environment: [:]) }
        let refused = await UploadCommand.execute(
            ["App.ipa", "--url", "http://relay.example.com/h/studio", "--key", "mdc_x"], environment: [:], output: { _ in },
            progress: { _ in })
        #expect(refused == 2)  // Plain http only on this Mac.
    }

    /// The script for containers without Mobdev, against this Mac's HTTP API with the token.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/curl")))
    func shellScriptUploads() async throws {
        let (store, _) = setup()
        // A local router checks the Host header against its port.
        let port = Locked<UInt16>(0)
        let local = APIRouter(
            tools: PhoneTools(phone: FakePhone(lines: [], apps: FakeApps()), activity: ActivityLog(), settleDelay: 0, uploads: store),
            uploads: store, token: { "secret" }, port: { port.get() })
        let checked = HTTPServer(port: 0) { await local.handle($0, from: .local) }
        try await checked.start()
        defer { checked.stop() }
        port.set(checked.port)

        let app = try temporary.app()
        let run = try await MobdevUploadScript.run(
            [app.path], url: "http://127.0.0.1:\(checked.port)", key: "secret", environment: ["MOBDEV_CHUNK_SIZE": "300"])
        #expect(run.status == 0, "\(run.errors)")
        let id = run.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = try store.build(id)
        #expect(build.kind == .app && build.name == "Fixture.app.zip")
        #expect(FileManager.default.fileExists(atPath: build.url.appendingPathComponent("Info.plist").path))
        #expect(run.errors.contains("Uploaded Fixture.app.zip"))

        let data = randomData(2000)
        let apk = try temporary.file("app debug.apk", data)
        let json = try await MobdevUploadScript.run(["--json", apk.path], url: "http://127.0.0.1:\(checked.port)", key: "secret")
        #expect(json.status == 0, "\(json.errors)")
        let result = try JSONValue.parse(Data(json.output.utf8))
        #expect(result["sha256"] == .string(sha256(data)) && result["name"] == "app_debug.apk")

        let wrongKey = try await MobdevUploadScript.run([apk.path], url: "http://127.0.0.1:\(checked.port)", key: "wrong")
        #expect(wrongKey.status == 1 && wrongKey.errors.contains("Missing or wrong bearer token"))
        let notABuild = try await MobdevUploadScript.run([try temporary.file("notes.txt", Data()).path], url: "http://127.0.0.1:1", key: "k")
        #expect(notABuild.status == 1 && notABuild.errors.contains("is not a build"))
        #expect(try await MobdevUploadScript.run([], url: "http://127.0.0.1:1", key: "k").status == 2)
    }
}

/// The whole way a cloud agent's build goes, on a real simulator. Opt-in, since it installs there:
///
///     MOBDEV_TEST_SIMULATOR=<udid> MOBDEV_TEST_SIMULATOR_APP=../examples/flows/fixture/MobdevFixture.app \
///       MOBDEV_HOME=$(mktemp -d) swift test --filter UploadIntegration
///
/// scripts/mobdev-upload.sh zips the fixture and sends it through the Go relay to tools for the
/// simulator; install_app {"upload"} through the relay installs it, list_apps shows it, and it is
/// uninstalled afterwards.
@Suite(.serialized) struct UploadIntegrationTests {
    static let simulator = ProcessInfo.processInfo.environment["MOBDEV_TEST_SIMULATOR"]
    static let app = ProcessInfo.processInfo.environment["MOBDEV_TEST_SIMULATOR_APP"]

    @Test(.enabled(if: simulator != nil && app != nil && RelayEndToEndTests.goPath != nil))
    func installsAnUploadedBuildOnASimulator() async throws {
        let device = try #require(Self.simulator)
        let relay = try await RelayProcess.start()
        defer { relay.stop() }
        let temporary = TemporaryFolder()
        let store = UploadStore(folder: temporary.url.appendingPathComponent("uploads"))
        let emulators = EmulatorHub(adb: nil) {}
        let tools = DeviceTools(hub: DeviceHub(keyboardLayout: .us) {}, emulators: emulators, settleDelay: 0, uploads: store)
        emulators.start()
        defer { emulators.stop() }
        for _ in 0..<60 where !emulators.devices.contains(where: { $0.id == device }) {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        try #require(emulators.devices.contains { $0.id == device }, "\(device) did not appear")
        let router = APIRouter(tools: tools, uploads: store, token: { "unused" }, port: { 0 })
        let client = RelayClient(handler: { request in await router.handle(request, from: .relay) })
        let secret = "mdh_" + SecretStore.randomHex(bytes: 32)
        client.start(url: relay.base, secret: secret, hostName: "studio", accessToken: nil)
        defer { client.stop() }
        for _ in 0..<100 where client.state != .connected { try await Task.sleep(for: .milliseconds(50)) }
        let key = RelayClient.clientKey(forSecret: secret)
        let mac = relay.base.appendingPathComponent("h/studio")

        let script = try await MobdevUploadScript.run([try #require(Self.app)], url: mac.absoluteString, key: key)
        #expect(script.status == 0, "\(script.errors)")
        print(script.errors)
        let id = script.output.trimmingCharacters(in: .whitespacesAndNewlines)

        func call(_ tool: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
            var request = URLRequest(url: mac.appendingPathComponent("v1/tools/\(tool)"), timeoutInterval: 120)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = JSONValue.object(arguments.merging(["device": .string(device)]) { $1 }).encoded()
            let (body, _) = try await URLSession.shared.data(for: request)
            let result = try JSONValue.parse(body)
            print("── \(tool) \(arguments)\n\(result["text"]?.stringValue ?? result.compactString)")
            return result
        }
        let installed = try await call("install_app", ["upload": .string(id)])
        #expect(installed["ok"] == true)
        #expect(installed["text"]?.stringValue?.contains("from the upload MobdevFixture.app.zip") == true)
        let listed = try await call("list_apps", [:])
        #expect(listed["text"]?.stringValue?.contains("dev.mobdev.fixture") == true)
        let removed = try await call("uninstall_app", ["bundle_id": "dev.mobdev.fixture"])
        #expect(removed["ok"] == true)

        // The same with Mobdev upload, once swift build made it.
        let mobdev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/Mobdev")
        if FileManager.default.isExecutableFile(atPath: mobdev.path) {
            let upload = try await MobdevUploadScript.command(
                mobdev.path, ["upload", try #require(Self.app), "--url", mac.absoluteString],
                environment: ["MOBDEV_KEY": key, "MOBDEV_HOME": temporary.url.path])
            print(upload.errors)
            #expect(upload.status == 0)
            let second = upload.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let again = try await call("install_app", ["upload": .string(second)])
            #expect(again["ok"] == true)
            #expect(try await call("uninstall_app", ["bundle_id": "dev.mobdev.fixture"])["ok"] == true)
        }
    }
}

/// Runs scripts/mobdev-upload.sh with dash, a strictly POSIX shell.
enum MobdevUploadScript {
    static let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/mobdev-upload.sh").path

    static func run(_ arguments: [String], url: String, key: String, environment: [String: String] = [:]) async throws
        -> (status: Int32, output: String, errors: String)
    {
        let dash = "/bin/dash"
        return try await command(
            FileManager.default.isExecutableFile(atPath: dash) ? dash : "/bin/sh", [path] + arguments,
            environment: environment.merging(["MOBDEV_URL": url, "MOBDEV_KEY": key]) { first, _ in first })
    }

    /// Runs a command off the test's threads, which may have to answer its requests.
    static func command(_ executable: String, _ arguments: [String], environment: [String: String]) async throws
        -> (status: Int32, output: String, errors: String)
    {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try runBlocking(executable, arguments, environment: environment) })
            }
        }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], environment: [String: String]) throws
        -> (status: Int32, output: String, errors: String)
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment.merging(
            ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
        ) { first, _ in first }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Read both while it runs, so neither pipe fills up.
        let outputData = Locked(Data())
        let reader = Thread { outputData.set(output.fileHandleForReading.readDataToEndOfFile()) }
        reader.start()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        while reader.isExecuting || !reader.isFinished { usleep(10_000) }
        return (
            process.terminationStatus, String(decoding: outputData.get(), as: UTF8.self),
            String(decoding: errorData, as: UTF8.self)
        )
    }
}
