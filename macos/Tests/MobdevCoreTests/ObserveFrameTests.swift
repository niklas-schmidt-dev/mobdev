import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// A FakePhone that counts the pictures taken of its screen.
private final class CountingPhone: FakePhone, @unchecked Sendable {
    let looks = Locked(0)

    override func frame() -> CGImage? {
        looks.withLock { $0 += 1 }
        return super.frame()
    }
}

@Suite struct ObserveFrameTests {
    func tools(_ phone: PhoneBackend) -> PhoneTools {
        PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0) { _, _ in
            [TextMatch(text: "Hello", box: CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.03), confidence: 1, exact: false)]
        }
    }

    @Test func theTreeAloneTakesNoPicture() async throws {
        let phone = CountingPhone(lines: [], tree: ObserveTests.rows)
        let output = try await tools(phone).call("observe", arguments: [:], source: "test", screenshotByDefault: false)
        #expect(output.text.contains("from the UI tree; screenshot 590×1280 px"))
        #expect(output.image == nil)
        #expect(phone.looks.get() == 0)
    }

    @Test func marksDrawnOnThePictureTakeOne() async throws {
        let phone = CountingPhone(lines: [], tree: ObserveTests.rows)
        let output = try await tools(phone).call(
            "observe", arguments: ["image": true], source: "test", screenshotByDefault: false)
        #expect(output.image != nil)
        #expect(phone.looks.get() == 1)
    }

    @Test func withoutATreeTextRecognitionTakesOne() async throws {
        let phone = CountingPhone(lines: [])
        let output = try await tools(phone).call("observe", arguments: [:], source: "test", screenshotByDefault: false)
        #expect(output.text.contains("[1] Text \"Hello\""))
        #expect(phone.looks.get() == 1)

        let drawn = try await tools(phone).call(
            "observe", arguments: ["image": true], source: "test", screenshotByDefault: false)
        #expect(drawn.image != nil)
        #expect(phone.looks.get() == 2)
    }

    @Test func aScreenThatIsNotThereFailsAsBefore() async throws {
        let phone = CountingPhone(lines: [], tree: ObserveTests.rows)
        phone.screen.set(.searching)
        let output = try await tools(phone).call("observe", arguments: [:], source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("not available"))
    }
}
