import CoreGraphics
import Foundation

/// One problem `accessibility_audit` found.
struct AccessibilityIssue: Sendable, Equatable {
    enum Severity: String, Sendable, Comparable, CaseIterable {
        /// Below a platform guideline, or likely to confuse.
        case warning
        /// Fails WCAG 2.2 AA or leaves an element unusable with VoiceOver or TalkBack.
        case error

        static func < (a: Severity, b: Severity) -> Bool { a == .warning && b == .error }
    }

    var severity: Severity
    /// One of `AccessibilityAudit.rules`.
    var rule: String
    var element: UIElement
    /// More elements the issue is about, such as the others with the same label.
    var others: [UIElement] = []
    /// What is wrong and how to fix it.
    var message: String
}

/// The checks of `accessibility_audit`, run on the UI tree and the pixels of the screen it
/// describes: tappable elements without a label, tap targets below 44×44 pt (iOS) or 48×48 dp
/// (Android), text contrast below WCAG's 4.5:1, different tappable elements with the same label,
/// and labels that are file names or identifiers.
struct AccessibilityAudit {
    static let rules = ["missing_label", "small_target", "low_contrast", "duplicate_label", "unclear_label"]

    let elements: [UIElement]
    let android: Bool
    /// Pixels of the screen per point (iOS) or dp (Android).
    let scale: Double
    /// The screen's size in pixels.
    let screen: (width: Int, height: Int)
    /// The screen's pixels, for text contrast; nil leaves contrast out.
    let pixels: PixelBuffer?

    var reader: String { android ? "TalkBack" : "VoiceOver" }
    var unit: String { android ? "dp" : "pt" }
    /// Apple's Human Interface Guidelines ask for 44×44 pt, Android's Material guidelines for 48×48 dp.
    var minimumTarget: Double { android ? 48 : 44 }
    /// WCAG 2.2's minimum target size (2.5.8, level AA), in CSS pixels, which points and dp match.
    static let wcagMinimumTarget = 24.0

    /// The issues top to bottom, those of one element together, errors first.
    func run(skipping skipped: Set<String> = []) -> [AccessibilityIssue] {
        let screenRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let visible = elements.filter { element in
            let shown = element.frame.intersection(screenRect)
            return !shown.isNull && shown.width > 0.004 && shown.height > 0.002
        }
        // iOS often wraps an element in another of the same size; such a pair is one target.
        let targets = ElementQuery.onePerPlace(visible.filter(\.tappable))
        var issues: [AccessibilityIssue] = []
        if !skipped.contains("missing_label") { issues += missingLabels(targets, among: visible) }
        if !skipped.contains("small_target") { issues += smallTargets(targets) }
        if !skipped.contains("low_contrast"), let pixels { issues += lowContrast(visible, pixels) }
        if !skipped.contains("duplicate_label") { issues += duplicateLabels(targets) }
        if !skipped.contains("unclear_label") { issues += unclearLabels(ElementQuery.onePerPlace(visible)) }
        return issues.sorted { a, b in
            let (fa, fb) = (a.element.frame, b.element.frame)
            if fa != fb {
                return abs(fa.minY - fb.minY) > 0.008 ? fa.minY < fb.minY : fa.minX < fb.minX
            }
            if a.severity != b.severity { return a.severity > b.severity }
            return Self.rules.firstIndex(of: a.rule) ?? 0 < Self.rules.firstIndex(of: b.rule) ?? 0
        }
    }

    // MARK: Rules

    /// Something to tap that says nothing: an icon-only button reads as just "button". A row or
    /// cell without a label of its own is fine when there is text inside it, which the screen
    /// reader reads instead.
    private func missingLabels(_ targets: [UIElement], among visible: [UIElement]) -> [AccessibilityIssue] {
        targets.compactMap { element in
            guard element.label.trimmingCharacters(in: .whitespaces).isEmpty,
                element.frame.width * element.frame.height < 0.6
            else { return nil }
            let area = element.frame.insetBy(dx: -0.002, dy: -0.002)
            let hasText = visible.contains { other in
                other != element && !other.label.trimmingCharacters(in: .whitespaces).isEmpty && area.contains(other.frame)
            }
            guard !hasText else { return nil }
            if Self.isField(element.role) {
                // iOS reads a field's placeholder, which is its value until something is typed.
                guard element.value.isEmpty else { return nil }
                return AccessibilityIssue(
                    severity: .warning, rule: "missing_label", element: element,
                    message: android
                        ? "Field without a label or hint: TalkBack cannot say what goes in it. Set android:hint, or a label with labelFor."
                        : "Field without a label: VoiceOver cannot say what goes in it. Set its accessibilityLabel (or a placeholder).")
            }
            return AccessibilityIssue(
                severity: .error, rule: "missing_label", element: element,
                message:
                    "\(element.role) without a label, such as an icon-only button: \(reader) reads only \"button\". Set its \(android ? "contentDescription" : "accessibilityLabel") to what it does, such as \"Close\".")
        }
    }

