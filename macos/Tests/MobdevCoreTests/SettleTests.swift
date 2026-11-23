import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// A phone whose pictures follow a script: look n gets `picture(n)`. Each look can take a while,
/// as `screencap` does on Android without scrcpy.
private final class ScriptedScreen: FakePhone, @unchecked Sendable {
    let picture: @Sendable (Int) -> CGImage?
    let lookTime: TimeInterval
    let looks = Locked(0)

    init(lookTime: TimeInterval = 0, tree: [UIElement]? = nil, _ picture: @escaping @Sendable (Int) -> CGImage?) {
        self.picture = picture
        self.lookTime = lookTime
        super.init(lines: [], tree: tree)
    }

    /// The pictures in turn, the last one staying.
    convenience init(_ pictures: [CGImage], lookTime: TimeInterval = 0) {
        self.init(lookTime: lookTime) { pictures[min($0, pictures.count - 1)] }
    }

    override func frame() -> CGImage? {
        if lookTime > 0 { Thread.sleep(forTimeInterval: lookTime) }
        return picture(looks.withLock { count in
            defer { count += 1 }
            return count
        })
    }
}

/// Screens that differ clearly, each with one line of text at its own height.
private let distinctScreens = (0..<4).map {
    FakePhone.render(lines: [("Screen \($0)", 100, 400 + CGFloat($0) * 500)], width: 1179, height: 2556)
}

