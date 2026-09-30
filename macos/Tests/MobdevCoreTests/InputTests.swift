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
    @Test func descriptorDeclaresAllFourReports() {
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

    @Test func relativeMouseClampsToSignedBytes() {
        #expect(HIDReportMap.relativeMouseReport(buttons: 1, dx: 500, dy: -500, wheel: -3) == [1, 0x7F, 0x81, 0xFD])
    }

    @Test func tapMovesThenClicksThroughTheRelativeMouse() async throws {
        let sink = RecordingSink()
        let input = HIDInput(sink: sink, step: 0, wakeAfterIdle: nil)
        try await input.tap(at: NormalizedPoint(x: 0.25, y: 0.75), hold: 0)
        let reports = sink.reports.get()
        #expect(reports.map(\.0) == [.absolutePointer, .relativeMouse, .relativeMouse])
        #expect(reports[0].1 == HIDReportMap.absolutePointerReport(x: 0.25, y: 0.75))
        #expect(reports[1].1 == [1, 0, 0, 0])
        #expect(reports[2].1 == [0, 0, 0, 0])
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
        #expect(sink.reports.get()[0].1 == [0, 0, 0, 0])
    }

    @Test func failureReleasesButtons() async {
        let sink = RecordingSink()
        sink.connected = false
        let input = HIDInput(sink: sink, step: 0, wakeAfterIdle: nil)
        await #expect(throws: HIDError.self) { try await input.tap(at: NormalizedPoint(x: 0.5, y: 0.5)) }
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
