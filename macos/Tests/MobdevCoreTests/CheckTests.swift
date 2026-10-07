import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MobdevCore

/// Screens drawn for the checks: white, with rectangles and text placed from the top-left.
enum Canvas {
    static func image(width: Int = 1179, height: Int = 2556, _ draw: (CGContext) -> Void = { _ in }) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return context.makeImage()!
    }

    /// Fills a rectangle given from the top-left.
    static func fill(_ context: CGContext, _ rect: CGRect, _ color: CGColor) {
        context.setFillColor(color)
        context.fill(CGRect(x: rect.minX, y: CGFloat(context.height) - rect.maxY, width: rect.width, height: rect.height))
    }

    /// Text with its baseline at y from the top.
    static func text(_ context: CGContext, _ text: String, x: CGFloat, baseline y: CGFloat, size: CGFloat = 64, color: CGColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        context.textPosition = CGPoint(x: x, y: CGFloat(context.height) - y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }

    static let black = CGColor(gray: 0, alpha: 1)
    static let blue = CGColor(red: 0, green: 0.48, blue: 1, alpha: 1)

    /// A sign-in screen with a status bar clock, a title, a field and a button at `buttonY`.
    static func signIn(buttonY: CGFloat = 1400, clock: String = "9:41", title: String = "Welcome back") -> CGImage {
        image { context in
            text(context, clock, x: 120, baseline: 110, size: 50, color: black)
            text(context, title, x: 90, baseline: 420, size: 96, color: black)
            fill(context, CGRect(x: 90, y: 700, width: 1000, height: 140), CGColor(gray: 0.93, alpha: 1))
            text(context, "Email", x: 130, baseline: 790, size: 56, color: CGColor(gray: 0.45, alpha: 1))
            fill(context, CGRect(x: 90, y: buttonY, width: 1000, height: 150), blue)
            text(context, "Continue", x: 440, baseline: buttonY + 95, size: 60, color: CGColor(gray: 1, alpha: 1))
        }
    }

    /// The image after a round trip through JPEG at `quality`.
    static func jpeg(_ image: CGImage, quality: Double) -> CGImage {
        let data = ImageTools.encode(image, quality: quality)!.data
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }
}

/// A phone whose screen a test draws and changes, with a UI tree where there is one.
final class CanvasPhone: PhoneBackend, @unchecked Sendable {
    let screen: Locked<CGImage>
    let tree: [UIElement]?
    let scale: Double?
    let input: InputRoute

    init(_ image: CGImage, tree: [UIElement]? = nil, scale: Double? = nil, input: InputRoute = .direct("Simulator")) {
        screen = Locked(image)
        self.tree = tree
        self.scale = scale
        self.input = input
    }

    func status() -> PhoneStatus {
        let image = screen.get()
        return PhoneStatus(
            screen: .connected(name: "Canvas", width: image.width, height: image.height),
            bluetooth: .unsupported("not needed"), keyboardLayout: .us, input: input)
    }

    func frame() -> CGImage? { screen.get() }
    func uiTree() async throws -> [UIElement]? { tree }
    func screenScale() async -> Double? { scale }
    func tap(at point: NormalizedPoint, hold: TimeInterval) async throws {}
    func swipe(from start: NormalizedPoint, to end: NormalizedPoint, duration: TimeInterval) async throws {}
    func scroll(at point: NormalizedPoint, ticks: Int) async throws {}
    func pan(at point: NormalizedPoint, ticks: Int) async throws {}
    func type(_ strokes: [KeyStroke]) async throws {}
    func press(_ stroke: KeyStroke) async throws {}
    func press(_ button: ConsumerUsage) async throws {}
}

/// Answers with what it was given, and remembers the question.
final class FakeJudge: ScreenJudge, @unchecked Sendable {
    let result: Result<ScreenJudgement, ToolFailure>
    let asked = Locked<[(question: String, text: String)]>([])

    init(_ result: Result<ScreenJudgement, ToolFailure>) { self.result = result }

    func judge(_ question: String, screenshot: CGImage, screenText: String) async throws -> ScreenJudgement {
        asked.withLock { $0.append((question, screenText)) }
        return try result.get()
    }
}

func checkTools(_ phone: any PhoneBackend, judge: any ScreenJudge = FakeJudge(.failure(ToolFailure("no judge")))) -> PhoneTools {
    PhoneTools(phone: phone, activity: ActivityLog(), settleDelay: 0, judge: judge) { _, _ in [] }
}

