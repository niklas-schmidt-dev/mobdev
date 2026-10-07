import CoreGraphics
import Foundation

/// Where checks keep their files while a test or a flow file runs, set as a task-local value by
/// the runner so the tools need no extra arguments: `assert_screenshot` finds named baselines in
/// `<root>/baselines` and writes its diff into `artifacts`.
struct CheckContext: Sendable {
    /// The folder whose `baselines/` holds named baselines: the project's, or the flow file's.
    let root: URL
    /// Where diffs and actual screenshots go, such as the test's folder in the run's output. Nil
    /// puts them next to the baseline.
    let artifacts: URL?
    /// The files written into `artifacts`, for the test's result.
    let files = Locked<[String]>([])

    @TaskLocal static var current: CheckContext?
}

/// Tools that judge a screen, for tests and flows: compare it with a baseline picture, audit its
/// accessibility, or ask Apple Intelligence a yes/no question about it. Each fails its step when
/// the screen does not pass.
extension PhoneTools {
    static let checkDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "assert_screenshot", title: "Assert screenshot",
            description:
                "Compare the screen with a baseline picture (visual regression). Fails when more than threshold of the pixels changed, with a diff image (changed pixels in red) and the files' paths. Without a baseline it records one and passes, so the first run creates them; commit them. name resolves to baselines/<ios|android>/<width>x<height>/<name>.png in the test project (run_tests, Mobdev test) or next to the flow file, else in Mobdev's folder; path names a .png directly. Small differences from antialiasing and compression are ignored, and so is the status bar unless compare_status_bar is true. mask hides changing content: rectangles in screenshot pixels, or element ids or labels. update: true replaces the baseline.",
            inputSchema: schema(
                [
                    "name": ["type": "string", "description": "Baseline name, e.g. login-screen"],
                    "path": ["type": "string", "description": "Or an absolute path to a .png on the Mac that runs Mobdev"],
                    "threshold": [
                        "type": "number", "minimum": 0, "maximum": 1,
                        "description": "Share of compared pixels that may change, default 0.0005 (0.05%); 0 for none",
                    ],
                    "mask": [
                        "type": "array",
                        "items": [
                            "anyOf": [
                                ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4],
                                ["type": "string"],
                            ]
                        ],
                        "description":
                            "Areas to ignore: [x, y, width, height] in screenshot pixels, or an element's id or label (OCR text where there is no UI tree)",
                    ],
                    "compare_status_bar": ["type": "boolean", "description": "Also compare the status bar, default false"],
                    "update": ["type": "boolean", "description": "Replace the baseline with the current screen"],
                ], screenshot: false),
            readOnly: false),
        ToolDefinition(
            name: "accessibility_audit", title: "Accessibility audit",
            description:
                "Check the screen's accessibility from the UI tree (simulators, Android, iPhones with Mobdev Runner): tappable elements without a label (icon-only buttons), tap targets below 44×44 pt on iOS or 48×48 dp on Android, text contrast below 4.5:1 measured from the screenshot, different targets with the same label, and labels that are file names or identifiers. Lists each issue with severity (error or warning), rule, element and position. image: true returns the screenshot with the issues boxed. fail_on: error (or warning) makes the call fail when there are issues that severe, for tests.",
            inputSchema: schema(
                [
                    "image": ["type": "boolean", "description": "Also return a screenshot with the issues boxed, default false"],
                    "fail_on": [
                        "type": "string", "enum": ["error", "warning"],
                        "description": "Fail when an issue of this severity or worse is found",
                    ],
                    "ignore": [
                        "type": "array", "items": ["type": "string", "enum": .array(AccessibilityAudit.rules.map(JSONValue.string))],
                        "description": "Rules to skip",
                    ],
                ], screenshot: false),
            readOnly: true),
        ToolDefinition(
            name: "assert_with_ai", title: "Assert with AI",
            description:
                "Ask Apple Intelligence on this Mac a yes/no question about the screen, e.g. \"Is the whole sign-in form visible, with no overlapping or cut-off text?\". It looks at the screenshot (macOS 27; else it reads the screen's elements); nothing leaves the Mac. Fails when the answer is not expect (default yes) or the model is unsure, and says why. Needs a Mac with Apple Intelligence turned on.",
            inputSchema: schema(
                [
                    "question": ["type": "string", "description": "A yes/no question about what the screen shows"],
                    "expect": [
                        "type": "string", "enum": ["yes", "no"],
                        "description": "The answer that passes, default yes",
                    ],
                ], required: ["question"], screenshot: false),
            readOnly: true),
    ]

    func runCheckTool(_ name: String, _ args: Arguments) async throws -> ToolOutput? {
        switch name {
        case "assert_screenshot": return try await assertScreenshot(args)
        case "accessibility_audit": return try await accessibilityAudit(args)
        case "assert_with_ai": return try await assertWithAI(args)
        default: return nil
        }
    }

    // MARK: Screenshots

    /// The default for `threshold`: about 400 pixels of a 590×1280 screenshot, a 20×20 square.
    static let screenshotThreshold = 0.0005
    /// The status bar's share of the screen's height, left out unless compare_status_bar.
    static let statusBarShare = 0.07

    private func assertScreenshot(_ args: Arguments) async throws -> ToolOutput {
        let threshold = try args.number("threshold", default: Self.screenshotThreshold, range: 0...1)
        let masks = try maskItems(args.value["mask"])
        let compareStatusBar = args.bool("compare_status_bar") ?? false
        var (frame, _) = try currentFrame()
        let baseline = try baselineURL(args, frame: frame)
        let files = FileManager.default
        try files.createDirectory(at: baseline.url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let exists = files.fileExists(atPath: baseline.url.path)
        if !exists || args.bool("update") == true {
            // An app still fading in after its launch made a baseline no later run matched (2026-10-07).
            let settled = (try? await waitForIdle(timeout: 5, stable: 1)) != nil
            (frame, _) = try currentFrame()
            let screenshot = ImageTools.scaled(frame, longEdge: ScreenGeometry.screenshotLongEdge)
            try write(screenshot, to: baseline.url)
            removeStaleFiles(of: baseline)
            var text = exists
                ? "Updated the baseline \(baseline.url.path) with the current screen."
                : "Recorded a new baseline \(baseline.url.path), since there was none. Commit it with your tests: later runs compare the screen with it."
            if !settled { text += " The screen kept changing for 5 s, so the baseline may show it in motion: mask what moves." }
            return ToolOutput(
                text: text,
                data: ["passed": true, "baseline": .string(baseline.url.path), "recorded": .bool(!exists), "updated": .bool(exists)])
        }
        guard let expectedImage = ImageDiff.load(baseline.url) else {
            throw ToolFailure("\(baseline.url.path) is not a picture Mobdev can read. Pass update: true to replace it.")
        }

        func compareScreen() async throws -> ScreenComparison {
            try await compare(frame, with: expectedImage, baseline: baseline.url, masks: masks, statusBar: compareStatusBar)
        }
        var outcome = try await compareScreen()
        if outcome.comparison.changedShare > threshold {
            // An animation or a screen still loading: once more after it settles.
            _ = try? await waitForIdle(timeout: 3, stable: 0.5)
            (frame, _) = try currentFrame()
            outcome = try await compareScreen()
        }
        let comparison = outcome.comparison
        let share = comparison.changedShare
        var data: [String: JSONValue] = [
            "baseline": .string(baseline.url.path), "changed": .number((share * 1_000_000).rounded() / 1_000_000),
            "changed_pixels": .number(Double(comparison.changedPixels)), "compared_pixels": .number(Double(comparison.comparedPixels)),
            "threshold": .number(threshold),
            "regions": .array(comparison.regions.prefix(10).map { rect in .array([rect.minX, rect.minY, rect.width, rect.height].map { .number($0) }) }),
        ]
        let notes = outcome.unmatched.isEmpty
            ? "" : " Nothing on screen matched the mask \(outcome.unmatched.map { "\"\($0)\"" }.joined(separator: ", "))."
        guard share > threshold else {
            removeStaleFiles(of: baseline)
            data["passed"] = true
            return ToolOutput(
                text: "The screen matches the baseline \(baseline.url.lastPathComponent): \(Self.percent(share)) of pixels changed, threshold \(Self.percent(threshold)).\(notes)",
                data: .object(data))
        }

        let stem = baseline.url.deletingPathExtension().lastPathComponent
        let folder = baseline.artifacts ?? baseline.url.deletingLastPathComponent()
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let diffURL = folder.appendingPathComponent("\(stem)-diff.png")
        let actualURL = folder.appendingPathComponent("\(stem)-actual.png")
        let diff = ImageDiff.picture(of: comparison, over: outcome.actual)
        if let diff { try write(diff, to: diffURL) }
        if let actual = outcome.actual.image { try write(actual, to: actualURL) }
        if baseline.artifacts != nil { CheckContext.current?.files.withLock { $0 += [diffURL.path, actualURL.path] } }
        data["passed"] = false
        data["diff"] = .string(diffURL.path)
        data["actual"] = .string(actualURL.path)
        let regions = comparison.regions.prefix(5).map { "(\(Int($0.minX)), \(Int($0.minY)), \(Int($0.width))×\(Int($0.height)))" }
        let text = """
            The screen differs from the baseline \(baseline.url.path): \(Self.percent(share)) of pixels changed, more than the threshold of \(Self.percent(threshold)). \
            Changed \(comparison.regions.count == 1 ? "region" : "regions") (x, y, width×height): \(regions.joined(separator: ", "))\(comparison.regions.count > 5 ? " and more" : "").\(notes)
            Diff (changed pixels in red): \(diffURL.path)
            Actual screen: \(actualURL.path)
            If the change is intended, run again with update: true. Mask content that changes on its own, such as a clock.
            """
        return ToolOutput(text: text, data: .object(data), image: diff.flatMap { ImageTools.encode($0) }, isError: true)
    }

    private struct ScreenComparison {
        var comparison: ImageComparison
        var actual: PixelBuffer
        /// Mask names that matched no element or text.
        var unmatched: [String]
    }

    /// The screen at screenshot size against the baseline, which is scaled to that size when it was
    /// taken at another resolution of the same shape.
    private func compare(
        _ frame: CGImage, with expected: CGImage, baseline: URL, masks: [MaskItem], statusBar: Bool
    ) async throws -> ScreenComparison {
        let screenshot = ImageTools.scaled(frame, longEdge: ScreenGeometry.screenshotLongEdge)
        let width = screenshot.width, height = screenshot.height
        let sameShape = abs(Double(expected.width) / Double(expected.height) - Double(width) / Double(height)) < 0.01
        guard expected.width == width && expected.height == height || sameShape else {
            throw ToolFailure(
                "The baseline \(baseline.lastPathComponent) is \(expected.width)×\(expected.height) px, but the screen is \(width)×\(height) px: another device or orientation. Pass update: true to replace it, or use another name."
            )
        }
        guard let actual = PixelBuffer(screenshot), let reference = PixelBuffer(expected, width: width, height: height) else {
            throw ToolFailure("Could not read the pixels of the screen or the baseline.")
        }
        var rects: [CGRect] = []
        if !statusBar {
            rects.append(CGRect(x: 0, y: 0, width: Double(width), height: (Double(height) * Self.statusBarShare).rounded(.up)))
        }
        var unmatched: [String] = []
        var tree: [UIElement]??
        for mask in masks {
            switch mask {
            case .rect(let rect): rects.append(rect)
            case .element(let query):
                if tree == nil { tree = .some(try? await phone.uiTree()) }
                let found: [CGRect]
                if let elements = tree ?? nil {
                    let byID = ElementQuery(id: query, text: nil).matches(in: elements)
                    found = (byID.isEmpty ? ElementQuery(id: nil, text: query).matches(in: elements) : byID).map(\.frame)
                } else {
                    found = (try await screenText(query, in: frame)).matches.map(\.box)
                }
                if found.isEmpty { unmatched.append(query) }
                // A little larger, so antialiased edges around it are left out too.
                rects += found.map {
                    CGRect(
                        x: $0.minX * Double(width), y: $0.minY * Double(height), width: $0.width * Double(width),
                        height: $0.height * Double(height)
                    ).insetBy(dx: -2, dy: -2)
                }
            }
        }
        return ScreenComparison(
            comparison: ImageDiff.compare(actual, reference, masks: rects), actual: actual, unmatched: unmatched)
    }

    enum MaskItem: Equatable {
        /// In screenshot pixels.
        case rect(CGRect)
        /// An element's identifier or label, or text on screen.
        case element(String)
    }

    func maskItems(_ value: JSONValue?) throws -> [MaskItem] {
        guard let value, !value.isNull else { return [] }
        guard let items = value.arrayValue, items.count <= 100 else {
            throw ToolFailure("mask must be an array of up to 100 items: [x, y, width, height] or an element's id or label.")
        }
        return try items.map { item in
            if let text = item.stringValue, !text.isEmpty { return .element(text) }
            if let numbers = item.arrayValue?.compactMap(\.doubleValue), numbers.count == 4, item.arrayValue?.count == 4,
                numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0
            {
                return .rect(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
            }
            throw ToolFailure(
                "Each mask item is [x, y, width, height] in screenshot pixels, with a positive width and height, or an element's id or label; \(item.compactString) is neither.")
        }
    }

    struct Baseline {
        let url: URL
        /// Where a failed comparison's files go; nil next to the baseline.
        let artifacts: URL?
    }

    /// `path` as given, or `name` under baselines/<platform>/<width>x<height>/ in the running test
    /// project or next to the flow file, else in Mobdev's folder. The size is the screen's in
    /// pixels, so every device model and orientation has its own baselines.
    func baselineURL(_ args: Arguments, frame: CGImage) throws -> Baseline {
        if args.has("path") {
            guard !args.has("name") else { throw ToolFailure("Pass name or path, not both.") }
            let path = (try args.string("path") as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), path.lowercased().hasSuffix(".png") else {
                throw ToolFailure("path must be an absolute path to a .png file on the Mac that runs Mobdev.")
            }
            return Baseline(url: URL(fileURLWithPath: path).standardizedFileURL, artifacts: CheckContext.current?.artifacts)
        }
        guard args.has("name") else { throw ToolFailure("Pass name (a baseline name such as login-screen) or path.") }
        var name = try args.string("name", maxLength: 100)
        if name.lowercased().hasSuffix(".png") { name = String(name.dropLast(4)) }
        guard let first = name.first, first.isLetter || first.isNumber,
            name.allSatisfy({ $0.isLetter || $0.isNumber || " ._-".contains($0) })
        else {
            throw ToolFailure("name may hold letters, digits, spaces, dots, dashes and underscores, like login-screen.")
        }
        let context = CheckContext.current
        let url = (context?.root ?? MobdevPaths.home).appendingPathComponent("baselines", isDirectory: true)
            .appendingPathComponent(TestCase.platformName(deviceKind), isDirectory: true)
            .appendingPathComponent("\(frame.width)x\(frame.height)", isDirectory: true)
            .appendingPathComponent("\(name).png")
        return Baseline(url: url, artifacts: context?.artifacts)
    }

    /// What the device is; a backend that is no `Device` (a test's) by how its input travels.
    var deviceKind: DeviceKind {
        if let device = phone as? any Device { return device.kind }
        switch phone.status().input {
        case .bluetooth: return .iPhone
        case .direct(let route): return route == "adb" ? .android : .simulator
        }
    }

    /// The diff and actual screen a failed comparison left next to its baseline, once it passes.
    private func removeStaleFiles(of baseline: Baseline) {
        guard baseline.artifacts == nil else { return }
        let stem = baseline.url.deletingPathExtension().lastPathComponent
        let folder = baseline.url.deletingLastPathComponent()
        for suffix in ["-diff.png", "-actual.png"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(stem + suffix))
        }
    }

    private func write(_ image: CGImage, to url: URL) throws {
        guard let png = ImageTools.encode(image, png: true) else { throw ToolFailure("Could not encode \(url.lastPathComponent).") }
        do {
            try png.data.write(to: url, options: .atomic)
        } catch {
            throw ToolFailure("Could not write \(url.path): \(error.localizedDescription)")
        }
    }

    /// "0.05%", "1.2%", "0%".
    static func percent(_ share: Double) -> String {
        let value = share * 100
        if value == 0 { return "0%" }
        if value < 0.01 { return "<0.01%" }
        return value < 1 ? String(format: "%.2f%%", value) : String(format: "%.1f%%", value)
    }

    // MARK: Accessibility

    private func accessibilityAudit(_ args: Arguments) async throws -> ToolOutput {
        let failOn: AccessibilityIssue.Severity?
        if args.has("fail_on") {
            guard let severity = AccessibilityIssue.Severity(rawValue: try args.string("fail_on")) else {
                throw ToolFailure("fail_on must be error or warning.")
            }
            failOn = severity
        } else {
            failOn = nil
        }
        let ignored = Set(args.strings("ignore"))
        if let unknown = ignored.sorted().first(where: { !AccessibilityAudit.rules.contains($0) }) {
            throw ToolFailure("ignore has an unknown rule \"\(unknown)\". Rules: \(AccessibilityAudit.rules.joined(separator: ", ")).")
        }
        // Colors measured while the screen fades in would be too pale.
        _ = try? await waitForIdle(timeout: 3, stable: 0.5)
        let elements = try await tree()
        let (frame, size) = try currentFrame()
        let android = deviceKind == .android
        let scale = await phone.screenScale()
            ?? AccessibilityAudit.estimatedScale(width: frame.width, height: frame.height, android: android)
        let audit = AccessibilityAudit(
            elements: elements, android: android, scale: scale, screen: (frame.width, frame.height),
            pixels: ignored.contains("low_contrast") ? nil : PixelBuffer(frame))
        let issues = audit.run(skipping: ignored)
        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.count - errors

        func position(_ element: UIElement) -> String { coordinates(element.center, size) }
        var lines = [
            issues.isEmpty
                ? "No accessibility issues in \(elements.count) elements."
                : "Accessibility audit of \(elements.count) elements: \(errors) \(errors == 1 ? "error" : "errors"), \(warnings) \(warnings == 1 ? "warning" : "warnings")."
        ]
        for (index, issue) in issues.enumerated() {
            var line = "[\(index + 1)] \(issue.severity.rawValue) \(issue.rule): \(Self.name(issue.element)) at \(position(issue.element))"
            if !issue.others.isEmpty { line += " and " + issue.others.map(position).joined(separator: ", ") }
            lines.append(line + ". " + issue.message)
        }
        let checked = AccessibilityAudit.rules.filter { !ignored.contains($0) }
        lines.append(
            "Checked \(checked.joined(separator: ", ")) at \(String(format: "%.3g", scale)) px per \(audit.unit). Fix errors first; warnings are below platform guidelines.")
        let failing = failOn.map { level in issues.filter { $0.severity >= level }.count } ?? 0
        if let failOn, failing > 0 {
            let counted = failOn == .error ? (failing == 1 ? "error" : "errors") : (failing == 1 ? "issue" : "issues")
            lines.append("Fails with fail_on \(failOn.rawValue): \(failing) \(counted).")
        }

        let w = Double(size.width), h = Double(size.height)
        func frameJSON(_ element: UIElement) -> JSONValue {
            .array(
                [element.frame.minX * w, element.frame.minY * h, element.frame.width * w, element.frame.height * h]
                    .map { .number($0.rounded()) })
        }
        let data: JSONValue = [
            "passed": .bool(failing == 0), "elements": .number(Double(elements.count)),
            "errors": .number(Double(errors)), "warnings": .number(Double(warnings)), "scale": .number(scale),
            "issues": .array(
                issues.enumerated().map { index, issue in
                    [
                        "number": .number(Double(index + 1)), "severity": .string(issue.severity.rawValue),
                        "rule": .string(issue.rule), "message": .string(issue.message),
                        "role": .string(issue.element.role), "label": .string(issue.element.label),
                        "id": .string(issue.element.identifier),
                        "x": .number((issue.element.center.x * w).rounded()), "y": .number((issue.element.center.y * h).rounded()),
                        "frame": frameJSON(issue.element), "others": .array(issue.others.map(frameJSON)),
                    ]
                }),
        ]
        var output = ToolOutput(text: lines.joined(separator: "\n"), data: data, isError: failing > 0)
        if args.bool("image") == true {
            // One box per element, numbered with its issues, red with an error and else orange.
            var boxes: [(element: UIElement, numbers: [Int], error: Bool)] = []
            for (index, issue) in issues.enumerated() {
                for element in [issue.element] + issue.others {
                    if let box = boxes.firstIndex(where: { $0.element.frame == element.frame }) {
                        boxes[box].numbers.append(index + 1)
                        boxes[box].error = boxes[box].error || issue.severity == .error
                    } else {
                        boxes.append((element, [index + 1], issue.severity == .error))
                    }
                }
            }
            let marks = boxes.enumerated().map { index, box in
                ScreenMark(
                    number: index, role: box.element.role, label: box.element.label, identifier: box.element.identifier,
                    value: box.element.value, frame: box.element.frame, enabled: box.element.enabled)
            }
            output.image = Self.marked(
                frame, marks: marks,
                color: { mark in
                    boxes[mark.number].error
                        ? CGColor(red: 1, green: 0.18, blue: 0.33, alpha: 1) : CGColor(red: 0.95, green: 0.55, blue: 0, alpha: 1)
                },
                badge: { mark in boxes[mark.number].numbers.map(String.init).joined(separator: ",") })
        }
        return output
    }

    /// `Button "Close" id=close`, or the role alone.
    static func name(_ element: UIElement) -> String {
        var parts = [element.role]
        if !element.label.isEmpty { parts.append("\"\(element.label)\"") }
        if !element.identifier.isEmpty { parts.append("id=\(element.identifier)") }
        return parts.joined(separator: " ")
    }

    // MARK: AI

    /// At most this much of the screen's text goes to the model, whose context is small.
    static let maxJudgedText = 3000

    private func assertWithAI(_ args: Arguments) async throws -> ToolOutput {
        let question = try args.string("question", maxLength: 500)
        let expectText = args.has("expect") ? try args.string("expect") : "yes"
        guard let expected = ScreenJudgement.Answer(rawValue: expectText), expected != .unsure else {
            throw ToolFailure("expect must be yes or no.")
        }
        _ = try? await waitForIdle(timeout: 3, stable: 0.5)
        let (frame, size) = try currentFrame()
        let screenshot = ImageTools.scaled(frame, longEdge: ScreenGeometry.screenshotLongEdge)
        // The observe list, from the tree or else the recognized text, for a model that takes no images.
        var lines = ["Screenshot \(size.width)×\(size.height) px."]
        if let found = try? await currentMarks(in: frame) { lines += found.marks.map { describe($0, size) } }
        // In single quotes: the model's answer copied double quotes and ended its reason there.
        var screenText = lines.joined(separator: "\n").replacingOccurrences(of: "\"", with: "'")
        if screenText.count > Self.maxJudgedText { screenText = String(screenText.prefix(Self.maxJudgedText)) + "\n…" }

        let judgement = try await judge.judge(question, screenshot: screenshot, screenText: screenText)
        let source = judgement.sawImage
            ? "Apple Intelligence on this Mac, from the screenshot"
            : "Apple Intelligence on this Mac, from the screen's text: this Mac's model takes no images"
        let passed = judgement.answer == expected
        let text: String
        switch judgement.answer {
        case .unsure:
            text = "Apple Intelligence could not tell from the screen: \(judgement.reason) Ask a more specific question, or check with wait_for_element or assert_screenshot. (\(source).)"
        case expected:
            text = "\(judgement.answer.rawValue.capitalized), as expected: \(judgement.reason) (\(source).)"
        default:
            text = "Expected \(expected.rawValue), but the answer is \(judgement.answer.rawValue): \(judgement.reason) (\(source).)"
        }
        return ToolOutput(
            text: text,
            data: [
                "passed": .bool(passed), "answer": .string(judgement.answer.rawValue), "expected": .string(expected.rawValue),
                "reason": .string(judgement.reason), "input": .string(judgement.sawImage ? "image" : "text"),
            ],
            image: passed ? nil : ImageTools.encode(screenshot), isError: !passed)
    }
}
