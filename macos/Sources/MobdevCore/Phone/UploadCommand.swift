import Foundation

/// `Mobdev upload <file>`: sends a build to a Mac running Mobdev, through a relay or to the app on
/// this Mac, so `install_app` can install it there with `{"upload": "<id>"}`. For cloud agents and
/// CI that build somewhere else; `scripts/mobdev-upload.sh` does the same with curl alone.
///
/// Prints the upload's id, or with --json the finished upload. Progress and errors go to standard
/// error. Exits 0 when the upload is finished, 1 when the Mac refused it and 2 when it could not
/// be sent.
public enum UploadCommand {
    static let usage = """
        Usage: Mobdev upload <file> [--url <URL>] [--key <client key>] [--json]

        Sends a build to a Mac running Mobdev, so install_app can install it there: an .ipa, an
        .apk, a zipped .app, or an .app folder, which is zipped first. Prints the upload's id; then
        call install_app with {"upload": "<id>"}. The build goes in chunks of up to 8 MiB; a chunk
        that fails is sent again, and the upload goes on where the Mac's copy ends.
          --url   the relay URL with the Mac's name, e.g. https://relay.mobdev.sh/h/studio, or a
                  Mac's HTTP API; without it the build goes to the Mobdev app on this Mac
          --key   the relay's client key (mdc_…); MOBDEV_KEY works too, and ps cannot show it
          --json  print the finished upload as JSON: id, path on the Mac, kind, sha256
        """

    struct Options: Equatable {
        var file: String
        var url: String?
        var key: String?
        var json = false
    }

    public static func run(_ arguments: [String]) -> Never {
        let progress: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        CommandSupport.run { await execute(arguments, output: CommandSupport.print, progress: progress) }
    }

    static func parse(_ arguments: [String], environment: [String: String]) throws -> Options {
        var rest = arguments[...]
        var file: String?
        var options = Options(file: "")
        while let argument = rest.popFirst() {
            switch argument {
            case "--json": options.json = true
            case "--url", "--key":
                guard let value = rest.popFirst() else { throw ToolFailure("\(argument) needs a value.") }
                if argument == "--url" { options.url = value } else { options.key = value }
            case "-h", "--help": throw ToolFailure("")
            default:
                guard !argument.hasPrefix("-") else { throw ToolFailure("Unknown option \(argument).") }
                guard file == nil else { throw ToolFailure("Upload one file at a time.") }
                file = argument
            }
        }
        guard let file else { throw ToolFailure("Which file?") }
        options.file = file
        if options.key == nil, let key = environment["MOBDEV_KEY"], !key.isEmpty { options.key = key }
        return options
    }

    static func execute(
        _ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
        output: @escaping @Sendable (String) -> Void, progress: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        let options: Options
        do {
            options = try parse(arguments, environment: environment)
        } catch {
            let message = String(describing: error)
            progress(message.isEmpty ? usage : "\(message)\n\n\(usage)")
            return 2
        }
        let transport: any UploadTransport
        if let url = options.url {
            guard let key = options.key else {
                progress("Pass the relay's client key with --key or MOBDEV_KEY.")
                return 2
            }
            do {
                transport = HTTPUploadTransport(base: try RelayClient.validatedURL(url), key: key)
            } catch {
                progress("\(url): \(error)")
                return 2
            }
        } else {
            // As with Mobdev call: a binary outside an app bundle, as swift build makes, never
            // reaches the installed app.
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                progress(
                    "Without --url, Mobdev upload sends the build to the Mobdev app on this Mac; this Mobdev is not inside the app. Pass --url.")
                return 2
            }
            transport = SocketUploadTransport(
                socket: MobdevPaths.socketFile, token: SecretStore.read(MobdevPaths.tokenFile))
        }
        let prepared: (file: URL, name: String, temporary: URL?)
        do {
            prepared = try await prepare(options.file, progress: progress)
        } catch {
            progress(String(describing: error))
            return 2
        }
        defer { if let temporary = prepared.temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            let client = UploadClient(transport: transport, progress: progress)
            let result = try await client.upload(prepared.file, name: prepared.name)
            let id = result["id"]?.stringValue ?? ""
            progress("Uploaded \(prepared.name). Install it with install_app {\"upload\": \"\(id)\"}.")
            output(options.json ? result.compactString : id)
            return 0
        } catch let failure as UploadClient.Failure {
            progress(failure.description)
            return failure.refused ? 1 : 2
        } catch is CancellationError {
            return 130  // Interrupted; the Mac drops the unfinished upload after 24 hours.
        } catch {
            progress(String(describing: error))
            return 2
        }
    }

    /// The file to send and its name: an .app folder is zipped into a temporary folder first.
    static func prepare(_ path: String, progress: @Sendable (String) -> Void) async throws
        -> (file: URL, name: String, temporary: URL?)
    {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            throw ToolFailure("\(path) does not exist.")
        }
        let kind = url.pathExtension.lowercased()
        if isFolder.boolValue {
            guard kind == "app" else {
                throw ToolFailure("\(path) is a folder. Mobdev upload sends an .app folder, an .ipa, an .apk or a .zip.")
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
                "mobdev-upload-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let zip = temporary.appendingPathComponent(url.lastPathComponent + ".zip")
            progress("Zipping \(url.lastPathComponent)…")
            // No resource forks or extended attributes: an app bundle needs neither, and they would
            // add AppleDouble files.
            let result = try await ProcessRunner().run(
                URL(fileURLWithPath: "/usr/bin/ditto"),
                ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", url.path, zip.path], timeout: 600)
            guard result.status == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                throw ToolFailure("Could not zip \(url.lastPathComponent): \(result.output)")
            }
            return (zip, zip.lastPathComponent, temporary)
        }
        guard ["ipa", "apk", "zip"].contains(kind) else {
            throw ToolFailure(
                "\(url.lastPathComponent) is not a build. Mobdev upload sends an .app folder, an .ipa, an .apk or a zipped .app.")
        }
        return (url, url.lastPathComponent, nil)
    }
}

