import CoreGraphics
import CoreText
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

    /// Recognizes one rendered word. The first recognition in a new app binary loads and compiles
    /// Vision's models, which takes around 45 seconds; running it at launch keeps an agent's first
    /// read_screen or tap_text fast, also right after an update.
    public static func warmUp() {
        let width = 480, height = 120
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 56, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        context.textPosition = CGPoint(x: 24, y: 40)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Mobdev", attributes: attributes)), context)
        guard let image = context.makeImage() else { return }
        let started = Date()
        _ = try? recognize(image)
        Log.info(String(format: "text recognition ready after %.1f s", Date().timeIntervalSince(started)))
    }

    /// Vision can stall, for example while it compiles its models for the Neural Engine. Callers
    /// wait at most this long, so an agent gets an answer instead of a tool that never returns.
    static let timeout: TimeInterval = 90

    private static func recognize(_ image: CGImage) throws -> [VNRecognizedTextObservation] {
        let done = DispatchSemaphore(value: 0)
        let result = Locked<Result<[VNRecognizedTextObservation], any Error>?>(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            result.set(Result { try perform(image) })
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let finished = result.get() else {
            throw ToolFailure(
                "Text recognition did not answer within \(Int(timeout)) s; Vision may still be preparing its models. Try again in a minute, or use screenshot.")
        }
        return try finished.get()
    }

    private static func perform(_ image: CGImage) throws -> [VNRecognizedTextObservation] {
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
