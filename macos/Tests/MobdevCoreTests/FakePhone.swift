import CoreGraphics
import CoreText
import Foundation
@testable import MobdevCore

/// A phone that renders a static screen with text and records every input.
final class FakePhone: PhoneBackend, @unchecked Sendable {
    enum Event: Equatable {
        case tap(NormalizedPoint, TimeInterval)
        case swipe(NormalizedPoint, NormalizedPoint)
        case scroll(Int)
        case type([KeyStroke])
        case key(KeyStroke)
        case button(ConsumerUsage)
    }

    let image: CGImage
    let events = Locked<[Event]>([])
    let bluetoothConnected: Bool
    let layout: KeyboardLayout

    /// Text lines drawn at (x, y) in pixels from the top-left of a 1179×2556 screen.
    init(lines: [(String, CGFloat, CGFloat)], bluetoothConnected: Bool = true, layout: KeyboardLayout = .us) {
        image = Self.render(lines: lines, width: 1179, height: 2556)
        self.bluetoothConnected = bluetoothConnected
        self.layout = layout
    }

    func status() -> PhoneStatus {
        PhoneStatus(
            screen: .connected(name: "Fake iPhone", width: image.width, height: image.height),
            bluetooth: bluetoothConnected ? .connected(hosts: 1) : .advertising, keyboardLayout: layout)
    }

    func frame() -> CGImage? { image }

    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws {
        events.withLock { $0.append(.tap(point, hold)) }
    }

    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {
        events.withLock { $0.append(.swipe(start, end)) }
    }

    func scroll(at point: NormalizedPoint, ticks: Int) async throws {
        events.withLock { $0.append(.scroll(ticks)) }
    }

    func type(_ strokes: [KeyStroke]) async throws {
        events.withLock { $0.append(.type(strokes)) }
    }

    func press(_ stroke: KeyStroke) async throws {
        events.withLock { $0.append(.key(stroke)) }
    }

    func press(_ button: ConsumerUsage) async throws {
        events.withLock { $0.append(.button(button)) }
    }

    static func render(lines: [(String, CGFloat, CGFloat)], width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        for (text, x, y) in lines {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                    red: 0, green: 0, blue: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            // Core Graphics has a bottom-left origin; y is the text's vertical center from the top.
            context.textPosition = CGPoint(x: x, y: CGFloat(height) - y - 22)
            CTLineDraw(line, context)
        }
        return context.makeImage()!
    }
}

/// Records HID reports without Bluetooth.
final class RecordingSink: ReportSink, @unchecked Sendable {
    let reports = Locked<[(ReportID, [UInt8])]>([])
    var connected = true

    func send(_ id: ReportID, _ bytes: [UInt8]) throws {
        guard connected else { throw HIDError.notConnected }
        reports.withLock { $0.append((id, bytes)) }
    }
}
