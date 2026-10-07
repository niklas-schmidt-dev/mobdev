import Foundation

/// Reads the requests of an iOS app from what its own CFNetwork logs, on simulators and on
/// iPhones in Developer Mode alike, without installing anything.
///
/// The app runs with `CFNETWORK_DIAGNOSTICS=1`, which makes CFNetwork log each request's steps, and
/// `ACTIVITY_LOG_STDERR=1`, which copies the app's whole system log to the console Mobdev already
/// captures: on iOS 27 the diagnostics stay in the system log without it, even with
/// `OS_ACTIVITY_DT_MODE`, which passes on only errors of the system's own logging. No narrower switch
/// turned up: `ACTIVITY_LOG_STDERR` takes no filter, and `CFNETWORK_HAR_LOGGING` logged nothing
/// (simulator, 2026-10-07). Level 1 is enough; 3 adds hex dumps of what is sent. Lines look like
///
///     2026-10-07 15:28:56.327755+0200 NetFixture[40402:61638776] [Diagnostics] CFNetwork Diagnostics [1:10] 15:28:56.327 {
///     Protocol Enqueue: request GET http://example.com/<redacted>
///              Request: request GET http://example.com/<redacted>
///     } [1:10]
///
/// followed for the same request by "Protocol Received" (the status line), "Did Finish" (total
/// time and bytes) or "Did Fail" (the error), and a "[Summary] Task <…> summary for task success
/// {…}" line with status, bytes on the wire and protocol. iOS replaces the path and query with
/// "<redacted>", so only the method, scheme and host of the URL are known.
///
/// Everything else the network stack logs (libnetwork, BoringSSL, QUIC…) is recognized as well and
/// kept out of `logs`, where it would bury what the app prints.
final class CFNetworkLog: Sendable {
    let app: String
    let log: NetworkLog

    private struct Pending {
        var id: Int
        var method: String
        var url: String
        var hasStatus = false
        var opened: Date
    }

    private struct Finished {
        var number: Int
        var milliseconds: Double
        var failed: Bool
        var at: Date
    }

    private struct Summary {
        var status: Int
        var milliseconds: Double
        var requestBytes: Int?
        var responseBytes: Int?
        var httpProtocol: String?
        var failed: Bool
        var at: Date
    }

    private struct State {
        var recording = true
        /// The Diagnostics message being read: its time and lines so far.
        var block: (time: Date, lines: [String])?
        /// The last line was the network stack's, so the indented lines of the same message follow.
        var continuing = false
        var pending: [Pending] = []
        var finished: [Finished] = []
        var summaries: [Summary] = []
    }

    private let state = Locked(State())

    init(app: String, log: NetworkLog) {
        self.app = app
        self.log = log
    }

    /// Whether new requests are listed. Lines are still kept out of `logs` after it stops, since
    /// the app logs them until it is launched again.
    var isRecording: Bool { state.get().recording }

    /// Stops listing requests; the ones still running are listed as they stand.
    func stopRecording() {
        let open = state.withLock { state -> [Pending] in
            state.recording = false
            defer { state.pending = [] }
            return state.pending
        }
        for request in open { log.finish(request.id) }
    }

