import CoreGraphics
import Foundation
import Testing
@testable import MobdevCore

/// A phone that shows `pictures` in turn, one per look, the last one staying.
private final class PictureSequence: FakePhone, @unchecked Sendable {
    let pictures: [CGImage]
    let looks = Locked(0)

    init(_ pictures: [CGImage]) {
        self.pictures = pictures
        super.init(lines: [])
    }

    override func frame() -> CGImage? {
        let look = looks.withLock { count in
            defer { count += 1 }
            return count
        }
        return pictures[min(look, pictures.count - 1)]
    }
}

@Suite struct WaitForTextTests {
    /// A blank screen, the same pixels drawn again, and the same screen with a short word on it.
    static let blank = FakePhone.render(lines: [], width: 1179, height: 2556)
    static let blankAgain = FakePhone.render(lines: [], width: 1179, height: 2556)
    static let word = FakePhone.render(lines: [("OK", 560, 1500)], width: 1179, height: 2556)

    /// Tools whose text recognition counts its reads and sees "OK" only on `word`.
    func tools(_ phone: PhoneBackend) -> (PhoneTools, Locked<Int>) {
        let reads = Locked(0)
        let tools = PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0) { image, query in
            reads.withLock { $0 += 1 }
            guard image === Self.word, query == nil || query == "OK" else { return [] }
            return [TextMatch(text: "OK", box: CGRect(x: 0.47, y: 0.58, width: 0.06, height: 0.02), confidence: 1, exact: true)]
        }
        return (tools, reads)
    }

    /// Three looks at the same picture take one recognition, then the word one more.
    @Test func theSamePictureIsRecognizedOnce() async throws {
        let phone = PictureSequence([Self.blank, Self.blank, Self.blank, Self.word])
        let (tools, reads) = tools(phone)
        let output = try await tools.call(
            "wait_for_text", arguments: ["text": "OK", "timeout": 30], source: "test", screenshotByDefault: false)
        #expect(output.text.contains("is visible"))
        #expect(phone.looks.get() == 4)
        #expect(reads.get() == 2)
    }

    @Test func aWaitThatTimesOutStillSaysSo() async throws {
        let phone = PictureSequence([Self.blank])
        let (tools, reads) = tools(phone)
        let output = try await tools.call(
            "wait_for_text", arguments: ["text": "OK", "timeout": 0], source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text.contains("did not appear"))
        #expect(reads.get() == 1)
    }

    /// The word changes too little of the screen for FrameSignature to notice, which is why the
    /// wait compares exact pixels: equal pixels drawn again are skipped, the word is read.
    @Test func textThatAppearsBetweenTwoPollsIsFound() async throws {
        let before = try #require(FrameSignature(Self.blank)), after = try #require(FrameSignature(Self.word))
        #expect(after.changed(from: before) < 0.002)

        let phone = PictureSequence([Self.blank, Self.blankAgain, Self.word])
        let (tools, reads) = tools(phone)
        let output = try await tools.call(
            "wait_for_text", arguments: ["text": "OK", "timeout": 30], source: "test", screenshotByDefault: false)
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("is visible"))
        #expect(phone.looks.get() == 3)
        #expect(reads.get() == 2)
    }

    @Test func textThatGoesIsNoticed() async throws {
        let phone = PictureSequence([Self.word, Self.word, Self.blank])
        let (tools, reads) = tools(phone)
        let output = try await tools.call(
            "wait_for_text", arguments: ["text": "OK", "gone": true, "timeout": 30], source: "test",
            screenshotByDefault: false)
        #expect(output.text.contains("is gone"))
        #expect(reads.get() == 2)
    }

    @Test func pixelsCompareExactly() throws {
        let blank = try #require(FramePixels(Self.blank))
        #expect(blank == FramePixels(Self.blankAgain))
        #expect(blank != FramePixels(Self.word))
    }
}
