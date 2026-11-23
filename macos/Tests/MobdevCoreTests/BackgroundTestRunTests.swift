import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// `run_tests` runs in the background holding the device: a call that cannot wait for the end, such
/// as one through a relay, returns while it runs, `test_result` reads it, a caller that gives up
/// leaves it running, and `stop` ends it.
@Suite struct BackgroundTestRunTests {
    /// A project whose first test waits until "Go" is on the screen, so it runs until a test says
    /// so, and whose second presses home.
    func project() throws -> TestProject {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-background-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tests"), withIntermediateDirectories: true)
        try Data(#"{"name": "Background"}"#.utf8).write(to: root.appendingPathComponent("mobdev.json"))
        try Data(#"{"name": "Waits", "steps": [{"wait_for_element": {"text": "Go", "timeout": 60}}]}"#.utf8)
            .write(to: root.appendingPathComponent("tests/a-waits.json"))
        try Data(#"{"name": "Home", "steps": ["home"]}"#.utf8).write(to: root.appendingPathComponent("tests/b-home.json"))
        return try TestProject.load(root)
    }

    /// A phone whose screen shows "Go" once `go` is called.
    final class Gate: Sendable {
        let phone = FakePhone(lines: [], tree: [])
        func go() {
            phone.currentTree.set([
                UIElement(
                    role: "StaticText", label: "Go", identifier: "", value: "", frame: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.05),
                    enabled: true, tappable: false)
            ])
        }
    }

    func call(_ tools: PhoneTools, _ name: String, _ arguments: JSONValue, source: String = "local") async throws -> ToolOutput {
        try await tools.call(name, arguments: arguments, source: source, screenshotByDefault: false)
    }

    func result(_ project: TestProject, _ arguments: [String: JSONValue] = [:]) throws -> ToolOutput {
        var arguments = arguments
        arguments["project"] = .string(project.folder.path)
        return try ProjectTools.call("test_result", Arguments(.object(arguments)), projects: ProjectList())
    }

    /// Until the project has no run going on, at most `seconds`.
    func waitForEnd(_ project: TestProject, seconds: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !TestRuns.running(for: project.folder).isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test func aCallThatCannotWaitReturnsWhileTheRunGoesOn() async throws {
        let project = try project()
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let gate = Gate()
        let tools = PhoneTools(phone: gate.phone, activity: ActivityLog(), settleDelay: 0)
        let arguments: JSONValue = ["project": .string(project.folder.path), "video": false, "wait": 0.3]

        let started = try await call(tools, "run_tests", arguments, source: "relay")
        #expect(!started.isError, "\(started.text)")
        #expect(started.text.hasPrefix("Started the tests of Background on Device. They go on in the background and hold the device"))
        #expect(started.text.contains("Tests \"Background\" on Device, started by relay: 0 of 2 done after "))
        #expect(started.text.contains("now Waits."))
        #expect(started.data?["running"] == true)
        #expect(started.data?["total"]?.doubleValue == 2)
        #expect(started.data?["next"] == "Waits")
        #expect(TestRuns.running(for: project.folder).count == 1)

        // The device stays held: actions from others are busy and say how to learn more.
        let tap = try await call(tools, "home", [:])
        #expect(tap.isError)
        #expect(
            tap.text.hasPrefix(
                "Busy: a test run from relay is running on this device. Wait for it to finish; test_result says how far it is, and run_tests with stop true stops it."
            ), "\(tap.text)")
        #expect(gate.phone.events.get().isEmpty)

        // test_result reads the run going on, and a second start reports it instead of starting again.
        let progress = try result(project)
        #expect(!progress.isError)
        #expect(progress.text.hasPrefix("Tests \"Background\" on Device, started by relay: 0 of 2 done"))
        #expect(progress.text.hasSuffix("Still running; call test_result again for the results."))
        #expect(progress.data?["running"] == true)
        let again = try await call(tools, "run_tests", ["project": .string(project.folder.path), "video": false])
        #expect(!again.isError)
        #expect(again.text.hasPrefix("Background already has tests running on Device; call test_result for the results once they end."))
        #expect(TestRuns.runs(for: project).count == 1)
        let listed = try ProjectTools.call("list_tests", Arguments(["project": .string(project.folder.path)]), projects: ProjectList())
        #expect(listed.text.contains("Running: Tests \"Background\" on Device, started by relay: 0 of 2 done"))

        gate.go()
        try await waitForEnd(project)
        #expect(TestRuns.running(for: project.folder).isEmpty)
        #expect(tools.hold.get() == nil)
        let done = try result(project)
        #expect(!done.isError)
        #expect(done.text.hasPrefix("Tests \"Background\" on Device: 2 passed in "), "\(done.text)")
        #expect(done.data?["running"] == nil)
        // The suite ran once, and its end shows in the activity although the call had returned.
        #expect(gate.phone.events.get().filter { $0 == .button(.home) }.count == 1)
        #expect(tools.activity.all.contains { $0.tool == "run_tests" && $0.summary.hasPrefix("Tests \"Background\" on Device: 2 passed") })
        #expect(try await !call(tools, "home", [:]).isError)
    }

    @Test func aCallerThatWaitsGetsTheWholeRunInOneCall() async throws {
        let project = try project()
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let gate = Gate()
        let tools = PhoneTools(phone: gate.phone, activity: ActivityLog(), settleDelay: 0)
        Task {
            try await Task.sleep(nanoseconds: 700_000_000)
            gate.go()
        }
        let output = try await call(tools, "run_tests", ["project": .string(project.folder.path), "video": false])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.hasPrefix("Tests \"Background\" on Device: 2 passed in "))
        #expect(output.data?["tests"]?.arrayValue?.count == 2)
        #expect(output.data?["running"] == nil)
        #expect(tools.hold.get() == nil)
        #expect(TestRuns.running(for: project.folder).isEmpty)
    }

    @Test func aCancelledCallLeavesTheRunGoing() async throws {
        let project = try project()
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let gate = Gate()
        let tools = PhoneTools(phone: gate.phone, activity: ActivityLog(), settleDelay: 0)
        // What the relay client does with the relay's "cancel" frame, after 90 seconds or when the
        // agent hangs up: it cancels the call's task.
        let caller = Task {
            try await call(tools, "run_tests", ["project": .string(project.folder.path), "video": false], source: "relay")
        }
        for _ in 0..<200 where TestRuns.running(for: project.folder).isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        caller.cancel()
        let answer = try await caller.value
        #expect(answer.text.hasPrefix("Started the tests of Background on Device."), "\(answer.text)")

        try await Task.sleep(nanoseconds: 300_000_000)
        let run = try #require(TestRuns.running(for: project.folder).first)
        #expect(!run.isFinished)
        #expect(tools.hold.get()?.id == run.hold)
        gate.go()
        try await waitForEnd(project)
        let final = try #require(TestRuns.result(for: project))
        #expect(!final.cancelled)
        #expect(final.tests.map(\.status) == [.passed, .passed])
        #expect(tools.hold.get() == nil)
    }

    @Test func stopEndsTheRunAfterTheCurrentStepAndFreesTheDevice() async throws {
        let project = try project()
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let gate = Gate()
        let tools = PhoneTools(phone: gate.phone, activity: ActivityLog(), settleDelay: 0)
        let started = try await call(tools, "run_tests", ["project": .string(project.folder.path), "video": false, "wait": 0])
        #expect(started.text.hasPrefix("Started the tests of Background"))

        // Any caller stops it, with or without project; it no longer waits for "Go". Usually it is
        // in the first test's wait by now; on a loaded machine it may not have begun it yet.
        try await Task.sleep(nanoseconds: 300_000_000)
        let stopped = try await call(tools, "run_tests", ["stop": true], source: "relay")
        #expect(!stopped.isError, "\(stopped.text)")
        #expect(stopped.text.hasPrefix("Stopped the tests of Background on Device, started by local.\nTests \"Background\" on Device: 0 passed, "))
        #expect(stopped.text.contains(" Cancelled."))
        #expect(stopped.data?["cancelled"] == true)
        let tests = stopped.data?["tests"]?.arrayValue ?? []
        #expect(tests.count <= 1)
        #expect(tests.allSatisfy { $0["status"] == "failed" })
        #expect(tools.hold.get() == nil)
        #expect(TestRuns.running(for: project.folder).isEmpty)
        #expect(gate.phone.events.get().isEmpty)
        #expect(TestRuns.result(for: project)?.cancelled == true)

        let nothing = try await call(tools, "run_tests", ["stop": true])
        #expect(!nothing.isError)
        #expect(nothing.text == "No tests are running on Device.")
        #expect(try await !call(tools, "home", [:]).isError)
    }

    @Test func theHoldIsReleasedHoweverTheRunEnds() async throws {
        let project = try project()
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let gate = Gate()
        let tools = PhoneTools(phone: gate.phone, activity: ActivityLog(), settleDelay: 0)

        // A test that does not exist ends the run before it starts.
        let missing = try await call(tools, "run_tests", ["project": .string(project.folder.path), "tests": ["nope"], "video": false])
        #expect(missing.isError)
        #expect(missing.text.contains("No test \"nope\" in Background."))
        #expect(tools.hold.get() == nil)

        // The app's Stop cancels its call, which stops its run at the step it is at.
        let app = Task {
            await tools.runTests(
                project, options: TestRunOptions(output: project.folder.appendingPathComponent("app-run"), video: false), source: "app")
        }
        for _ in 0..<200 where TestRuns.running(for: project.folder).isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        // Meanwhile another start on the device runs nothing: the run going on is reported.
        let second = try await call(tools, "run_tests", ["project": .string(project.folder.path), "video": false], source: "relay")
        #expect(second.text.hasPrefix("Background already has tests running on Device"), "\(second.text)")
        let blocked = await tools.runTests(
            project, options: TestRunOptions(output: project.folder.appendingPathComponent("blocked"), video: false), source: "app")
        #expect(blocked.error?.hasPrefix("Busy: a test run from app is running on this device.") == true)
        #expect(blocked.tests.isEmpty)
        app.cancel()
        let cancelled = await app.value
        #expect(cancelled.cancelled)
        #expect(tools.hold.get() == nil)
        #expect(TestRuns.running(for: project.folder).isEmpty)
        #expect(gate.phone.events.get().isEmpty)
    }

    /// Through the real Go relay: the agent hangs up, the relay sends "cancel", and the run goes on
    /// to the end anyway.
    @Test(.enabled(if: RelayEndToEndTests.goPath != nil, "Go is not installed"))
    func aRelayCancelDoesNotStopTheRun() async throws {
        let project = try project()
        defer { try? FileManager.default.removeItem(at: project.folder) }
        let relay = try await RelayProcess.start()
        defer { relay.stop() }
        let gate = Gate()
        let tools = PhoneTools(phone: gate.phone, activity: ActivityLog(), settleDelay: 0)
        let router = APIRouter(tools: tools, token: { "unused" }, port: { 0 })
        let reached = Locked(false)
        let cancelled = Locked(false)
        let client = RelayClient(handler: { request in
            reached.set(true)
            let response = await router.handle(request, from: .relay)
            cancelled.set(Task.isCancelled)
            return response
        })
        let secret = "mdh_" + SecretStore.randomHex(bytes: 32)
        client.start(url: relay.base, secret: secret, hostName: "studio", accessToken: nil)
        defer { client.stop() }
        for _ in 0..<100 where client.state != .connected { try await Task.sleep(for: .milliseconds(50)) }
        #expect(client.state == .connected)

        var request = URLRequest(url: relay.base.appendingPathComponent("v1/tools/run_tests"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(RelayClient.clientKey(forSecret: secret))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = JSONValue(["project": .string(project.folder.path), "video": false]).encoded()
        let agent = Task { try await URLSession.shared.data(for: request) }
        for _ in 0..<200 where TestRuns.running(for: project.folder).isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(reached.get())
        #expect(!TestRuns.running(for: project.folder).isEmpty)
        agent.cancel()
        for _ in 0..<100 where !cancelled.get() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(cancelled.get())

        let run = try #require(TestRuns.running(for: project.folder).first)
        #expect(!run.isFinished)
        #expect(tools.hold.get()?.id == run.hold)
        gate.go()
        try await waitForEnd(project)
        let final = try #require(TestRuns.result(for: project))
        #expect(!final.cancelled)
        #expect(final.tests.map(\.status) == [.passed, .passed])
        #expect(tools.hold.get() == nil)
    }
}
