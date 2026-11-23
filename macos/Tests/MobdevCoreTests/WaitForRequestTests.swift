import Foundation
import Testing
@testable import MobdevCore

/// Android's proxy without a network: tests add the requests to its log themselves.
final class FakeProxy: NetworkProxyBackend, @unchecked Sendable {
    let log = NetworkLog()
    private let current = Locked<String?>(nil)

    var address: String? { current.get() }

    func start() async throws -> String {
        current.set("10.0.2.2:5555")
        return "10.0.2.2:5555"
    }

    func stop() async throws -> Bool {
        current.withLock { address in
            defer { address = nil }
            return address != nil
        }
    }

    var mocks: [ResponseMock] { [] }
    func addMock(_ mock: ResponseMock) {}
    func clearMocks() -> Int { 0 }
}

@Suite struct WaitForRequestTests {
    func call(_ tools: PhoneTools, _ name: String, _ arguments: JSONValue = [:]) async throws -> ToolOutput {
        try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
    }

    /// A finished plain HTTP request as the proxy lists it.
    static func request(_ method: String, _ url: String, status: Int?) -> NetworkEntry {
        let parts = URLComponents(string: url)!
        var entry = NetworkEntry(
            time: Date(), method: method, scheme: parts.scheme, host: parts.host!, port: parts.port,
            path: parts.path.isEmpty ? "/" : parts.path, query: parts.query, source: .proxy)
        entry.status = status
        entry.duration = 0.05
        return entry
    }

    /// An HTTPS connection through the proxy, as it opens.
    static func tunnel(_ host: String) -> NetworkEntry {
        var entry = NetworkEntry(time: Date(), method: "CONNECT", scheme: nil, host: host, port: 443, source: .proxy)
        entry.status = 200
        return entry
    }

