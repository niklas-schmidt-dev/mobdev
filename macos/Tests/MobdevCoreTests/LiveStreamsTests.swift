import Foundation
import Testing
@testable import MobdevCore

/// The frames a stream sends to the relay, decoded.
private final class SentFrames: @unchecked Sendable {
    let frames = Locked<[[String: Any]]>([])

    var send: LiveStreams.Send {
        { [frames] text in
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            frames.withLock { $0.append(object) }
            return true
        }
    }

    func of(_ type: String) -> [[String: Any]] { frames.get().filter { $0["type"] as? String == type } }

    func wait(for type: String, count: Int = 1, seconds: Double = 5) async {
        for _ in 0..<Int(seconds * 50) where of(type).count < count { try? await Task.sleep(for: .milliseconds(20)) }
    }
}

private func start(_ id: String = "s1", fps: Int = 5, viewers: String = #"[{"kind":"owner","control":true}]"#) -> String {
    #"{"type":"live_start","id":"\#(id)","device":"","fps":\#(fps),"viewers":\#(viewers)}"#
}

/// A ToolCalling that knows no device.
private struct NoDevices: ToolCalling {
    var definitions: [ToolDefinition] { [] }
    func call(_ name: String, arguments: JSONValue?, source: String, screenshotByDefault: Bool) async throws -> ToolOutput {
        throw UnknownToolError(name: name)
    }
    func phone(for device: String?) throws -> PhoneBackend { throw ToolFailure("No device \"\(device ?? "")\".") }
    func activity(for device: String?) -> ActivityLog? { nil }
}

@Suite(.serialized) struct LiveStreamsTests {
    let phone = FakePhone(lines: [("Settings", 420, 300)])
    let activity = ActivityLog()
    var tools: PhoneTools { PhoneTools(phone: phone, activity: activity, settleDelay: 0) }

