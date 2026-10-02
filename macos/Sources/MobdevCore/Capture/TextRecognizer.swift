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

/// Why text recognition gave no answer.
public struct TextRecognitionError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// On-device text recognition with Apple's Vision framework. Nothing leaves the Mac.
///
/// The app recognizes text in a fresh process for every call, `Mobdev __text`. In the app's own
/// process, Vision on the Neural Engine once failed every request with e5rt error 13 after about a
/// hundred had worked, until Mobdev restarted, while a fresh process read the same screens
/// (2026-10-02). Vision has also stalled for over ten minutes; a helper that hangs can be killed.
/// A fresh process adds about 0.1 s.
public enum TextRecognizer {
    public static func lines(in image: CGImage) throws -> [TextMatch] {
        try read(image, query: nil)
    }

    /// Occurrences of `query`, exact line matches first, then top to bottom.
    public static func find(_ query: String, in image: CGImage) throws -> [TextMatch] {
        try read(image, query: query)
    }

    /// Every line when `query` is nil, otherwise the occurrences of `query`.
    static func read(_ image: CGImage, query: String?, timeout: TimeInterval = timeout) throws -> [TextMatch] {
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle?.isEmpty == true { return [] }
        if let helper {
            if let matches = try recognize(image, query: needle, helper: helper, timeout: timeout) { return matches }
        }
        let observations = try inProcess(image, timeout: timeout)
        return needle.map { matches(of: $0, in: observations) } ?? lines(observations)
    }