func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mobdev-checks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Image comparison

@Suite struct ImageDiffTests {
    func pixels(_ image: CGImage) -> PixelBuffer {
        let small = ImageTools.scaled(image, longEdge: ScreenGeometry.screenshotLongEdge)
        return PixelBuffer(small)!
    }

    @Test func identicalScreensDoNotDiffer() {
        let screen = pixels(Canvas.signIn())
        let comparison = ImageDiff.compare(screen, screen)
        #expect(comparison.changedPixels == 0)
        #expect(comparison.regions.isEmpty)
        #expect(comparison.comparedPixels == screen.width * screen.height)
    }

    @Test func compressionAndAntialiasingAreNoise() {
        let screen = pixels(Canvas.signIn())
        let compressed = pixels(Canvas.jpeg(Canvas.signIn(), quality: 0.8))
        #expect(ImageDiff.compare(compressed, screen).changedShare < PhoneTools.screenshotThreshold)
        // Text and edges up to a pixel to the side, as another rendering pass might put them, are
        // the same; three pixels are a change.
        func shifted(_ distance: Double) -> PixelBuffer {
            pixels(
                Canvas.image { context in
                    context.translateBy(x: distance, y: distance)
                    context.draw(Canvas.signIn(), in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
                })
        }
        #expect(ImageDiff.compare(shifted(0.5), screen).changedPixels == 0)
        #expect(ImageDiff.compare(shifted(1), screen).changedPixels == 0)
        #expect(ImageDiff.compare(shifted(3), screen).changedShare > PhoneTools.screenshotThreshold)
    }

    @Test func aMovedButtonAndChangedTextAreChanges() throws {
        let screen = pixels(Canvas.signIn())
        let moved = ImageDiff.compare(pixels(Canvas.signIn(buttonY: 1440)), screen)
        #expect(moved.changedShare > PhoneTools.screenshotThreshold)
        // The regions are where the button's edges and label moved, in screenshot pixels.
        let region = try #require(moved.regions.first)
        #expect(region.minY >= 650 && region.maxY <= 816)

        let retitled = ImageDiff.compare(pixels(Canvas.signIn(title: "Welcome home")), screen)
        #expect(retitled.changedShare > PhoneTools.screenshotThreshold)
        #expect(retitled.regions.allSatisfy { $0.maxY < 250 })
    }

    @Test func masksLeaveAreasOut() {
        let screen = pixels(Canvas.signIn())
        let moved = pixels(Canvas.signIn(buttonY: 1440))
        let masked = ImageDiff.compare(moved, screen, masks: [CGRect(x: 0, y: 650, width: 590, height: 150)])
        #expect(masked.changedPixels == 0)
        #expect(masked.comparedPixels == screen.width * screen.height - 590 * 150)

        let picture = ImageDiff.picture(of: ImageDiff.compare(moved, screen), over: moved)
        #expect(picture?.width == screen.width)
        #expect(picture?.height == screen.height)
    }
}

// MARK: - assert_screenshot

@Suite struct AssertScreenshotTests {
    @Test func recordsComparesFailsAndUpdates() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let phone = CanvasPhone(Canvas.signIn())
        let tools = checkTools(phone)
        let path = folder.appendingPathComponent("shots/sign-in.png").path
        func assert(_ arguments: JSONValue = [:]) async throws -> ToolOutput {
            var object = arguments.objectValue ?? [:]
            object["path"] = .string(path)
            return try await tools.call("assert_screenshot", arguments: .object(object), source: "test", screenshotByDefault: false)
        }

        // The first run records the baseline at screenshot size and passes.
        let recorded = try await assert()
        #expect(!recorded.isError)
        #expect(recorded.text.hasPrefix("Recorded a new baseline \(path)"))
        let baseline = try #require(ImageDiff.load(URL(fileURLWithPath: path)))
        #expect((baseline.width, baseline.height) == (590, 1280))

        let same = try await assert()
        #expect(!same.isError)
        #expect(same.text.contains("matches the baseline sign-in.png: 0% of pixels changed"))

        // The clock in the status bar changes on its own and is left out.
        phone.screen.set(Canvas.signIn(clock: "10:02"))
        #expect(!(try await assert()).isError)
        #expect(try await assert(["compare_status_bar": true]).isError)

