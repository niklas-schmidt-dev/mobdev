import CoreGraphics
import Foundation

/// How the AssistiveTouch pointer answers being moved to a point. It tells whether a drag becomes a
/// swipe: with Snap to Item on, iOS moves the pointer onto the nearest item and turns every drag
/// into a tap on it.
public enum PointerBehavior: String, Sendable, Equatable, Codable {
    /// A small dot appeared where it was aimed: Snap to Item is off, so drags become swipes.
    case follows
    /// An outline appeared around an item instead: Snap to Item is on, so a drag taps that item.
    case snaps
    /// Nothing appeared: AssistiveTouch is off, or the pointer is hidden.
    case hidden

    public static let snapAdvice =
        "Turn off Settings › Accessibility › Touch › AssistiveTouch › Snap to Item on the iPhone and keep Perform Touch Gestures on."

    public var summary: String {
        switch self {
        case .follows: "follows the aim, so swipes work"
        case .snaps: "snaps to items (AssistiveTouch Snap to Item is on), so swipes turn into taps. \(Self.snapAdvice)"
        case .hidden: "did not appear when moved. AssistiveTouch may be off"
        }
    }
}

/// Reads the pointer's reaction from two frames: one with the pointer parked far away and one
/// after it moved to the probe point. Only a band of rows around the point counts, so the parked
/// pointer and the status bar clock stay out of it.
public enum PointerCheck {
    /// Frames are compared at this width, about a quarter of an iPhone's.
    static let sampleWidth = 296
    /// Half the band's height, as a fraction of the screen height.
    static let bandHalfHeight = 0.1
    /// Where the pointer waits before it moves to `point`: far enough that it stays out of the band.
    public static func parking(for point: NormalizedPoint) -> NormalizedPoint {
        NormalizedPoint(x: point.x, y: point.y >= 0.5 ? point.y - 0.4 : point.y + 0.4)
    }

    /// Nil when the frames do not tell, e.g. because something else on the screen changed.
    public static func classify(before: CGImage, after: CGImage, at point: NormalizedPoint) -> PointerBehavior? {
        guard let changes = changes(before, after, around: point) else { return nil }
        guard changes.count >= 4 else { return .hidden }
        let width = Double(changes.size.width), height = Double(changes.size.height)
        let box = changes.box
        // The pointer's dot is about 4% of the screen width across.
        let dot = 0.07 * width
        let aimedX = point.x * width, aimedY = point.y * height
        if Double(box.width) <= dot, Double(box.height) <= dot, abs(Double(box.midX) - aimedX) <= dot,
            abs(Double(box.midY) - aimedY) <= dot
        {
            return .follows
        }
        // An outline around a row or button, or the pointer drawn somewhere other than aimed.
        if Double(box.width) >= 0.12 * width || abs(Double(box.midX) - aimedX) > dot
            || abs(Double(box.midY) - aimedY) > dot
        {
            return .snaps
        }
        return nil
    }

    /// Where the pointer moves for a second look: a little to the side, so it stays on the same item.
    public static func nudge(for point: NormalizedPoint) -> NormalizedPoint {
        NormalizedPoint(x: point.x <= 0.5 ? point.x + 0.04 : point.x - 0.04, y: point.y)
    }

    /// The second look, when `classify` saw more than a dot: iOS also lights up or lifts an item
    /// under a pointer that follows, which looked like a snap outline on a home screen widget
    /// (2026-10-01). The pointer then moves to `nudge` on the same item. One that follows leaves a
    /// small trail between the two points while the item stays lit; one that snaps stays put, so
    /// nothing changes. Nil when something else changed.
    public static func confirm(
        aimed: CGImage, nudged: CGImage, from point: NormalizedPoint, to nudge: NormalizedPoint
    ) -> PointerBehavior? {
        guard let changes = changes(aimed, nudged, around: point) else { return nil }
        guard changes.count >= 4 else { return .snaps }
        let width = Double(changes.size.width), height = Double(changes.size.height)
        let box = changes.box
        let dot = 0.07 * width
        let span = abs(nudge.x - point.x) * width
        let middleX = (point.x + nudge.x) / 2 * width, middleY = point.y * height
        if Double(box.width) <= dot + span, Double(box.height) <= dot, abs(Double(box.midX) - middleX) <= dot,
            abs(Double(box.midY) - middleY) <= dot
        {
            return .follows
        }
        return nil
    }

    /// Whether nothing changed between two frames around `point`, so a comparison would only see the pointer.
    public static func isStill(_ first: CGImage, _ second: CGImage, around point: NormalizedPoint) -> Bool {
        (changes(first, second, around: point)?.count ?? .max) < 4
    }

    private struct Changes {
        let count: Int
        let box: CGRect
        let size: (width: Int, height: Int)
    }

    private static func changes(_ first: CGImage, _ second: CGImage, around point: NormalizedPoint) -> Changes? {
        guard first.width == second.width, first.height == second.height, first.width > 0 else { return nil }
        let width = sampleWidth
        let height = max(1, Int((Double(first.height) * Double(width) / Double(first.width)).rounded()))
        guard let a = gray(first, width: width, height: height), let b = gray(second, width: width, height: height)
        else { return nil }
        let top = max(0, Int((point.y - bandHalfHeight) * Double(height)))
        let bottom = min(height - 1, Int((point.y + bandHalfHeight) * Double(height)))
        guard top <= bottom else { return nil }
        var count = 0
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in top...bottom {
            for x in 0..<width {
                let index = y * width + x
                guard abs(Int(a[index]) - Int(b[index])) > 36 else { continue }
                count += 1
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        let box = count > 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : .zero
        return Changes(count: count, box: box, size: (width, height))
    }

    /// Luminance, top row first.
    private static func gray(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