    /// Recognizes one rendered word. The first recognition in a new app binary loads and compiles
    /// Vision's models, which took 45 to 60 seconds on an M4 Max; running it at launch keeps an
    /// agent's first read_screen or tap_text fast, also right after an update. It may take longer
    /// than a tool may wait, so that a slower Mac finishes compiling instead of starting over.
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
        do {
            _ = try read(image, query: nil, timeout: 600)
            Log.info(String(format: "text recognition ready after %.1f s", Date().timeIntervalSince(started)))
        } catch {
            Log.error("text recognition warm-up: \(error)")
        }
    }

    /// Vision can stall, for example while it compiles its models for the Neural Engine. Callers
    /// wait at most this long, so an agent gets an answer instead of a tool that never returns.
    static let timeout: TimeInterval = 90

    static func timedOut(after timeout: TimeInterval) -> TextRecognitionError {
        TextRecognitionError(
            "Text recognition did not answer within \(Int(timeout)) s; Vision may still be preparing its models.")
    }

    // MARK: Helper process

    /// The Mobdev executable, which recognizes text with `Mobdev __text`. Nil in tests, unless
    /// MOBDEV_TEXT_HELPER names the executable.
    static let helper: URL? = {
        if let custom = ProcessInfo.processInfo.environment["MOBDEV_TEXT_HELPER"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        guard let executable = Bundle.main.executableURL, executable.lastPathComponent == "Mobdev" else { return nil }
        return executable
    }()

    /// The matches from `Mobdev __text`, which reads the image's pixels from standard input. Nil
    /// when the helper does not start; the caller then recognizes in its own process.
    static func recognize(_ image: CGImage, query: String?, helper: URL, timeout: TimeInterval = timeout) throws
        -> [TextMatch]?
    {
        guard let pixels = pixels(of: image) else { throw TextRecognitionError("Could not read the screen's pixels.") }
        let arguments = ["__text", String(image.width), String(image.height)] + (query.map { [$0] } ?? [])
        let started = Date()
        let status: Int32
        let data: Data
        do {
            (status, data) = try ProcessRunner().runBinary(helper, arguments, input: pixels, timeout: timeout)
        } catch {
            Log.error("text recognition helper did not start: \(error)")
            return nil
        }
        let value = try? JSONValue.parse(data)
        if status == 0, let items = value?.arrayValue { return items.compactMap(match(from:)) }
        if let error = value?["error"]?.stringValue { throw TextRecognitionError(error) }
        if Date().timeIntervalSince(started) >= timeout { throw timedOut(after: timeout) }
        throw TextRecognitionError("The text recognition process ended without an answer (exit \(status)).")
    }

    /// `Mobdev __text <width> <height> [query]`: recognizes text in raw BGRA pixels from standard
    /// input and prints the matches as JSON, or {"error": …} with exit status 1.
    public static func runHelper(_ arguments: [String]) -> Never {
        var status: Int32 = 0
        let output: JSONValue
        do {
            guard arguments.count == 2 || arguments.count == 3, let width = Int(arguments[0]),
                let height = Int(arguments[1]), (1...16384).contains(width), (1...16384).contains(height)
            else { throw TextRecognitionError("Usage: Mobdev __text <width> <height> [query] < pixels") }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let screen = image(fromPixels: input, width: width, height: height) else {
                throw TextRecognitionError("Expected \(width * height * 4) bytes of BGRA pixels, got \(input.count).")
            }
            let observed = try observations(in: screen)
            let result = arguments.count == 3 ? matches(of: arguments[2], in: observed) : lines(observed)
            output = .array(result.map(json))
        } catch {
            output = ["error": .string(String(describing: error))]
            status = 1
        }
        FileHandle.standardOutput.write(output.encoded())
        exit(status)
    }

    /// Premultiplied BGRA, row after row without padding.
    static func pixels(of image: CGImage) -> Data? {
        let width = image.width, height = image.height
        var data = Data(count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }

    static func image(fromPixels data: Data, width: Int, height: Int) -> CGImage? {
        guard data.count == width * height * 4, let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func json(_ match: TextMatch) -> JSONValue {
        [
            "text": .string(match.text), "confidence": .number(Double(match.confidence)), "exact": .bool(match.exact),
            "box": [.number(match.box.minX), .number(match.box.minY), .number(match.box.width), .number(match.box.height)],
        ]
    }

    static func match(from value: JSONValue) -> TextMatch? {
        guard let text = value["text"]?.stringValue, let box = value["box"]?.arrayValue?.compactMap(\.doubleValue),
            box.count == 4
        else { return nil }
        return TextMatch(
            text: text, box: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]),
            confidence: Float(value["confidence"]?.doubleValue ?? 0), exact: value["exact"]?.boolValue ?? false)
    }

    // MARK: Recognition

    /// In this process, for tests and a bare `swift run`, given up after `timeout`.
    private static func inProcess(_ image: CGImage, timeout: TimeInterval) throws -> [VNRecognizedTextObservation] {
        let done = DispatchSemaphore(value: 0)
        let result = Locked<Result<[VNRecognizedTextObservation], any Error>?>(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            result.set(Result { try observations(in: image) })
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, let finished = result.get() else {
            throw timedOut(after: timeout)
        }
        return try finished.get()
    }

    /// Vision on its default devices (the Neural Engine), and on the CPU if that fails: the CPU
    /// still worked in a process where the Neural Engine failed, at about 160 ms per screen instead
    /// of 90 ms (M4 Max).
    static func observations(
        in image: CGImage,
        perform: (CGImage, _ cpuOnly: Bool) throws -> [VNRecognizedTextObservation] = perform(_:cpuOnly:)
    ) throws -> [VNRecognizedTextObservation] {
        do {
            return try perform(image, false)
        } catch {
            Log.error("text recognition failed, trying the CPU: \(error)")
            do {
                return try perform(image, true)
            } catch let cpuError {
                throw TextRecognitionError("Vision failed: \(error); on the CPU: \(cpuError)")
            }
        }
    }

    static func perform(_ image: CGImage, cpuOnly: Bool) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        if cpuOnly {
            for (stage, devices) in try request.supportedComputeStageDevices {
                guard let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) else { continue }
                request.setComputeDevice(cpu, for: stage)
            }
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results ?? []
    }

    static func lines(_ observations: [VNRecognizedTextObservation]) -> [TextMatch] {
        observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextMatch(
                text: candidate.string, box: topLeft(observation.boundingBox), confidence: candidate.confidence,
                exact: false)
        }
        .sorted(by: readingOrder)
    }

    static func matches(of query: String, in observations: [VNRecognizedTextObservation]) -> [TextMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var matches: [TextMatch] = []
        for observation in observations {
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

    private static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    static func readingOrder(_ lhs: TextMatch, _ rhs: TextMatch) -> Bool {
        if abs(lhs.box.midY - rhs.box.midY) > 0.01 { return lhs.box.midY < rhs.box.midY }
        return lhs.box.minX < rhs.box.minX
    }
}