    /// An Android device capturing through a proxy that sees what the test adds.
    func android() async throws -> (tools: PhoneTools, proxy: FakeProxy, phone: FakePhone) {
        let proxy = FakeProxy()
        let phone = FakePhone(lines: [], networkProxy: proxy)
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0)
        let started = try await call(tools, "start_network_capture")
        #expect(!started.isError, "\(started.text)")
        return (tools, proxy, phone)
    }

    /// An iOS simulator capturing an app that reported the net fixture's four requests.
    func iOS() async throws -> (tools: PhoneTools, apps: LaunchRecordingApps) {
        let apps = LaunchRecordingApps()
        let tools = PhoneTools(phone: FakePhone(lines: [], apps: apps), activity: ActivityLog(), settleDelay: 0)
        let started = try await call(tools, "start_network_capture", ["bundle_id": "dev.mobdev.netfixture"])
        #expect(!started.isError, "\(started.text)")
        return (tools, apps)
    }

    @Test func findsTheRequestTheLastActionCausedThoughItFinishedFirst() async throws {
        let (tools, proxy, phone) = try await android()
        // Before the tap, so it does not count.
        proxy.log.add(Self.request("POST", "http://10.0.2.2:3000/api/login", status: 200))
        phone.onTap.set { _ in
            proxy.log.add(Self.request("POST", "http://10.0.2.2:3000/api/login?next=home", status: 200))
        }
        _ = try await call(tools, "tap", ["x": 100, "y": 200])
        let found = try await call(
            tools, "wait_for_request", ["url": "/api/login", "method": "post", "status": 200, "timeout": 0])
        #expect(!found.isError, "\(found.text)")
        #expect(found.text.hasPrefix("Found "))
        #expect(found.text.contains(" POST http://10.0.2.2:3000/api/login?… 200, 50 ms.\n"))
        #expect(found.text.hasSuffix("Cursor: 2. Pass it as after to wait for a later request."))
        #expect(found.data?["cursor"] == 2)
        #expect(found.data?["open"] == false)
        #expect(found.data?["request"]?["status"] == 200)
        #expect(found.data?["request"]?["query"] == nil)

        // Reading only looks, so it does not move the start: the same request is found again.
        _ = try await call(tools, "network_log")
        let again = try await call(tools, "wait_for_request", ["url": "/api/login", "timeout": 0])
        #expect(again.data?["cursor"] == 2)
    }

    @Test func iOSFindsWhatTheAppReported() async throws {
        let (tools, apps) = try await iOS()
        for line in CFNetworkLogTests.lines { apps.logs.append(app: "dev.mobdev.netfixture", text: line) }
        let post = try await call(
            tools, "wait_for_request", ["url": "https://httpbin.org", "method": "POST", "status": 200, "timeout": 0])
        #expect(!post.isError, "\(post.text)")
        #expect(post.text.contains("POST https://httpbin.org/… 200, 185 B out, 787 B in, 801 ms, h2."))
        #expect(post.data?["cursor"] == 4)
        // A request that failed happened too.
        let failed = try await call(tools, "wait_for_request", ["url": "nonexistent.invalid", "timeout": 0])
        #expect(failed.text.contains("GET https://nonexistent.invalid/… host not found (-1003)"))
        let other = try await call(tools, "wait_for_request", ["url": "example.com", "status": 500, "timeout": 0])
        #expect(other.isError)
        #expect(
            other.text.hasPrefix(
                "Timed out after 0 s: no request matched url \"example.com\", status 500. Capturing dev.mobdev.netfixture through CFNetwork's log.\nWith \"example.com\" in the URL but another method or status:\n"
            ))
        #expect(other.text.contains("GET http://example.com/… 404"))
        #expect(other.text.hasSuffix("2 other requests finished since cursor 0; network_log with after 0 lists them."))
    }

    @Test func waitsForARequestThatArrivesLater() async throws {
        let (tools, proxy, _) = try await android()
        let late = Task {
            try await Task.sleep(nanoseconds: 300_000_000)
            proxy.log.add(Self.request("GET", "http://10.0.2.2:3000/api/feed", status: 200))
        }
        let found = try await call(tools, "wait_for_request", ["url": "/api/feed", "timeout": 20])
        try await late.value
        #expect(!found.isError, "\(found.text)")
        #expect(found.text.contains(" GET http://10.0.2.2:3000/api/feed 200, 50 ms."))

        // HTTPS shows as a connection to the host, counted once it opens: a kept-alive one is
        // listed only when it closes, minutes later.
        let opening = Task {
            try await Task.sleep(nanoseconds: 300_000_000)
            return proxy.log.open(Self.tunnel("api.example.com"))
        }
        let tunnel = try await call(tools, "wait_for_request", ["url": "https://api.example.com", "timeout": 20])
        let id = try await opening.value
        #expect(!tunnel.isError, "\(tunnel.text)")
        #expect(tunnel.text.contains(" CONNECT api.example.com:443 tunnel, open for "))
        #expect(tunnel.text.contains("Android's proxy sees HTTPS only as this connection to the host."))
        #expect(tunnel.data?["open"] == true)
        #expect(tunnel.data?["cursor"] == 1)
        proxy.log.finish(id)
    }

    /// The cursor a wait returns with an open connection asks for a later one: neither the same
    /// connection while it is open nor the entry it becomes when it closes may satisfy it.
    @Test func aCursorFromAnOpenConnectionDoesNotFindItAgain() async throws {
        let (tools, proxy, _) = try await android()
        let first = proxy.log.open(Self.tunnel("api.example.com"))
        let found = try await call(tools, "wait_for_request", ["url": "https://api.example.com", "after": 0, "timeout": 0])
        #expect(found.data?["open"] == true)
        #expect(found.data?["cursor"] == 0)

        let again = try await call(tools, "wait_for_request", ["url": "https://api.example.com", "after": 0, "timeout": 0])
        #expect(again.isError, "\(again.text)")
        #expect(again.text.hasPrefix("Timed out after 0 s"))
        proxy.log.finish(first)
        let closed = try await call(tools, "wait_for_request", ["url": "https://api.example.com", "after": 0, "timeout": 0])
        #expect(closed.isError, "\(closed.text)")

        // A second connection is what the cursor waits for.
        try await Task.sleep(nanoseconds: 5_000_000)
        let second = proxy.log.open(Self.tunnel("api.example.com"))
        let next = try await call(tools, "wait_for_request", ["url": "https://api.example.com", "after": 0, "timeout": 0])
        #expect(next.data?["open"] == true)
        proxy.log.finish(second)
    }

    /// Without a cursor a wait counts from the last action, so it may return an open connection a
    /// second time, with a newer cursor. The first cursor still means "later than this connection".
    @Test func theFirstCursorOfAnOpenConnectionStaysGood() async throws {
        let (tools, proxy, _) = try await android()
        let id = proxy.log.open(Self.tunnel("api.example.com"))
        let first = try await call(tools, "wait_for_request", ["url": "https://api.example.com", "timeout": 0])
        #expect(first.data?["cursor"] == 0)
        proxy.log.add(Self.request("GET", "http://10.0.2.2:3000/other", status: 200))
        let second = try await call(tools, "wait_for_request", ["url": "https://api.example.com", "timeout": 0])
        #expect(second.data?["open"] == true)
        #expect(second.data?["cursor"] == 1)

        let later = try await call(tools, "wait_for_request", ["url": "https://api.example.com", "after": 0, "timeout": 0])
        #expect(later.isError, "\(later.text)")
        proxy.log.finish(id)
    }

    @Test func timesOutAndSaysWhatCameInstead() async throws {
        let (tools, proxy, _) = try await android()
        proxy.log.add(Self.request("POST", "http://10.0.2.2:3000/api/login", status: 500))
        proxy.log.add(Self.request("GET", "http://10.0.2.2:3000/api/feed", status: 200))
        // A connection that was open before, whose requests do not show again.
        let id = proxy.log.open(Self.tunnel("10.0.2.2"))
        let started = Date()
        let failed = try await call(
            tools, "wait_for_request",
            ["url": "10.0.2.2", "method": "POST", "status": 200, "timeout": 0.5])
        #expect(failed.isError)
        #expect(Date().timeIntervalSince(started) >= 0.5)
        let lines = failed.text.components(separatedBy: "\n")
        #expect(
            lines.first
                == "Timed out after 0.5 s: no request matched url \"10.0.2.2\", method POST, status 200. Capturing through Mobdev's proxy at 10.0.2.2:5555."
        )
        #expect(lines.dropFirst().first == "With \"10.0.2.2\" in the URL but another method or status:")
        #expect(failed.text.contains(" POST http://10.0.2.2:3000/api/login 500, 50 ms\n"))
        #expect(failed.text.contains("Still running:\n"))
        #expect(failed.text.contains(" CONNECT 10.0.2.2:443 tunnel, open for "))
        #expect(
            failed.text.contains(
                "Android's proxy sees HTTPS only as a connection to the host, so a path, method or status matches plain HTTP requests only."
            ))
        #expect(failed.text.contains("A request sent over an HTTPS connection that was already open does not show again."))
        #expect(lines.last == "No other request finished since cursor 0.")
        proxy.log.finish(id)
    }

    @Test func failsAtOnceWithoutACapture() async throws {
        let tools = PhoneTools(
            phone: FakePhone(lines: [], apps: LaunchRecordingApps()), activity: ActivityLog(), settleDelay: 0)
        let started = Date()
        let iOS = try await call(tools, "wait_for_request", ["url": "example.com", "timeout": 30])
        #expect(iOS.isError)
        #expect(
            iOS.text
                == "Network capture is not running, so no request can arrive: no request matched url \"example.com\". Start it with start_network_capture, then do what should send the request."
        )

        let (android, proxy, _) = try await android()
        proxy.log.add(Self.request("GET", "http://10.0.2.2:3000/api/feed", status: 200))
        _ = try await call(android, "stop_network_capture")
        let missing = try await call(android, "wait_for_request", ["url": "/api/login", "timeout": 60])
        #expect(missing.text.hasPrefix("Network capture is not running"))
        // At once, not after the timeout; a busy runner may take seconds for the test itself.
        #expect(Date().timeIntervalSince(started) < 45)
        // What was recorded before it stopped is still there to find.
        let recorded = try await call(android, "wait_for_request", ["url": "/api/feed", "after": 0, "timeout": 30])
        #expect(!recorded.isError, "\(recorded.text)")
    }

    @Test func refusesAFilterTheDeviceCannotSee() async throws {
        let started = Date()
        let (iOS, _) = try await iOS()
        let path = try await call(iOS, "wait_for_request", ["url": "https://api.example.com/v1/login", "timeout": 30])
        #expect(path.isError)
        #expect(
            path.text
                == "iOS reports requests without their paths and queries (https://api.example.com/…), so url \"https://api.example.com/v1/login\" can never match. Wait for the host instead, e.g. url \"api.example.com\", with method and status if needed."
        )
        let query = try await call(iOS, "wait_for_request", ["url": "?page=2", "timeout": 30])
        #expect(query.text.hasPrefix("iOS reports requests without their paths and queries (https://api.example.com/…)"))

        let (android, _, _) = try await android()
        let https = try await call(
            android, "wait_for_request", ["url": "https://api.example.com/v1/login", "method": "POST", "timeout": 30])
        #expect(https.isError)
        #expect(
            https.text
                == "Android's proxy sees an HTTPS request only as a connection to its host (CONNECT api.example.com:443), without path, method or status, so url \"https://api.example.com/v1/login\", method POST can never match. Wait for url \"api.example.com\" alone; plain HTTP, such as a local dev server, shows in full."
        )
        let status = try await call(android, "wait_for_request", ["url": "https://api.example.com", "status": 200, "timeout": 60])
        #expect(status.text.hasPrefix("Android's proxy sees an HTTPS request only as a connection"))
        #expect(Date().timeIntervalSince(started) < 45)

        // What the device can see waits as usual.
        let host = try await call(iOS, "wait_for_request", ["url": "https://api.example.com/", "timeout": 0])
        #expect(host.text.hasPrefix("Timed out after 0 s"))
        let plain = try await call(android, "wait_for_request", ["url": "http://10.0.2.2/api", "status": 200, "timeout": 0])
        #expect(plain.text.hasPrefix("Timed out after 0 s"))
        #expect(!plain.text.contains("sees HTTPS only"))
    }

    @Test func iOSPathsCountOnceTheDeviceShowsThem() async throws {
        let (tools, _) = try await iOS()
        var entry = NetworkEntry(
            time: Date(), app: "dev.mobdev.netfixture", method: "GET", scheme: "https", host: "api.example.com",
            path: "/v1/feed", source: .cfnetwork)
        entry.status = 200
        tools.appNetwork.log.add(entry)
        let found = try await call(tools, "wait_for_request", ["url": "/v1/feed", "after": 0, "timeout": 0])
        #expect(!found.isError, "\(found.text)")
    }

    @Test func countsFromTheCursorItIsGiven() async throws {
        let (tools, proxy, _) = try await android()
        for path in ["/a", "/b", "/a"] {
            proxy.log.add(Self.request("GET", "http://10.0.2.2:3000\(path)", status: 200))
        }
        let log = try await call(tools, "network_log")
        #expect(log.data?["cursor"] == 3)

        let first = try await call(tools, "wait_for_request", ["url": ":3000/a", "after": 0, "timeout": 0])
        #expect(first.data?["cursor"] == 1)
        let second = try await call(tools, "wait_for_request", ["url": ":3000/a", "after": 1, "timeout": 0])
        #expect(second.data?["cursor"] == 3)
        let none = try await call(tools, "wait_for_request", ["url": ":3000/a", "after": 3, "timeout": 0])
        #expect(none.text.hasPrefix("Timed out after 0 s: no request matched url \":3000/a\"."))
        #expect(none.text.hasSuffix("No other request finished since cursor 3."))
        // A cursor from before Mobdev restarted is newer than the log: it starts over.
        let restarted = try await call(tools, "wait_for_request", ["url": ":3000/b", "after": 99, "timeout": 0])
        #expect(restarted.data?["cursor"] == 2)

        // A tunnel counts after a cursor once it opened after that request finished.
        let old = proxy.log.open(Self.tunnel("old.example.com"))
        try await Task.sleep(nanoseconds: 300_000_000)
        // Started 0.2 s ago and took 0.05 s: it finished after the old tunnel opened.
        var request = Self.request("GET", "http://10.0.2.2:3000/c", status: 200)
        request.time = Date().addingTimeInterval(-0.2)
        proxy.log.add(request)
        let new = proxy.log.open(Self.tunnel("new.example.com"))
        #expect(try await call(tools, "wait_for_request", ["url": "example.com", "after": 4, "timeout": 0]).data?["request"]?["host"] == "new.example.com")
        #expect(try await call(tools, "wait_for_request", ["url": "example.com", "after": 0, "timeout": 0]).data?["request"]?["host"] == "old.example.com")
        proxy.log.finish(old)
        proxy.log.finish(new)
    }

    @Test func worksAsAFlowStepAfterTheTapThatSendsTheRequest() async throws {
        let (tools, proxy, phone) = try await android()
        phone.onTap.set { _ in proxy.log.add(Self.request("POST", "http://10.0.2.2:3000/api/login", status: 200)) }
        let passing = try await call(
            tools, "run_flow",
            [
                "steps": [
                    ["tap": ["x": 100, "y": 200]],
                    ["wait_for_request": ["url": "/api/login", "method": "POST", "status": 200]],
                ]
            ])
        #expect(!passing.isError, "\(passing.text)")
        #expect(passing.text.hasPrefix("Flow \"Flow\" passed: 2 steps"))

        let failing = try await call(
            tools, "run_flow",
            ["steps": [["tap": ["x": 100, "y": 200]], ["wait_for_request": ["url": "/api/logout", "timeout": 0.2]]]])
        #expect(failing.isError)
        #expect(failing.text.hasPrefix("Flow \"Flow\" failed at step 2 of 2: wait_for_request {\"timeout\":0.2,\"url\":\"/api/logout\"}."))
        #expect(failing.text.contains("Timed out after 0.2 s: no request matched url \"/api/logout\"."))

        // Maestro has no command that checks requests, so exporting names the step.
        let flow = Flow(name: "x", steps: [Flow.Step("wait_for_request", ["url": "/api/login"])])
        #expect {
            try Maestro.export(flow)
        } throws: { error in
            String(describing: error).contains(
                "\n  1. wait_for_request {\"url\":\"/api/login\"}: no Maestro command does what wait_for_request does.")
        }
    }

    @Test func filterSplitsTheURLAndMatchesTunnelsByHost() {
        let parts = RequestFilter(url: "HTTPS://api.example.com/v1?page=2").parts
        #expect(parts.scheme == "https")
        #expect(parts.host == "api.example.com")
        #expect(parts.rest == "/v1?page=2")
        #expect(RequestFilter(url: "/api/login").parts.host == "")
        #expect(!RequestFilter(url: "api.example.com/").hasPath)
        #expect(RequestFilter(url: "api.example.com/v1").hasPath)
        #expect(!RequestFilter(url: "login").hasPath)

        let tunnel = Self.tunnel("api.example.com")
        #expect(RequestFilter(url: "https://api.example.com").matches(tunnel))
        #expect(RequestFilter(url: "https://API.example.com/").matches(tunnel))
        #expect(RequestFilter(url: "api.example.com:443").matches(tunnel))
        #expect(RequestFilter(url: "example.com", method: "CONNECT").matches(tunnel))
        #expect(!RequestFilter(url: "https://api.example.com/v1").matches(tunnel))
        #expect(!RequestFilter(url: "http://api.example.com").matches(tunnel))
        #expect(!RequestFilter(url: "api.example.com", method: "GET").matches(tunnel))
        #expect(!RequestFilter(url: "api.example.com", status: 200).matches(tunnel))
    }
}
