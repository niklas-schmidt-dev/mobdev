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
        case pan(Int)
        case type([KeyStroke])
        case key(KeyStroke)
        case button(ConsumerUsage)
        case checkPointer(NormalizedPoint)
    }

    let image: CGImage
    let events = Locked<[Event]>([])
    let bluetoothConnected: Bool
    let layout: KeyboardLayout
    let apps: AppBackend?
    /// What `checkPointer` finds; the last result also shows in `status()`.
    let pointerCheckResult: PointerBehavior?
    let pointer = Locked<PointerBehavior?>(nil)
    /// What `uiTree` returns; nil like an iPhone.
    let tree: [UIElement]?
    /// How many reads fail first, like a busy simulator's.
    let unreadableReads = Locked(0)

    /// Text lines drawn at (x, y) in pixels from the top-left of a 1179×2556 screen.
    init(
        lines: [(String, CGFloat, CGFloat)], bluetoothConnected: Bool = true, layout: KeyboardLayout = .us,
        apps: AppBackend? = nil, pointerCheckResult: PointerBehavior? = nil, tree: [UIElement]? = nil
    ) {
        image = Self.render(lines: lines, width: 1179, height: 2556)
        self.bluetoothConnected = bluetoothConnected
        self.layout = layout
        self.apps = apps
        self.pointerCheckResult = pointerCheckResult
        self.tree = tree
    }

    func uiTree() async throws -> [UIElement]? {
        let unreadable = unreadableReads.withLock { count -> Bool in
            defer { count = max(0, count - 1) }
            return count > 0
        }
        if unreadable { throw DeveloperError("The simulator's app has no size yet.") }
        return tree
    }

    func status() -> PhoneStatus {
        PhoneStatus(
            screen: .connected(name: "Fake iPhone", width: image.width, height: image.height),
            bluetooth: bluetoothConnected ? .connected(hosts: 1) : .advertising, keyboardLayout: layout,
            pointer: pointer.get())
    }

    func checkPointer(at point: NormalizedPoint) async throws -> PointerBehavior? {
        events.withLock { $0.append(.checkPointer(point)) }
        if let pointerCheckResult { pointer.set(pointerCheckResult) }
        return pointerCheckResult
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

    func pan(at point: NormalizedPoint, ticks: Int) async throws {
        events.withLock { $0.append(.pan(ticks)) }
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

/// An app backend with no apps that remembers the URLs it was asked to open, and logs each under
/// `app` as if the app had printed it.
final class FakeApps: AppBackend, @unchecked Sendable {
    let logs = AppLogs()
    let platform: AppPlatform
    let app: String
    let opened = Locked<[URL]>([])

    init(platform: AppPlatform = .simulator, app: String = "dev.mobdev.fixture") {
        self.platform = platform
        self.app = app
    }

    func activate(_ bundleID: String) async throws {}
    func apps(all: Bool) async throws -> [InstalledApp] { [] }
    func app(_ bundleID: String) async throws -> InstalledApp? { nil }
    func install(at path: URL) async throws -> InstalledApp { throw DeveloperError("FakeApps installs nothing.") }
    func uninstall(_ bundleID: String) async throws -> InstalledApp { throw DeveloperError("FakeApps has no apps.") }
    func launch(_ bundleID: String, arguments: [String], environment: [String: String], restart: Bool) async throws
        -> LaunchOutcome
    { .launched }
    func stop(_ bundleID: String) async throws -> Bool { false }
    func open(_ url: URL) async throws {
        opened.withLock { $0.append(url) }
        logs.append(app: app, text: "fixture: opened \(url.absoluteString)")
    }
    func crashReports() async throws -> [CrashReportFile] { [] }
    func crashReport(named name: String) async throws -> (report: CrashReport?, file: URL) {
        throw DeveloperError("FakeApps has no reports.")
    }
}

/// Records HID reports without Bluetooth.
final class RecordingSink: ReportSink, @unchecked Sendable {
    let reports = Locked<[(ReportID, [UInt8])]>([])
    var connected = true
    /// Reports the iPhone has not subscribed to yet.
    var unsubscribed: Set<ReportID> = []

    func send(_ id: ReportID, _ bytes: [UInt8]) throws {
        guard connected else { throw HIDError.notConnected }
        guard !unsubscribed.contains(id) else { throw HIDError.notSubscribed(id) }
        reports.withLock { $0.append((id, bytes)) }
    }
}
