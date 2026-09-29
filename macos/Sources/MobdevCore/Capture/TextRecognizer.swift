import CoreGraphics
import Foundation
import Vision

/// Text found on the screen. `box` is normalized to the screen with a top-left origin.
public struct TextMatch: Sendable, Equatable {
    public let text: String
    public let box: CGRect
    public let confidence: Float
    /// True when the whole recognized line equals the query (ignoring case and accents).
    public let exact: Bool

    public var center: NormalizedPoint { NormalizedPoint(x: box.midX, y: box.midY) }
}

/// On-device text recognition with Apple's Vision framework. Nothing leaves the Mac.
public enum TextRecognizer {
    public static func lines(in image: CGImage) throws -> [TextMatch] {
        try recognize(image).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextMatch(
                text: candidate.string, box: topLeft(observation.boundingBox), confidence: candidate.confidence,
                exact: false)
        }
        .sorted(by: readingOrder)
    }

    /// Occurrences of `query`, exact line matches first, then top to bottom.
    public static func find(_ query: String, in image: CGImage) throws -> [TextMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var matches: [TextMatch] = []
        for observation in try recognize(image) {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.compare(needle, options: options) == .orderedSame {
                matches.append(
                    TextMatch(
                        text: line, box: topLeft(observation.boundingBox), confidence: candidate.confidence,
                        exact: true))
                continue
            }
            var searchRange = line.startIndex..<line.endIndex
            while let range = line.range(of: needle, options: options, range: searchRange) {
                let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                matches.append(
                    TextMatch(
                        text: String(line[range]), box: topLeft(box), confidence: candidate.confidence, exact: false))
                searchRange = range.upperBound..<line.endIndex
            }
        }
        return matches.sorted { lhs, rhs in
            if lhs.exact != rhs.exact { return lhs.exact }
            return readingOrder(lhs, rhs)
        }
    }

    private static func recognize(_ image: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results ?? []
    }

    private static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    private static func readingOrder(_ lhs: TextMatch, _ rhs: TextMatch) -> Bool {
        if abs(lhs.box.midY - rhs.box.midY) > 0.01 { return lhs.box.midY < rhs.box.midY }
        return lhs.box.minX < rhs.box.minX
    }
}