        // A moved button fails with a diff next to the baseline.
        phone.screen.set(Canvas.signIn(buttonY: 1440))
        let failed = try await assert()
        #expect(failed.isError)
        #expect(failed.text.contains("differs from the baseline \(path)"))
        #expect(failed.image?.mimeType == "image/jpeg")
        let diff = folder.appendingPathComponent("shots/sign-in-diff.png").path
        let actual = folder.appendingPathComponent("shots/sign-in-actual.png").path
        #expect(failed.data?["diff"]?.stringValue == diff)
        #expect(FileManager.default.fileExists(atPath: diff))
        #expect(FileManager.default.fileExists(atPath: actual))
        #expect(failed.text.contains("Diff (changed pixels in red): \(diff)"))

        // A mask over the button lets it pass, and a passing run removes the stale files.
        let masked = try await assert(["mask": [[0, 650, 590, 150]]])
        #expect(!masked.isError)
        #expect(!FileManager.default.fileExists(atPath: diff))
        #expect(try await assert(["threshold": 0.5]).isError == false)

        // update: true takes the new screen as the baseline.
        let updated = try await assert(["update": true])
        #expect(updated.text.hasPrefix("Updated the baseline"))
        #expect(!(try await assert()).isError)
    }

    @Test func masksElementsByIdOrLabel() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let button = UIElement(
            role: "Button", label: "Continue", identifier: "continue", value: "",
            frame: CGRect(x: 90.0 / 1179, y: 1400.0 / 2556, width: 1000.0 / 1179, height: 190.0 / 2556), enabled: true,
            tappable: true)
        let phone = CanvasPhone(Canvas.signIn(), tree: [button])
        let tools = checkTools(phone)
        let path = folder.appendingPathComponent("a.png").path
        _ = try await tools.call("assert_screenshot", arguments: ["path": .string(path)], source: "test", screenshotByDefault: false)
        phone.screen.set(Canvas.signIn(buttonY: 1420))
        for mask in ["continue", "Continue"] {
            let output = try await tools.call(
                "assert_screenshot", arguments: ["path": .string(path), "mask": [.string(mask)]], source: "test",
                screenshotByDefault: false)
            #expect(!output.isError, "mask \(mask): \(output.text)")
        }
        let unmatched = try await tools.call(
            "assert_screenshot", arguments: ["path": .string(path), "mask": ["nothing"]], source: "test", screenshotByDefault: false)
        #expect(unmatched.isError)
        #expect(unmatched.text.contains("Nothing on screen matched the mask \"nothing\"."))
    }

    @Test func rejectsMistakes() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let phone = CanvasPhone(Canvas.signIn())
        let tools = checkTools(phone)
        func call(_ arguments: JSONValue) async throws -> ToolOutput {
            try await tools.call("assert_screenshot", arguments: arguments, source: "test", screenshotByDefault: false)
        }
        #expect(try await call([:]).text.contains("Pass name"))
        #expect(try await call(["path": "relative.png"]).isError)
        #expect(try await call(["name": "../up"]).isError)
        #expect(try await call(["path": "/tmp/x.png", "name": "x"]).isError)
        #expect(try await call(["path": "/tmp/x.png", "mask": [[1, 2, 3]]]).text.contains("Each mask item"))

        // A baseline of another shape is another device or orientation.
        let path = folder.appendingPathComponent("wide.png")
        try ImageTools.encode(Canvas.image(width: 2556, height: 1179), png: true)!.data.write(to: path)
        let rotated = try await call(["path": .string(path.path)])
        #expect(rotated.isError)
        #expect(rotated.text.contains("is 2556×1179 px, but the screen is 590×1280 px"))

        // A full-size baseline of the same shape is scaled to the screenshot.
        let full = folder.appendingPathComponent("full.png")
        try ImageTools.encode(Canvas.signIn(), png: true)!.data.write(to: full)
        #expect(!(try await call(["path": .string(full.path)])).isError)
    }

    @Test func namesResolveInTheRunningProjectOrMobdevsFolder() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = checkTools(CanvasPhone(Canvas.signIn()))
        let frame = Canvas.signIn()
        let outside = try tools.baselineURL(Arguments(["name": "login"]), frame: frame)
        #expect(outside.url.path == MobdevPaths.home.appendingPathComponent("baselines/ios/1179x2556/login.png").path)
        #expect(outside.artifacts == nil)

        let artifacts = folder.appendingPathComponent("out/sign-in")
        let context = CheckContext(root: folder, artifacts: artifacts)
        try await CheckContext.$current.withValue(context) {
            let inside = try tools.baselineURL(Arguments(["name": "login.png"]), frame: frame)
            #expect(inside.url.path == folder.appendingPathComponent("baselines/ios/1179x2556/login.png").path)
            _ = try await tools.call("assert_screenshot", arguments: ["name": "login"], source: "test", screenshotByDefault: false)
            let android = checkTools(CanvasPhone(Canvas.signIn(buttonY: 1500), input: .direct("adb")))
            #expect(try android.baselineURL(Arguments(["name": "login"]), frame: frame).url.path.contains("/baselines/android/"))
        }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("baselines/ios/1179x2556/login.png").path))
        #expect(context.files.get().isEmpty)

        // A flow file's baselines live next to it.
        let flows = folder.appendingPathComponent("flows")
        try FileManager.default.createDirectory(at: flows, withIntermediateDirectories: true)
        try Data("{\"steps\": [{\"assert_screenshot\": {\"name\": \"start\"}}]}".utf8).write(to: flows.appendingPathComponent("look.json"))
        let ran = try await tools.call(
            "run_flow", arguments: ["path": .string(flows.appendingPathComponent("look.json").path)], source: "test",
            screenshotByDefault: false)
        #expect(!ran.isError)
        #expect(FileManager.default.fileExists(atPath: flows.appendingPathComponent("baselines/ios/1179x2556/start.png").path))
    }

    @Test func aFailedComparisonInATestIsListedWithTheTest() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tests"), withIntermediateDirectories: true)
        try Data("{\"name\": \"Screens\"}".utf8).write(to: root.appendingPathComponent("mobdev.json"))
        try Data("{\"name\": \"Sign in looks right\", \"steps\": [{\"assert_screenshot\": {\"name\": \"sign-in\"}}]}".utf8)
            .write(to: root.appendingPathComponent("tests/looks.json"))
        let project = try TestProject.load(root)
        let phone = CanvasPhone(Canvas.signIn())
        let tools = checkTools(phone)

        let first = await tools.runTests(project, options: TestRunOptions(output: root.appendingPathComponent("run1"), video: false), source: "test")
        #expect(first.passed)
        #expect(first.tests[0].steps[0].text.hasPrefix("Recorded a new baseline \(root.path)/baselines/ios/1179x2556/sign-in.png"))
        #expect(first.tests[0].files == nil)

        phone.screen.set(Canvas.signIn(title: "Welcome home"))
        let output = root.appendingPathComponent("run2")
        let second = await tools.runTests(project, options: TestRunOptions(output: output, video: false), source: "test")
        #expect(!second.passed)
        let test = second.tests[0]
        let files = [output.appendingPathComponent("looks/sign-in-diff.png").path, output.appendingPathComponent("looks/sign-in-actual.png").path]
        #expect(test.files == files)
        #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        #expect(second.text.contains("  File: \(files[0])"))
        // results.json keeps them, and older results without files still load.
        #expect(try TestRunResult.load(output).tests[0].files == files)
        #expect(try TestRunResult.load(root.appendingPathComponent("run1")).tests[0].files == nil)
    }
}

