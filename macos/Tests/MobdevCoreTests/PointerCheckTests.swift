import CoreGraphics
import Testing
@testable import MobdevCore

/// Frames shaped like a dark Settings screen: a row, the AssistiveTouch dot (about 44 px across on
/// a 1179 px wide screen) or the outline iOS draws around the item the pointer snapped to.
@Suite struct PointerCheckTests {
    static let width = 1179, height = 2556
    /// The middle of the row.
    let aimed = NormalizedPoint(x: 0.5, y: 1075.0 / 2556)

    static func frame(
        dotAt dot: NormalizedPoint? = nil, outline: Bool = false, changedBlock: Bool = false, lit: Bool = false
    ) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        // Top-left coordinates, like the screen.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(gray: 0.08, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // An item under a pointer that follows can light up, as home screen widgets do.
        context.setFillColor(gray: lit ? 0.32 : 0.16, alpha: 1)
        context.fill(CGRect(x: 50, y: 1000, width: 1079, height: 150))
        if let dot {
            context.setFillColor(gray: 0.55, alpha: 1)
            context.fillEllipse(
                in: CGRect(x: dot.x * Double(width) - 22, y: dot.y * Double(height) - 22, width: 44, height: 44))
        }
        if outline {
            context.setStrokeColor(gray: 1, alpha: 1)
            context.setLineWidth(6)
            context.addPath(
                CGPath(
                    roundedRect: CGRect(x: 40, y: 990, width: 1099, height: 170), cornerWidth: 30, cornerHeight: 30,
                    transform: nil))
            context.strokePath()
        }
        if changedBlock {
            context.setFillColor(gray: 0.9, alpha: 1)
            context.fill(CGRect(x: 100, y: 900, width: 900, height: 400))
        }
        return context.makeImage()!
    }

    @Test func aDotWhereAimedMeansThePointerFollows() {
        let before = Self.frame()
        #expect(PointerCheck.classify(before: before, after: Self.frame(dotAt: aimed), at: aimed) == .follows)
    }

    @Test func anOutlineAroundTheRowMeansItSnaps() {
        let before = Self.frame()
        #expect(PointerCheck.classify(before: before, after: Self.frame(outline: true), at: aimed) == .snaps)
    }

    @Test func aDotAwayFromTheAimMeansItSnaps() {
        let before = Self.frame()
        let elsewhere = NormalizedPoint(x: 0.15, y: aimed.y)
        #expect(PointerCheck.classify(before: before, after: Self.frame(dotAt: elsewhere), at: aimed) == .snaps)
    }

    /// Seen on a home screen widget: the dot plus the widget lighting up looked like a snap at first.
    @Test func anItemThatLightsUpUnderAFollowingPointerIsToldApartByASecondLook() {
        let lit = Self.frame(dotAt: aimed, lit: true)
        #expect(PointerCheck.classify(before: Self.frame(), after: lit, at: aimed) == .snaps)
        let nudge = PointerCheck.nudge(for: aimed)
        #expect(
            PointerCheck.confirm(aimed: lit, nudged: Self.frame(dotAt: nudge, lit: true), from: aimed, to: nudge)
                == .follows)
    }

    @Test func aSnappedOutlineStaysWhenThePointerMovesOn() {
        let outline = Self.frame(outline: true)
        let nudge = PointerCheck.nudge(for: aimed)
        #expect(PointerCheck.confirm(aimed: outline, nudged: Self.frame(outline: true), from: aimed, to: nudge) == .snaps)
        #expect(
            PointerCheck.confirm(aimed: outline, nudged: Self.frame(outline: true, changedBlock: true), from: aimed, to: nudge)
                == nil)
    }

    @Test func noChangeMeansThePointerIsHidden() {
        let before = Self.frame()
        #expect(PointerCheck.classify(before: before, after: Self.frame(), at: aimed) == .hidden)
    }

    @Test func aScreenThatChangesByItselfIsNotStill() {
        let before = Self.frame()
        #expect(PointerCheck.isStill(before, Self.frame(), around: aimed))
        #expect(!PointerCheck.isStill(before, Self.frame(changedBlock: true), around: aimed))
    }

    @Test func theParkedPointerStaysOutOfTheComparedBand() {
        for y in [0.1, 0.45, 0.5, 0.9] {
            let parked = PointerCheck.parking(for: NormalizedPoint(x: 0.5, y: y))
            #expect(abs(parked.y - y) > 2 * PointerCheck.bandHalfHeight)
            #expect((0.05...0.95).contains(parked.y))
        }
    }
}
