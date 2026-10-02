import Foundation
import Testing
@testable import MobdevCore

@Suite struct KeyboardLayoutTests {
    @Test func usLettersDigitsAndSymbols() throws {
        let layout = KeyboardLayout.us
        #expect(layout.strokes(for: "a") == [KeyStroke(0x04)])
        #expect(layout.strokes(for: "A") == [KeyStroke(0x04, KeyStroke.shift)])
        #expect(layout.strokes(for: "0") == [KeyStroke(0x27)])
        #expect(layout.strokes(for: "@") == [KeyStroke(0x1F, KeyStroke.shift)])
        #expect(layout.strokes(for: "?") == [KeyStroke(0x38, KeyStroke.shift)])
        #expect(try layout.strokes(typing: "Hi\n").count == 3)
    }

    @Test func usComposesAccentsWithOptionDeadKeys() {
        let layout = KeyboardLayout.us
        #expect(layout.strokes(for: "é") == [KeyStroke(0x08, KeyStroke.option), KeyStroke(0x08)])
        #expect(layout.strokes(for: "Ü") == [KeyStroke(0x18, KeyStroke.option), KeyStroke(0x18, KeyStroke.shift)])
        #expect(layout.strokes(for: "ß") == [KeyStroke(0x16, KeyStroke.option)])
    }

    @Test func germanSwapsYAndZAndHasUmlauts() {
        let layout = KeyboardLayout.german
        #expect(layout.strokes(for: "z") == [KeyStroke(0x1C)])
        #expect(layout.strokes(for: "y") == [KeyStroke(0x1D)])
        #expect(layout.strokes(for: "ä") == [KeyStroke(0x34)])
        #expect(layout.strokes(for: "Ö") == [KeyStroke(0x33, KeyStroke.shift)])
        #expect(layout.strokes(for: "ß") == [KeyStroke(0x2D)])
        #expect(layout.strokes(for: "@") == [KeyStroke(0x0F, KeyStroke.option)])
        #expect(layout.strokes(for: "\"") == [KeyStroke(0x1F, KeyStroke.shift)])
        #expect(layout.strokes(for: "-") == [KeyStroke(0x38)])
        #expect(layout.strokes(for: "é") == [KeyStroke(0x2E), KeyStroke(0x08)])
    }

    @Test func everyPrintableASCIICharacterIsTypeableInBothLayouts() throws {
        let ascii = (32...126).map { Character(UnicodeScalar($0)!) }
        for layout in KeyboardLayout.allCases {
            for character in ascii where !(layout == .german && character == "^") {
                #expect(layout.strokes(for: character) != nil, "\(layout) cannot type \(character)")
            }
        }
    }

    @Test func untypeableCharacterFailsWithAClearError() {
        #expect(throws: KeyboardError.untypeable("😀", .us)) { try KeyboardLayout.us.strokes(typing: "ok😀") }
    }

    @Test func namedKeysAndModifiers() throws {
        let layout = KeyboardLayout.us
        #expect(try layout.stroke(forKey: "space", modifiers: ["cmd"]) == KeyStroke(0x2C, KeyStroke.command))
        #expect(try layout.stroke(forKey: "h", modifiers: ["cmd"]) == KeyStroke(0x0B, KeyStroke.command))
        #expect(throws: KeyboardError.unknownKey("launch")) { try layout.stroke(forKey: "launch", modifiers: []) }
        #expect(throws: KeyboardError.unknownModifier("hyper")) {
            try layout.stroke(forKey: "a", modifiers: ["hyper"])
        }
    }

    @Test func macKeyCodesMapByPosition() {
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0x00, isISO: false) == 0x04)  // A
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0x06, isISO: false) == 0x1D)  // Z position
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0x24, isISO: false) == 0x28)  // Return
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0x0A, isISO: true) == 0x35)
        #expect(MacKeyCodes.hidUsage(forKeyCode: 0x32, isISO: true) == 0x64)
    }
}