// MARK: - accessibility_audit

@Suite struct AccessibilityAuditTests {
    /// An element from a frame in pixels of a 1179×2556 screen.
    static func element(
        _ role: String, _ label: String = "", id: String = "", _ x: Double, _ y: Double, _ width: Double, _ height: Double,
        tappable: Bool = true, enabled: Bool = true
    ) -> UIElement {
        UIElement(
            role: role, label: label, identifier: id, value: "",
            frame: CGRect(x: x / 1179, y: y / 2556, width: width / 1179, height: height / 2556), enabled: enabled,
            tappable: tappable)
    }

    func audit(_ elements: [UIElement], android: Bool = false, pixels: PixelBuffer? = nil) -> [AccessibilityIssue] {
        AccessibilityAudit(elements: elements, android: android, scale: 3, screen: (1179, 2556), pixels: pixels).run()
    }

    @Test func findsUnlabeledTargetsButNotRowsWithText() {
        let issues = audit([
            Self.element("Button", id: "close", 1000, 150, 150, 150),
            Self.element("Cell", "", 0, 600, 1179, 200),
            Self.element("StaticText", "Wi-Fi", 60, 650, 300, 80, tappable: false),
            Self.element("TextField", "", 60, 900, 1000, 150),
            Self.element("Application", "", 0, 0, 1179, 2556),
        ])
        #expect(issues.map(\.rule) == ["missing_label", "missing_label"])
        #expect(issues[0].severity == .error)
        #expect(issues[0].element.identifier == "close")
        #expect(issues[0].message.contains("accessibilityLabel"))
        #expect(issues[1].severity == .warning)
        #expect(issues[1].element.role == "TextField")
        #expect(audit([Self.element("ImageButton", "", 10, 10, 200, 200)], android: true)[0].message.contains("TalkBack"))
    }

