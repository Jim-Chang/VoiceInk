import Foundation
import OSLog

enum AutoLearnLocalReviewPolicy {
    static let maximumWords = 3

    static func accepts(source: String?, destination: String) -> Bool {
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        let source = source?.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        let terms = [source, destination].compactMap { $0 }
        return terms.allSatisfy { term in
            !term.isEmpty && term.count <= AutoLearnLimits.maximumCandidateCharacters
                && term.split(whereSeparator: \.isWhitespace).count <= maximumWords
                && term.contains(where: \.isLetter)
                && !term.unicodeScalars.contains {
                    CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
                }
        } && source?.contains(",") != true && source != destination
    }
}

struct AutoLearnLocalReviewer: Sendable {
    private struct Evaluation {
        var pair: (source: String, destination: String)? = nil
        let reason: String
    }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AutoLearnLocalReview")

    /// Structural checks only. The user decides whether a short edit is reusable.
    func review(_ candidates: [AutoLearnReviewCandidate],
        batchID: UUID = UUID()) async throws -> [AutoLearnReviewDecision] {
        var suggestions: [AutoLearnReviewDecision] = []
        for candidate in candidates {
            await Task.yield()
            try Task.checkCancellation()
            let evaluation = evaluate(candidate)
            guard let pair = evaluation.pair else {
                logger.notice("Auto Learn local candidate skipped batchID=\(batchID.uuidString, privacy: .public) candidateID=\(candidate.candidateID.uuidString, privacy: .public) reason=\(evaluation.reason, privacy: .public)")
                continue
            }
            suggestions.append(.init(candidateID: candidate.candidateID,
                learningAction: .addReplacementOnly,
                incorrectTextToReplace: pair.source,
                correctedVocabularyTerm: pair.destination))
            logger.notice("Auto Learn local suggestion batchID=\(batchID.uuidString, privacy: .public) candidateID=\(candidate.candidateID.uuidString, privacy: .public) requiresApproval=true")
        }
        return suggestions
    }

    private func evaluate(_ candidate: AutoLearnReviewCandidate) -> Evaluation {
        let original = candidate.originalText.precomposedStringWithCanonicalMapping
        let corrected = candidate.correctedText.precomposedStringWithCanonicalMapping
        guard original.count <= 1_024, corrected.count <= 1_024 else { return .init(reason: "contextTooLong") }
        guard let pair = CorrectionDiffEngine.replacementPair(from: .init(original: original, corrected: corrected))
        else { return .init(reason: "ambiguousEdit") }
        guard AutoLearnLocalReviewPolicy.accepts(source: pair.source, destination: pair.destination)
        else { return .init(reason: "ineligibleCorrection") }
        return .init(pair: pair, reason: "wordOrPhraseCorrection")
    }
}