    @Test func streamsSmallJPEGsAndRepeatsAnUnchangedPicture() async throws {
        let sent = SentFrames()
        let live = LiveStreams(tools: tools, allowed: true, repeatInterval: 0.1)
        live.handle(start(fps: 10), send: sent.send)
        await sent.wait(for: "live_frame", count: 3)
        let frames = sent.of("live_frame")
        #expect(frames.count >= 3)
        #expect(frames.map { $0["seq"] as? Int }.prefix(3) == [1, 2, 3])
        let first = try #require(frames.first)
        #expect(first["id"] as? String == "s1")
        // The fake screen is 1179 × 2556: 800 px on the long edge.
        #expect(first["width"] as? Int == 369)
        #expect(first["height"] as? Int == 800)
        let jpeg = try #require(Data(base64Encoded: first["jpeg"] as? String ?? ""))
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        #expect(live.sessions.map(\.id) == ["s1"])
        #expect(activity.all.first?.tool == "live_view")
        #expect(activity.all.first?.source == "browser")
        #expect(activity.all.first?.summary == "Live view started: watched by you in the dashboard")

        live.handle(#"{"type":"live_stop","id":"s1"}"#, send: sent.send)
        #expect(live.sessions.isEmpty)
        let count = sent.of("live_frame").count
        try await Task.sleep(for: .milliseconds(300))
        #expect(sent.of("live_frame").count <= count + 1)  // One may have been on its way.
        #expect(sent.of("live_end").isEmpty)
    }

    @Test func sendsAnUnchangedPictureOnlyOnce() async throws {
        let sent = SentFrames()
        let live = LiveStreams(tools: tools, allowed: true, repeatInterval: 30)
        live.handle(start(fps: 10), send: sent.send)
        await sent.wait(for: "live_frame")
        try await Task.sleep(for: .milliseconds(500))
        #expect(sent.of("live_frame").count == 1)
        live.end(device: nil)
    }

    @Test func refusesWhileLiveViewIsOff() async {
        let sent = SentFrames()
        let live = LiveStreams(tools: tools, allowed: false)
        live.handle(start(), send: sent.send)
        await sent.wait(for: "live_end")
        #expect(sent.of("live_end").first?["code"] as? String == "disabled")
        #expect(sent.of("live_end").first?["reason"] as? String == LiveStreams.disabledReason)
        #expect(live.sessions.isEmpty)
        #expect(sent.of("live_frame").isEmpty)
    }

    @Test func turningLiveViewOffEndsEveryStream() async {
        let sent = SentFrames()
        let changes = Locked<[[LiveStreams.Session]]>([])
        let live = LiveStreams(tools: tools, allowed: true) { sessions in changes.withLock { $0.append(sessions) } }
        live.handle(start("a"), send: sent.send)
        await sent.wait(for: "live_frame")
        live.setAllowed(false)
        await sent.wait(for: "live_end")
        #expect(sent.of("live_end").map { $0["id"] as? String } == ["a"])
        #expect(sent.of("live_end").first?["code"] as? String == "disabled")
        #expect(live.sessions.isEmpty)
        #expect(changes.get().last == [])
        #expect(activity.all.first?.summary == "Live view ended: it was turned off on this Mac")
    }

    @Test func runsInputAsToolCallsFromTheBrowser() async throws {
        let sent = SentFrames()
        let live = LiveStreams(tools: tools, allowed: true)
        live.handle(start(), send: sent.send)
        live.handle(#"{"type":"live_input","id":"s1","input":{"action":"tap","x":0.5,"y":0.5}}"#, send: sent.send)
        live.handle(#"{"type":"live_input","id":"s1","input":{"action":"home"}}"#, send: sent.send)
        live.handle(#"{"type":"live_input","id":"other","input":{"action":"home"}}"#, send: sent.send)
        for _ in 0..<100 where phone.events.get().count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(phone.events.get() == [.tap(NormalizedPoint(x: 0.5, y: 0.5), 0.08), .button(.home)])
        let taps = activity.all.filter { $0.tool == "tap" }
        #expect(taps.first?.source == "browser")
        live.end(device: nil)
    }

    @Test func viewOnlyStreamsTakeNoInput() async throws {
        let sent = SentFrames()
        let live = LiveStreams(tools: tools, allowed: true)
        live.handle(start(viewers: #"[{"kind":"share","label":"Anna","control":false}]"#), send: sent.send)
        live.handle(#"{"type":"live_input","id":"s1","input":{"action":"home"}}"#, send: sent.send)
        try await Task.sleep(for: .milliseconds(300))
        #expect(phone.events.get().isEmpty)
        #expect(activity.all.first?.summary == "Live view started: watched by the share link “Anna” (view only)")
        // Someone who may control joins: the change is logged and input runs.
        live.handle(
            start(viewers: #"[{"kind":"share","label":"Anna","control":false},{"kind":"owner","control":true}]"#),
            send: sent.send)
        #expect(activity.all.first?.summary == "Now watched by the share link “Anna” (view only) and you in the dashboard")
        live.handle(#"{"type":"live_input","id":"s1","input":{"action":"home"}}"#, send: sent.send)
        for _ in 0..<100 where phone.events.get().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(phone.events.get() == [.button(.home)])
        live.end(device: nil)
    }

    @Test func endsStreamsTheRelayStoppedRenewing() async {
        let sent = SentFrames()
        let live = LiveStreams(tools: tools, allowed: true, renewTimeout: 0.3)
        live.handle(start(), send: sent.send)
        await sent.wait(for: "live_end")
        #expect(sent.of("live_end").first?["code"] as? String == "timeout")
        #expect(live.sessions.isEmpty)
    }

    @Test func refusesUnknownDevices() async {
        let sent = SentFrames()
        let live = LiveStreams(tools: NoDevices(), allowed: true)
        live.handle(#"{"type":"live_start","id":"x","device":"Pixel","fps":5,"viewers":[]}"#, send: sent.send)
        await sent.wait(for: "live_end")
        #expect(sent.of("live_end").first?["code"] as? String == "no_device")
        #expect(sent.of("live_end").first?["reason"] as? String == "No device \"Pixel\".")
    }

    @Test func inputBecomesScreenshotPixels() throws {
        func call(_ json: String) -> (String, [String: JSONValue])? {
            let input = try! JSONDecoder().decode(LiveStreams.Input.self, from: Data(json.utf8))
            // A 1179 × 2556 screen: screenshots are 590 × 1280.
            return LiveStreams.toolCall(for: input, frameSize: (1179, 2556))
        }
        #expect(call(#"{"action":"tap","x":0.5,"y":0.25}"#)?.0 == "tap")
        #expect(call(#"{"action":"tap","x":0.5,"y":0.25}"#)?.1 == ["x": 295, "y": 320])
        #expect(call(#"{"action":"tap","x":1,"y":1}"#)?.1 == ["x": 589, "y": 1279])
        #expect(call(#"{"action":"tap","x":1.2,"y":0.5}"#) == nil)
        #expect(
            call(#"{"action":"swipe","from_x":0.5,"from_y":0.8,"to_x":0.5,"to_y":0.2,"duration":5}"#)?.1
                == ["from_x": 295, "from_y": 1024, "to_x": 295, "to_y": 256, "duration": 2])
        #expect(call(#"{"action":"long_press","x":0,"y":0}"#)?.1 == ["x": 0, "y": 0, "seconds": 1])
        #expect(
            call(#"{"action":"scroll","direction":"down","amount":50}"#)?.1
                == ["x": 295, "y": 640, "direction": "down", "amount": 20])
        #expect(call(#"{"action":"scroll","direction":"sideways"}"#) == nil)
        #expect(call(#"{"action":"text","text":"Grüße"}"#)?.0 == "type_text")
        #expect(call(#"{"action":"text","text":""}"#) == nil)
        #expect(
            call(#"{"action":"key","key":"enter","modifiers":["cmd","hyper"]}"#)?.1
                == ["key": "enter", "modifiers": ["cmd"]])
        #expect(call(#"{"action":"home"}"#)?.0 == "home")
        #expect(call(#"{"action":"reboot"}"#) == nil)
        // Without a picture there is nowhere to tap, but keys still work.
        let tap = try JSONDecoder().decode(LiveStreams.Input.self, from: Data(#"{"action":"tap","x":0.5,"y":0.5}"#.utf8))
        #expect(LiveStreams.toolCall(for: tap, frameSize: nil) == nil)
    }

    @Test func describesWhoWatches() {
        typealias Viewer = LiveStreams.Viewer
        #expect(LiveStreams.describe([Viewer(kind: "key", control: true)]) == "an agent with the client key")
        #expect(
            LiveStreams.describe([
                Viewer(kind: "owner", control: true), Viewer(kind: "share", label: "QA", control: false),
                Viewer(kind: "share", label: "QA", control: false),
            ]) == "you in the dashboard and the share link “QA” (view only) ×2")
    }
}