    @Test func measuresTapTargetsInPointsOrDp() {
        let issues = audit([
            Self.element("Button", "Big", 0, 300, 300, 150),
            Self.element("Button", "Small", 0, 600, 90, 90),
            Self.element("Button", "Tiny", 0, 900, 60, 60),
        ])
        // Top to bottom.
        #expect(issues.map(\.element.label) == ["Small", "Tiny"])
        #expect(issues.map(\.severity) == [.warning, .error])
        #expect(issues[0].message.hasPrefix("Tap target of 30×30 pt, below 44×44 pt."))
        #expect(issues[1].message.contains("WCAG's minimum of 24×24"))
        // 132 px is 44 pt at 3 px per pt, but only 44 dp at 3 px per dp: below Android's 48.
        let android = audit([Self.element("Button", "Edge", 0, 300, 132, 132)], android: true)
        #expect(android.map(\.rule) == ["small_target"])
        #expect(audit([Self.element("Button", "Edge", 0, 300, 132, 132)]).isEmpty)
    }

    @Test func findsDuplicateAndUnclearLabels() {
        let issues = audit([
            Self.element("Button", "Delete", 0, 300, 300, 150),
            Self.element("Button", "delete", 0, 600, 300, 150),
            // The label inside the second button repeats it; that is one target.
            Self.element("Button", "Delete", 10, 610, 280, 130),
            Self.element("Button", "ic_close.png", 600, 300, 150, 150),
            Self.element("Button", "closeButton", 600, 600, 150, 150),
            Self.element("Image", "chevron.right", 600, 900, 150, 150, tappable: false),
            Self.element("Button", "iPhone", 600, 1200, 300, 150),
            Self.element("StaticText", "user_name", 0, 1200, 300, 150, tappable: false),
        ])
        let byRule = Dictionary(grouping: issues, by: \.rule)
        #expect(byRule["duplicate_label"]?.count == 1)
        #expect(byRule["duplicate_label"]?[0].others.count == 1)
        #expect(byRule["duplicate_label"]?[0].message.hasPrefix("2 targets are all labeled \"Delete\"") == true)
        #expect(byRule["unclear_label"]?.map(\.element.label).sorted() == ["chevron.right", "closeButton", "ic_close.png"])
        #expect(byRule["unclear_label"]?.first { $0.element.label == "ic_close.png" }?.severity == .error)
        #expect(AccessibilityAudit.isIdentifierLike("IMG_0042"))
        #expect(AccessibilityAudit.isIdentifierLike("com.example:id/close"))
        #expect(AccessibilityAudit.isIdentifierLike("Button"))
        #expect(!AccessibilityAudit.isIdentifierLike("Sign in"))
        #expect(!AccessibilityAudit.isIdentifierLike("YouTube"))
        #expect(!AccessibilityAudit.isIdentifierLike("mobdev.sh"))
    }