@Suite struct HIDReportTests {
    @Test func descriptorDeclaresEveryReport() {
        let descriptor = HIDReportMap.descriptor
        for id in ReportID.allCases {
            #expect(zip(descriptor, descriptor.dropFirst()).contains { $0 == (0x85, id.rawValue) })
        }
    }

    @Test func absolutePointerIsLittleEndianAndClamped() {
        #expect(HIDReportMap.absolutePointerReport(x: 0, y: 1) == [0, 0, 0, 0xFF, 0x7F])
        #expect(HIDReportMap.absolutePointerReport(x: 0.5, y: 0.5) == [0, 0x00, 0x40, 0x00, 0x40])
        #expect(HIDReportMap.absolutePointerReport(x: -1, y: 2) == [0, 0, 0, 0xFF, 0x7F])
    }

    /// The sideways wheel is the relative mouse's AC Pan. iOS reveals content further right for a
    /// negative one (tried on an iPhone 14 Pro with iOS 27.0.1, 2026-10-02).
    @Test func sidewaysScrollIsTheMousesPan() async throws {
        #expect(HIDReportMap.relativeMouseReport(buttons: 0).count == ReportID.relativeMouse.length)
        #expect(HIDReportMap.relativeMouseReport(buttons: 0, pan: -300) == [0, 0, 0, 0, 0x81])
        let sink = RecordingSink()
        let input = HIDInput(sink: sink, step: 0, wakeAfterIdle: nil)
        try await input.pan(at: NormalizedPoint(x: 0.5, y: 0.5), ticks: 2)
        #expect(sink.reports.get().map(\.0) == [.absolutePointer, .relativeMouse, .relativeMouse])
        #expect(sink.reports.get().last?.1 == [0, 0, 0, 0, 0xFF])
    }

    /// Simulators and Android scroll with a swipe: revealing content further down or right moves
    /// the finger up or left.
    @Test func wheelSwipesMoveTheFingerAgainstTheContent() {
        let center = NormalizedPoint(x: 0.5, y: 0.5)
        let down = wheelSwipe(at: center, ticks: 4)
        #expect(down.from.x == 0.5 && down.from.y > down.to.y)
        let right = wheelSwipe(at: center, ticks: 4, sideways: true)
        #expect(right.from.y == 0.5 && right.from.x > right.to.x)
        let left = wheelSwipe(at: NormalizedPoint(x: 0.9, y: 0.5), ticks: -20, sideways: true)
        #expect(left.from.x < left.to.x && left.to.x <= 0.95)
    }

    @Test func relativeMouseClampsToSignedBytes() {
        #expect(HIDReportMap.relativeMouseReport(buttons: 1, dx: 500, dy: -500, wheel: -3, pan: 2) == [1, 0x7F, 0x81, 0xFD, 2])
    }

    @Test func tapMovesThenClicksThroughTheRelativeMouse() async throws {
        let sink = RecordingSink()
        let input = HIDInput(sink: sink, step: 0, wakeAfterIdle: nil)
        try await input.tap(at: NormalizedPoint(x: 0.25, y: 0.75), hold: 0)
        let reports = sink.reports.get()
        #expect(reports.map(\.0) == [.absolutePointer, .relativeMouse, .relativeMouse])
        #expect(reports[0].1 == HIDReportMap.absolutePointerReport(x: 0.25, y: 0.75))
        #expect(reports[1].1 == [1, 0, 0, 0, 0])
        #expect(reports[2].1 == [0, 0, 0, 0, 0])
    }

