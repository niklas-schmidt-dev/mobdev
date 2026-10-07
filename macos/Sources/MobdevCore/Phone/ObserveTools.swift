import CoreGraphics
import CoreText
import Foundation

/// One numbered thing on the screen from `observe`: an element of the UI tree, or a line of text
/// where there is no tree. `tap_mark` taps it by number.
public struct ScreenMark: Sendable, Equatable {
    public var number: Int
    public var role: String
    public var label: String
    public var identifier: String
    public var value: String
    /// As fractions of the screen, origin top-left.
    public var frame: CGRect
    public var enabled: Bool

    public var center: NormalizedPoint { NormalizedPoint(x: frame.midX, y: frame.midY) }
}

/// What `observe` saw last, for `tap_mark`.
struct ObservedMarks: Sendable {
    var marks: [ScreenMark]
    var at: Date
}

/// Tools that make agents faster and steadier: a compact, numbered view of the screen, taps by
/// number, scrolling until something shows, and waiting until the screen stops moving.
extension PhoneTools {
    static let observeDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "observe", title: "Observe",
            description:
                "A compact, numbered list of what is on screen: the UI tree's elements where there is one (simulators, Android, iPhones with Mobdev Runner), else the recognized text. Each line is a mark with role, label, identifier and position; tap_mark taps one by number. image: true adds a screenshot with the marks drawn on it. Cheaper than a screenshot and steadier than guessing coordinates.",
            inputSchema: schema(
                [
                    "image": ["type": "boolean", "description": "Also return a screenshot with numbered boxes, default false"],
                    "contains": ["type": "string", "description": "Only marks whose label, identifier or value contains this"],
                ], screenshot: false),
            readOnly: true),
        ToolDefinition(
            name: "tap_mark", title: "Tap mark",
            description:
                "Tap a mark from the last observe by its number. Call observe again after the screen changed: marks are where things were then.",
            inputSchema: schema(["mark": ["type": "integer", "minimum": 1]], required: ["mark"]),
            readOnly: false),
        ToolDefinition(
            name: "scroll_until_visible", title: "Scroll until visible",
            description:
                "Scroll until an element (id, from the UI tree) or text is on screen, then say where it is. Stops at the end of the list. direction is where the content should move into view from: down (default) reveals what is further down.",
            inputSchema: schema(
                [
                    "text": ["type": "string"],
                    "id": ["type": "string", "description": "Identifier from the UI tree"],
                    "direction": ["type": "string", "enum": ["down", "up", "left", "right"]],
                    "max_scrolls": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Default 10"],
                ]),
            readOnly: false),
        ToolDefinition(
            name: "wait_for_idle", title: "Wait for idle",
            description:
                "Wait until the screen stops changing for stable seconds (default 0.5), e.g. after a tap that starts an animation or loads content. The status bar is ignored. Fails when it never settles within timeout.",
            inputSchema: schema(
                [
                    "timeout": ["type": "number", "description": "Seconds, default 10, at most 60"],
                    "stable": ["type": "number", "description": "Seconds without change, default 0.5"],
                ], screenshot: false),
            readOnly: true),
    ]

    func runObserveTool(_ name: String, _ args: Arguments) async throws -> ToolOutput? {
        switch name {
        case "observe":
            let (frame, size) = try currentFrame()
            let (marks, fromTree) = try await currentMarks(in: frame)
            observed.set(ObservedMarks(marks: marks, at: Date()))
            let query = args.has("contains") ? try args.string("contains") : nil
            let shown = marks.filter { mark in
                query.map {
                    mark.label.localizedCaseInsensitiveContains($0) || mark.identifier.localizedCaseInsensitiveContains($0)
                        || mark.value.localizedCaseInsensitiveContains($0)
                } ?? true
            }
            let source = fromTree ? "from the UI tree" : "from text recognition (no UI tree on this device)"
            var lines = [
                "\(marks.count) marks \(source); screenshot \(size.width)×\(size.height) px. tap_mark taps one by number."
            ]
            if let query, shown.isEmpty { lines.append("No mark matches \"\(query)\".") }
            lines += shown.map { describe($0, size) }
            var output = ToolOutput(text: lines.joined(separator: "\n"), data: .array(shown.map { json($0, size) }))
            if args.bool("image") == true { output.image = Self.marked(frame, marks: shown) }
            return output
        case "tap_mark":
            let number = Int(try args.number("mark", default: 0, range: 1...10_000))
            guard let observed = observed.get() else { throw ToolFailure("No marks yet. Call observe first.") }
            guard let mark = observed.marks.first(where: { $0.number == number }) else {
                throw ToolFailure("No mark \(number). The last observe had marks 1 to \(observed.marks.count).")
            }
            let size = try screenshotSize()
            try requireTouch()
            try await phone.tap(at: mark.center, hold: 0.08)
            let age = Date().timeIntervalSince(observed.at)
            return ToolOutput(
                text: "Tapped \(describe(mark, size))."
                    + (age > 120 ? " Those marks are \(Int(age / 60)) minutes old; call observe if the screen changed." : ""))
        case "scroll_until_visible":
            return try await scrollUntilVisible(args)
        case "wait_for_idle":
            let timeout = try args.number("timeout", default: 10, range: 0...60)
            let stable = try args.number("stable", default: 0.5, range: 0.1...10)
            let seconds = try await waitForIdle(timeout: timeout, stable: stable)
            return ToolOutput(text: "The screen was still for \(format(stable)) s after \(String(format: "%.1f", seconds)) s.")
        default:
            return nil
        }
    }

    // MARK: Marks

    /// While a flow is being recorded, a tap on a mark is saved as a step that still works when the
    /// marks are gone: tap_element by a unique identifier or label, tap_text for recognized text,
    /// else tap at the point.
    func recordMarkTap(_ args: Arguments) {
        guard recorder.isRecording, let observed = observed.get(),
            let number = args.value["mark"]?.doubleValue.map({ Int($0) }),
            let mark = observed.marks.first(where: { $0.number == number }), let size = try? screenshotSize()
        else { return }
        let fromText = mark.role == "Text" && mark.identifier.isEmpty
        if !fromText, !mark.identifier.isEmpty, observed.marks.filter({ $0.identifier == mark.identifier }).count == 1 {
            recorder.record("tap_element", ["id": .string(mark.identifier)])
        } else if !mark.label.isEmpty, observed.marks.filter({ $0.label == mark.label }).count == 1 {
            recorder.record(fromText ? "tap_text" : "tap_element", ["text": .string(mark.label)])
        } else {
            recorder.record(
                "tap",
                [
                    "x": .number((mark.center.x * Double(size.width)).rounded()),
                    "y": .number((mark.center.y * Double(size.height)).rounded()),
                ])
        }
    }

    /// The UI tree's useful elements, else the recognized lines, in reading order and numbered.
    private func currentMarks(in frame: CGImage) async throws -> (marks: [ScreenMark], fromTree: Bool) {
        if let elements = try? await phone.uiTree(), let marks = Self.marks(from: elements), !marks.isEmpty {
            return (marks, true)
        }
        let text = try await screenText(nil, in: frame)
        let marks = text.matches.enumerated().map { index, match in
            ScreenMark(
                number: index + 1, role: "Text", label: match.text, identifier: "", value: "", frame: match.box,
                enabled: true)
        }
        return (marks, text.fromTree)
    }

    /// At most this many marks, so a huge list does not flood the agent's context.
    static let maxMarks = 200

    /// What can be read or tapped, visible on screen, one per place, top to bottom. A tappable
    /// element without a label, such as an Android list row, takes the labels of the text inside it,
    /// which then is not listed again. Containers that cover most of the screen, and icons and frames
    /// with nothing to read or tap, say nothing an agent needs.
    static func marks(from elements: [UIElement]) -> [ScreenMark]? {
        let screen = CGRect(x: 0, y: 0, width: 1, height: 1)
        var useful = elements.filter { element in
            let frame = element.frame
            let visible = frame.intersection(screen)
            guard !visible.isNull, visible.width > 0.004, visible.height > 0.002 else { return false }
            guard frame.width * frame.height < 0.6 || element.tappable && !element.label.isEmpty else { return false }
            return !element.label.isEmpty || element.tappable
        }
        var consumed = Set<Int>()
        // Smallest rows first, so text goes to the row it is in rather than to a list around it.
        let unlabelled = useful.indices.filter { useful[$0].tappable && useful[$0].label.isEmpty }
            .sorted { useful[$0].frame.width * useful[$0].frame.height < useful[$1].frame.width * useful[$1].frame.height }
        for row in unlabelled {
            let frame = useful[row].frame.insetBy(dx: -0.002, dy: -0.002)
            let inside = useful.indices.filter { index in
                index != row && !consumed.contains(index) && !useful[index].tappable && !useful[index].label.isEmpty
                    && frame.contains(useful[index].frame)
            }
            guard !inside.isEmpty else { continue }
            useful[row].label = inside.prefix(3).map { useful[$0].label }.joined(separator: ", ")
            consumed.formUnion(inside)
        }
        useful = useful.indices.filter { !consumed.contains($0) }.map { useful[$0] }
        let sorted = ElementQuery.onePerPlace(useful).sorted { a, b in
            abs(a.frame.minY - b.frame.minY) > 0.008 ? a.frame.minY < b.frame.minY : a.frame.minX < b.frame.minX
        }
        return sorted.prefix(maxMarks).enumerated().map { index, element in
            ScreenMark(
                number: index + 1, role: element.role, label: element.label, identifier: element.identifier,
                value: element.value, frame: element.frame, enabled: element.enabled)
        }
    }

    private func describe(_ mark: ScreenMark, _ size: (width: Int, height: Int)) -> String {
        var parts = ["[\(mark.number)] \(mark.role)"]
        if !mark.label.isEmpty { parts.append("\"\(mark.label)\"") }
        if !mark.identifier.isEmpty { parts.append("id=\(mark.identifier)") }
        if !mark.value.isEmpty, mark.value != mark.label { parts.append("value=\(mark.value)") }
        if !mark.enabled { parts.append("disabled") }
        parts.append(coordinates(mark.center, size))
        return parts.joined(separator: " ")
    }

    private func json(_ mark: ScreenMark, _ size: (width: Int, height: Int)) -> JSONValue {
        let w = Double(size.width), h = Double(size.height)
        return [
            "mark": .number(Double(mark.number)), "role": .string(mark.role), "label": .string(mark.label),
            "id": .string(mark.identifier), "value": .string(mark.value), "enabled": .bool(mark.enabled),
            "x": .number((mark.center.x * w).rounded()), "y": .number((mark.center.y * h).rounded()),
            "frame": [
                .number((mark.frame.minX * w).rounded()), .number((mark.frame.minY * h).rounded()),
                .number((mark.frame.width * w).rounded()), .number((mark.frame.height * h).rounded()),
            ],
        ]
    }

    /// The screenshot with a numbered box around every mark.
    static func marked(_ frame: CGImage, marks: [ScreenMark]) -> EncodedImage? {
        let image = ImageTools.scaled(frame, longEdge: ScreenGeometry.screenshotLongEdge)
        let width = image.width, height = image.height
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return ImageTools.encode(image) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let colors: [CGColor] = [
            CGColor(red: 1, green: 0.18, blue: 0.33, alpha: 1), CGColor(red: 0, green: 0.48, blue: 1, alpha: 1),
            CGColor(red: 0.2, green: 0.7, blue: 0.2, alpha: 1), CGColor(red: 0.95, green: 0.55, blue: 0, alpha: 1),
        ]
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(14, CGFloat(width) / 36), nil)
        for mark in marks {
            let color = colors[mark.number % colors.count]
            // Core Graphics counts from the bottom.
            let box = CGRect(
                x: mark.frame.minX * Double(width), y: Double(height) - mark.frame.maxY * Double(height),
                width: mark.frame.width * Double(width), height: mark.frame.height * Double(height))
            context.setStrokeColor(color)
            context.setLineWidth(2)
            context.stroke(box)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(mark.number)", attributes: attributes))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            // A badge in the box's top-left corner, kept on the picture.
            let badgeSize = CGSize(width: textWidth + 8, height: ascent + descent + 4)
            let badge = CGRect(
                x: min(max(box.minX, 0), Double(width) - badgeSize.width),
                y: min(max(box.maxY - badgeSize.height, 0), Double(height) - badgeSize.height),
                width: badgeSize.width, height: badgeSize.height)
            context.setFillColor(color)
            context.fill(badge)
            context.textPosition = CGPoint(x: badge.minX + 4, y: badge.minY + 2 + descent)
            CTLineDraw(line, context)
        }
        return context.makeImage().flatMap { ImageTools.encode($0) }
    }

    // MARK: Scrolling

    private func scrollUntilVisible(_ args: Arguments) async throws -> ToolOutput {
        let id = args.has("id") ? try args.string("id") : nil
        let text = args.has("text") ? try args.string("text") : nil
        guard id != nil || text != nil else { throw ToolFailure("Pass text or id.") }
        let direction = args.has("direction") ? try args.string("direction") : "down"
        guard ["down", "up", "left", "right"].contains(direction) else {
            throw ToolFailure("direction must be down, up, left or right.")
        }
        let maxScrolls = Int(try args.number("max_scrolls", default: 10, range: 1...50))
        let what = id.map { "id \"\($0)\"" } ?? "\"\(text ?? "")\""
        try requireTouch()
        var unchanged = 0
        for scrolls in 0...maxScrolls {
            let (frame, size) = try currentFrame()
            if let point = try await locate(id: id, text: text, in: frame) {
                return ToolOutput(
                    text: "\(what) is visible at \(coordinates(point, size))"
                        + (scrolls == 0 ? " without scrolling." : " after \(scrolls) scroll\(scrolls == 1 ? "" : "s")."),
                    data: [
                        "x": .number((point.x * Double(size.width)).rounded()),
                        "y": .number((point.y * Double(size.height)).rounded()), "scrolls": .number(Double(scrolls)),
                    ])
            }
            if scrolls == maxScrolls { break }
            let before = FrameSignature(frame)
            let center = NormalizedPoint(x: 0.5, y: 0.5)
            switch direction {
            case "down": try await phone.scroll(at: center, ticks: 5)
            case "up": try await phone.scroll(at: center, ticks: -5)
            case "right": try await phone.pan(at: center, ticks: 5)
            default: try await phone.pan(at: center, ticks: -5)
            }
            try await pause(0.7)
            if let before, let after = phone.frame().flatMap(FrameSignature.init), after.changed(from: before) < 0.002 {
                unchanged += 1
                // Twice, since a slow list may not have moved yet the first time.
                if unchanged >= 2 {
                    throw ToolFailure("\(what) is not on screen, and scrolling \(direction) no longer moves anything: the end is reached.")
                }
            } else {
                unchanged = 0
            }
        }
        throw ToolFailure("\(what) is not visible after \(maxScrolls) scrolls \(direction).")
    }

    /// Where the element or text is, when it is on screen: from the tree where there is one, else
    /// for text from text recognition.
    private func locate(id: String?, text: String?, in frame: CGImage) async throws -> NormalizedPoint? {
        let onScreen = { (point: NormalizedPoint) in (0.01...0.99).contains(point.x) && (0.02...0.98).contains(point.y) }
        let tree = try? await phone.uiTree()
        if let tree {
            let found = ElementQuery(id: id, text: id == nil ? text : nil).matches(in: tree).first { onScreen($0.center) }
            return found?.center
        }
        guard id == nil, let text else {
            throw ToolFailure("This device has no UI tree, so it cannot look for an id. Pass text instead.")
        }
        let found = try await screenText(text, in: frame).matches
        return (found.first(where: \.exact) ?? found.first).map(\.center).flatMap { onScreen($0) ? $0 : nil }
    }

    // MARK: Idle

    /// Seconds until the screen stayed the same for `stable` seconds; throws after `timeout`.
    func waitForIdle(timeout: TimeInterval, stable: TimeInterval) async throws -> TimeInterval {
        let started = Date()
        var reference: FrameSignature?
        var still = started
        while true {
            if let current = phone.frame().flatMap(FrameSignature.init) {
                if let previous = reference, current.changed(from: previous) < 0.002 {
                    if Date().timeIntervalSince(still) >= stable { return Date().timeIntervalSince(started) }
                } else {
                    reference = current
                    still = Date()
                }
            }
            if Date().timeIntervalSince(started) >= timeout {
                throw ToolFailure(
                    "The screen kept changing for \(format(timeout)) s, e.g. a video, an animation or a loading indicator that never stops.")
            }
            try await pause(0.1)
        }
    }
}

/// A screen boiled down to a small grayscale picture, to tell whether it changed. The top 7%, where
/// the status bar's clock and battery change on their own, is left out.
struct FrameSignature: Sendable {
    let pixels: [UInt8]

    static let width = 48

    init?(_ image: CGImage) {
        guard image.width > 0, image.height > 0 else { return nil }
        let width = Self.width
        let height = max(8, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Rows start at the top of the picture.
        let skipped = Int((Double(height) * 0.07).rounded(.up))
        self.pixels = Array(pixels[(skipped * width)...])
    }

    /// The share of pixels that differ noticeably, 0 to 1.
    func changed(from other: FrameSignature) -> Double {
        guard pixels.count == other.pixels.count, !pixels.isEmpty else { return 1 }
        var differing = 0
        for index in pixels.indices where abs(Int(pixels[index]) - Int(other.pixels[index])) > 12 { differing += 1 }
        return Double(differing) / Double(pixels.count)
    }
}