    /// Takes one console line of the app. True when it is the system's network logging, which then
    /// stays out of `logs`.
    func consume(_ rawLine: String) -> Bool {
        // The terminal sometimes puts control characters in front, e.g. an end-of-transmission;
        // a tab stays, it marks a continued message.
        let line = String(
            rawLine.drop { character in
                character.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }
            })
        let header = Self.header(line)
        let finishedBlock = state.withLock { state -> (time: Date, lines: [String])? in
            guard let block = state.block else { return nil }
            if header == nil, line.firstMatch(of: /^\} \[\d+:\d+\]$/) == nil {
                // A message that never ends is given up after a while rather than eating the console.
                if block.lines.count < 200 { state.block?.lines.append(line) } else { state.block = nil }
                return nil
            }
            state.block = nil
            return block
        }
        if let finishedBlock { handle(block: finishedBlock.lines, time: finishedBlock.time) }
        if header == nil, finishedBlock != nil || state.get().block != nil { return true }

        guard let header else {
            // The other lines of a message over several lines are indented ("\t[C7.1.1 …]",
            // "    \"LocalDataTask <…>\""), start with a closing bracket ("), NSLocalizedDescription=…")
            // or are a quoted hex dump. What the app prints next starts otherwise and ends it.
            return state.withLock { state in
                guard state.continuing, let first = line.first, first.isWhitespace || ")]}'\"".contains(first) else {
                    state.continuing = false
                    return false
                }
                return true
            }
        }
        let network = Self.isNetworkStack(category: header.category, message: header.message)
        state.withLock { $0.continuing = network }
        guard network else { return false }
        if header.category == "Diagnostics", header.message.hasPrefix("CFNetwork Diagnostics ["),
            header.message.hasSuffix("{")
        {
            state.withLock { state in
                state.block = (header.time, [])
                state.continuing = false
            }
            return true
        }
        if header.category == "Summary" { handle(summary: header.message, time: header.time) }
        return true
    }

    // MARK: Lines

    struct Header: Equatable {
        var time: Date
        var process: String
        var category: String
        var message: String
    }

    /// "2026-10-07 15:28:56.327755+0200 NetFixture[40402:61638776] [Diagnostics] message"; some of
    /// libnetwork's lines have an empty category, "[]".
    static func header(_ line: String) -> Header? {
        guard let match = line.firstMatch(of: /^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+[+-]\d{4}) (.+?)\[\d+:\d+\] \[([^\]]*)\] (.*)$/),
            let time = date(String(match.1))
        else { return nil }
        return Header(time: time, process: String(match.2), category: String(match.3), message: String(match.4))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter
    }()

    static func date(_ text: String) -> Date? { dateFormatter.date(from: text) }

    /// The lines of Apple's network stack seen in an iOS 27 app's log while it made requests:
    /// CFNetwork's diagnostics, summaries and task lines, libnetwork, BoringSSL, QUIC, HTTP/3,
    /// certificate checks and the trustd connections they open. Matched by category and how the
    /// message starts, so an app's own log lines in a category of the same name stay.
    static func isNetworkStack(category: String, message: String) -> Bool {
        switch category {
        case "Diagnostics": message.hasPrefix("CFNetwork Diagnostics")
        case "Summary": message.hasPrefix("Task <") || message.hasPrefix("Connection ")
        case "Default": message.hasPrefix("Task <") || message.hasPrefix("Connection ")
        case "connection":
            message.hasPrefix("nw_") || message.firstMatch(of: /^\[C\d/) != nil
                || message.firstMatch(of: /^\[0x[0-9a-f]+\] (activating connection: .*name=com\.apple\.trustd|invalidated because the current process cancelled)/) != nil
        case "": message.hasPrefix("nw_")
        case "boringssl": message.hasPrefix("boringssl_") || message.hasPrefix("nw_protocol_boringssl")
        case "quic": message.hasPrefix("quic_")
        case "h3stream", "h3connection", "h2stream", "h2connection": message.hasPrefix("0x")
        case "trust": message.hasPrefix("(Trust 0x")
        case "activity": message.contains("nw_activity") || message.contains("parent activity")
        default: false
        }
    }

    // MARK: Diagnostics

    /// "request GET http://example.com/<redacted>" or a bare URL, which is what a GET's loader shows.
    static func request(_ text: String) -> (method: String?, url: String) {
        let parts = text.split(separator: " ")
        if parts.count == 3, parts[0] == "request" { return (String(parts[1]), String(parts[2])) }
        return (nil, text)
    }

    /// "https://example.com:8443/<redacted>" as scheme, host, port (when not the default) and path,
    /// nil when iOS hid it.
    static func components(_ url: String) -> (scheme: String, host: String, port: Int?, path: String?)? {
        guard let separator = url.range(of: "://") else { return nil }
        let scheme = url[..<separator.lowerBound].lowercased()
        let rest = url[separator.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let defaultPort = scheme == "http" ? 80 : 443
        guard let (host, port) = ProxyRequestHead.hostAndPort(String(rest[..<slash]), defaultPort: defaultPort) else {
            return nil
        }
        let path = String(rest[slash...])
        let hidden = path.contains("<redacted>") || path.contains("<private>")
        return (scheme, host, port == defaultPort ? nil : port, hidden ? nil : (path.isEmpty ? "/" : path))
    }

    /// "Protocol Enqueue: request GET http://…" and the indented "Key: value" lines below it.
    static func fields(_ lines: [String]) -> (title: String, value: String, fields: [String: String])? {
        var pairs: [(String, String)] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // "Key: value", or "Key:" with nothing after it.
            guard let colon = trimmed.range(of: ": ") ?? (trimmed.hasSuffix(":") ? trimmed.range(of: ":", options: .backwards) : nil)
            else { continue }
            pairs.append((String(trimmed[..<colon.lowerBound]), String(trimmed[colon.upperBound...])))
        }
        guard let first = pairs.first else { return nil }
        var fields: [String: String] = [:]
        for (key, value) in pairs.dropFirst() where fields[key] == nil { fields[key] = value }
        return (first.0, first.1, fields)
    }

    private func handle(block lines: [String], time: Date) {
        guard isRecording, let block = Self.fields(lines) else { return }
        switch block.title {
        case "Protocol Enqueue":
            let request = Self.request(block.value)
            guard let method = request.method, let parts = Self.components(request.url) else { return }
            let entry = NetworkEntry(
                time: time, app: app, method: method, scheme: parts.scheme, host: parts.host, port: parts.port,
                path: parts.path, source: .cfnetwork)
            let id = log.open(entry)
            state.withLock { state in
                state.pending.append(Pending(id: id, method: method, url: request.url, opened: time))
                // A request whose end never shows (it was cancelled, say) does not stay forever.
                if state.pending.count > 500 { state.pending.removeFirst(state.pending.count - 500) }
            }
        case "Protocol Received":
            let request = Self.request(block.value)
            guard let status = block.fields["Response"].flatMap(Self.status) else { return }
            let id = state.withLock { state -> Int? in
                guard let index = state.pending.firstIndex(where: {
                    !$0.hasStatus && $0.url == request.url && (request.method == nil || $0.method == request.method)
                }) else { return nil }
                state.pending[index].hasStatus = true
                return state.pending[index].id
            }
            if let id { log.update(id) { $0.status = status } }
        case "Did Finish", "Did Fail":
            let failed = block.title == "Did Fail"
            let request = Self.request(block.fields["Loader"] ?? "")
            let seconds = block.fields["total time"].flatMap { Double($0.trimmingCharacters(in: .letters)) }
            let bytes = block.fields["total bytes"].flatMap { Int($0) }
            let error = failed ? Self.error(block.fields["Error"] ?? "") : nil
            let pending = state.withLock { state -> Pending? in
                guard let index = state.pending.firstIndex(where: {
                    $0.url == request.url && (request.method == nil || $0.method == request.method)
                }) else { return nil }
                return state.pending.remove(at: index)
            }
            func complete(_ entry: inout NetworkEntry) {
                if let seconds { entry.duration = seconds }
                if let bytes, !failed { entry.bytesReceived = bytes }
                entry.error = error
            }
            let number: Int?
            if let pending {
                number = log.finish(pending.id, complete)
            } else if let parts = Self.components(request.url) {
                // Without its start, e.g. one that began before Mobdev listened.
                var entry = NetworkEntry(
                    time: time.addingTimeInterval(-(seconds ?? 0)), app: app, method: request.method ?? "GET",
                    scheme: parts.scheme, host: parts.host, port: parts.port, path: parts.path, source: .cfnetwork)
                complete(&entry)
                number = log.add(entry)
            } else {
                number = nil
            }
            if let number, let seconds {
                pair(Finished(number: number, milliseconds: seconds * 1000, failed: failed, at: Date()))
            }
        default:
            break
        }
    }

    /// "HTTP/1.1 404 Not Found" or "HTTP/2.0 200"; HTTP/3 answers say "not yet parsed".
    static func status(_ text: String) -> Int? {
        guard let match = text.firstMatch(of: /^HTTP\/[\d.]+ (\d{3})/) else { return nil }
        return Int(match.1)
    }

    /// "Error Domain=kCFErrorDomainCFNetwork Code=-1003 UserInfo=…" as what it means.
    static func error(_ text: String) -> String {
        guard let match = text.firstMatch(of: /Code=(-?\d+)/), let code = Int(match.1) else {
            return text.isEmpty ? "failed" : String(text.prefix(200))
        }
        let meanings = [
            -999: "cancelled", -1001: "timed out", -1003: "host not found", -1004: "could not connect",
            -1005: "connection lost", -1009: "offline", -1022: "blocked by App Transport Security",
            -1200: "secure connection failed", -1202: "untrusted certificate",
        ]
        return meanings[code].map { "\($0) (\(code))" } ?? "error \(code)"
    }

    // MARK: Summaries

    /// "Task <…>.<1> summary for task success {transaction_duration_ms=203, response_status=404,
    /// connection=1, protocol="http/1.1", …, request_bytes=221, …, response_bytes=701, …}".
    static func summaryValues(_ message: String) -> (failed: Bool, values: [String: String])? {
        guard let match = message.firstMatch(of: /summary for task (success|failure) \{(.*)\}$/) else { return nil }
        var values: [String: String] = [:]
        for pair in match.2.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            values[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return (match.1 == "failure", values)
    }

    private func handle(summary message: String, time: Date) {
        guard isRecording, let (failed, values) = Self.summaryValues(message),
            let milliseconds = values["transaction_duration_ms"].flatMap(Double.init)
        else { return }
        let httpProtocol = values["protocol"].flatMap { $0 == "(null)" || $0.isEmpty ? nil : $0 }
        pair(
            Summary(
                status: values["response_status"].flatMap { Int($0) } ?? -1, milliseconds: milliseconds,
                requestBytes: values["request_bytes"].flatMap { Int($0) },
                responseBytes: values["response_bytes"].flatMap { Int($0) }, httpProtocol: httpProtocol,
                failed: failed, at: Date()))
    }

    /// The summary names the task, not the URL, so it joins the finished request of the same
    /// outcome whose time is closest: it was logged within a millisecond after "Did Finish" each
    /// time, with durations 0.5 to 17 ms apart.
    private func pair(_ finished: Finished) { pair(finished: finished, summary: nil) }
    private func pair(_ summary: Summary) { pair(finished: nil, summary: summary) }

    private func pair(finished: Finished?, summary: Summary?) {
        let match = state.withLock { state -> (Finished, Summary)? in
            let now = Date()
            state.finished.removeAll { now.timeIntervalSince($0.at) > 5 }
            state.summaries.removeAll { now.timeIntervalSince($0.at) > 5 }
            func fits(_ finished: Finished, _ summary: Summary) -> Double? {
                let gap = abs(finished.milliseconds - summary.milliseconds)
                guard finished.failed == summary.failed, gap <= max(30, finished.milliseconds * 0.2) else { return nil }
                return gap
            }
            if let finished {
                let best = state.summaries.indices.compactMap { index in fits(finished, state.summaries[index]).map { (index, $0) } }
                    .min { $0.1 < $1.1 }
                guard let best else {
                    state.finished.append(finished)
                    return nil
                }
                return (finished, state.summaries.remove(at: best.0))
            }
            guard let summary else { return nil }
            let best = state.finished.indices.compactMap { index in fits(state.finished[index], summary).map { (index, $0) } }
                .min { $0.1 < $1.1 }
            guard let best else {
                state.summaries.append(summary)
                return nil
            }
            return (state.finished.remove(at: best.0), summary)
        }
        guard let (finished, summary) = match else { return }
        log.amend(finished.number) { entry in
            if summary.status > 0 { entry.status = summary.status }
            if let bytes = summary.requestBytes, bytes > 0 { entry.bytesSent = bytes }
            if let bytes = summary.responseBytes, bytes > 0 { entry.bytesReceived = bytes }
            if let httpProtocol = summary.httpProtocol { entry.httpProtocol = httpProtocol }
        }
    }
}