    @Test func measuresTextContrastFromThePixels() throws {
        let grays: [(String, Double)] = [("Black", 0), ("Mid", 0.53), ("Pale", 0.75), ("Fine", 0.40)]
        let screen = Canvas.image { context in
            for (index, (text, gray)) in grays.enumerated() {
                let color = CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
                Canvas.text(context, text, x: 60, baseline: 400 + Double(index) * 300, size: 64, color: color)
            }
            let darkBlue = CGColor(red: 0, green: 0.35, blue: 0.8, alpha: 1)
            Canvas.fill(context, CGRect(x: 60, y: 1500, width: 600, height: 150), darkBlue)
            Canvas.text(context, "Go", x: 300, baseline: 1600, size: 64, color: CGColor(gray: 1, alpha: 1))
        }
        let elements = grays.enumerated().map { index, entry in
            Self.element("StaticText", entry.0, 50, 330 + Double(index) * 300, 400, 100, tappable: false)
        } + [
            Self.element("Button", "Go", 60, 1500, 600, 150),
            // Disabled text is exempt, as in WCAG: this one covers the pale text.
            Self.element("StaticText", "Off", 50, 930, 400, 100, tappable: false, enabled: false),
        ]
        let issues = audit(elements, pixels: PixelBuffer(screen)).filter { $0.rule == "low_contrast" }
        #expect(issues.map(\.element.label) == ["Mid", "Pale"])
        #expect(issues.map(\.severity) == [.warning, .error])
        #expect(issues[0].message.hasPrefix("Text contrast about 3."))
        #expect(issues[0].message.contains("on #FFFFFF"))

        let black = CGRect(x: 50, y: 330, width: 400, height: 100)
        let measured = try #require(AccessibilityAudit.contrast(in: PixelBuffer(screen)!, rect: black))
        #expect(measured.ratio > 19)
        #expect(abs(AccessibilityAudit.contrastRatio([118, 118, 118], [255, 255, 255]) - 4.54) < 0.01)
    }

    @Test func estimatesTheScreenScale() {
        #expect(AccessibilityAudit.estimatedScale(width: 1179, height: 2556, android: false) == 3)
        #expect(AccessibilityAudit.estimatedScale(width: 2556, height: 1179, android: false) == 3)
        #expect(AccessibilityAudit.estimatedScale(width: 828, height: 1792, android: false) == 2)
        #expect(AccessibilityAudit.estimatedScale(width: 1640, height: 2360, android: false) == 2)
        #expect(abs(AccessibilityAudit.estimatedScale(width: 1080, height: 2400, android: true) - 2.63) < 0.01)
        #expect(AndroidDevice.parseDensity("Physical density: 420\n") == 420)
        #expect(AndroidDevice.parseDensity("Physical density: 420\r\nOverride density: 480\r\n") == 480)
        #expect(AndroidDevice.parseDensity("nothing") == nil)
    }

    @Test func theToolListsIssuesDrawsThemAndFailsOnRequest() async throws {
        let tree = [
            Self.element("Button", id: "close", 1000, 150, 150, 150),
            Self.element("Button", "Small", 0, 600, 90, 90),
        ]
        let tools = checkTools(CanvasPhone(Canvas.image(), tree: tree, scale: 3))
        let listed = try await tools.call("accessibility_audit", arguments: [:], source: "test", screenshotByDefault: false)
        #expect(!listed.isError)
        #expect(listed.text.hasPrefix("Accessibility audit of 2 elements: 1 error, 1 warning."))
        #expect(listed.text.contains("[1] error missing_label: Button id=close at (538, 113)."))
        #expect(listed.text.contains("[2] warning small_target: Button \"Small\" at (23, 323)."))
        #expect(listed.data?["issues"]?.arrayValue?.count == 2)
        #expect(listed.image == nil)

        let drawn = try await tools.call("accessibility_audit", arguments: ["image": true], source: "test", screenshotByDefault: false)
        #expect(drawn.image?.height == 1280)
        let failing = try await tools.call("accessibility_audit", arguments: ["fail_on": "error"], source: "test", screenshotByDefault: false)
        #expect(failing.isError)
        #expect(failing.text.hasSuffix("Fails with fail_on error: 1 error."))
        let ignoring = try await tools.call(
            "accessibility_audit", arguments: ["fail_on": "warning", "ignore": ["missing_label", "small_target"]], source: "test",
            screenshotByDefault: false)
        #expect(!ignoring.isError)
        #expect(ignoring.text.hasPrefix("No accessibility issues in 2 elements."))
        #expect(try await tools.call("accessibility_audit", arguments: ["ignore": ["nope"]], source: "test", screenshotByDefault: false).isError)

        let noTree = try await checkTools(CanvasPhone(Canvas.image())).call(
            "accessibility_audit", arguments: [:], source: "test", screenshotByDefault: false)
        #expect(noTree.isError)
        #expect(noTree.text.contains("no UI tree"))
    }