    /// Targets smaller than the platform asks for are a warning; smaller than WCAG's 24×24 an error.
    private func smallTargets(_ targets: [UIElement]) -> [AccessibilityIssue] {
        targets.compactMap { element in
            let width = element.frame.width * Double(screen.width) / scale
            let height = element.frame.height * Double(screen.height) / scale
            // Half a point of slack for frames rounded on the way.
            guard min(width, height) < minimumTarget - 0.5 else { return nil }
            let size = "\(Int(width.rounded()))×\(Int(height.rounded())) \(unit)"
            let tiny = min(width, height) < Self.wcagMinimumTarget - 0.5
            return AccessibilityIssue(
                severity: tiny ? .error : .warning, rule: "small_target", element: element,
                message: "Tap target of \(size), below \(Int(minimumTarget))×\(Int(minimumTarget)) \(unit)"
                    + (tiny ? " and WCAG's minimum of 24×24" : "")
                    + ". Make the tappable area larger, e.g. with padding, even if the icon stays small.")
        }
    }

    /// Text that is hard to read: WCAG asks for 4.5:1 (3:1 for large text, which a tree cannot
    /// tell). Below 3:1 is an error, from 3 to 4.5 a warning. Disabled elements are exempt, as in
    /// WCAG, and so are elements whose background is not even enough to measure, such as a photo.
    private func lowContrast(_ visible: [UIElement], _ pixels: PixelBuffer) -> [AccessibilityIssue] {
        visible.compactMap { element in
            guard element.enabled, !element.label.trimmingCharacters(in: .whitespaces).isEmpty,
                Self.showsText(element.role), element.frame.width * element.frame.height < 0.25
            else { return nil }
            let rect = CGRect(
                x: element.frame.minX * Double(pixels.width), y: element.frame.minY * Double(pixels.height),
                width: element.frame.width * Double(pixels.width), height: element.frame.height * Double(pixels.height))
            guard let measured = Self.contrast(in: pixels, rect: rect), measured.ratio < 4.5 else { return nil }
            let ratio = String(format: "%.1f:1", (measured.ratio * 10).rounded(.down) / 10)
            return AccessibilityIssue(
                severity: measured.ratio < 3 ? .error : .warning, rule: "low_contrast", element: element,
                message:
                    "\(element.role.contains("Text") ? "Text" : "Text or icon") contrast about \(ratio) (\(Self.hex(measured.text)) on \(Self.hex(measured.background))), below 4.5:1\(measured.ratio < 3 ? " and even the 3:1 for large text" : ""). Use a darker or lighter color.")
        }
    }