@Suite struct SettleTests {
    func tools(_ phone: PhoneBackend, _ settle: Settle) -> PhoneTools {
        PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: settle.fixed, settle: settle) { _, _ in [] }
    }

    /// A tap that returns its screenshot, and how long it took.
    func tap(_ tools: PhoneTools) async throws -> (output: ToolOutput, seconds: TimeInterval) {
        let started = Date()
        let output = try await tools.call("tap", arguments: ["x": 100, "y": 100], source: "test", screenshotByDefault: true)
        #expect(!output.isError, "\(output.text)")
        return (output, Date().timeIntervalSince(started))
    }

    /// Short times, and a limit no busy test runner reaches, so the outcome does not depend on timing.
    static let quick = Settle(fixed: 0.05, first: 0.01, still: 0.05, limit: 30, poll: 0.01)

    @Test func theAppWaitsAsBeforeAtMostForAStillScreen() {
        let app = Settle.standard(0.6)
        #expect(app.fixed == 0.6 && app.first == 0.15 && app.still == 0.25 && app.limit == 1.5)
        let short = Settle.standard(0.3)
        #expect(short.first + short.still <= 0.3 + 1e-9)
        #expect(short.first > 0 && short.still > 0)
        #expect(Settle.standard(0).first == 0 && Settle.standard(0).still == 0)
    }

    @Test func withoutADelayThePictureIsTakenAtOnce() async throws {
        let phone = ScriptedScreen(distinctScreens)
        let tools = tools(phone, Settle(fixed: 0))
        let (output, _) = try await tap(tools)
        #expect(output.image == ImageTools.screenshot(distinctScreens[0]))
        #expect(phone.looks.get() == 1)
    }

    /// The first action has not timed a picture yet and waits as before. The next one returns the
    /// screen once it stopped changing, not the moment in between.
    @Test func anActionReturnsTheScreenOnceItIsStill() async throws {
        let phone = ScriptedScreen(distinctScreens)
        let tools = tools(phone, Self.quick)
        let (first, _) = try await tap(tools)
        #expect(phone.looks.get() == 1)
        #expect(first.image == ImageTools.screenshot(distinctScreens[0]))
        #expect(tools.frameCost.get() != nil)

        let (second, _) = try await tap(tools)
        #expect(second.image == ImageTools.screenshot(distinctScreens[3]))
        // Screens 1, 2 and 3, then 3 again until it was still for long enough.
        #expect(phone.looks.get() >= 5)
    }

    /// The effect showed and the screen is still: no need to wait out the fixed time.
    @Test func anEffectThatShowsAndSettlesReturnsSoonerThanTheFixedWait() async throws {
        // Screen 0 before the action, screen 1 from then on.
        let phone = ScriptedScreen([distinctScreens[0], distinctScreens[1]])
        let tools = tools(phone, Settle(fixed: 120, first: 0.01, still: 0.05, limit: 300, poll: 0.01))
        tools.frameCost.set(0.01)
        let (output, seconds) = try await tap(tools)
        #expect(output.image == ImageTools.screenshot(distinctScreens[1]))
        #expect(seconds >= 0.06)
        // Waiting as before would take two minutes; a busy runner takes seconds for this.
        #expect(seconds < 60)
    }

    /// Nothing changed yet, so nothing says the action's effect has shown: the fixed wait, as before.
    @Test func aScreenThatDoesNotChangeWaitsAsBefore() async throws {
        let phone = ScriptedScreen([distinctScreens[0]])
        let tools = tools(phone, Settle(fixed: 0.3, first: 0.01, still: 0.05, limit: 30, poll: 0.01))
        tools.frameCost.set(0.01)
        let (output, seconds) = try await tap(tools)
        #expect(output.image == ImageTools.screenshot(distinctScreens[0]))
        #expect(seconds >= 0.3)
    }

    /// An app that answers a tap after a moment: the screen is still at first, and a wait that took
    /// that for the end would return the screen from before the tap.
    @Test func anEffectThatShowsLateIsInThePicture() async throws {
        let showsAt = Locked(Date.distantFuture)
        let phone = ScriptedScreen { _ in Date() >= showsAt.get() ? distinctScreens[1] : distinctScreens[0] }
        let tools = tools(phone, Settle(fixed: 2, first: 0.01, still: 0.05, limit: 30, poll: 0.01))
        tools.frameCost.set(0.01)
        showsAt.set(Date().addingTimeInterval(0.3))
        let (output, seconds) = try await tap(tools)
        #expect(output.image == ImageTools.screenshot(distinctScreens[1]))
        #expect(seconds >= 0.3)
    }

    /// How many looks fit before the limit depends on how busy the Mac is; the picture is always
    /// the newest one.
    @Test func aScreenThatKeepsMovingReturnsAtTheLimit() async throws {
        let phone = ScriptedScreen { distinctScreens[$0 % 2] }
        let tools = tools(phone, Settle(fixed: 0.05, first: 0.01, still: 0.05, limit: 0.3, poll: 0.01))
        tools.frameCost.set(0.01)
        let (output, seconds) = try await tap(tools)
        #expect(seconds >= 0.3)
        #expect(seconds < 60)
        #expect(output.image == ImageTools.screenshot(distinctScreens[(phone.looks.get() - 1) % 2]))
    }

    /// Pictures as slow as `screencap` are not worth repeating: one after the fixed wait, as before.
    @Test func slowPicturesWaitAsBefore() async throws {
        let phone = ScriptedScreen(distinctScreens, lookTime: 0.05)
        let tools = tools(phone, Settle(fixed: 0.1, first: 0.01, still: 0.05, limit: 30, poll: 0.01, slowFrame: 0.02))
        let (_, seconds) = try await tap(tools)
        #expect(phone.looks.get() == 1)
        #expect(seconds >= 0.15)
        _ = try await tap(tools)
        #expect(phone.looks.get() == 2)

        // Fast before, slow now (scrcpy stopped): the slow look ends the polling, and the next action
        // waits as before.
        tools.frameCost.set(0.01)
        _ = try await tap(tools)
        #expect(phone.looks.get() == 4)
        _ = try await tap(tools)
        #expect(phone.looks.get() == 5)
    }

    @Test func withoutAPictureAnActionWaitsAsBefore() async throws {
        let phone = ScriptedScreen { _ in nil }
        let tools = tools(phone, Settle(fixed: 0.1, first: 0.01, still: 0.05, limit: 30, poll: 0.01))
        tools.frameCost.set(0.01)
        let (output, seconds) = try await tap(tools)
        #expect(output.image == nil)
        #expect(seconds >= 0.1)
        #expect(phone.looks.get() == 2)
    }

    @Test func toolsThatOnlyLookTakeNoSettledPicture() async throws {
        let phone = ScriptedScreen(distinctScreens)
        let tools = tools(phone, Self.quick)
        let output = try await tools.call("status", arguments: [:], source: "test", screenshotByDefault: true)
        #expect(output.image == nil)
        #expect(phone.looks.get() == 0)
    }
}