/// One request of the upload protocol, over HTTP or the app's socket.
protocol UploadTransport: Sendable {
    /// Status and body. Throws when no answer came: the request may or may not have arrived.
    func send(_ method: String, _ path: String, body: Data, contentType: String?) async throws -> (status: Int, body: Data)
}

/// To a relay (`https://relay.mobdev.sh/h/<mac>`) or a Mac's HTTP API, with a bearer key.
struct HTTPUploadTransport: UploadTransport {
    let base: URL
    let key: String
    private let session: URLSession

    init(base: URL, key: String) {
        self.base = base
        self.key = key
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ method: String, _ path: String, body: Data, contentType: String?) async throws -> (status: Int, body: Data) {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text + path) else { throw URLError(.badURL) }
        // A relay gives the Mac 90 s; this waits a little longer.
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if method != "GET" { request.httpBody = body }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// To the Mobdev app on this Mac over its private socket, as `Mobdev call` does.
struct SocketUploadTransport: UploadTransport {
    let socket: URL
    let token: String?

    func send(_ method: String, _ path: String, body: Data, contentType: String?) async throws -> (status: Int, body: Data) {
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let contentType { headers["Content-Type"] = contentType }
        let request = MCPStdioBridge.Bridge.request(method, path, headers: headers, body: body)
        let socket = self.socket
        let response = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try LocalSocket.exchange(request, at: socket, timeout: 300) })
            }
        }
        let (data, status) = try MCPStdioBridge.Bridge.parse(response)
        return (status, data)
    }
}