    /// Different targets with the same label: a screen reader user cannot tell which is which.
    /// An element and one inside it with the same label are one target.
    private func duplicateLabels(_ targets: [UIElement]) -> [AccessibilityIssue] {
        let labelled = targets.filter { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        let groups = Dictionary(grouping: labelled) { ElementQuery.folded($0.label) }
        return groups.values.compactMap { group -> AccessibilityIssue? in
            let separate = group.filter { element in
                !group.contains { other in
                    other != element && other.frame.insetBy(dx: -0.002, dy: -0.002).contains(element.frame)
                }
            }
            guard separate.count > 1 else { return nil }
            let sorted = separate.sorted { a, b in
                a.frame.minY == b.frame.minY ? a.frame.minX < b.frame.minX : a.frame.minY < b.frame.minY
            }
            return AccessibilityIssue(
                severity: .warning, rule: "duplicate_label", element: sorted[0], others: Array(sorted.dropFirst()),
                message:
                    "\(sorted.count) targets are all labeled \"\(sorted[0].label)\", so \(reader) users cannot tell them apart. Add what each one is about, such as \"\(sorted[0].label) photo 2\".")
        }
    }

    /// Labels a person would not say: file names, identifiers and the role again.
    private func unclearLabels(_ visible: [UIElement]) -> [AccessibilityIssue] {
        visible.compactMap { element in
            let label = element.label.trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !Self.isField(element.role),
                element.tappable || element.role.contains("Image") || element.role.contains("Button")
            else { return nil }
            if Self.isFileName(label) {
                return AccessibilityIssue(
                    severity: .error, rule: "unclear_label", element: element,
                    message:
                        "The label is a file name, which \(reader) reads out as it is. Describe what it shows or does instead, such as \"Close\".")
            }
            guard Self.isIdentifierLike(label) else { return nil }
            return AccessibilityIssue(
                severity: .warning, rule: "unclear_label", element: element,
                message:
                    "The label \"\(label)\" looks like an identifier or a generic name, not words a person would say. Describe what it shows or does.")
        }
    }

    // MARK: Helpers

    static func isField(_ role: String) -> Bool {
        ["Field", "EditText", "TextArea", "ComboBox", "AutoComplete"].contains { role.contains($0) }
    }

    /// Roles that show their label as text: iOS's StaticText, Button and Link, Android's TextView,
    /// Button and their kin. Fields are left out: what is typed into them is the user's.
    static func showsText(_ role: String) -> Bool {
        !isField(role) && (role.contains("Text") || role.contains("Button") || role == "Link")
    }

    static func isFileName(_ label: String) -> Bool {
        label.range(of: #"^[^\s/]+\.(png|jpe?g|gif|svg|pdf|webp|heic|tiff?|bmp|ico)$"#, options: [.regularExpression, .caseInsensitive])
            != nil
    }

    /// "ic_close", "btnBack", "closeButton", "chevron.right", "com.example:id/close", "IMG_0042",
    /// or just "button" or "image". Brand names such as "iPhone" are fine.
    static func isIdentifierLike(_ label: String) -> Bool {
        if ["button", "image", "icon", "img", "picture", "graphic", "untitled", "label"].contains(ElementQuery.folded(label)) {
            return true
        }
        guard label.count >= 3, !label.contains(where: \.isWhitespace) else { return false }
        let patterns = [
            #"_"#,
            #":id/"#,
            #"^(ic|img|icn|icon|btn|button|image|asset|bg)([-_.]|[A-Z0-9])"#,
            #"^[a-z]+([A-Z][a-z0-9]*)*(Button|Btn|Icon|Image|Img|View|Label|Cell)$"#,
            #"^[a-z0-9]+(\.[a-z0-9]+){2,}$"#,
            #"^[a-z0-9]+\.(fill|circle|square|right|left|up|down|forward|backward|slash|badge|plus|minus|horizontal|vertical|rectangle|ellipsis)$"#,
        ]
        return patterns.contains { label.range(of: $0, options: .regularExpression) != nil }
    }

    /// The contrast of the text inside `rect` (pixels of the image): the most common color is the
    /// background, and the frequent color that stands out from it most is the text. Nil when the
    /// background is not even enough to tell (a photo, a gradient) or nothing stands out.
    static func contrast(in pixels: PixelBuffer, rect: CGRect) -> (ratio: Double, text: [Double], background: [Double])? {
        let area = rect.intersection(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)).integral
        guard !area.isNull, area.width >= 4, area.height >= 4 else { return nil }
        let x0 = Int(area.minX), y0 = Int(area.minY), x1 = Int(area.maxX), y1 = Int(area.maxY)
        // Every pixel of a list row; large areas sampled to about as many.
        let step = max(1, Int((Double((x1 - x0) * (y1 - y0)) / 200_000).squareRoot()))
        // Colors in 16 levels per channel, with the exact average of each kept.
        var counts = [Int](repeating: 0, count: 4096)
        var sums = [Double](repeating: 0, count: 4096 * 3)
        var total = 0
        pixels.bytes.withUnsafeBufferPointer { bytes in
            for y in stride(from: y0, to: y1, by: step) {
                for x in stride(from: x0, to: x1, by: step) {
                    let offset = (y * pixels.width + x) * 4
                    let bin = Int(bytes[offset] >> 4) << 8 | Int(bytes[offset + 1] >> 4) << 4 | Int(bytes[offset + 2] >> 4)
                    counts[bin] += 1
                    sums[bin * 3] += Double(bytes[offset])
                    sums[bin * 3 + 1] += Double(bytes[offset + 1])
                    sums[bin * 3 + 2] += Double(bytes[offset + 2])
                    total += 1
                }
            }
        }
        func color(_ bin: Int) -> [Double] {
            let count = Double(counts[bin])
            return [sums[bin * 3] / count, sums[bin * 3 + 1] / count, sums[bin * 3 + 2] / count]
        }
        guard total > 0, let background = counts.indices.max(by: { counts[$0] < counts[$1] }),
            Double(counts[background]) >= Double(total) * 0.3
        else { return nil }
        let backgroundColor = color(background)
        // Antialiased edges fall between text and background, so the text's own color is the
        // farthest one that still covers a little of the area: a short label in a list row, such
        // as Settings' "Siri", covers well under 1% of it.
        let frequent = max(3, Int(Double(total) * 0.001))
        var best: (ratio: Double, color: [Double])?
        for bin in counts.indices where bin != background && counts[bin] >= frequent {
            let candidate = color(bin)
            let ratio = contrastRatio(candidate, backgroundColor)
            if ratio > (best?.ratio ?? 0) { best = (ratio, candidate) }
        }
        guard let best, best.ratio >= 1.1 else { return nil }
        return (best.ratio, best.color, backgroundColor)
    }

    /// WCAG's contrast ratio of two sRGB colors (0–255 per channel), from 1 to 21.
    static func contrastRatio(_ a: [Double], _ b: [Double]) -> Double {
        func luminance(_ color: [Double]) -> Double {
            func channel(_ value: Double) -> Double {
                let c = value / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color[0]) + 0.7152 * channel(color[1]) + 0.0722 * channel(color[2])
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func hex(_ color: [Double]) -> String {
        "#" + color.prefix(3).map { String(format: "%02X", Int(min(max($0.rounded(), 0), 255))) }.joined()
    }

    /// Pixels per point (iOS) or dp (Android) of a screen this size, for when the device does not
    /// say. iPads, and iPhones up to 828 px wide (XR, 11, SE), have 2 pixels per point, other
    /// iPhones 3. Android phones are about 411 dp wide.
    static func estimatedScale(width: Int, height: Int, android: Bool) -> Double {
        let short = Double(min(width, height))
        if android { return max(short / 411, 1) }
        return (1000..<1400).contains(short) ? 3 : 2
    }
}