    @Test func recordedFlowsKeepChecksButNotLooks() {
        let recorder = FlowRecorder()
        recorder.start()
        recorder.record("accessibility_audit", ["image": true])
        recorder.record("accessibility_audit", ["fail_on": "error"])
        recorder.record("assert_screenshot", ["name": "home"])
        recorder.record("assert_with_ai", ["question": "Is it blue?"])
        #expect(recorder.stop().map(\.tool) == ["accessibility_audit", "assert_screenshot", "assert_with_ai"])
    }
}

// MARK: - assert_with_ai

@Suite struct AssertWithAITests {
    @Test func passesFailsAndSaysWhy() async throws {
        let tree = [AccessibilityAuditTests.element("Button", "Sign in", 90, 1400, 1000, 150)]
        let phone = CanvasPhone(Canvas.signIn(), tree: tree)
        let yes = FakeJudge(.success(ScreenJudgement(answer: .yes, reason: "The button is fully visible.", sawImage: true)))
        let passed = try await checkTools(phone, judge: yes).call(
            "assert_with_ai", arguments: ["question": "Is the Sign in button visible?"], source: "test", screenshotByDefault: false)
        #expect(!passed.isError)
        #expect(passed.text == "Yes, as expected: The button is fully visible. (Apple Intelligence on this Mac, from the screenshot.)")
        #expect(passed.image == nil)
        let asked = try #require(yes.asked.get().first)
        #expect(asked.question == "Is the Sign in button visible?")
        #expect(asked.text.contains("[1] Button 'Sign in' (295, 739)"))

        let expectNo = try await checkTools(phone, judge: yes).call(
            "assert_with_ai", arguments: ["question": "Is any text cut off?", "expect": "no"], source: "test",
            screenshotByDefault: false)
        #expect(expectNo.isError)
        #expect(expectNo.text.hasPrefix("Expected no, but the answer is yes: "))
        #expect(expectNo.image?.mimeType == "image/jpeg")
        #expect(expectNo.data?["passed"]?.boolValue == false)

        let textOnly = FakeJudge(.success(ScreenJudgement(answer: .no, reason: "No error is shown.", sawImage: false)))
        let fromText = try await checkTools(phone, judge: textOnly).call(
            "assert_with_ai", arguments: ["question": "Is an error shown?", "expect": "no"], source: "test", screenshotByDefault: false)
        #expect(!fromText.isError)
        #expect(fromText.text.contains("from the screen's text: this Mac's model takes no images"))

        let unsure = FakeJudge(.success(ScreenJudgement(answer: .unsure, reason: "The screen is blank.", sawImage: true)))
        let notSure = try await checkTools(phone, judge: unsure).call(
            "assert_with_ai", arguments: ["question": "Is it dark mode?", "expect": "no"], source: "test", screenshotByDefault: false)
        #expect(notSure.isError)
        #expect(notSure.text.hasPrefix("Apple Intelligence could not tell from the screen: The screen is blank."))
    }

    @Test func saysWhenAppleIntelligenceIsUnavailable() async throws {
        let off = FakeJudge(.failure(ToolFailure("Apple Intelligence is turned off on this Mac.")))
        let output = try await checkTools(CanvasPhone(Canvas.signIn()), judge: off).call(
            "assert_with_ai", arguments: ["question": "Is it blue?"], source: "test", screenshotByDefault: false)
        #expect(output.isError)
        #expect(output.text == "Apple Intelligence is turned off on this Mac.")
        let bad = try await checkTools(CanvasPhone(Canvas.signIn()), judge: off).call(
            "assert_with_ai", arguments: ["question": "Is it blue?", "expect": "maybe"], source: "test", screenshotByDefault: false)
        #expect(bad.text == "expect must be yes or no.")
    }

    #if canImport(FoundationModels)
    @Test func explainsEachReasonTheModelIsUnavailable() {
        #expect(AppleIntelligenceJudge.message(for: .appleIntelligenceNotEnabled).contains("System Settings › Apple Intelligence & Siri"))
        #expect(AppleIntelligenceJudge.message(for: .modelNotReady).contains("Try again in a few minutes"))
        #expect(AppleIntelligenceJudge.message(for: .deviceNotEligible).contains("cannot run Apple Intelligence"))
    }
    #endif
}