/// Sends a file with the upload protocol: create, PUT the chunks in order, finish. A chunk without
/// an answer, or a busy relay, is retried after asking the Mac how much it has, so nothing is sent
/// twice; after a chunk got no answer the chunks get smaller, for slow connections.
struct UploadClient: Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        /// The Mac answered and said no, rather than not being reachable.
        var refused = false
    }

    let transport: any UploadTransport
    var attempts = 8
    /// Waits before the given retry, from 1.
    var pause: @Sendable (Int) async throws -> Void = { attempt in
        try await Task.sleep(for: .seconds(min(1 << min(attempt - 1, 4), 15)))
    }
    var progress: @Sendable (String) -> Void = { _ in }

    static let maxChunk = 8 << 20

    /// Half, down to 1 MiB; a chunk size the Mac asked for below that stays.
    static func smaller(_ chunk: Int) -> Int {
        chunk > 1 << 20 ? max(chunk / 2, 1 << 20) : chunk
    }

    /// Answers worth asking again: the relay or the Mac is busy, or did not answer in time.
    static func retryable(_ status: Int) -> Bool {
        [0, 408, 425, 429, 500, 502, 503, 504].contains(status)
    }

    /// The finished upload as the Mac reported it.
    func upload(_ file: URL, name: String) async throws -> JSONValue {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        progress("Uploading \(name), \(UploadStore.bytes(size))…")
        let digest = try UploadStore.sha256(of: file)
        let created = try await request(
            "POST", "/v1/uploads",
            body: JSONValue(["name": .string(name), "size": .number(Double(size)), "sha256": .string(digest)]).encoded(),
            contentType: "application/json", expect: 201)
        guard let id = created["id"]?.stringValue else { throw Failure(description: "The Mac sent no upload id.") }
        var chunk = min(Int(created["chunk_size"]?.doubleValue ?? 0), Self.maxChunk)
        if chunk <= 0 { chunk = Self.maxChunk }
        var offset = Int64(created["received"]?.doubleValue ?? 0)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var failures = 0
        var reported = -1
        while offset < size {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: Int(min(Int64(chunk), size - offset))) ?? Data()
            guard !data.isEmpty else { throw Failure(description: "\(file.path) changed while it was being uploaded.") }
            let answer: (status: Int, body: Data)
            do {
                answer = try await transport.send(
                    "PUT", "/v1/uploads/\(id)?offset=\(offset)", body: data, contentType: "application/octet-stream")
            } catch let error as LocalSocket.Failure where error == .notRunning {
                throw Failure(description: "Mobdev is not running on this Mac. Open it, or pass --url.")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // No answer: perhaps too slow for the relay's limit. Smaller chunks, then ask what arrived.
                chunk = Self.smaller(chunk)
                offset = try await resume(id, after: String(describing: error), failures: &failures)
                continue
            }
            let body = try? JSONValue.parse(answer.body)
            switch answer.status {
            case 200:
                offset = Int64(body?["received"]?.doubleValue ?? Double(offset + Int64(data.count)))
                failures = 0
                let percent = Int(Double(offset) / Double(size) * 100)
                if percent / 10 != reported / 10 {
                    reported = percent
                    progress("  \(UploadStore.bytes(offset)) of \(UploadStore.bytes(size)) (\(percent) %)")
                }
            case 409 where body?["received"]?.doubleValue != nil:
                // The Mac has more or less than this chunk assumed, e.g. after an answer got lost.
                offset = Int64(body?["received"]?.doubleValue ?? 0)
            case let status where Self.retryable(status):
                // The Go relay answers 408 when a request takes more than 30 s to arrive.
                if status == 408 { chunk = Self.smaller(chunk) }
                offset = try await resume(id, after: Self.message(status, answer.body), failures: &failures)
            default:
                throw Failure(description: Self.message(answer.status, answer.body), refused: true)
            }
        }
        progress("Finishing: the Mac checks the SHA-256\(name.lowercased().hasSuffix(".zip") ? " and unpacks the app" : "")…")
        return try await request("POST", "/v1/uploads/\(id)/finish", body: Data(), contentType: nil, expect: 200)
    }

    /// After a failed chunk: waits, then asks the Mac how many bytes it has.
    private func resume(_ id: String, after reason: String, failures: inout Int) async throws -> Int64 {
        failures += 1
        guard failures < attempts else { throw Failure(description: "Gave up after \(attempts) tries: \(reason)") }
        progress("  \(reason); trying again…")
        try await pause(failures)
        let status = try await request("GET", "/v1/uploads/\(id)", body: Data(), contentType: nil, expect: 200)
        return Int64(status["received"]?.doubleValue ?? 0)
    }

    /// A request answered with `expect`, retried while there is no answer or the relay is busy.
    /// Creating, asking and finishing can be repeated: a finish that outlasted the relay's wait goes
    /// on on the Mac, and asking again waits for it.
    private func request(_ method: String, _ path: String, body: Data, contentType: String?, expect: Int) async throws
        -> JSONValue
    {
        var failures = 0
        while true {
            try Task.checkCancellation()
            let reason: String
            do {
                let answer = try await transport.send(method, path, body: body, contentType: contentType)
                if answer.status == expect, let value = try? JSONValue.parse(answer.body) { return value }
                guard Self.retryable(answer.status) else {
                    throw Failure(description: Self.message(answer.status, answer.body), refused: true)
                }
                reason = Self.message(answer.status, answer.body)
            } catch let failure as Failure {
                throw failure
            } catch let error as LocalSocket.Failure where error == .notRunning {
                throw Failure(description: "Mobdev is not running on this Mac. Open it, or pass --url.")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reason = String(describing: error)
            }
            failures += 1
            guard failures < attempts else { throw Failure(description: "Gave up after \(attempts) tries: \(reason)") }
            progress("  \(reason); trying again…")
            try await pause(failures)
        }
    }

    static func message(_ status: Int, _ body: Data) -> String {
        if let error = (try? JSONValue.parse(body))?["error"]?.stringValue { return "\(error) (HTTP \(status))" }
        let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(text)"
    }
}
