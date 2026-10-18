import AppKit
import SwiftUI

@MainActor
private final class AutoLearnSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AutoLearnSuggestionController: ObservableObject {
    static let shared = AutoLearnSuggestionController()
    static let dismissalSeconds = 7

    @Published private(set) var proposals: [AutoLearnReviewProposal] = []
    @Published private(set) var isApplying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var secondsRemaining = AutoLearnSuggestionController.dismissalSeconds
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func update(_ proposals: [AutoLearnReviewProposal]) {
        let previousID = self.proposals.first?.id
        self.proposals = proposals
        guard let proposal = proposals.first else {
            dismissTask?.cancel()
            panel?.close()
            panel = nil
            NotificationManager.shared.setRecorderOverlayFrame(nil)
            return
        }
        if proposal.id != previousID {
            errorMessage = nil
            secondsRemaining = Self.dismissalSeconds
            scheduleDismissal()
        }
        if panel == nil {
            present()
        }
        resizePanel()
    }

    func resolve(approve: Bool) {
        guard !isApplying, let proposal = proposals.first else { return }
        guard !approve || isValidSuggestion else { return }
        isApplying = true
        errorMessage = nil
        let source = proposal.incorrectTextToReplace?.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = (proposal.correctedVocabularyTerm ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                if approve {
                    _ = try await AutoLearnService.shared.applyReviewProposals([
                        .init(proposalID: proposal.id,
                            includesReplacement: proposal.addsReplacement,
                            includesVocabulary: proposal.addsVocabulary,
                            incorrectTextToReplace: proposal.addsReplacement ? source : nil,
                            correctedVocabularyTerm: destination)
                    ])
                } else {
                    try await AutoLearnService.shared.dismissReviewProposals([proposal.id])
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isApplying = false
            resizePanel()
            if errorMessage == nil, secondsRemaining == 0 {
                resolve(approve: false)
            }
        }
    }

    var isValidSuggestion: Bool {
        guard let proposal = proposals.first else { return false }
        return AutoLearnLocalReviewPolicy.accepts(
            source: proposal.addsReplacement ? proposal.incorrectTextToReplace ?? "" : nil,
            destination: proposal.correctedVocabularyTerm ?? "")
    }

    private func scheduleDismissal() {
        dismissTask?.cancel()
        guard let proposalID = proposals.first?.id else { return }
        secondsRemaining = Self.dismissalSeconds
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(Self.dismissalSeconds))
        dismissTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(until: min(deadline, clock.now.advanced(by: .seconds(1))))
                } catch { return }
                guard let self, !Task.isCancelled, self.proposals.first?.id == proposalID else { return }
                let remaining = clock.now.duration(to: deadline).components
                self.secondsRemaining = max(0, Int(remaining.seconds) + (remaining.attoseconds > 0 ? 1 : 0))
                if self.secondsRemaining == 0 {
                    if self.errorMessage == nil { self.resolve(approve: false) }
                    return
                }
            }
        }
    }

    private func resizePanel() {
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panel, let view = panel.contentView else { return }
            view.layoutSubtreeIfNeeded()
            panel.setContentSize(view.fittingSize)
            if let metrics = MiniRecorderPanel.calculateWindowMetrics(size: panel.frame.size, screen: panel.screen) {
                panel.setFrameOrigin(metrics.origin)
            }
            NotificationManager.shared.setRecorderOverlayFrame(panel.frame)
        }
    }

    private func present() {
        let view = AutoLearnSuggestionView(controller: self)
        let hostingView = NSHostingView(rootView: view)
        guard let metrics = MiniRecorderPanel.calculateWindowMetrics(size: hostingView.fittingSize) else { return }
        let panel = AutoLearnSuggestionPanel(contentRect: metrics,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        // Offer the correction without taking keyboard focus from the editor.
        panel.orderFrontRegardless()
        NotificationManager.shared.setRecorderOverlayFrame(panel.frame)
    }
}

private struct AutoLearnSuggestionView: View {
    @ObservedObject var controller: AutoLearnSuggestionController

    var body: some View {
        if let proposal = controller.proposals.first {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Learn this correction?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    AutoLearnCountdownView(secondsRemaining: controller.secondsRemaining)
                        .id(proposal.id)
                }

                correction(for: proposal)

                if let error = controller.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Status.error)
                }

                HStack(spacing: 8) {
                    Spacer()
                    AppActionButton("Dismiss") { controller.resolve(approve: false) }
                    AppActionButton("Add Correction", kind: .primary) {
                        controller.resolve(approve: true)
                    }
                    .disabled(!controller.isValidSuggestion)
                }
                .padding(.top, 4)
            }
            .padding(16)
            .frame(width: 420)
            .background(AppTheme.Surface.window, in: RoundedRectangle(cornerRadius: AppTheme.Radius.card))
            .fixedSize(horizontal: false, vertical: true)
            .disabled(controller.isApplying)
        }
    }

    private func correction(for proposal: AutoLearnReviewProposal) -> some View {
        let original = Text(proposal.incorrectTextToReplace ?? "")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        let corrected = Text(proposal.correctedVocabularyTerm ?? "")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
        let arrow = Image(systemName: "arrow.right")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Replace with")

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if proposal.addsReplacement {
                    original
                    arrow
                }
                corrected
            }
            .fixedSize()

            VStack(alignment: .leading, spacing: 6) {
                if proposal.addsReplacement {
                    HStack(spacing: 8) {
                        original
                        arrow
                    }
                }
                corrected
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

private struct AutoLearnCountdownView: View {
    let secondsRemaining: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: CGFloat(secondsRemaining) / CGFloat(AutoLearnSuggestionController.dismissalSeconds))
                .stroke(AppTheme.Accent.primary.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: secondsRemaining)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dismisses automatically")
    }
}
