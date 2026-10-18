import Foundation

actor AutoLearnReviewProposalStore {
    private struct LegacyStoredState: Decodable {
        let proposals: [AutoLearnReviewProposal]
        let dismissedPairs: [String]
    }

    private let fileManager: FileManager
    private let fileURL: URL
    private let dismissedPairsFileURL: URL
    private var proposals: [AutoLearnReviewProposal] = []
    private var dismissedPairs = Set<String>()
    private var isLoaded = false

    init(fileManager: FileManager = .default, fileURL: URL? = nil, dismissedPairsFileURL: URL? = nil) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let proposalsURL = fileURL ?? applicationSupport
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
            .appendingPathComponent("auto-learn-review-proposals.json")
        self.fileURL = proposalsURL
        self.dismissedPairsFileURL = dismissedPairsFileURL ?? proposalsURL.deletingLastPathComponent()
            .appendingPathComponent("auto-learn-dismissed-pairs.json")
    }

    func all() throws -> [AutoLearnReviewProposal] {
        try loadIfNeeded()
        return proposals
    }

    func append(
        decisions: [AutoLearnReviewDecision],
        candidates: [AutoLearnReviewCandidate]
    ) throws -> Int {
        try loadIfNeeded()
        let candidatesByID = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.candidateID, $0) }
        )
        let additions = decisions.compactMap { decision -> AutoLearnReviewProposal? in
            guard decision.learningAction != .rejectCorrection,
                let candidate = candidatesByID[decision.candidateID]
            else { return nil }

            return AutoLearnReviewProposal(
                id: UUID(),
                candidateID: decision.candidateID,
                originalText: candidate.originalText,
                correctedText: candidate.correctedText,
                learningAction: decision.learningAction,
                incorrectTextToReplace: decision.incorrectTextToReplace,
                correctedVocabularyTerm: decision.correctedVocabularyTerm
            )
        }
        var knownKeys = Set(proposals.map(Self.proposalKey))
        let uniqueAdditions = additions.filter {
            !dismissedPairs.contains(Self.correctionKey($0))
                && knownKeys.insert(Self.proposalKey($0)).inserted
        }
        guard !uniqueAdditions.isEmpty else { return 0 }
        let originalProposals = proposals
        proposals.append(contentsOf: uniqueAdditions)
        do {
            try save()
        } catch {
            proposals = originalProposals
            throw error
        }
        return uniqueAdditions.count
    }

    /// A user's declined correction also overrides later automatic AI learning.
    func excludingDismissed(
        _ decisions: [AutoLearnReviewDecision], candidates: [AutoLearnReviewCandidate]
    ) throws -> [AutoLearnReviewDecision] {
        try loadIfNeeded()
        guard !dismissedPairs.isEmpty else { return decisions }
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.candidateID, $0) })
        return decisions.filter { decision in
            if decision.learningAction == .rejectCorrection { return true }
            let proposedKey = Self.correctionKey(source: decision.incorrectTextToReplace,
                destination: decision.correctedVocabularyTerm)
            if dismissedPairs.contains(proposedKey) { return false }
            if let candidate = candidatesByID[decision.candidateID],
                let observed = CorrectionDiffEngine.replacementPair(from: .init(
                    original: candidate.originalText, corrected: candidate.correctedText)),
                dismissedPairs.contains(Self.correctionKey(source: observed.source, destination: observed.destination)) {
                return false
            }
            return true
        }
    }

    func remove(_ proposalIDs: Set<UUID>) throws {
        guard !proposalIDs.isEmpty else { return }
        try loadIfNeeded()
        let originalProposals = proposals
        let originalCount = proposals.count
        proposals.removeAll { proposalIDs.contains($0.id) }
        if proposals.count != originalCount {
            do {
                try save()
            } catch {
                proposals = originalProposals
                throw error
            }
        }
    }

    /// Explicit dismissal and an ignored popup both suppress this correction
    /// pair permanently. Approval removes a proposal without suppressing it.
    func dismiss(_ proposalIDs: Set<UUID>) throws {
        guard !proposalIDs.isEmpty else { return }
        try loadIfNeeded()
        let dismissed = proposals.filter { proposalIDs.contains($0.id) }
        guard !dismissed.isEmpty else { return }

        let updatedPairs = dismissedPairs.union(dismissed.map(Self.correctionKey))
        try write(updatedPairs.sorted(), to: dismissedPairsFileURL)
        dismissedPairs = updatedPairs
        proposals.removeAll { dismissedPairs.contains(Self.correctionKey($0)) }
        // History is authoritative and already saved. If proposal cleanup fails,
        // loading still filters these pairs, and the next save cleans up the file.
        try? save()
    }

    func update(
        proposalID: UUID,
        incorrectTextToReplace: String?,
        correctedVocabularyTerm: String
    ) throws {
        try loadIfNeeded()
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }) else { return }

        let proposal = proposals[index]
        let updatedProposal = AutoLearnReviewProposal(
            id: proposal.id,
            candidateID: proposal.candidateID,
            originalText: proposal.originalText,
            correctedText: proposal.correctedText,
            learningAction: proposal.learningAction,
            incorrectTextToReplace: incorrectTextToReplace,
            correctedVocabularyTerm: correctedVocabularyTerm
        )
        guard Self.proposalKey(updatedProposal) != Self.proposalKey(proposal) else { return }

        let originalProposals = proposals
        proposals[index] = updatedProposal
        do {
            try save()
        } catch {
            proposals = originalProposals
            throw error
        }
    }

    private func loadIfNeeded() throws {
        guard !isLoaded else { return }
        let decoder = JSONDecoder()
        var loadedDismissedPairs = Set<String>()
        if fileManager.fileExists(atPath: dismissedPairsFileURL.path) {
            let data = try Data(contentsOf: dismissedPairsFileURL)
            loadedDismissedPairs = Set(try decoder.decode([String].self, from: data))
        }

        var loadedProposals: [AutoLearnReviewProposal] = []
        if fileManager.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            if let legacy = try? decoder.decode(LegacyStoredState.self, from: data) {
                loadedDismissedPairs.formUnion(legacy.dismissedPairs)
                loadedProposals = legacy.proposals.filter { !loadedDismissedPairs.contains(Self.correctionKey($0)) }
                // Save history first so interrupted migration cannot lose it.
                try write(loadedDismissedPairs.sorted(), to: dismissedPairsFileURL)
                try write(loadedProposals, to: fileURL)
            } else {
                loadedProposals = try decoder.decode([AutoLearnReviewProposal].self, from: data)
            }
        }
        dismissedPairs = loadedDismissedPairs
        proposals = loadedProposals.filter { !dismissedPairs.contains(Self.correctionKey($0)) }
        isLoaded = true
    }

    private func save() throws {
        try write(proposals, to: fileURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func proposalKey(_ proposal: AutoLearnReviewProposal) -> String {
        [
            proposal.learningAction.rawValue,
            correctionKey(proposal)
        ].joined(separator: "\u{0}")
    }

    private static func correctionKey(_ proposal: AutoLearnReviewProposal) -> String {
        correctionKey(source: proposal.incorrectTextToReplace, destination: proposal.correctedVocabularyTerm)
    }

    private static func correctionKey(source: String?, destination: String?) -> String {
        [
            WordReplacementVariants.key(for: source ?? ""),
            WordReplacementVariants.destinationKey(for: destination ?? "")
        ].joined(separator: "\u{0}")
    }
}
