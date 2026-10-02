import CoreGraphics
import Foundation
import Testing
import Vision
@testable import MobdevCore

@Suite struct TextRecognizerTests {
    // 1179×2556, like FakePhone.
    let screen = FakePhone.render(
        lines: [("Settings", 420, 300), ("General", 120, 1200), ("General", 120, 1600)], width: 1179, height: 2556)

    /// `Mobdev`, once `swift build` made it.
    static let mobdev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/Mobdev")
    static var mobdevBuilt: Bool { FileManager.default.isExecutableFile(atPath: mobdev.path) }

    struct NeuralEngineFailure: Error, CustomStringConvertible {
        var description: String { #"e5rtError("e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed", 13)"# }
    }

    @Test func pixelsSurviveTheTripToTheHelper() throws {
        let pixels = try #require(TextRecognizer.pixels(of: screen))
        #expect(pixels.count == 1179 * 2556 * 4)
        let copy = try #require(TextRecognizer.image(fromPixels: pixels, width: 1179, height: 2556))
        #expect(TextRecognizer.pixels(of: copy) == pixels)
        #expect(TextRecognizer.image(fromPixels: pixels.dropLast(), width: 1179, height: 2556) == nil)
    }

    @Test func matchesSurviveJSON() {
        let match = TextMatch(text: "Wi-Fi", box: CGRect(x: 0.1, y: 0.25, width: 0.2, height: 0.03), confidence: 0.5, exact: true)
        #expect(TextRecognizer.match(from: TextRecognizer.json(match)) == match)
    }

    @Test(.needsTextRecognition) func theCPURecognizesTextToo() throws {
        let lines = TextRecognizer.lines(try TextRecognizer.perform(screen, cpuOnly: true))
        #expect(lines.map(\.text) == ["Settings", "General", "General"])
    }

    @Test(.needsTextRecognition) func aNeuralEngineFailureFallsBackToTheCPU() throws {
        let attempts = Locked<[Bool]>([])
        let observations = try TextRecognizer.observations(in: screen) { image, cpuOnly in
            attempts.withLock { $0.append(cpuOnly) }
            guard cpuOnly else { throw NeuralEngineFailure() }
            return try TextRecognizer.perform(image, cpuOnly: true)
        }
        #expect(attempts.get() == [false, true])
        #expect(TextRecognizer.matches(of: "general", in: observations).count == 2)
    }

    @Test func aFailureOnTheCPUTooSaysBoth() {
        #expect {
            _ = try TextRecognizer.observations(in: screen) { _, cpuOnly in
                throw cpuOnly ? TextRecognitionError("no CPU") : TextRecognitionError("no Neural Engine")
            }
        } throws: { error in
            String(describing: error) == "Vision failed: no Neural Engine; on the CPU: no CPU"
        }
    }

    @Test(.needsTextRecognition, .enabled(if: mobdevBuilt, "needs swift build"))
    func theHelperRecognizesText() throws {
        let lines = try #require(try TextRecognizer.recognize(screen, query: nil, helper: Self.mobdev))
        #expect(lines.map(\.text) == ["Settings", "General", "General"])
        let general = try #require(try TextRecognizer.recognize(screen, query: "general", helper: Self.mobdev))
        let allExact = general.allSatisfy(\.exact)
        #expect(general.count == 2)
        #expect(allExact)
        #expect(abs(general[0].center.y - 1200.0 / 2556.0) < 0.02)
    }

    @Test(.enabled(if: mobdevBuilt, "needs swift build")) func theHelperExplainsBadInput() throws {
        let (status, data) = try ProcessRunner().runBinary(
            Self.mobdev, ["__text", "10", "10"], input: Data(count: 12), timeout: 30)
        #expect(status == 1)
        #expect(try JSONValue.parse(data)["error"]?.stringValue == "Expected 400 bytes of BGRA pixels, got 12.")
    }

    /// `true` exits without reading its input: the 12 MB write must neither block nor raise SIGPIPE.
    @Test func aHelperWithoutAnAnswerIsAnError() throws {
        let started = Date()
        #expect {
            _ = try TextRecognizer.recognize(screen, query: nil, helper: URL(fileURLWithPath: "/usr/bin/true"))
        } throws: { error in
            String(describing: error) == "The text recognition process ended without an answer (exit 0)."
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func aHelperThatDoesNotStartLeavesItToThisProcess() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/Mobdev")
        #expect(try TextRecognizer.recognize(screen, query: nil, helper: missing) == nil)
    }
}
