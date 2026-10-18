import Foundation
import OSLog
import SwiftData

actor AutoLearnService {
    static let shared = AutoLearnService()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AutoLearn")
    private let accessibilityRuntime = AutoLearnAXRuntime()
    private let focusObserver = AutoLearnFocusObserver()
    private let pendingQueue = AutoLearnPendingQueue()
    private let reviewProposalStore = AutoLearnReviewProposalStore()

    private var replacementStore: WordReplacementStore?
    private var reviewer: AutoLearnAIReviewer?
    private var lifecycleGeneration: UInt64 = 0
    private var snapshotCancellationGeneration: UInt64 = 0
    private var activeToken: AutoLearnPasteToken?
    private var activeGeneration: UInt64?
    private var activeProcessID: pid_t?
    private var deadlineTask: Task<Void, Never>?
    private var focusFinalizationTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    private var reviewGeneration: UInt64 = 0
    private var claimedCandidateIDs = Set<UUID>()
    private var providerAvailabilityObserver: NSObjectProtocol?

    private init() {}

    func configure(modelContainer: ModelContainer, reviewer: AutoLearnAIReviewer) async {
        guard replacementStore == nil else { return }
        let store = WordReplacementStore(modelContainer: modelContainer)
        replacementStore = store
        self.reviewer = reviewer
        observeProviderAvailability()
        do {
            try await pendingQueue.recoverInterruptedReviews()
            await notifyQueueChanged()
            await notifyReviewProposalsChanged()
            await schedulePendingReview()
        } catch {
            log(error, message: "Failed to recover queued Auto Learn reviews")
        }
    }

    /// Retry queued work after provider settings change.
    private func observeProviderAvailability() {
        guard providerAvailabilityObserver == nil else { return }
        providerAvailabilityObserver = NotificationCenter.default.addObserver(
            forName: .AppSettingsDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task {
                await AutoLearnService.shared.serviceConfigurationDidChange()
            }
        }
    }

    func serviceConfigurationDidChange() async {
        guard AutoLearnSettings.isEnabled else { return }
        guard (try? await pendingQueue.pendingCount()) ?? 0 > 0 else { return }
        await schedulePendingReview()
    }

    func settingDidChange(isEnabled: Bool) async {
        await cancelReviewTask()
        if isEnabled {
            await notifyReviewProposalsChanged()
            await schedulePendingReview()
            return
        }
        lifecycleGeneration &+= 1
        await discardActiveSession()
        await MainActor.run { AutoLearnSuggestionController.shared.update([]) }
    }

    func reviewMethodDidChange() async {
        await cancelReviewTask()
        if UserDefaults.standard.bool(forKey: AutoLearnSettings.isAIReviewFailureKey) {
            AutoLearnSettings.clearFailure()
        }
        await schedulePendingReview()
    }

    func reviewProposals() async throws -> [AutoLearnReviewProposal] {
        try await reviewProposalStore.all()
    }

    func reviewProposalCount() async throws -> Int {
        let proposals = try await reviewProposalStore.all()
        return proposals.count
    }

    func applyReviewProposals(
        _ selections: [AutoLearnReviewSelection]
    ) async throws -> AutoLearnMutationSummary {
        guard let replacementStore, !selections.isEmpty else { return .empty }
        for selection in selections where selection.includesReplacement || selection.includesVocabulary {
            let source = selection.includesReplacement ? selection.incorrectTextToReplace ?? "" : nil
            guard AutoLearnLocalReviewPolicy.accepts(source: source,
                destination: selection.correctedVocabularyTerm) else { return .empty }
        }
        let selectionsByID = Dictionary(
            uniqueKeysWithValues: selections.map { ($0.proposalID, $0) }
        )
        let proposals = try await reviewProposalStore.all().filter {
            selectionsByID[$0.id] != nil
        }
        guard !proposals.isEmpty else { return .empty }

        let candidates = Dictionary(
            proposals.map { ($0.candidateID, $0.reviewCandidate) },
            uniquingKeysWith: { first, _ in first }
        ).values.map { $0 }
        let decisions = proposals.compactMap { proposal -> AutoLearnReviewDecision? in
            guard let selection = selectionsByID[proposal.id] else { return nil }
            let action: AutoLearnReviewAction
            switch (selection.includesReplacement, selection.includesVocabulary) {
            case (true, true):
                action = .addReplacementAndVocabulary
            case (true, false):
                action = .addReplacementOnly
            case (false, true):
                action = .addVocabularyOnly
            case (false, false):
                return nil
            }
            return AutoLearnReviewDecision(
                candidateID: proposal.candidateID,
                learningAction: action,
                incorrectTextToReplace: action == .addVocabularyOnly
                    ? nil
                    : selection.incorrectTextToReplace,
                correctedVocabularyTerm: selection.correctedVocabularyTerm
            )
        }
        guard !decisions.isEmpty else { return .empty }
        let summary = try await replacementStore.apply(decisions, candidates: candidates)
        // Editing a suggestion approves a different rule. Remember the original
        // unaccepted pair so the narrower or incorrect mapping is not offered again.
        let editedProposalIDs = Set(proposals.compactMap { proposal -> UUID? in
            guard let selection = selectionsByID[proposal.id] else { return nil }
            let sourceChanged = WordReplacementVariants.key(for: proposal.incorrectTextToReplace ?? "")
                != WordReplacementVariants.key(for: selection.incorrectTextToReplace ?? "")
            let destinationChanged = WordReplacementVariants.destinationKey(for: proposal.correctedVocabularyTerm ?? "")
                != WordReplacementVariants.destinationKey(for: selection.correctedVocabularyTerm)
            return sourceChanged || destinationChanged ? proposal.id : nil
        })
        try await reviewProposalStore.dismiss(editedProposalIDs)
        try await reviewProposalStore.remove(Set(proposals.map(\.id)))
        await notifyReviewProposalsChanged()

        if summary.hasChanges {
            await MainActor.run {
                NotificationCenter.default.post(name: .wordReplacementsDidChange, object: nil)
            }
            await showLearnedNotification(for: summary)
        }
        return summary
    }

    func dismissReviewProposals(_ proposalIDs: Set<UUID>) async throws {
        try await reviewProposalStore.dismiss(proposalIDs)
        await notifyReviewProposalsChanged()
    }

    func updateReviewProposal(
        proposalID: UUID,
        incorrectTextToReplace: String?,
        correctedVocabularyTerm: String
    ) async throws {
        try await reviewProposalStore.update(
            proposalID: proposalID,
            incorrectTextToReplace: incorrectTextToReplace,
            correctedVocabularyTerm: correctedVocabularyTerm
        )
    }

    func retryPendingReviews() async {
        await schedulePendingReview()
    }

    func outstandingReviewCount() async throws -> Int {
        try await pendingQueue.outstandingCount()
    }

    func recordingDidStart() async {
        guard AutoLearnSettings.isEnabled else { return }
        if let token = activeToken {
            await completeSession(token: token, persist: true)
        }
        lifecycleGeneration &+= 1
        await discardActiveSession()
    }

    func pasteDidFinish(text: String, processID: pid_t?, commandPosted: Bool) async -> UInt64? {
        guard AutoLearnSettings.isEnabled,
            replacementStore != nil,
            commandPosted,
            let processID
        else {
            return nil
        }

        // Finalize the previous session after Command-V so Accessibility and
        // SwiftData work do not delay the paste.
        let previousToken = activeToken
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        deadlineTask?.cancel()
        deadlineTask = nil
        focusFinalizationTask?.cancel()
        focusFinalizationTask = nil
        focusObserver.stop()
        activeToken = nil
        activeGeneration = nil
        activeProcessID = nil

        guard lifecycleGeneration == generation, AutoLearnSettings.isEnabled else { return nil }

        deadlineTask = Task { [weak self] in
            if let previousToken {
                // `finishSnapshot` drops the session, so the pending capture is
                // cancelled before a new one can be started.
                await self?.persistFinishedSession(token: previousToken)
            }
            await self?.beginObservation(
                text: text,
                processID: processID,
                generation: generation
            )
        }
        return generation
    }

    func cancelForAutoSend(generation: UInt64) async {
        guard AutoLearnSettings.isEnabled else { return }
        guard lifecycleGeneration == generation else { return }
        lifecycleGeneration &+= 1
        await discardActiveSession()
    }

    func shutdown() async {
        lifecycleGeneration &+= 1
        await cancelReviewTask()
        await discardActiveSession()
        await MainActor.run { AutoLearnSuggestionController.shared.update([]) }
    }

    func focusMayHaveChanged(token: AutoLearnPasteToken) {
        guard AutoLearnSettings.isEnabled, activeToken == token else { return }
        focusFinalizationTask?.cancel()
        focusFinalizationTask = Task { [weak self] in
            await self?.finalizeIfFocusLeft(token: token)
        }
    }

    private func beginObservation(
        text: String,
        processID: pid_t,
        generation: UInt64
    ) async {
        guard await sleep(nanoseconds: AutoLearnLimits.verificationDelayNanoseconds),
            !Task.isCancelled,
            lifecycleGeneration == generation,
            AutoLearnSettings.isEnabled
        else { return }

        guard let token = await accessibilityRuntime.capturePastedText(
                text: text,
                processID: processID
            )
        else { return }

        guard lifecycleGeneration == generation,
            !Task.isCancelled,
            AutoLearnSettings.isEnabled
        else {
            await accessibilityRuntime.discard(token: token)
            return
        }

        activeToken = token
        activeGeneration = generation
        activeProcessID = processID
        focusObserver.start(processID: processID, token: token) { token in
            Task {
                await AutoLearnService.shared.focusMayHaveChanged(token: token)
            }
        }
        scheduleDeadline(
            token: token,
            after: AutoLearnLimits.observationDurationNanoseconds
        )
    }

    private func discardActiveSession() async {
        snapshotCancellationGeneration &+= 1
        let token = activeToken
        deadlineTask?.cancel()
        deadlineTask = nil
        focusFinalizationTask?.cancel()
        focusFinalizationTask = nil
        focusObserver.stop()
        activeToken = nil
        activeGeneration = nil
        activeProcessID = nil
        if let token {
            await accessibilityRuntime.discard(token: token)
        } else {
            await accessibilityRuntime.discard()
        }
    }

    private func completeSession(token: AutoLearnPasteToken, persist: Bool) async {
        guard activeToken == token, activeGeneration != nil else { return }
        deadlineTask?.cancel()
        activeToken = nil
        activeGeneration = nil
        activeProcessID = nil
        deadlineTask = nil
        focusFinalizationTask?.cancel()
        focusFinalizationTask = nil
        focusObserver.stop()

        if persist {
            await persistFinishedSession(token: token)
        } else {
            await accessibilityRuntime.discard(token: token)
        }
    }

    private func persistFinishedSession(token: AutoLearnPasteToken) async {
        let cancellationGeneration = snapshotCancellationGeneration
        let snapshot = await accessibilityRuntime.finishSnapshot(token: token)
        guard snapshotCancellationGeneration == cancellationGeneration else { return }
        await persistSnapshot(snapshot)
    }

    private func finalizeIfFocusLeft(token: AutoLearnPasteToken) async {
        guard await sleep(nanoseconds: AutoLearnLimits.focusChangeGraceNanoseconds),
            !Task.isCancelled,
            activeToken == token,
            AutoLearnSettings.isEnabled
        else {
            return
        }

        guard !(await accessibilityRuntime.targetIsFocused(token: token)) else { return }
        await completeSession(token: token, persist: true)
    }

    private func scheduleDeadline(token: AutoLearnPasteToken, after delay: UInt64) {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            guard let self,
                await self.sleep(nanoseconds: delay),
                !Task.isCancelled
            else { return }
            await self.finalizeAtDeadline(token: token)
        }
    }

    private func finalizeAtDeadline(token: AutoLearnPasteToken) async {
        guard activeToken == token, AutoLearnSettings.isEnabled else { return }
        await completeSession(token: token, persist: true)
    }

    private func persistSnapshot(_ snapshot: AutoLearnFieldSnapshot?) async {
        guard AutoLearnSettings.isEnabled,
            let snapshot
        else { return }

        guard let revision = FinalSnapshotDiffEngine.revision(from: snapshot) else { return }
        let candidates = CorrectionDiffEngine.candidates(from: revision)
        guard !candidates.isEmpty else { return }

        do {
            let insertedCount = try await pendingQueue.enqueue(candidates)
            if insertedCount > 0 {
                logger.notice(
                    "Queued \(insertedCount, privacy: .public) Auto Learn candidate(s) for review"
                )
                await schedulePendingReview()
            }
            await notifyQueueChanged()
        } catch {
            log(error, message: "Failed to queue Auto Learn candidates")
        }
    }

    private func schedulePendingReview() async {
        guard reviewTask == nil, AutoLearnSettings.isEnabled, replacementStore != nil else { return }
        let count = (try? await pendingQueue.pendingCount()) ?? 0
        guard count > 0, reviewTask == nil, AutoLearnSettings.isEnabled else { return }

        reviewGeneration &+= 1
        let generation = reviewGeneration
        reviewTask = Task { [weak self] in
            await self?.processPendingReviewBatch(generation: generation)
        }
    }

    private func processPendingReviewBatch(generation: UInt64) async {
        guard !Task.isCancelled, reviewGeneration == generation,
            AutoLearnSettings.isEnabled, let replacementStore else {
            try? await releaseAllClaimsToQueue()
            await finishReviewTask(generation: generation)
            return
        }

        let usesAIReview = AutoLearnSettings.isAIReviewEnabled
        let batchID = UUID()
        do {
            let candidates = try await pendingQueue.claimPending(limit: AutoLearnLimits.maximumReviewBatchCandidates)
            let candidateIDs = Set(candidates.map(\.candidateID))
            claimedCandidateIDs.formUnion(candidateIDs)
            guard !candidates.isEmpty else {
                await finishReviewTask(generation: generation)
                await schedulePendingReview()
                return
            }

            var automaticDecisions: [AutoLearnReviewDecision] = []
            var suggestions: [AutoLearnReviewDecision] = []
            if usesAIReview, let reviewer {
                do {
                    let result = try await reviewer.review(candidates, batchID: batchID)
                    automaticDecisions = result.reviewDecisions
                    // Invalid or missing decisions need confirmation too. An
                    // explicit AI rejection is never offered again locally.
                    let unresolvedIDs = Set(result.unresolvedReviews.map(\.candidateID))
                    if !unresolvedIDs.isEmpty {
                        suggestions = try await localSuggestions(
                            candidates.filter { unresolvedIDs.contains($0.candidateID) }, batchID: batchID)
                    }
                } catch {
                    try Task.checkCancellation()
                    guard reviewGeneration == generation,
                        AutoLearnSettings.isAIReviewEnabled == usesAIReview else { throw CancellationError() }
                    log(error, message: "Auto Learn AI review failed; falling back to local approval batchID=\(batchID)")
                    suggestions = try await localSuggestions(candidates, batchID: batchID)
                }
            } else {
                suggestions = try await localSuggestions(candidates, batchID: batchID)
            }

            try Task.checkCancellation()
            guard reviewGeneration == generation, AutoLearnSettings.isEnabled,
                AutoLearnSettings.isAIReviewEnabled == usesAIReview else { throw CancellationError() }
            automaticDecisions = try await reviewProposalStore.excludingDismissed(automaticDecisions, candidates: candidates)
            try Task.checkCancellation()
            guard reviewGeneration == generation, AutoLearnSettings.isEnabled,
                AutoLearnSettings.isAIReviewEnabled == usesAIReview else { throw CancellationError() }
            let summary = try await replacementStore.apply(automaticDecisions, candidates: candidates)
            let unsavedSuggestions = try await replacementStore.unsavedSuggestions(suggestions)
            let queuedSuggestions = try await reviewProposalStore.append(decisions: unsavedSuggestions, candidates: candidates)
            try await pendingQueue.remove(candidateIDs)
            releaseClaim(candidateIDs)
            await notifyQueueChanged()
            AutoLearnSettings.clearFailure()
            logger.notice("Auto Learn batch completed batchID=\(batchID.uuidString, privacy: .public) usesAIReview=\(usesAIReview, privacy: .public) automaticDecisions=\(automaticDecisions.count, privacy: .public) suggestions=\(suggestions.count, privacy: .public) queuedSuggestions=\(queuedSuggestions, privacy: .public) replacementsCreated=\(summary.createdCount, privacy: .public) replacementsUpdated=\(summary.updatedCount, privacy: .public) vocabularyCreated=\(summary.vocabularyCount, privacy: .public)")

            if summary.hasChanges {
                await MainActor.run {
                    NotificationCenter.default.post(name: .wordReplacementsDidChange, object: nil)
                }
                await showLearnedNotification(for: summary)
            }
            await notifyReviewProposalsChanged()
            await processPendingReviewBatch(generation: generation)
        } catch {
            try? await releaseAllClaimsToQueue()
            if !Task.isCancelled, !(error is CancellationError), reviewGeneration == generation {
                AutoLearnSettings.recordFailure(error)
            }
            await finishReviewTask(generation: generation)
            log(error, message: "Auto Learn batch interrupted; candidates remain queued batchID=\(batchID)")
        }
    }

    private func localSuggestions(_ candidates: [AutoLearnReviewCandidate], batchID: UUID) async throws
        -> [AutoLearnReviewDecision] {
        try await AutoLearnLocalReviewer().review(candidates, batchID: batchID)
    }

    /// Forgets the in-flight batch; cancellation consumes its claim before a
    /// replacement batch can populate the set.
    private func releaseClaim(_ candidateIDs: Set<UUID>) {
        claimedCandidateIDs.subtract(candidateIDs)
    }

    private func releaseAllClaimsToQueue() async throws {
        guard !claimedCandidateIDs.isEmpty else { return }
        let claimedIDs = claimedCandidateIDs
        try await pendingQueue.release(claimedIDs)
        claimedCandidateIDs.subtract(claimedIDs)
    }

    private func finishReviewTask(generation: UInt64) async {
        guard reviewGeneration == generation else { return }
        reviewTask = nil
    }

    /// Cancels the active batch and returns its claims so rapid disable/re-enable
    /// cannot strand them. Releasing is idempotent.
    private func cancelReviewTask() async {
        reviewGeneration &+= 1
        let cancellationGeneration = reviewGeneration
        let cancelledTask = reviewTask
        cancelledTask?.cancel()
        if let cancelledTask {
            await cancelledTask.value
        }
        guard reviewGeneration == cancellationGeneration else { return }
        reviewTask = nil

        guard !claimedCandidateIDs.isEmpty else { return }
        let claimedIDs = claimedCandidateIDs
        claimedCandidateIDs = []
        try? await pendingQueue.release(claimedIDs)
        await notifyQueueChanged()
    }

    private func notifyQueueChanged() async {
        let outstandingCount = (try? await pendingQueue.outstandingCount()) ?? 0
        await MainActor.run {
            NotificationCenter.default.post(
                name: .autoLearnQueueDidChange,
                object: outstandingCount
            )
        }
    }

    private func notifyReviewProposalsChanged() async {
        guard let proposals = try? await reviewProposalStore.all() else { return }
        let count = proposals.count
        await MainActor.run {
            AutoLearnSuggestionController.shared.update(AutoLearnSettings.isEnabled ? proposals : [])
            NotificationCenter.default.post(
                name: .autoLearnReviewProposalsDidChange,
                object: count
            )
        }
    }

    private func showLearnedNotification(for summary: AutoLearnMutationSummary) async {
        let corrections = summary.learnedCorrections
        guard !corrections.isEmpty else { return }

        if corrections.count == 1, let correction = corrections.first {
            let notificationTitle: String
            if correction.vocabularyCreationDate != nil {
                notificationTitle = String(
                    localized: "Added “\(correction.correctedVocabularyTerm)” to Dictionary"
                )
            } else {
                notificationTitle = String(
                    localized: "Learned “\(correction.incorrectTextToReplace)” → “\(correction.correctedVocabularyTerm)”"
                )
            }
            await MainActor.run {
                NotificationManager.shared.showNotification(
                    title: notificationTitle,
                    type: .success,
                    duration: 4,
                    actionButton: (
                        label: String(localized: "Undo"),
                        action: {
                            Task {
                                await AutoLearnService.shared.undo(correction)
                            }
                        }
                    ),
                    atRecorderPosition: true
                )
            }
        } else {
            await MainActor.run {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Learned \(corrections.count) corrections"),
                    type: .success,
                    atRecorderPosition: true
                )
            }
        }
    }

    private func undo(_ correction: AutoLearnAppliedCorrection) async {
        guard let replacementStore else { return }
        do {
            try await replacementStore.undo(correction)
            await MainActor.run {
                NotificationCenter.default.post(name: .wordReplacementsDidChange, object: nil)
            }
        } catch {
            log(error, message: "Failed to undo Auto Learn correction")
        }
    }

    private func log(_ error: Error, message: String) {
        let nsError = error as NSError
        logger.error(
            "\(message, privacy: .public): domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)"
        )
    }

    private func sleep(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return true
        } catch {
            return false
        }
    }
}
