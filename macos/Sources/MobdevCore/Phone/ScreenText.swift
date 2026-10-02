import CoreGraphics
import Foundation

/// Text on the screen for read_screen, find_text, tap_text and wait_for_text.
struct ScreenText {
    var matches: [TextMatch]
    /// The matches are the UI tree's labels, because text recognition failed.
    var fromTree: Bool
}

extension PhoneTools {
    static let fromTreeNote = "Text recognition failed, so Mobdev read the UI tree instead."

    /// Every line (query nil) or where `query` is, from Vision's text recognition. When that fails
    /// on a device with a UI tree (simulators, Android, iPhones with Mobdev Runner), from the tree's
    /// labels; with `treeOnly`, without trying recognition first.
    func screenText(_ query: String?, in frame: CGImage, treeOnly: Bool = false) async throws -> ScreenText {
        var failure: TextRecognitionError?
        if !treeOnly {
            let readText = self.readText
            do {
                // Off the cooperative threads: recognition can take up to TextRecognizer.timeout.
                let matches = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(with: Result { try readText(frame, query) })
                    }
                }
                return ScreenText(matches: matches, fromTree: false)
            } catch let error as TextRecognitionError {
                Log.error("text recognition: \(error)")
                failure = error
            }
        }
        if let elements = try? await phone.uiTree() {
            return ScreenText(matches: Self.text(in: elements, query: query), fromTree: true)
        }
        // The first line is what the activity list shows; the details are for whoever debugs it.
        throw ToolFailure(
            """
            Text recognition failed in macOS, so Mobdev cannot read the text on this screen right now. Use screenshot to look at it; the next call may work again.
            Details: \(failure.map(String.init(describing:)) ?? "the UI tree could not be read either")
            """)
    }

    /// The UI tree's text: every element with a label or value, or those whose label (else value)
    /// contains `query`, preferring exact labels and what can be tapped, top to bottom.
    static func text(in elements: [UIElement], query: String?) -> [TextMatch] {
        func match(_ element: UIElement, _ text: String, exact: Bool) -> TextMatch {
            TextMatch(text: text, box: element.frame, confidence: 1, exact: exact)
        }
        guard let query else {
            return ElementQuery.onePerPlace(elements.filter { !$0.label.isEmpty || !$0.value.isEmpty })
                .map { element in
                    let text =
                        element.value.isEmpty || element.value == element.label
                        ? element.label
                        : element.label.isEmpty ? element.value : "\(element.label): \(element.value)"
                    return match(element, text, exact: false)
                }
                .sorted(by: TextRecognizer.readingOrder)
        }
        let needle = ElementQuery.folded(query)
        guard !needle.isEmpty else { return [] }
        let labelled = ElementQuery(id: nil, text: query).matches(in: elements)
        let found =
            labelled.isEmpty
            ? ElementQuery.onePerPlace(elements.filter { ElementQuery.folded($0.value).contains(needle) })
                .map { match($0, $0.value, exact: ElementQuery.folded($0.value) == needle) }
            : labelled.map { match($0, $0.label, exact: ElementQuery.folded($0.label) == needle) }
        return found.sorted(by: TextRecognizer.readingOrder)
    }
}
