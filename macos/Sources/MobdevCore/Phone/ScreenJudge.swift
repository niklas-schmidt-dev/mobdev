import CoreGraphics
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// A model's answer to a yes/no question about a screen.
struct ScreenJudgement: Sendable, Equatable {
    enum Answer: String, Sendable {
        case yes, no
        /// The screen does not show enough to tell.
        case unsure
    }

    var answer: Answer
    /// What on the screen the answer rests on.
    var reason: String
    /// Whether the model looked at the screenshot, or only read the screen's text.
    var sawImage: Bool
}

/// Answers yes/no questions about a screen for `assert_with_ai`: Apple Intelligence on this Mac in
/// Mobdev, a fake in tests. Throws a `ToolFailure` that says why when it cannot answer.
protocol ScreenJudge: Sendable {
    /// `screenText` lists what is on screen, for a model that takes no images.
    func judge(_ question: String, screenshot: CGImage, screenText: String) async throws -> ScreenJudgement
}

/// Apple's on-device foundation model, through the FoundationModels framework: nothing leaves the
/// Mac. It looks at the screenshot where the model takes images (macOS 27), else reads the screen's
/// text. Not both: with the list of elements next to the picture, the model answered from the
/// list's first lines and missed text drawn over other text that it saw in the picture alone
/// (2026-10-07).
struct AppleIntelligenceJudge: ScreenJudge {
    static let instructions = """
        You are a careful tester who checks screenshots of a phone app during automated tests. \
        Answer the question about the screen with yes or no, judging only from what the screen shows. \
        Answer unsure when the screen does not show enough to tell. Give a short reason that names \
        what you see.
        """

    func judge(_ question: String, screenshot: CGImage, screenText: String) async throws -> ScreenJudgement {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        if case .unavailable(let reason) = model.availability { throw ToolFailure(Self.message(for: reason)) }
        var vision = false
        if #available(macOS 27, *) { vision = model.capabilities.contains(.vision) }
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        // A bound on the answer: once the model repeated itself until its context was full, which
        // took over three minutes (2026-10-07).
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 300)
        do {
            if #available(macOS 27, *), vision {
                let response = try await session.respond(generating: Verdict.self, options: options) {
                    "Question about this screen: \(question)"
                    Attachment(screenshot)
                }
                return response.content.judgement(sawImage: true)
            }
            guard !screenText.isEmpty else {
                throw ToolFailure("Apple Intelligence on this Mac takes no images, and the screen shows no text to judge from.")
            }
            let response = try await session.respond(
                to: "Question about the screen: \(question)\n\nWhat the screen shows, top to bottom:\n\(screenText)",
                generating: Verdict.self, options: options)
            return response.content.judgement(sawImage: false)
        } catch let failure as ToolFailure {
            throw failure
        } catch {
            throw ToolFailure("Apple Intelligence could not answer: \(Self.describe(error))")
        }
        #else
        throw ToolFailure(
            "assert_with_ai needs a Mobdev built with the macOS 26 SDK or later, which has Apple's FoundationModels framework.")
        #endif
    }

    #if canImport(FoundationModels)
    /// Why the model cannot answer, and what to do about it.
    static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            "This Mac cannot run Apple Intelligence, so assert_with_ai is not available on it. Use assert_screenshot, accessibility_audit or wait_for_element instead."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence is turned off on this Mac. Turn it on in System Settings › Apple Intelligence & Siri, then try again."
        case .modelNotReady:
            "Apple Intelligence's model is not ready on this Mac yet; it may still be downloading. Try again in a few minutes."
        @unknown default:
            "Apple Intelligence is not available on this Mac (\(reason))."
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription, !text.isEmpty { return text }
        return String(describing: error)
    }
    #endif
}

#if canImport(FoundationModels)
/// The answer the model fills in, reason first so it looks before it decides.
@Generable
struct Verdict {
    @Guide(
        description:
            "One or two sentences on what the screen shows that the answer rests on. Quote text from the screen in single quotes, never double quotes."
    )
    var reason: String
    @Guide(description: "yes or no, or unsure when the screen does not show enough to tell", .anyOf(["yes", "no", "unsure"]))
    var answer: String

    func judgement(sawImage: Bool) -> ScreenJudgement {
        ScreenJudgement(
            answer: ScreenJudgement.Answer(rawValue: answer.lowercased()) ?? .unsure,
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines), sawImage: sawImage)
    }
}
#endif
