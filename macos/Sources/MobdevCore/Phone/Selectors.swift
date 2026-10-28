import CoreGraphics
import Foundation

/// A regular expression from a tool argument, with the text it was written as. Case-insensitive.
struct Pattern: CustomStringConvertible {
    let source: String
    let expression: NSRegularExpression

    init(_ source: String) throws {
        do {
            expression = try NSRegularExpression(pattern: source, options: [.caseInsensitive])
        } catch {
            throw ToolFailure("regex \"\(source)\" is not a valid regular expression.")
        }
        self.source = source
    }

    func matches(_ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    var description: String { "/\(source)/" }
}

/// A part of the screen an element must be in, by its center.
enum ScreenRegion: String, CaseIterable {
    case topHalf = "top_half"
    case bottomHalf = "bottom_half"
    case leftHalf = "left_half"
    case rightHalf = "right_half"
    case center

    func contains(_ point: NormalizedPoint) -> Bool {
        switch self {
        case .topHalf: point.y < 0.5
        case .bottomHalf: point.y >= 0.5
        case .leftHalf: point.x < 0.5
        case .rightHalf: point.x >= 0.5
        case .center: (0.25...0.75).contains(point.x) && (0.25...0.75).contains(point.y)
        }
    }
}

/// "The field below Email": a label to measure from, and the side of it an element must be on.
struct NearQuery: CustomStringConvertible {
    enum Direction: String, CaseIterable {
        case below, above, left, right, any
    }

    let text: String
    let direction: Direction

    /// `"Email"`, or `{"text": "Email", "direction": "below"}`.
    init(_ value: JSONValue) throws {
        if let text = value.stringValue, !text.isEmpty {
            self.text = text
            direction = .any
            return
        }
        guard let text = value["text"]?.stringValue, !text.isEmpty else {
            throw ToolFailure("near needs text, e.g. {\"text\": \"Email\", \"direction\": \"below\"}.")
        }
        self.text = text
        let raw = value["direction"]?.stringValue ?? "any"
        guard let direction = Direction(rawValue: raw) else {
            throw ToolFailure("near.direction must be one of \(Direction.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        self.direction = direction
    }

    /// Whether `frame` is on the asked side of `anchor`, by their centers; never the anchor itself.
    func accepts(_ frame: CGRect, anchor: CGRect) -> Bool {
        guard frame != anchor else { return false }
        switch direction {
        case .below: return frame.midY > anchor.midY
        case .above: return frame.midY < anchor.midY
        case .right: return frame.midX > anchor.midX
        case .left: return frame.midX < anchor.midX
        case .any: return true
        }
    }

    var description: String { direction == .any ? "near \"\(text)\"" : "\(direction.rawValue) \"\(text)\"" }
}

extension CGRect {
    /// Between the centers, for frames in fractions of a screen `aspect` times as wide as high.
    func distance(to other: CGRect, aspect: Double) -> Double { hypot((midX - other.midX) * aspect, midY - other.midY) }
}
