import Foundation
import Testing
@testable import MobdevCore

// MARK: - iOS: CFNetwork's log

@Suite struct CFNetworkLogTests {
    /// What the net fixture app (four requests on launch) printed on an iOS 27 simulator with
    /// CFNETWORK_DIAGNOSTICS=1 and ACTIVITY_LOG_STDERR=1, 2026-10-07: lines kept verbatim, most of
    /// the network stack's left out.
    static let console = #"""
        dev.mobdev.netfixture: 46055
        netfixture: launched
        2026-10-07 15:30:54.722193+0200 NetFixture[46055:61652858] [app] netfixture: logger info line
        2026-10-07 15:30:54.877541+0200 NetFixture[46055:61652858] [InterfaceStyle] Not push traits update to screen for new style 0, <_UIKeyboardInputScene: 0x109cc0000>
        2026-10-07 15:30:56.322378+0200 NetFixture[46055:61652917] [Diagnostics] CFNetwork Diagnostics [1:10] 15:30:56.322 {
        Protocol Enqueue: request GET http://example.com/<redacted>
                 Request: request GET http://example.com/<redacted>
                 Message: GET http://example.com/<redacted>
        } [1:10]
        2026-10-07 15:30:56.322413+0200 NetFixture[46055:61652917] [Default] Initializing AlternativeServices Storage singleton
        2026-10-07 15:30:56.324821+0200 NetFixture[46055:61652917] [Diagnostics] CFNetwork Diagnostics [1:11] 15:30:56.324 {
        Protocol Enqueue: request GET https://nonexistent.invalid/<redacted>
                 Request: request GET https://nonexistent.invalid/<redacted>
                 Message: GET https://nonexistent.invalid/<redacted>
        } [1:11]
        2026-10-07 15:30:56.324984+0200 NetFixture[46055:61652917] [Diagnostics] CFNetwork Diagnostics [1:13] 15:30:56.324 {
        Protocol Enqueue: request GET https://example.com/<redacted>
                 Request: request GET https://example.com/<redacted>
                 Message: GET https://example.com/<redacted>
        } [1:13]
        2026-10-07 15:30:56.325056+0200 NetFixture[46055:61652917] [Diagnostics] CFNetwork Diagnostics [1:14] 15:30:56.325 {
        Protocol Enqueue: request POST https://httpbin.org/<redacted>
                 Request: request POST https://httpbin.org/<redacted>
                 Message: POST https://httpbin.org/<redacted>
        } [1:14]
        2026-10-07 15:30:56.325151+0200 NetFixture[46055:61652917] [Default] Task <766A4C80-D999-4EB7-B482-9373D59C182D>.<2> Alt-Svc entry found
        2026-10-07 15:30:56.326345+0200 NetFixture[46055:61652917] [connection] nw_connection_create_with_id [C1] create connection to example.com:80
        2026-10-07 15:30:56.341558+0200 NetFixture[46055:61652917] [boringssl] boringssl_session_handshake_incomplete(273) [C5:1][0x109d216e0] Handshake incomplete: waiting for data to read [2]
        2026-10-07 15:30:56.341759+0200 NetFixture[46055:61652917] [connection] [C4.1.1.1 18.233.182.23:443 initial path ((null))] event: path:start @0.008s
        2026-10-07 15:30:56.342478+0200 NetFixture[46055:61652917] [Default] Task <B0DA8944-3408-4053-9390-6341F8A7881C>.<3> HTTP load failed, 0/0 bytes (error code: -1003 [12:8])
        2026-10-07 15:30:56.342569+0200 NetFixture[46055:61652917] [Diagnostics] CFNetwork Diagnostics [1:15] 15:30:56.342 {
        Response Error: (null)
               Request: request GET https://nonexistent.invalid/<redacted>
                 Error: Error Domain=kCFErrorDomainCFNetwork Code=-1003 UserInfo={_kCFStreamErrorDomainKey=12, _kCFStreamErrorCodeKey=8, _NSURLErrorNWResolutionReportKey=<private>, _NSURLErrorNWPathKey=<private>}
        } [1:15]
        2026-10-07 15:30:56.342650+0200 NetFixture[46055:61652889] [Diagnostics] CFNetwork Diagnostics [1:16] 15:30:56.342 {
                   Did Fail: (null)
                     Loader: https://nonexistent.invalid/<redacted>
                      Error: Error Domain=kCFErrorDomainCFNetwork Code=-1003 UserInfo={_kCFStreamErrorDomainKey=12, _kCFStreamErrorCodeKey=8, _NSURLErrorNWResolutionReportKey=<private>, _NSURLErrorNWPathKey=<private>}
        init to origin load: 0.00657105s
                 total time: 0.028381s
                total bytes: 0
        } [1:16]
        2026-10-07 15:30:56.344637+0200 NetFixture[46055:61652889] [Summary] Task <B0DA8944-3408-4053-9390-6341F8A7881C>.<3> summary for task failure {transaction_duration_ms=24, response_status=-1, connection=2, reused=1, reused_after_ms=0, request_start_ms=0, request_duration_ms=0, response_start_ms=0, response_duration_ms=0, request_bytes=0, request_throughput_kbps=0, response_bytes=0, response_throughput_kbps=0, cache_hit=false}
        2026-10-07 15:30:56.345029+0200 NetFixture[46055:61652889] [client] No XPC connection in Simulator
        2026-10-07 15:30:56.345154+0200 NetFixture[46055:61652917] [Default] Task <B0DA8944-3408-4053-9390-6341F8A7881C>.<3> finished with error [-1003] Error Domain=NSURLErrorDomain Code=-1003 "A server with the specified hostname could not be found." UserInfo={_kCFStreamErrorCodeKey=8, NSUnderlyingError=0x109c17ab0 {Error Domain=kCFErrorDomainCFNetwork Code=-1003 "(null)" UserInfo={_kCFStreamErrorDomainKey=12, _kCFStreamErrorCodeKey=8, _NSURLErrorNWResolutionReportKey=Resolved 0 endpoints in 2ms using unknown from cache, _NSURLErrorNWPathKey=satisfied (Path is satisfied), interface: en0[802.11], uses wifi, LQM: unknown}}, _NSURLErrorFailingURLSessionTaskErrorKey=LocalDataTask <B0DA8944-3408-4053-9390-6341F8A7881C>.<3>, _NSURLErrorRelatedURLSessionTaskErrorKey=(
            "LocalDataTask <B0DA8944-3408-4053-9390-6341F8A7881C>.<3>"
        ), NSLocalizedDescription=A server with the specified hostname could not be found., NSErrorFailingURLStringKey=https://nonexistent.invalid/missing, NSErrorFailingURLKey=https://nonexistent.invalid/missing, _kCFStreamErrorDomainKey=12}
        netfixture: GET https://nonexistent.invalid/missing -> -1 0 bytes Error Domain=NSURLErrorDomain Code=-1003 "A server with the specified hostname could not be found." UserInfo={_kCFStreamErrorCodeKey=8, NSUnderlyingError=0x109c17ab0 {Error Domain=kCFErrorDomainCFNetwork Code=-1003 "(null)" UserInfo={_kCFStreamErrorDomainKey=12, _kCFStreamErrorCodeKey=8, _NSURLErrorNWResolutionReportKey=Resolved 0 endpoints in 2ms using unknown from cache, _NSURLErrorNWPathKey=satisfied (Path is satisfied), interface: en0[802.11], uses wifi, LQM: unknown}}, _NSURLErrorFailingURLSessionTaskErrorKey=LocalDataTask <B0DA8944-3408-4053-9390-6341F8A7881C>.<3>, _NSURLErrorRelatedURLSessionTaskErrorKey=(
            "LocalDataTask <B0DA8944-3408-4053-9390-6341F8A7881C>.<3>"
        ), NSLocalizedDescription=A server with the specified hostname could not be found., NSErrorFailingURLStringKey=https://nonexistent.invalid/missing, NSErrorFailingURLKey=https://nonexistent.invalid/missing, _kCFStreamErrorDomainKey=12}
        2026-10-07 15:30:56.419836+0200 NetFixture[46055:61652893] [Default] Task <E58FC2B9-A678-4D65-8B49-A81C47AFD59D>.<1> received response, status 404 content C
        2026-10-07 15:30:56.419904+0200 NetFixture[46055:61652893] [Diagnostics] CFNetwork Diagnostics [1:20] 15:30:56.419 {
        Protocol Received: request GET http://example.com/<redacted>
                 Response: HTTP/1.1 404 Not Found
        } [1:20]
        2026-10-07 15:30:56.420241+0200 NetFixture[46055:61652895] [Diagnostics] CFNetwork Diagnostics [1:25] 15:30:56.420 {
                 Did Finish: (null)
                     Loader: http://example.com/<redacted>
        init to origin load: 0.00722897s
                 total time: 0.106637s
                total bytes: 577
        } [1:25]
        2026-10-07 15:30:56.420313+0200 NetFixture[46055:61652895] [Diagnostics] CFNetwork Diagnostics [1:26] 15:30:56.420 {
         touchConnection: (null)
                  Loader: http://example.com/<redacted>
        Timeout Interval: 60.000 seconds
        } [1:26]
        2026-10-07 15:30:56.420401+0200 NetFixture[46055:61652895] [Summary] Task <E58FC2B9-A678-4D65-8B49-A81C47AFD59D>.<1> summary for task success {transaction_duration_ms=106, response_status=404, connection=1, protocol="http/1.1", domain_lookup_duration_ms=7, connect_duration_ms=69, secure_connection_duration_ms=0, private_relay=false, request_start_ms=92, request_duration_ms=0, response_start_ms=105, response_duration_ms=0, request_bytes=221, request_throughput_kbps=16664, response_bytes=702, response_throughput_kbps=16183, cache_hit=true}
        2026-10-07 15:30:56.420476+0200 NetFixture[46055:61652917] [Default] Task <E58FC2B9-A678-4D65-8B49-A81C47AFD59D>.<1> finished successfully
        netfixture: GET http://example.com/plain?secret=1 -> 404 577 bytes
        2026-10-07 15:30:56.429777+0200 NetFixture[46055:61652889] [h3stream] 0x109e1e698 ID=0 Task <766A4C80-D999-4EB7-B482-9373D59C182D>.<2> received response, status 404 content U
        2026-10-07 15:30:56.429868+0200 NetFixture[46055:61652889] [Diagnostics] CFNetwork Diagnostics [1:27] 15:30:56.429 {
        Protocol Received: request GET https://example.com/<redacted>
                 Response: not yet parsed
        } [1:27]
        2026-10-07 15:30:56.429996+0200 NetFixture[46055:61652889] [connection] [0x109c31b80] activating connection: mach=true listener=false peer=false name=com.apple.trustd
        2026-10-07 15:30:56.430100+0200 NetFixture[46055:61652889] [trust] (Trust 0x1055c4d80) trustd returned 4
        2026-10-07 15:30:56.430203+0200 NetFixture[46055:61652889] [connection] [0x109c31b80] invalidated because the current process cancelled the connection by calling xpc_connection_cancel()
        2026-10-07 15:30:56.430938+0200 NetFixture[46055:61652889] [boringssl] nw_protocol_boringssl_signal_connected(907) [C5:1][0x104bcd1e0] TLS connected [server(0) version(0x0304) ciphersuite(TLS_AES_256_GCM_SHA384) group(0x11ec) signature_alg(0x0403) alpn(h3) resumed(0) offered_ticket(0) in_early_data(0) early_data_accepted(0) false_started(0) ocsp_received(1) sct_received(1) connect_time(88ms) flight_time(35ms) rtt(32ms) write_stalls(0) read_stalls(6) pake(0x0000)]
        2026-10-07 15:30:56.431053+0200 NetFixture[46055:61652889] [] nw_protocol_implementation_report_connected [C3.1.1.1:2] Reporting connected with protocol: 0x104bccc80, flow: fffffffffffffffe
        2026-10-07 15:30:56.431341+0200 NetFixture[46055:61652886] [AXLoading] Initial load did occur NetFixture
        2026-10-07 15:30:56.432964+0200 NetFixture[46055:61652893] [Diagnostics] CFNetwork Diagnostics [1:32] 15:30:56.432 {
                 Did Finish: (null)
                     Loader: https://example.com/<redacted>
        init to origin load: 0.00668502s
                 total time: 0.11875s
                total bytes: 577
        } [1:32]
        2026-10-07 15:30:56.433075+0200 NetFixture[46055:61652893] [Summary] Task <766A4C80-D999-4EB7-B482-9373D59C182D>.<2> summary for task success {transaction_duration_ms=113, response_status=404, connection=3, protocol="h3", domain_lookup_duration_ms=4, connect_duration_ms=77, secure_connection_duration_ms=75, private_relay=false, request_start_ms=99, request_duration_ms=0, response_start_ms=109, response_duration_ms=3, request_bytes=102, request_throughput_kbps=3940, response_bytes=478, response_throughput_kbps=1207, cache_hit=true}
        netfixture: GET https://example.com/tls/path?token=abc -> 404 577 bytes
        2026-10-07 15:30:57.114561+0200 NetFixture[46055:61652893] [Diagnostics] CFNetwork Diagnostics [1:38] 15:30:57.114 {
        Protocol Received: request POST https://httpbin.org/<redacted>
                 Response: HTTP/2.0 200
        } [1:38]
        2026-10-07 15:30:57.115220+0200 NetFixture[46055:61652895] [Diagnostics] CFNetwork Diagnostics [1:43] 15:30:57.115 {
                 Did Finish: (null)
                     Loader: request POST https://httpbin.org/<redacted>
        init to origin load: 0.00799501s
                 total time: 0.800898s
                total bytes: 647
        } [1:43]
        2026-10-07 15:30:57.115504+0200 NetFixture[46055:61652895] [Summary] Task <2285E79F-363E-4781-8DC3-A1924B247B8A>.<4> summary for task success {transaction_duration_ms=795, response_status=200, connection=4, protocol="h2", domain_lookup_duration_ms=3, connect_duration_ms=581, secure_connection_duration_ms=331, private_relay=false, request_start_ms=606, request_duration_ms=0, response_start_ms=792, response_duration_ms=2, request_bytes=185, request_throughput_kbps=3691, response_bytes=787, response_throughput_kbps=2738, cache_hit=true}
        netfixture: POST -> 200 647 bytes
        """#

    /// A connection's summary when it closes, over several lines (seen in a later run).
    static let connectionClosed = [
        "2026-10-07 16:02:17.050112+0200 NetFixture[88434:61979221] [connection] [C2 Hostname#f9e0e2f2:443 quic-connection, url: https://example.com/tls/path, definite, attribution: developer] cancelled",
        "\t[C6 61057CEE-1D98-4BAD-9407-C3866F9F45C4 192.168.0.49:62016<->172.66.147.243:443]",
        "\tConnected Path: satisfied (Path is satisfied), interface: en0[802.11], uses wifi, LQM: unknown",
        "\tDuration: 0.070s, QUIC @0.000s took 0.000s, TLS 1.3 took 0.055s",
        "\tbytes in/out: 8317/3802, packets in/out: 7/6, rtt: 0.022s, retransmitted bytes: 0, out-of-order bytes: 1184",
        "'01 01 00 00 01 00 00 00 00 00 00 00 C0 0B 06 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 E7 03'",
        "netfixture: GET https://example.com/tls/path?token=abc -> 404 577 bytes",
    ]

    static var lines: [String] { console.components(separatedBy: "\n") + connectionClosed }

    @Test func listsRequestsWithMethodHostStatusBytesAndTime() throws {
        let log = NetworkLog()
        let reader = CFNetworkLog(app: "dev.mobdev.netfixture", log: log)
        for line in Self.lines { _ = reader.consume(line) }
        let entries = log.read(app: nil, after: nil, limit: 10, contains: nil).entries
        #expect(entries.map(\.number) == [1, 2, 3, 4])
        #expect(log.openEntries.isEmpty)
        guard entries.count == 4 else { return }

        let failed = entries[0]
        #expect(failed.method == "GET")
        #expect(failed.target(query: false) == "https://nonexistent.invalid/…")
        #expect(failed.error == "host not found (-1003)")
        #expect(failed.status == nil)
        #expect(failed.duration == 0.028381)

        let plain = entries[1]
        #expect(plain.app == "dev.mobdev.netfixture")
        #expect(plain.scheme == "http")
        #expect(plain.host == "example.com")
        #expect(plain.port == nil)
        #expect(plain.path == nil)  // iOS hides it.
        #expect(plain.status == 404)
        #expect(plain.bytesSent == 221)  // From the summary: on the wire, headers included.
        #expect(plain.bytesReceived == 702)
        #expect(plain.httpProtocol == "http/1.1")
        #expect(plain.duration == 0.106637)
        #expect(plain.source == .cfnetwork)
        #expect(plain.time == CFNetworkLog.date("2026-10-07 15:30:56.322378+0200"))

        // HTTP/3 answers have no parsed status line; the summary gives it.
        let h3 = entries[2]
        #expect(h3.target(query: false) == "https://example.com/…")
        #expect(h3.status == 404)
        #expect(h3.httpProtocol == "h3")

        let post = entries[3]
        #expect(post.method == "POST")
        #expect(post.host == "httpbin.org")
        #expect(post.status == 200)
        #expect(post.bytesSent == 185)
        #expect(post.bytesReceived == 787)
        #expect(post.summary(query: false).hasSuffix("POST https://httpbin.org/… 200, 185 B out, 787 B in, 801 ms, h2"))
    }

    @Test func keepsTheNetworkStackOutOfTheAppsLog() {
        let reader = CFNetworkLog(app: "dev.mobdev.netfixture", log: NetworkLog())
        let kept = Self.lines.filter { !reader.consume($0) }
        #expect(kept.contains("netfixture: launched"))
        #expect(kept.contains { $0.hasSuffix("[app] netfixture: logger info line") })
        #expect(kept.contains { $0.contains("[InterfaceStyle]") })
        #expect(kept.contains("netfixture: POST -> 200 647 bytes"))
        // The app's own print of an error keeps its other lines; CFNetwork's copy goes entirely.
        #expect(kept.filter { $0.contains("\"LocalDataTask <B0DA8944") }.count == 1)
        #expect(kept.filter { $0.hasPrefix("), NSLocalizedDescription=") }.count == 1)
        #expect(!kept.contains { $0.contains("CFNetwork Diagnostics") || $0.contains("Did Finish") || $0.hasPrefix("} [") })
        #expect(!kept.contains { $0.contains("[Summary]") || $0.contains("[boringssl]") || $0.contains("[h3stream]") })
        #expect(!kept.contains { $0.contains("nw_connection_create") || $0.contains("[C4.1.1.1") })
        #expect(!kept.contains { $0.contains("[trust]") || ($0.contains("Task <") && $0.contains("[Default]")) })
        #expect(!kept.contains { $0.contains("[connection] [0x109c31b80]") || $0.contains("[] nw_protocol") })
        #expect(!kept.contains { $0.contains("TLS connected") })
        #expect(!kept.contains { $0.hasPrefix("\t") || $0.hasPrefix("'01 01") })
        #expect(kept.last == "netfixture: GET https://example.com/tls/path?token=abc -> 404 577 bytes")
        // Lines from other parts of the system stay: a category alone does not decide.
        #expect(kept.contains { $0.contains("[Default] Initializing AlternativeServices") })
        #expect(kept.contains { $0.contains("[client] No XPC connection") })
        #expect(kept.contains { $0.contains("[AXLoading] Initial load") })
    }

    @Test func listsNothingNewAfterItStops() {
        let log = NetworkLog()
        let reader = CFNetworkLog(app: "dev.mobdev.netfixture", log: log)
        let lines = Self.lines
        let half = lines.firstIndex { $0.contains("[1:20]") }!
        for line in lines[..<half] { _ = reader.consume(line) }
        reader.stopRecording()
        // Still kept out of the app's log.
        #expect(lines[half...].filter { reader.consume($0) }.count > 10)
        // The one that failed before, and the three still running listed as they stood.
        let entries = log.read(app: nil, after: nil, limit: 10, contains: nil).entries
        #expect(entries.count == 4)
        #expect(entries.filter { $0.status == nil && $0.error == nil }.count == 3)
    }

    @Test func readsTheParts() {
        #expect(CFNetworkLog.components("https://example.com:8443/<redacted>")! == ("https", "example.com", 8443, nil))
        #expect(CFNetworkLog.components("http://example.com:80/")! == ("http", "example.com", nil, "/"))
        #expect(CFNetworkLog.request("request POST https://a.b/<redacted>") == ("POST", "https://a.b/<redacted>"))
        #expect(CFNetworkLog.request("https://a.b/<redacted>") == (nil, "https://a.b/<redacted>"))
        #expect(CFNetworkLog.status("HTTP/1.1 404 Not Found") == 404)
        #expect(CFNetworkLog.status("HTTP/2.0 200") == 200)
        #expect(CFNetworkLog.status("not yet parsed") == nil)
        #expect(CFNetworkLog.error("Error Domain=kCFErrorDomainCFNetwork Code=-1001 UserInfo={}") == "timed out (-1001)")
        #expect(CFNetworkLog.error("Error Domain=NSPOSIXErrorDomain Code=61 UserInfo={}") == "error 61")
        #expect(CFNetworkLog.header("netfixture: launched") == nil)
        #expect(CFNetworkLog.header("2026-10-07 15:30:54.722193+0200 Net Fixture[46055:61652858] [app] hi")?.process == "Net Fixture")
    }
}

// MARK: - Android

/// adb with one emulator or phone whose `http_proxy` setting it keeps.
final class FakeADBDevice: CommandRunning, @unchecked Sendable {
    let proxySetting = Locked(":0")
    let calls = Locked<[String]>([])
    /// False makes every command fail, like a device that went away.
    let reachable = Locked(true)

    func answer(_ arguments: [String]) -> CommandResult {
        // Drops "-s <serial>".
        let joined = arguments.dropFirst(2).joined(separator: " ")
        calls.withLock { $0.append(joined) }
        guard reachable.get() else { return CommandResult(status: 1, output: "error: device not found") }
        if joined == "shell settings get global http_proxy" { return CommandResult(status: 0, output: proxySetting.get() + "\n") }
        if joined.hasPrefix("shell settings put global http_proxy ") {
            proxySetting.set(String(joined.dropFirst("shell settings put global http_proxy ".count)))
        }
        return CommandResult(status: 0, output: "")
    }

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        answer(arguments)
    }

    func start(
        _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningCommand {
        throw DeveloperError("not used")
    }

    func runBinary(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, data: Data) {
        let result = answer(arguments)
        return (result.status, Data(result.output.utf8))
    }
}

// Serialized: stopAll ends every capture of the process.
@Suite(.serialized) final class AndroidNetworkCaptureTests {
    let device = FakeADBDevice()
    let records = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-network-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: records) }
    var adb: ADB { ADB(executable: URL(fileURLWithPath: "/usr/bin/true"), runner: device) }

    func capture(emulator: Bool = true, serial: String = "emulator-5592") -> AndroidNetworkCapture {
        AndroidNetworkCapture(serial: serial, adb: adb, records: records) { emulator }
    }

    @Test func pointsAnEmulatorAtTheProxyAndRemovesItOnStop() async throws {
        let capture = capture()
        let address = try await capture.start()
        #expect(address.hasPrefix("10.0.2.2:"))
        #expect(device.proxySetting.get() == address)
        #expect(AndroidNetworkCapture.record("emulator-5592", in: records)?.address == address)
        #expect(try await capture.start() == address)  // Already running.

        #expect(try await capture.stop())
        #expect(device.proxySetting.get() == ":0")
        #expect(capture.address == nil)
        #expect(AndroidNetworkCapture.record("emulator-5592", in: records) == nil)
        #expect(try await capture.stop() == false)
    }

    @Test func aPhoneReachesTheProxyThroughAdbReverse() async throws {
        let capture = capture(emulator: false, serial: "R5CT1234")
        let address = try await capture.start()
        let port = address.split(separator: ":").last!
        #expect(address == "127.0.0.1:\(port)")
        #expect(device.calls.get().contains("reverse tcp:\(port) tcp:\(port)"))
        _ = try await capture.stop()
        #expect(device.calls.get().contains("reverse --remove tcp:\(port)"))
        #expect(device.proxySetting.get() == ":0")
    }

    @Test func leavesAnotherToolsProxyAlone() async throws {
        device.proxySetting.set("192.168.0.10:8888")
        let capture = capture()
        await #expect(throws: DeveloperError.self) { try await capture.start() }
        #expect(device.proxySetting.get() == "192.168.0.10:8888")
    }

    @Test func closingRemovesTheSettingRightAway() async throws {
        let capture = capture()
        _ = try await capture.start()
        capture.close()
        #expect(device.proxySetting.get() == ":0")
        #expect(AndroidNetworkCapture.record("emulator-5592", in: records) == nil)
    }

    @Test func aDeviceThatWentAwayIsClearedWhenItIsBack() async throws {
        let capture = capture()
        let address = try await capture.start()
        device.reachable.set(false)
        capture.close()
        // It could not be reached, so the note stays.
        #expect(AndroidNetworkCapture.record("emulator-5592", in: records)?.address == address)
        device.reachable.set(true)
        #expect(device.proxySetting.get() == address)
        await AndroidNetworkCapture.clearLeftover(serial: "emulator-5592", adb: adb, records: records)
        #expect(device.proxySetting.get() == ":0")
        #expect(AndroidNetworkCapture.record("emulator-5592", in: records) == nil)
    }

    @Test func stopAllRemovesEverySetting() async throws {
        _ = try await capture().start()
        AndroidNetworkCapture.stopAll()
        #expect(device.proxySetting.get() == ":0")
        #expect(AndroidNetworkCapture.record("emulator-5592", in: records) == nil)
    }

    @Test func theCaptureOfARunningMobdevStays() async throws {
        let capture = capture()
        let address = try await capture.start()
        await AndroidNetworkCapture.clearLeftover(serial: "emulator-5592", adb: adb, records: records)
        #expect(device.proxySetting.get() == address)
        _ = try await capture.stop()
    }

    @Test func aLeftoverOfAMobdevThatIsGoneIsClearedOrReplaced() async throws {
        let gone = AndroidNetworkCapture.Record(address: "10.0.2.2:5999", pid: 99_999, process: "Mobdev", reversePort: nil)
        #expect(!AndroidNetworkCapture.isRunning(gone))
        func leave() throws {
            try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
            try JSONEncoder().encode(gone).write(to: records.appendingPathComponent("emulator-5592.json"))
            device.proxySetting.set("10.0.2.2:5999")
        }
        try leave()
        await AndroidNetworkCapture.clearLeftover(serial: "emulator-5592", adb: adb, records: records)
        #expect(device.proxySetting.get() == ":0")
        #expect(AndroidNetworkCapture.record("emulator-5592", in: records) == nil)

        // Starting replaces it instead of refusing.
        try leave()
        let capture = capture()
        let address = try await capture.start()
        #expect(device.proxySetting.get() == address)
        _ = try await capture.stop()
    }
}

// MARK: - Tools

/// Remembers launches and nothing else.
final class LaunchRecordingApps: AppBackend, @unchecked Sendable {
    let logs = AppLogs()
    let platform: AppPlatform = .simulator
    let launches = Locked<[(app: String, environment: [String: String], restart: Bool)]>([])

    func activate(_ bundleID: String) async throws {}
    func apps(all: Bool) async throws -> [InstalledApp] { [] }
    func app(_ bundleID: String) async throws -> InstalledApp? { nil }
    func install(at path: URL) async throws -> InstalledApp { throw DeveloperError("no") }
    func uninstall(_ bundleID: String) async throws -> InstalledApp { throw DeveloperError("no") }
    func launch(_ bundleID: String, arguments: [String], environment: [String: String], restart: Bool) async throws
        -> LaunchOutcome
    {
        launches.withLock { $0.append((bundleID, environment, restart)) }
        return .launched
    }
    func stop(_ bundleID: String) async throws -> Bool { false }
    func open(_ url: URL) async throws {}
    func crashReports() async throws -> [CrashReportFile] { [] }
    func crashReport(named name: String) async throws -> (report: CrashReport?, file: URL) { throw DeveloperError("no") }
}

@Suite(.serialized) struct NetworkToolTests {
    func call(_ tools: PhoneTools, _ name: String, _ arguments: JSONValue = [:]) async throws -> ToolOutput {
        try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
    }

    @Test func iOSRelaunchesTheAppAndReadsItsRequestsFromItsConsole() async throws {
        let apps = LaunchRecordingApps()
        let tools = PhoneTools(phone: FakePhone(lines: [], apps: apps), activity: ActivityLog(), settleDelay: 0)
        let missing = try await call(tools, "start_network_capture")
        #expect(missing.isError)

        let started = try await call(tools, "start_network_capture", ["bundle_id": "dev.mobdev.netfixture"])
        #expect(!started.isError)
        let launch = try #require(apps.launches.get().last)
        #expect(launch.app == "dev.mobdev.netfixture")
        #expect(launch.environment == ["CFNETWORK_DIAGNOSTICS": "1", "ACTIVITY_LOG_STDERR": "1"])
        #expect(launch.restart)

        // The console's lines arrive as the app's output.
        for line in CFNetworkLogTests.lines { apps.logs.append(app: "dev.mobdev.netfixture", text: line) }
        let log = try await call(tools, "network_log")
        #expect(log.text.hasPrefix("4 requests. Capturing dev.mobdev.netfixture through CFNetwork's log.\n"))
        #expect(log.text.contains("GET http://example.com/… 404, 221 B out, 702 B in, 107 ms, http/1.1"))
        #expect(log.text.contains("GET https://nonexistent.invalid/… host not found (-1003), 28 ms"))
        #expect(log.text.hasSuffix("Cursor: 4. Pass it as after to get only newer requests."))
        #expect(log.data?["entries"]?.arrayValue?.count == 4)
        #expect(log.data?["entries"]?.arrayValue?.first?["source"] == "cfnetwork")

        let newer = try await call(tools, "network_log", ["after": 3])
        #expect(newer.data?["entries"]?.arrayValue?.count == 1)
        #expect(newer.text.hasPrefix("1 request since 3."))
        #expect(try await call(tools, "network_log", ["after": 4]).text.hasPrefix("No new requests."))
        let posts = try await call(tools, "network_log", ["contains": "POST"])
        #expect(posts.data?["entries"]?.arrayValue?.count == 1)

        // logs keeps what the app printed and loses the network stack's lines.
        let output = apps.logs.read(app: nil, after: nil, limit: 200, contains: nil).lines.map(\.text)
        #expect(output.contains("netfixture: launched"))
        #expect(!output.contains { $0.contains("CFNetwork Diagnostics") })

        let stopped = try await call(tools, "stop_network_capture")
        #expect(stopped.text.hasPrefix("Stopped recording requests of dev.mobdev.netfixture."))
        #expect(try await call(tools, "network_log").text.hasPrefix("4 requests. Not capturing now."))

        // A plain relaunch has no diagnostics: its lines reach logs again.
        _ = try await call(tools, "launch_app", ["bundle_id": "dev.mobdev.netfixture"])
        let diagnostics = try #require(CFNetworkLogTests.lines.first { $0.contains("[Diagnostics]") })
        apps.logs.append(app: "dev.mobdev.netfixture", text: diagnostics)
        #expect(apps.logs.read(app: nil, after: nil, limit: 1, contains: nil).lines.first?.text == diagnostics)
    }

    @Test func mocksAreForAndroid() async throws {
        let tools = PhoneTools(phone: FakePhone(lines: [], apps: LaunchRecordingApps()), activity: ActivityLog(), settleDelay: 0)
        let mocked = try await call(tools, "mock_response", ["url": "/api", "status": 500])
        #expect(mocked.isError)
        #expect(mocked.text.contains("Android only"))
    }
}

// In the serialized Android suite, where no stopAll runs alongside.
extension AndroidNetworkCaptureTests {
    func call(_ tools: PhoneTools, _ name: String, _ arguments: JSONValue = [:]) async throws -> ToolOutput {
        try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
    }

    @Test func toolsCaptureThroughTheProxy() async throws {
        let capture = capture()
        let apps = LaunchRecordingApps()
        let tools = PhoneTools(
            phone: FakePhone(lines: [], apps: apps, networkProxy: capture), activity: ActivityLog(), settleDelay: 0)

        let mocked = try await call(tools, "mock_response", ["url": "/api/feed", "body": "{\"items\":[]}"])
        #expect(mocked.text.contains("now get 200 with 12 bytes of application/json"))

        let started = try await call(tools, "start_network_capture", ["bundle_id": "com.example.app"])
        let address = try #require(capture.address)
        #expect(started.text.contains("through Mobdev's proxy at \(address)"))
        #expect(device.proxySetting.get() == address)
        #expect(apps.launches.get().map(\.app) == ["com.example.app"])

        // The emulator's request, as it arrives through 10.0.2.2.
        let client = TestClient(port: UInt16(address.split(separator: ":").last!)!)
        client.send("GET http://10.0.2.2:3000/api/feed?page=1 HTTP/1.1\r\nHost: 10.0.2.2:3000\r\nCookie: id=1\r\n\r\n")
        #expect(await client.waitForEnd().hasSuffix("{\"items\":[]}"))
        _ = await entries(in: capture.log, count: 1)

        let log = try await call(tools, "network_log", ["bundle_id": "com.example.app", "headers": true])
        #expect(log.text.contains("cannot tell which app made a request"))
        #expect(log.text.contains("GET http://10.0.2.2:3000/api/feed?… 200, mocked"))
        let entry = try #require(log.data?["entries"]?.arrayValue?.first)
        #expect(entry["source"] == "proxy")
        #expect(entry["query"] == nil)
        #expect(entry["request_headers"]?.arrayValue?.contains(["name": "Cookie", "value": "<redacted>"]) == true)
        let withQuery = try await call(tools, "network_log", ["query": true])
        #expect(withQuery.data?["entries"]?.arrayValue?.first?["query"] == "page=1")

        let stopped = try await call(tools, "stop_network_capture")
        #expect(stopped.text.contains("removed Mobdev's proxy"))
        #expect(device.proxySetting.get() == ":0")
        #expect(try await call(tools, "mock_response", ["clear": true]).text == "Removed 1 mocks.")
    }
}