    @Test func shiftedKeyPressesAndReleasesTheModifier() async throws {
        let sink = RecordingSink()
        let input = HIDInput(sink: sink, step: 0, wakeAfterIdle: nil)
        try await input.type([KeyStroke(0x04, KeyStroke.shift)])
        let keyboard = sink.reports.get().filter { $0.0 == .keyboard }.map(\.1)
        #expect(keyboard == [
            [0x02, 0, 0, 0, 0, 0, 0, 0],
            [0x02, 0, 0x04, 0, 0, 0, 0, 0],
            [0x02, 0, 0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0, 0, 0],
        ])
    }

    @Test func firstInputAfterIdleWakesTheLinkFirst() async throws {
        let sink = RecordingSink()
        let input = HIDInput(sink: sink, step: 0, wakeAfterIdle: 60)
        try await input.tap(at: NormalizedPoint(x: 0.5, y: 0.5), hold: 0)
        try await input.tap(at: NormalizedPoint(x: 0.5, y: 0.5), hold: 0)
        let kinds = sink.reports.get().map(\.0)
        // One empty mouse report before the first tap only; the second follows right after.
        #expect(kinds == [.relativeMouse, .absolutePointer, .relativeMouse, .relativeMouse,
            .absolutePointer, .relativeMouse, .relativeMouse])
        #expect(sink.reports.get()[0].1 == [0, 0, 0, 0, 0])
    }

    /// The mirror keeps the link awake while the mouse is over it, so its click needs no wake-up.
    @Test func stayingAwakeSkipsTheWakeUpBeforeAClick() async throws {
        let sink = RecordingSink()
        let input = HIDInput(sink: sink, step: 0, wakeAfterIdle: 0.5)
        input.stayAwake()
        input.stayAwake()  // Within a second of the first: nothing more.
        try await input.tap(at: NormalizedPoint(x: 0.5, y: 0.5), hold: 0)
        #expect(sink.reports.get().map(\.0) == [.relativeMouse, .absolutePointer, .relativeMouse, .relativeMouse])
    }

    @Test func failureReleasesButtons() async {
        let sink = RecordingSink()
        sink.connected = false
        let input = HIDInput(sink: sink, step: 0, wakeAfterIdle: nil)
        await #expect(throws: HIDError.self) { try await input.tap(at: NormalizedPoint(x: 0.5, y: 0.5)) }
    }

    /// An iPhone that has not subscribed to the pointer yet would get the press without the
    /// pointer moving: a tap wherever the pointer was. Neither a swipe nor the mirror presses then.
    @Test func noPressWithoutThePointer() async {
        let sink = RecordingSink()
        sink.unsubscribed = [.absolutePointer]
        let input = HIDInput(sink: sink, step: 0.001, wakeAfterIdle: nil)
        let start = NormalizedPoint(x: 0.5, y: 0.8), end = NormalizedPoint(x: 0.5, y: 0.2)
        await #expect(throws: HIDError.self) { try await input.swipe(from: start, to: end, duration: 0.01) }
        input.pointerDown(at: start)
        input.pointerUp(at: end)
        try? await input.move(to: end)  // Runs after the live calls on the same queue.
        let presses = sink.reports.get().filter { $0.0 == .relativeMouse && $0.1.first == 1 }
        #expect(presses.isEmpty)
    }

    /// Typing that nobody waits for any more (the relay timed out, the agent hung up) stops, and
    /// leaves no key held.
    @Test func cancelledTypingStopsBetweenKeys() async throws {
        let sink = RecordingSink()
        let input = HIDInput(sink: sink, step: 0.005, wakeAfterIdle: nil)
        let strokes = Array(repeating: KeyStroke(0x04), count: 400)  // About 4 seconds.
        let typing = Task { try await input.type(strokes) }
        try await Task.sleep(for: .milliseconds(150))
        typing.cancel()
        await #expect(throws: CancellationError.self) { try await typing.value }
        let keyboard = sink.reports.get().filter { $0.0 == .keyboard }.map(\.1)
        #expect(keyboard.count < strokes.count)
        #expect(keyboard.last == [0, 0, 0, 0, 0, 0, 0, 0])
        // The queue is free for the next input right away.
        try await input.press(KeyStroke(0x05))
    }
}

@Suite struct RefreshBackoffTests {
    @Test func doublesFromEightSecondsUpToTwoMinutes() {
        var backoff = RefreshBackoff()
        #expect((0..<7).map { _ in backoff.next() } == [8, 16, 32, 64, 120, 120, 120])
    }

    @Test func resetStartsOverAtEightSeconds() {
        var backoff = RefreshBackoff()
        _ = backoff.next()
        _ = backoff.next()
        backoff.reset()
        #expect(backoff.next() == 8)
    }
}
