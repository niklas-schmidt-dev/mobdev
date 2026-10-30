import CoreGraphics
import Foundation
import Network
import Testing
@testable import MobdevCore

/// Builds Mobdev Runner for a simulator with Xcode, starts it and drives the Settings app through it:
/// /tree, /tap and /type, then ui_tree, tap_element and wait_for_element on top. A simulator needs no
/// signing, and its runner listens on the Mac's 127.0.0.1. Opt-in, because it builds for a minute
/// or two and acts on the simulator:
///
///     MOBDEV_TEST_RUNNER_SIMULATOR=<udid> swift test --filter RunnerIntegration
@Suite(.serialized) struct RunnerIntegrationTests {
    static let simulator = ProcessInfo.processInfo.environment["MOBDEV_TEST_RUNNER_SIMULATOR"]
    static let settings = "com.apple.Preferences"

    @Test(.enabled(if: simulator != nil, "Set MOBDEV_TEST_RUNNER_SIMULATOR"), .timeLimit(.minutes(15)))
    func runnerServesTreeTapsAndTyping() async throws {
        let udid = Self.simulator!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        // Not the default port, so a runner Mobdev keeps for another simulator does not answer.
        let runner = UIRunner(udid: udid, simulator: true, folder: folder, port: 47291)
        defer { runner.stop() }

        let started = Date()
        runner.start(team: nil)
        while runner.state != .running, Date().timeIntervalSince(started) < 600 {
            if case .failed(let reason) = runner.state {
                Issue.record("Mobdev Runner failed: \(reason)")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        try #require(runner.state == .running)
        print("── runner running after \(Int(Date().timeIntervalSince(started))) s")

        // Settings' rows carry identifiers in every language.
        try await launchSettings(udid)
        var elements = try await read(runner) { $0.contains { $0.identifier == "com.apple.settings.general" } }
        let general = try #require(elements.first { $0.identifier == "com.apple.settings.general" })
        #expect(general.role == "Button")
        #expect(general.tappable)
        #expect(general.frame.minX >= 0 && general.frame.maxX <= 1 && general.frame.minY >= 0 && general.frame.maxY <= 1)
        let clock = Date()
        _ = try await runner.elements()
        print("── \(elements.count) elements; one read takes \(Int(Date().timeIntervalSince(clock) * 1000)) ms")

        // Tap the search field and type accents and emoji, which the Bluetooth keyboard cannot.
        let search = try #require(elements.first { $0.role == "SearchField" })
        try await runner.tap(at: search.center, hold: 0)
        try await Task.sleep(for: .seconds(1))
        let text = "Grüße 😀 ñ"
        try await runner.type(text)
        elements = try await read(runner) { $0.contains { $0.role == "SearchField" && $0.value == text } }
        #expect(elements.contains { $0.role == "SearchField" && $0.value == text })

        // With no field focused, typing fails with XCTest's reason, cut to its first sentence.
        try await launchSettings(udid)
        _ = try await read(runner) { $0.contains { $0.identifier == "com.apple.settings.general" } }
        do {
            try await runner.type("x")
            Issue.record("Typing without a focused field succeeded")
        } catch {
            #expect("\(error)".contains("keyboard focus"))
            #expect(!"\(error)".contains("\n"))
        }

        // The tools on top, as on an iPhone whose tree comes from the runner.
        let tools = PhoneTools(phone: RunnerPhone(runner: runner), activity: ActivityLog(), settleDelay: 0)
        let tree = try await tools.call("ui_tree", arguments: ["contains": "settings.general"], source: "test", screenshotByDefault: false)
        #expect(!tree.isError, "\(tree.text)")
        #expect(tree.text.contains("Button"))
        let tapped = try await tools.call(
            "tap_element", arguments: ["id": "com.apple.settings.general"], source: "test", screenshotByDefault: false)
        #expect(!tapped.isError, "\(tapped.text)")
        // General opens and replaces the list it was in.
        let gone = try await tools.call(
            "wait_for_element", arguments: ["id": "com.apple.settings.general", "gone": true, "timeout": 10], source: "test",
            screenshotByDefault: false)
        #expect(!gone.isError, "\(gone.text)")

        runner.stop()
        #expect(runner.state == .off)
        // Ending xcodebuild ends the test on the simulator, and with it the server.
        let client = RunnerClient(route: .loopback, port: 47291, token: "")
        var closed = false
        for _ in 0..<20 where !closed {
            do {
                _ = try await client.call("GET", "/health", timeout: 2)
            } catch {
                closed = "\(error)".contains("Could not connect")
            }
            if !closed { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(closed, "The runner still answers after stop()")

        // Starting again reuses the build, as when the iPhone comes back or Mobdev starts.
        let restarted = Date()
        runner.start(team: nil)
        while runner.state != .running, Date().timeIntervalSince(restarted) < 300 {
            if case .failed(let reason) = runner.state {
                Issue.record("Mobdev Runner failed on restart: \(reason)")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        #expect(runner.state == .running)
        print("── running again after \(Int(Date().timeIntervalSince(restarted))) s")
        #expect(try await runner.elements().contains { $0.identifier.hasPrefix("com.apple.settings.") })
    }

    /// Every input endpoint but /fingers (below) on a simulator, straight and through the tools, the way an
    /// iPhone in Developer Mode is driven without Bluetooth. Screenshots of the steps go to
    /// $TMPDIR/mobdev-runner-input when MOBDEV_TEST_RUNNER_SHOTS is set.
    ///
    ///     MOBDEV_TEST_RUNNER_SIMULATOR=<udid> swift test --filter runnerDrivesAllInput
    @Test(.enabled(if: simulator != nil, "Set MOBDEV_TEST_RUNNER_SIMULATOR"), .timeLimit(.minutes(15)))
    func runnerDrivesAllInput() async throws {
        let udid = Self.simulator!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = UIRunner(udid: udid, simulator: true, folder: folder, port: 47292)
        defer { runner.stop() }
        runner.start(team: nil)
        let started = Date()
        while runner.state != .running, Date().timeIntervalSince(started) < 600 {
            if case .failed(let reason) = runner.state {
                Issue.record("Mobdev Runner failed: \(reason)")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        try #require(runner.state == .running)
        print("── runner running after \(Int(Date().timeIntervalSince(started))) s")

        // /activate brings Settings to the front without simctl.
        _ = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["simctl", "terminate", udid, Self.settings], timeout: 30)
        var clock = Date()
        try await runner.activate(Self.settings)
        print("── activate: \(milliseconds(since: clock)) ms")
        var elements = try await read(runner) { $0.contains { $0.identifier == "com.apple.settings.general" } }
        try await shot(udid, "1-activated")
        let general = try #require(elements.first { $0.identifier == "com.apple.settings.general" })

        // /drag: swiping up scrolls the list, so General moves up.
        clock = Date()
        try await runner.drag(from: NormalizedPoint(x: 0.5, y: 0.75), to: NormalizedPoint(x: 0.5, y: 0.35), duration: 0.3)
        print("── drag: \(milliseconds(since: clock)) ms")
        clock = Date()
        elements = try await read(runner) { elements in
            elements.first { $0.identifier == "com.apple.settings.general" }.map { $0.frame.minY < general.frame.minY - 0.05 } ?? true
        }
        print("── tree after the drag: \(milliseconds(since: clock)) ms")
        try await shot(udid, "2-scrolled")
        let moved = elements.first { $0.identifier == "com.apple.settings.general" }
        #expect(moved.map { $0.frame.minY < general.frame.minY - 0.05 } ?? true, "General did not move up: \(String(describing: moved))")

        // /tap, /type and /key: type into the search field, select all with ⌘A and delete it.
        clock = Date()
        try await runner.activate(Self.settings)
        print("── activate in front: \(milliseconds(since: clock)) ms")
        try await runner.drag(from: NormalizedPoint(x: 0.5, y: 0.35), to: NormalizedPoint(x: 0.5, y: 0.8), duration: 0.3)
        elements = try await read(runner) { $0.contains { $0.role == "SearchField" } }
        let search = try #require(elements.first { $0.role == "SearchField" })
        clock = Date()
        try await runner.tap(at: search.center, hold: 0)
        print("── tap: \(milliseconds(since: clock)) ms")
        try await Task.sleep(for: .seconds(1))
        clock = Date()
        try await runner.type("abc 😀")
        print("── type 5 characters: \(milliseconds(since: clock)) ms")
        elements = try await read(runner) { $0.contains { $0.role == "SearchField" && $0.value == "abc 😀" } }
        #expect(elements.contains { $0.role == "SearchField" && $0.value == "abc 😀" })
        clock = Date()
        try await runner.press(key: "backspace", modifiers: [])
        print("── key: \(milliseconds(since: clock)) ms")
        elements = try await read(runner) { $0.contains { $0.role == "SearchField" && $0.value == "abc " } }
        #expect(elements.contains { $0.role == "SearchField" && $0.value == "abc " }, "backspace: \(elements.filter { $0.role == "SearchField" })")
        // An arrow key moves the cursor: X lands before the space.
        try await runner.press(key: "left", modifiers: [])
        try await runner.press(key: "x", modifiers: ["shift"])
        elements = try await read(runner) { $0.contains { $0.role == "SearchField" && $0.value == "abcX " } }
        #expect(elements.contains { $0.role == "SearchField" && $0.value == "abcX " }, "left, X: \(elements.filter { $0.role == "SearchField" })")
        // Backspaces typed as text clear the field. (⌘A is checked through press_key below: right
        // after typing, iOS's correction bubble can take the shortcut.)
        try await runner.press(key: "right", modifiers: [])
        try await runner.type(String(repeating: "\u{8}", count: 8))
        elements = try await read(runner) { $0.contains { $0.role == "SearchField" && ($0.value.isEmpty || $0.value == $0.label) } }
        try await shot(udid, "3-typed-and-cleared")
        #expect(
            elements.contains { $0.role == "SearchField" && ($0.value.isEmpty || $0.value == $0.label) },
            "cleared: \(elements.filter { $0.role == "SearchField" })")

        // /tap with count 2 is one gesture: a double tap on a word selects it, which shows its menu.
        try await runner.type("hello")
        try await Task.sleep(for: .milliseconds(500))
        elements = try await read(runner) { $0.contains { $0.role == "SearchField" && $0.value == "hello" } }
        if let field = elements.first(where: { $0.role == "SearchField" }) {
            try await runner.doubleTap(at: NormalizedPoint(x: field.frame.minX + field.frame.width * 0.25, y: field.center.y))
            try await Task.sleep(for: .seconds(1))
            try await shot(udid, "4-double-tapped")
            let menu = try await runner.elements().filter { $0.role == "MenuItem" || $0.label == "Copy" || $0.label == "Cut" }
            print("── after a double tap: \(menu.map(\.label))")
        }

        // /button home: the home screen is in front, which only lists SpringBoard's icons.
        try await runner.press(button: "home")
        elements = try await read(runner) { $0.contains { $0.role == "Icon" } }
        try await shot(udid, "5-home")
        #expect(elements.contains { $0.role == "Icon" })
        do {
            try await runner.press(button: "volume_up")
            Issue.record("A simulator pressed a volume button")
        } catch {
            #expect("\(error)".contains("no volume buttons"))
        }

        // /tap with hold: a long press on an icon opens its menu.
        if let icon = elements.first(where: { $0.role == "Icon" }) {
            try await runner.tap(at: icon.center, hold: 1.5)
            try await Task.sleep(for: .seconds(1))
            try await shot(udid, "6-long-press")
            let after = try await runner.elements()
            print("── after a long press on \(icon.label): \(after.filter { $0.role == "Button" }.prefix(8).map(\.label))")
            #expect(after.count != elements.count || after != elements, "Nothing changed after a long press")
            try await runner.press(button: "home")
        }

        // The tools on top, as on an iPhone in Developer Mode without Bluetooth.
        let tools = PhoneTools(phone: RunnerPhone(runner: runner), activity: ActivityLog(), settleDelay: 0)
        func call(_ name: String, _ arguments: JSONValue) async throws -> ToolOutput {
            let output = try await tools.call(name, arguments: arguments, source: "test", screenshotByDefault: false)
            #expect(!output.isError, "\(name): \(output.text)")
            print("── \(name): \(output.text.components(separatedBy: "\n").first ?? "")")
            return output
        }
        let status = try await call("status", [:])
        #expect(status.text.contains("Input: Mobdev Runner (Developer Mode)"))
        _ = try await call("open_app", ["name": "Settings"])
        _ = try await read(runner) { $0.contains { $0.identifier == "com.apple.settings.general" } }
        _ = try await call("scroll", ["direction": "down", "amount": 5])
        _ = try await call("swipe", ["from_x": 300, "from_y": 500, "to_x": 300, "to_y": 1000])
        _ = try await call("tap_element", ["role": "searchfield"])
        try await Task.sleep(for: .seconds(1))
        // The field may still hold the earlier text: select it and delete it.
        _ = try await call("press_key", ["key": "a", "modifiers": ["cmd"]])
        _ = try await call("press_key", ["key": "backspace"])
        _ = try await call("type_text", ["text": "Grüße 😀"])
        elements = try await read(runner) { $0.contains { $0.role == "SearchField" && $0.value == "Grüße 😀" } }
        #expect(elements.contains { $0.role == "SearchField" && $0.value == "Grüße 😀" })
        _ = try await call("press_key", ["key": "backspace", "count": 3])
        elements = try await read(runner) { $0.contains { $0.role == "SearchField" && $0.value == "Grüß" } }
        #expect(elements.contains { $0.role == "SearchField" && $0.value == "Grüß" }, "\(elements.filter { $0.role == "SearchField" })")
        _ = try await call("type_text", ["text": "e", "submit": true])
        _ = try await call("home", [:])
        _ = try await read(runner) { $0.contains { $0.role == "Icon" } }
        try await shot(udid, "7-tools")
    }

    /// The browser reports actual touch events for SimulatorKit or scrcpy. On Xcode 27, close
    /// Device Hub and reboot the simulator if its lingering dtuhidd session suppresses HID input.
    ///
    ///     MOBDEV_TEST_RUNNER_SIMULATOR=<udid> swift test --filter emulatorPinchesWithTwoFingers
    ///     MOBDEV_TEST_ANDROID=<serial> swift test --filter emulatorPinchesWithTwoFingers
    @Test(.enabled(if: simulator != nil || EmulatorIntegrationTests.android != nil, "Set a test simulator or Android device"), .timeLimit(.minutes(5)))
    func emulatorPinchesWithTwoFingers() async throws {
        let android = Self.simulator == nil
        let udid = Self.simulator ?? EmulatorIntegrationTests.android!
        let adb = android ? ADB.find() : nil
        if android { try #require(adb != nil, "adb is needed for the Android test") }
        let host = android ? "10.0.2.2" : "127.0.0.1"
        let marker = "pinch test ready"
        let page = try await PageServer(html: Self.touchPage.replacingOccurrences(of: ">ready<", with: ">\(marker)<"))
        defer { page.stop() }
        let session = try await EmulatorIntegrationTests.Session(device: udid, adb: adb)
        defer { session.stop() }
        let opened = try await session.call("open_url", ["url": .string("http://\(host):\(page.port)/")])
        try #require(!opened.isError, "\(opened.text)")
        for _ in 0..<150 where !page.loaded.get() { try await Task.sleep(for: .milliseconds(100)) }
        try #require(page.loaded.get(), "The browser did not load the touch test page")
        func touched() async throws -> [Double] {
            for _ in 0..<40 where page.lastTouch.get() == nil { try await Task.sleep(for: .milliseconds(100)) }
            let line = try #require(page.lastTouch.get(), "The page saw no touch")
            print("── \(line)")
            let words = line.split(separator: " ")
            return [1, 3, 5, 7, 9].map { Double(words[$0]) ?? -1 }
        }
        for scale in [2.0, 0.5] {
            page.lastTouch.set(nil)
            let output = try await session.call("pinch", ["scale": .number(scale), "duration": 1])
            try #require(!output.isError, "\(output.text)")
            let seen = try await touched()
            #expect(seen[0] == 2 && seen[1] >= 20)
            #expect((700...1800).contains(seen[2]))
            #expect(abs(seen[4] / seen[3] - scale) < 0.1)
        }
        // A one-finger swipe still lifts cleanly after a two-finger gesture.
        page.lastTouch.set(nil)
        let output = try await session.call("swipe", ["from_x": "50%", "from_y": "70%", "to_x": "50%", "to_y": "40%", "duration": 0.5])
        try #require(!output.isError, "\(output.text)")
        let seen = try await touched()
        #expect(seen[0] == 1 && seen[1] >= 10)
        #expect((300...1000).contains(seen[2]))
    }

    /// /fingers: two fingers pinch a page in Safari that reports what touched it, straight and
    /// through `pinch`: two fingers, moving for the time asked, their distance changed by the scale.
    ///
    ///     MOBDEV_TEST_RUNNER_SIMULATOR=<udid> swift test --filter runnerPinchesWithTwoFingers
    @Test(.enabled(if: simulator != nil, "Set MOBDEV_TEST_RUNNER_SIMULATOR"), .timeLimit(.minutes(15)))
    func runnerPinchesWithTwoFingers() async throws {
        let udid = Self.simulator!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = UIRunner(udid: udid, simulator: true, folder: folder, port: 47293)
        defer { runner.stop() }
        runner.start(team: nil)
        let started = Date()
        while runner.state != .running, Date().timeIntervalSince(started) < 600 {
            if case .failed(let reason) = runner.state {
                Issue.record("Mobdev Runner failed: \(reason)")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        try #require(runner.state == .running)

        let page = try await PageServer(html: Self.touchPage)
        defer { page.stop() }
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        _ = try await ProcessRunner().run(xcrun, ["simctl", "launch", udid, "com.apple.mobilesafari"], timeout: 60)
        try await Task.sleep(for: .seconds(2))
        _ = try await ProcessRunner().run(xcrun, ["simctl", "openurl", udid, "http://127.0.0.1:\(page.port)/"], timeout: 60)
        _ = try await read(runner) { $0.contains { $0.label == "ready" } }

        /// What the page saw of the last touch: fingers, moves, milliseconds, distance at the start and the end.
        func touched() async throws -> [Double] {
            let elements = try await read(runner) { $0.contains { $0.label.hasPrefix("fingers ") } }
            let label = try #require(elements.first { $0.label.hasPrefix("fingers ") }?.label, "The page saw no touch")
            print("── \(label)")
            let words = label.split(separator: " ")
            return [1, 3, 5, 7, 9].map { Double(words[$0]) ?? -1 }
        }
        let screen = try await runner.client().call("GET", "/tree", timeout: 60)["screen"]
        let width = try #require(screen?["width"]?.doubleValue), height = try #require(screen?["height"]?.doubleValue)

        try await runner.touch(pinchFingers(at: NormalizedPoint(x: 0.5, y: 0.5), scale: 3, alongWidth: width > height), duration: 1)
        var seen = try await touched()
        #expect(seen[0] == 2)
        #expect(seen[1] >= 20 && (700...1600).contains(seen[2]), "A one-second pinch: \(seen[1]) moves in \(seen[2]) ms")
        #expect(abs(seen[4] / seen[3] - 3) < 0.3, "Fingers from \(seen[3]) to \(seen[4]) points apart")

        let tools = PhoneTools(
            phone: RunnerPhone(runner: runner, size: (Int(width * 3), Int(height * 3))), activity: ActivityLog(), settleDelay: 0)
        let output = try await tools.call(
            "pinch", arguments: ["x": "50%", "y": "60%", "scale": 0.5, "duration": 0.5], source: "test", screenshotByDefault: false)
        #expect(!output.isError, "\(output.text)")
        seen = try await touched()
        #expect(seen[0] == 2)
        #expect((300...900).contains(seen[2]), "A half-second pinch took \(seen[2]) ms")
        #expect(abs(seen[4] / seen[3] - 0.5) < 0.05, "Fingers from \(seen[3]) to \(seen[4]) points apart")
    }

    /// A page that shows what its last touch was: "fingers 2 moves 60 ms 1000 span 157 to 472".
    static let touchPage = """
        <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
        <style>html, body { margin: 0; height: 100%; touch-action: none; font: 28px -apple-system }
        p { position: fixed; top: 10%; width: 100%; text-align: center }</style>
        <p id="out">ready</p>
        <script>
        let touch = null
        const distance = t => t.length < 2 ? 0 : Math.round(Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY))
        const listen = (type, handle) => document.addEventListener(type, event => { event.preventDefault(); handle(event) }, { passive: false })
        listen("touchstart", e => {
            if (!touch || touch.done) touch = { start: performance.now(), end: performance.now(), fingers: 0, moves: 0, from: 0, to: 0 }
            touch.fingers = Math.max(touch.fingers, e.touches.length)
            if (e.touches.length > 1 && !touch.from) touch.from = distance(e.touches)
        })
        listen("touchmove", e => {
            touch.moves += 1
            touch.end = performance.now()
            if (e.touches.length > 1) touch.to = distance(e.touches)
        })
        listen("touchend", e => {
            if (e.touches.length) return
            touch.done = true
            out.textContent = `fingers ${touch.fingers} moves ${touch.moves} ms ${Math.round(touch.end - touch.start)} span ${touch.from} to ${touch.to}`
            fetch('/touch?' + encodeURIComponent(out.textContent))
        })
        fetch('/ready')
        </script>
        """

    /// /fingers lands where XCTest's own taps land in every orientation: one finger on a row of
    /// Settings' sidebar selects what a tap there selects. XCTest takes the points in portrait, so
    /// the runner turns them; an iPad simulator shows the sidebar in every orientation.
    ///
    ///     MOBDEV_TEST_RUNNER_SIMULATOR=<udid of an iPad> swift test --filter fingersLandInEveryOrientation
    @Test(.enabled(if: simulator != nil, "Set MOBDEV_TEST_RUNNER_SIMULATOR"), .timeLimit(.minutes(15)))
    func fingersLandInEveryOrientation() async throws {
        let udid = Self.simulator!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = UIRunner(udid: udid, simulator: true, folder: folder, port: 47294)
        defer { runner.stop() }
        runner.start(team: nil)
        let started = Date()
        while runner.state != .running, Date().timeIntervalSince(started) < 600 {
            if case .failed(let reason) = runner.state {
                Issue.record("Mobdev Runner failed: \(reason)")
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        try #require(runner.state == .running)
        func rotate(_ orientation: String) async throws {
            _ = try await ProcessRunner().run(
                URL(fileURLWithPath: "/usr/bin/xcrun"), ["devicectl", "device", "orientation", "set", "--device", udid, orientation],
                timeout: 60)
            try await Task.sleep(for: .seconds(3))
        }
        let client = try runner.client()
        // An iPhone's Settings opens rows instead of selecting them.
        let screen = try await client.call("GET", "/tree", timeout: 60)["screen"]
        guard min(screen?["width"]?.doubleValue ?? 0, screen?["height"]?.doubleValue ?? 0) >= 700 else {
            print("── not an iPad: skipped")
            return
        }
        defer { Task { try? await rotate("portrait") } }
        func selected() async throws -> Set<String> {
            try await Task.sleep(for: .seconds(1))
            let tree = try await client.call("GET", "/tree", timeout: 60)
            return Set((tree["elements"]?.arrayValue ?? []).filter { $0["selected"]?.boolValue == true }.compactMap { $0["identifier"]?.stringValue })
        }
        for orientation in ["landscapeRight", "landscapeLeft", "portraitUpsideDown", "portrait"] {
            try await rotate(orientation)
            try await launchSettings(udid)
            try await Task.sleep(for: .seconds(3))
            let elements = try await read(runner) { $0.contains { $0.identifier == "com.apple.settings.camera" } }
            let rows = try ["com.apple.settings.accessibility", "com.apple.settings.camera"].map { id in
                try #require(elements.first { $0.identifier == id }, "No \(id) in \(orientation)").center
            }
            try await runner.tap(at: rows[0], hold: 0)
            let tapped = try await selected()
            try await runner.touch([(rows[1], rows[1])], duration: 0.05)
            let touched = try await selected()
            #expect(touched != tapped, "\(orientation): one finger on the second row changed nothing")
            try await runner.tap(at: rows[1], hold: 0)
            #expect(try await selected() == touched, "\(orientation): a tap selects other than one finger at \(rows[1])")
            try await runner.touch([(rows[0], rows[0])], duration: 0.05)
            #expect(try await selected() == tapped, "\(orientation): one finger selects other than a tap at \(rows[0])")
        }
    }

    private func milliseconds(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

    /// A screenshot of the simulator for a person to look at, when MOBDEV_TEST_RUNNER_SHOTS is set.
    private func shot(_ udid: String, _ name: String) async throws {
        guard ProcessInfo.processInfo.environment["MOBDEV_TEST_RUNNER_SHOTS"] != nil else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-runner-input")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await ProcessRunner().run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            ["simctl", "io", udid, "screenshot", folder.appendingPathComponent("\(name).png").path], timeout: 30)
    }

    /// Reads the tree from a runner already running on an iPhone, through usbmuxd. Read-only: it
    /// sends no taps or text. Start the runner with `TEST_RUNNER_MOBDEV_RUNNER_TOKEN=<token>`.
    ///
    ///     MOBDEV_TEST_RUNNER_DEVICE=<udid> MOBDEV_TEST_RUNNER_TOKEN=<token> \
    ///       swift test --filter runnerOnAnIPhoneAnswersOverUSB
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOBDEV_TEST_RUNNER_DEVICE"] != nil, "Set MOBDEV_TEST_RUNNER_DEVICE"))
    func runnerOnAnIPhoneAnswersOverUSB() async throws {
        let environment = ProcessInfo.processInfo.environment
        let client = RunnerClient(
            route: .usb(udid: environment["MOBDEV_TEST_RUNNER_DEVICE"]!), port: UIRunner.defaultPort,
            token: environment["MOBDEV_TEST_RUNNER_TOKEN"] ?? "")
        try await client.health()
        let raw = try await client.call("GET", "/tree", timeout: 30)
        print("── apps \(raw["apps"]?.compactString ?? ""), screen \(raw["screen"]?.compactString ?? "")")
        let elements = try RunnerClient.elements(fromTree: raw)
        for element in elements.prefix(40) where !element.label.isEmpty || !element.identifier.isEmpty {
            print("   \(element.role) \"\(element.label)\" id=\(element.identifier) center=(\(element.center.x), \(element.center.y))")
        }
        #expect(!elements.isEmpty)
    }

    /// Asks the Mac's usbmuxd which devices it carries. Read-only: nothing reaches a device.
    ///
    ///     MOBDEV_TEST_USBMUXD=<udid of a connected iPhone> swift test --filter RunnerIntegration
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOBDEV_TEST_USBMUXD"] != nil, "Set MOBDEV_TEST_USBMUXD"))
    func usbmuxdListsTheConnectedIPhone() throws {
        let udid = ProcessInfo.processInfo.environment["MOBDEV_TEST_USBMUXD"]!
        let devices = try USBMux().devices()
        print("── usbmuxd: \(devices.map { "\($0.id) \($0.serial) \($0.connection)" })")
        #expect(devices.contains { USBMux.normalized($0.serial) == USBMux.normalized(udid) })
    }

    private func launchSettings(_ udid: String) async throws {
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            ["simctl", "launch", "--terminate-running-process", udid, Self.settings], timeout: 60)
        try #require(result.status == 0, "\(result.output)")
    }

    /// Reads the tree until `accepted` holds, for up to 15 seconds, and returns the last tree.
    private func read(_ runner: UIRunner, until accepted: ([UIElement]) -> Bool) async throws -> [UIElement] {
        var elements: [UIElement] = []
        for _ in 0..<30 {
            elements = try await runner.elements()
            if accepted(elements) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        return elements
    }
}

/// A phone whose input and tree go through Mobdev Runner the way HardwareDevice's do while the
/// runner runs on an iPhone, with no Bluetooth to fall back on. Apps come from the simulator. The
/// screen size is an iPhone 17's in pixels unless given.
private final class RunnerPhone: PhoneBackend, @unchecked Sendable {
    let runner: UIRunner
    let control: DeviceControl
    let size: (width: Int, height: Int)
    init(runner: UIRunner, size: (width: Int, height: Int) = (1206, 2622)) {
        self.runner = runner
        self.size = size
        control = DeviceControl(udid: runner.udid, reportsFolder: FileManager.default.temporaryDirectory, simulator: true)
    }

    private var routes: IPhoneInput {
        IPhoneInput(runner: runner.state == .running ? runner : nil, bluetooth: { throw HIDError.notConnected }, layout: .us)
    }

    func status() -> PhoneStatus {
        PhoneStatus(
            screen: .connected(name: "Simulator", width: size.width, height: size.height), bluetooth: .advertising,
            keyboardLayout: .us, input: runner.state == .running ? .runner : .bluetooth, runner: runner.state)
    }

    func frame() -> CGImage? { nil }
    var apps: AppBackend? { control }
    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws { try await routes.tap(at: point, hold: hold) }
    func doubleTap(at point: NormalizedPoint) async throws { try await routes.doubleTap(at: point) }
    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {
        try await routes.swipe(from: start, to: end, duration: duration)
    }
    func scroll(at point: NormalizedPoint, ticks: Int) async throws { try await routes.scroll(at: point, ticks: ticks) }
    func pan(at point: NormalizedPoint, ticks: Int) async throws { try await routes.pan(at: point, ticks: ticks) }
    func touch(_ fingers: [(from: NormalizedPoint, to: NormalizedPoint)], duration: TimeInterval) async throws {
        try await routes.touch(fingers, duration: duration)
    }
    func type(_ strokes: [KeyStroke]) async throws { try await routes.type(strokes) }
    func press(_ stroke: KeyStroke) async throws { try await routes.press(stroke) }
    func press(_ button: ConsumerUsage) async throws { try await routes.press(button) }
    func typeText(_ text: String) async throws -> Bool { try await routes.typeText(text) }
    func openApp(named name: String) async throws -> String? { try await routes.openApp(named: name, apps: control) }
    func uiTree() async throws -> [UIElement]? { try await runner.elements() }
}

/// An HTTP server on 127.0.0.1 that answers every request with one page.
private final class PageServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16
    let lastTouch = Locked<String?>(nil)
    let loaded = Locked(false)

    init(html: String) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let queue = DispatchQueue(label: "page-server")
        let body = Data(html.utf8)
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        let lastTouch = self.lastTouch, loaded = self.loaded
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data, let request = String(data: data, encoding: .utf8),
                    let path = request.split(separator: " ").dropFirst().first {
                    if path == "/ready" { loaded.set(true) }
                    if path.hasPrefix("/touch?") { lastTouch.set(String(path.dropFirst(7)).removingPercentEncoding) }
                }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = Locked(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed.withLock({ let was = $0; $0 = true; return was }) {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    if !resumed.withLock({ let was = $0; $0 = true; return was }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}
