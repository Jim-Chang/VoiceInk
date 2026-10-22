import FluidAudio
import Dispatch
import Foundation
import TranscribeCpp
import os

/// Shared offline runtime for catalog-backed transcribe.cpp model families.
final class OfflineTranscribeCppService: TranscriptionService, @unchecked Sendable {
    private struct LoadedState {
        let modelName: String
        let model: Model
    }

    private struct LoadingState {
        let id: UUID
        let modelName: String
        let task: Task<Model, Error>
    }

    private enum LoadResolution {
        case loaded(Model)
        case loading(LoadingState)
    }

    private static let backendInitializationLock = NSLock()
    private static let modelInitializationLock = NSLock()
    private static var backendsInitialized = false

    private let stateLock = NSLock()
    private var loadedState: LoadedState?
    private var loadingState: LoadingState?
    private var activeTranscriptionCount = 0
    private var notificationObservers: [NSObjectProtocol] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let audioConverter = AudioConverter()
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "OfflineTranscribeCppService"
    )

    init() {
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(forName: .didChangeModel, object: nil, queue: nil) { [weak self] notification in
                guard let modelName = notification.userInfo?["modelName"] as? String else { return }
                self?.unloadModel(unlessSelectedModelIs: modelName)
            }
        )
        notificationObservers.append(
            center.addObserver(forName: .transcribeCppModelDeleted, object: nil, queue: nil) { [weak self] notification in
                guard let modelName = notification.userInfo?["modelName"] as? String else {
                    self?.unloadModel()
                    return
                }
                self?.unloadModel(named: modelName)
            }
        )

        let pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        pressureSource.setEventHandler { [weak self] in
            self?.unloadModel()
        }
        pressureSource.resume()
        memoryPressureSource = pressureSource
    }

    deinit {
        memoryPressureSource?.cancel()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        unloadModel()
    }

    private var backend: Backend {
        #if arch(arm64)
        return .metal
        #else
        return .cpu
        #endif
    }

    func loadModel(for model: TranscribeCppModel) async throws {
        let artifact = try resolveArtifact(for: model)
        _ = try await getOrLoadModel(for: model, artifact: artifact)
    }

    func transcribe(
        audioURL: URL,
        model: any TranscriptionModel,
        context: TranscriptionRequestContext
    ) async throws -> String {
        guard let transcribeCppModel = model as? TranscribeCppModel else {
            throw NSError(
                domain: "OfflineTranscribeCppService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported transcription model"]
            )
        }
        let artifact = try resolveArtifact(for: transcribeCppModel)

        let nativeModel = try await getOrLoadModel(for: transcribeCppModel, artifact: artifact)
        retainModel(nativeModel, named: transcribeCppModel.name)
        defer { releaseModel(named: transcribeCppModel.name) }

        let samples = try audioConverter.resampleAudioFile(audioURL)
        let language = selectedLanguage(context.language, for: transcribeCppModel)
        let options = RunOptions(
            timestamps: .none,
            itn: artifact.enablesInverseTextNormalization ? .on : .default,
            language: language,
            keepSpecialTags: false
        )
        let maximumChunkSeconds = effectiveMaximumChunkSeconds(
            configuredMaximum: artifact.maximumChunkSeconds,
            capabilitiesMaximumMilliseconds: nativeModel.capabilities.maxAudioMs
        )
        // voiceink-zhtw：VAD 開著時先用語音偵測切段，只送講話的部分（TranscribeCppSpeechSegmenter）
        let chunks = await speechAwareChunks(
            samples,
            maximumChunkSeconds: maximumChunkSeconds,
            artifact: artifact
        )

        let startedAt = ContinuousClock.now
        var chunkTranscripts: [(text: String, language: String?)] = []
        chunkTranscripts.reserveCapacity(chunks.count)
        // voiceink-zhtw：一段碰到產生上限不拖垮整個檔案（docs/plan/2026-10-22-long-audio-segmentation.md）
        var guardStats = ChunkGuardStats()

        for chunk in chunks {
            try Task.checkCancellation()
            let pieces = try await runGuarded(
                chunk,
                model: nativeModel,
                options: options,
                energyWindowCount: artifact.boundaryEnergyWindowSamples,
                stats: &guardStats
            )
            for piece in pieces where !piece.text.isEmpty {
                chunkTranscripts.append((text: piece.text, language: piece.language ?? language))
            }
        }
        ZhTWTiming.logger.notice(
            "asr-chunks chunks=\(chunks.count, privacy: .public) retried=\(guardStats.retried, privacy: .public) truncated=\(guardStats.truncated, privacy: .public)"
        )

        logger.notice(
            "\(transcribeCppModel.displayName, privacy: .public) completed in \(startedAt.duration(to: .now).formatted(.units(allowed: [.seconds], width: .narrow)), privacy: .public) for \(samples.count, privacy: .public) samples"
        )
        return joinedText(from: chunkTranscripts)
    }

    func cleanup() {
        unloadModel()
    }

    func unloadModel() {
        unloadModel { _ in true }
    }

    private func getOrLoadModel(
        for model: TranscribeCppModel,
        artifact: TranscribeCppModelArtifact
    ) async throws -> Model {
        let resolvedState: LoadResolution = stateLock.withLock {
            if let loadedState, loadedState.modelName == model.name {
                return .loaded(loadedState.model)
            }
            if let loadingState, loadingState.modelName == model.name {
                return .loading(loadingState)
            }

            loadingState?.task.cancel()
            loadingState = nil
            loadedState = nil

            let loadID = UUID()
            let backend = backend
            let task = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                guard let modelURL = artifact.installedModelFileURL else {
                    throw CocoaError(.fileNoSuchFile)
                }

                try Self.initializeBackendsIfNeeded()
                guard Transcribe.backendAvailable(backend) else {
                    throw TranscribeError.backend("The requested transcribe.cpp backend is unavailable")
                }

                // Serialize non-cancellable native construction to prevent overlapping model loads.
                return try Self.modelInitializationLock.withLock {
                    try Task.checkCancellation()
                    let loadedModel = try Model(
                        path: modelURL.path,
                        options: ModelOptions(backend: backend)
                    )
                    try Task.checkCancellation()
                    return loadedModel
                }
            }
            let state = LoadingState(id: loadID, modelName: model.name, task: task)
            loadingState = state
            return .loading(state)
        }

        if case .loaded(let loadedModel) = resolvedState {
            return loadedModel
        }

        guard case .loading(let loading) = resolvedState else {
            throw CocoaError(.fileReadUnknown)
        }

        let startedAt = ContinuousClock.now
        do {
            let loadedModel = try await loading.task.value
            if let architectureHint = artifact.architectureHint {
                guard loadedModel.arch.localizedCaseInsensitiveContains(architectureHint) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }

            let loadIsCurrent = stateLock.withLock {
                if
                    let currentState = loadedState,
                    currentState.modelName == model.name,
                    currentState.model === loadedModel
                {
                    return true
                }
                guard loadingState?.id == loading.id else { return false }
                loadedState = LoadedState(modelName: model.name, model: loadedModel)
                loadingState = nil
                return true
            }
            guard loadIsCurrent else { throw CancellationError() }

            logger.notice(
                "\(model.displayName, privacy: .public) loaded with \(loadedModel.backend, privacy: .public) in \(startedAt.duration(to: .now).formatted(.units(allowed: [.seconds], width: .narrow)), privacy: .public)"
            )
            return loadedModel
        } catch {
            stateLock.withLock {
                if loadingState?.id == loading.id {
                    loadingState = nil
                }
            }
            throw error
        }
    }

    private func unloadModel(named modelName: String) {
        unloadModel { $0 == modelName }
    }

    private func unloadModel(unlessSelectedModelIs modelName: String) {
        unloadModel { $0 != modelName }
    }

    private func unloadModel(where shouldUnload: (String) -> Bool) {
        let didUnload = stateLock.withLock {
            guard let activeModelName = loadedState?.modelName ?? loadingState?.modelName,
                shouldUnload(activeModelName),
                activeTranscriptionCount == 0
            else {
                return false
            }
            loadingState?.task.cancel()
            loadingState = nil
            loadedState = nil
            return true
        }
        if didUnload {
            logger.notice("transcribe.cpp runtime unloaded")
        }
    }

    private func retainModel(_ model: Model, named modelName: String) {
        stateLock.withLock {
            // Restore an acquired model after a racing unload and cancel its replacement load.
            loadingState?.task.cancel()
            loadingState = nil
            loadedState = LoadedState(modelName: modelName, model: model)
            activeTranscriptionCount += 1
        }
    }

    private func releaseModel(named modelName: String) {
        let didUnload = stateLock.withLock {
            guard activeTranscriptionCount > 0 else { return false }
            activeTranscriptionCount -= 1
            guard activeTranscriptionCount == 0,
                loadedState?.modelName == modelName || loadingState?.modelName == modelName
            else {
                return false
            }
            loadingState?.task.cancel()
            loadingState = nil
            loadedState = nil
            return true
        }
        if didUnload {
            logger.notice("transcribe.cpp runtime unloaded")
        }
    }

    private func resolveArtifact(for model: TranscribeCppModel) throws -> TranscribeCppModelArtifact {
        guard let artifact = TranscribeCppModelCatalog.artifact(for: model.name) else {
            throw NSError(
                domain: "OfflineTranscribeCppService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported transcribe.cpp model"]
            )
        }
        return artifact
    }

    private func selectedLanguage(_ language: String?, for model: TranscribeCppModel) -> String? {
        let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(language, for: model)
        guard compatibleLanguage != "auto" else { return nil }
        return compatibleLanguage.split(separator: "-").first.map(String.init)?.lowercased()
    }

    private func effectiveMaximumChunkSeconds(
        configuredMaximum: Int,
        capabilitiesMaximumMilliseconds: Int64
    ) -> Int {
        guard capabilitiesMaximumMilliseconds > 0 else { return configuredMaximum }
        let capabilitiesMaximum = Swift.max(1, Int(capabilitiesMaximumMilliseconds / 1_000))
        return Swift.min(configuredMaximum, capabilitiesMaximum)
    }

    private func joinedText(from chunks: [(text: String, language: String?)]) -> String {
        chunks.enumerated().reduce(into: "") { result, entry in
            let (index, chunk) = entry
            // voiceink-zhtw：中文也一樣，前後都是英文字母或數字時補空格，不然會黏成「APIdeploy」
            if index > 0,
                languageUsesSpaces(chunk.language) || ZhTWTranscript.needsSpaceBetween(result, chunk.text)
            {
                result.append(" ")
            }
            result.append(chunk.text)
        }
    }

    private func languageUsesSpaces(_ language: String?) -> Bool {
        guard let language else { return true }
        return language != "ja" && language != "yue" && language != "zh"
    }

    // MARK: - voiceink-zhtw：一段碰到產生上限時的保險

    private struct ChunkGuardStats {
        var retried = 0
        var truncated = 0
    }

    /// 切成兩半重跑的最短段長（4 秒）
    private static let minimumRetrySamples = 4 * 16_000

    /// 一段碰到產生上限（多半是模型鬼打牆，同一句一直重複）時：
    /// 段長 4 秒以上就在中間附近最安靜的地方切成兩半，各跑一次（只切一層，避免一段拖很久）；
    /// 還是碰到上限、或太短不切，就留已辨識的字、縮掉結尾的重複。其他錯誤和取消照舊往外丟。
    private func runGuarded(
        _ chunk: TranscribeCppSpeechSegmenter.Chunk,
        model: Model,
        options: RunOptions,
        energyWindowCount: Int,
        stats: inout ChunkGuardStats
    ) async throws -> [(text: String, language: String?)] {
        let samples = chunk.samples
        do {
            return [try await runChunk(samples, model: model, options: options)]
        } catch TranscribeError.outputTruncated(_, let partial) {
            guard samples.count >= Self.minimumRetrySamples else {
                return [salvage(partial, startSample: chunk.startSample, sampleCount: samples.count, stats: &stats)]
            }
            stats.retried += 1
            ZhTWTiming.logger.notice(
                "asr-retry at=\(String(format: "%.1f", Double(chunk.startSample) / 16_000), privacy: .public) length=\(String(format: "%.1f", Double(samples.count) / 16_000), privacy: .public)"
            )
            // 上限設成原長度的六成、在中間兩成裡找最安靜的地方，剛好切成兩半
            let halves = samples.energyAwareChunks(
                maximumCount: samples.count * 6 / 10,
                boundarySearchCount: samples.count * 2 / 10,
                energyWindowCount: energyWindowCount
            )
            var results: [(text: String, language: String?)] = []
            var halfOffset = 0
            for half in halves {
                try Task.checkCancellation()
                do {
                    results.append(try await runChunk(half, model: model, options: options))
                } catch TranscribeError.outputTruncated(_, let partial) {
                    let halfStart = chunk.sourcePosition(ofOffset: halfOffset)
                    results.append(salvage(partial, startSample: halfStart, sampleCount: half.count, stats: &stats))
                }
                halfOffset += half.count
            }
            return results
        }
    }

    /// 錄音超過一段的上限（30 秒）、而且 VAD 設定（IsVADEnabled，和 Whisper、Parakeet 共用）開著時，
    /// 先用語音偵測切段。短的聽寫不用：91 段實際聽寫比較過，結果有好有壞、沒有比較好，也不會鬼打牆。
    /// 關著、偵測失敗、或整段都沒偵測到講話時，照原作者的方式每 30 秒切一段。
    private func speechAwareChunks(
        _ samples: [Float],
        maximumChunkSeconds: Int,
        artifact: TranscribeCppModelArtifact
    ) async -> [TranscribeCppSpeechSegmenter.Chunk] {
        let maximumCount = maximumChunkSeconds * 16_000
        let splitBySilence: ([Float]) -> [[Float]] = {
            $0.energyAwareChunks(
                maximumCount: maximumCount,
                boundarySearchCount: artifact.boundarySearchSeconds * 16_000,
                energyWindowCount: artifact.boundaryEnergyWindowSamples
            )
        }

        if samples.count > maximumCount,
            UserDefaults.standard.bool(forKey: "IsVADEnabled"),
            let modelPath = await VADModelManager.shared.getModelPath()
        {
            let startedAt = ContinuousClock.now
            if let ranges = TranscribeCppSpeechSegmenter.speechRanges(
                in: samples,
                modelPath: modelPath,
                maximumSeconds: maximumChunkSeconds
            ), !ranges.isEmpty {
                let chunks = TranscribeCppSpeechSegmenter.pack(
                    ranges,
                    of: samples,
                    maximumCount: maximumCount,
                    splitLongSpeech: splitBySilence
                )
                let speechCount = ranges.reduce(0) { $0 + $1.count }
                ZhTWTiming.logger.notice(
                    "asr-vad seconds=\(String(format: "%.1f", Double(samples.count) / 16_000), privacy: .public) speech=\(String(format: "%.1f", Double(speechCount) / 16_000), privacy: .public) ranges=\(ranges.count, privacy: .public) chunks=\(chunks.count, privacy: .public) took=\(ZhTWTiming.seconds(startedAt.duration(to: .now)), privacy: .public)"
                )
                return chunks
            }
            ZhTWTiming.logger.notice("asr-vad fallback")
        }

        var start = 0
        return splitBySilence(samples).map { piece in
            defer { start += piece.count }
            return TranscribeCppSpeechSegmenter.Chunk(samples: piece, sourceRanges: [start..<(start + piece.count)])
        }
    }

    private func runChunk(
        _ samples: [Float],
        model: Model,
        options: RunOptions
    ) async throws -> (text: String, language: String?) {
        let session = try model.session()
        let transcript = try await session.run(samples, options: options)
        return (transcript.text.trimmingCharacters(in: .whitespacesAndNewlines), transcript.language)
    }

    /// 保留碰到上限前已辨識的字、縮掉結尾的重複；紀錄只寫時間位置和字數，不寫內容。
    private func salvage(
        _ partial: Transcript?,
        startSample: Int,
        sampleCount: Int,
        stats: inout ChunkGuardStats
    ) -> (text: String, language: String?) {
        stats.truncated += 1
        let text = ZhTWTranscript.collapseTrailingRepetition(partial?.text ?? "")
        ZhTWTiming.logger.notice(
            "asr-loop at=\(String(format: "%.1f", Double(startSample) / 16_000), privacy: .public) length=\(String(format: "%.1f", Double(sampleCount) / 16_000), privacy: .public) chars=\(text.count, privacy: .public)"
        )
        return (text, partial?.language)
    }

    private static func initializeBackendsIfNeeded() throws {
        try backendInitializationLock.withLock {
            guard !backendsInitialized else { return }
            try Transcribe.initBackends()
            backendsInitialized = true
        }
    }
}

private extension Array where Element == Float {
    /// Splits long-form audio near low-energy boundaries without overlapping samples.
    func energyAwareChunks(
        maximumCount: Int,
        boundarySearchCount: Int,
        energyWindowCount: Int
    ) -> [[Float]] {
        guard maximumCount > 0, count > maximumCount else { return [self] }

        let safeBoundarySearch = Swift.max(1, Swift.min(boundarySearchCount, maximumCount))
        let safeEnergyWindow = Swift.max(1, energyWindowCount)
        var chunks: [[Float]] = []
        var start = 0

        while start < count {
            let maximumEnd = Swift.min(start + maximumCount, count)
            if maximumEnd == count {
                chunks.append(Array(self[start..<maximumEnd]))
                break
            }

            let searchStart = Swift.max(start, maximumEnd - safeBoundarySearch)
            let splitPoint = quietestWindowStart(
                from: searchStart,
                to: maximumEnd,
                windowCount: safeEnergyWindow
            )
            let safeSplitPoint = Swift.max(start + 1, Swift.min(splitPoint, count))
            chunks.append(Array(self[start..<safeSplitPoint]))
            start = safeSplitPoint
        }

        return chunks
    }

    private func quietestWindowStart(from start: Int, to end: Int, windowCount: Int) -> Int {
        guard end - start > windowCount else { return (start + end) / 2 }

        var quietestStart = start
        var lowestEnergy = Double.infinity
        let finalWindowStart = end - windowCount
        var candidateStarts = [Int](stride(from: start, through: finalWindowStart, by: windowCount))
        if candidateStarts.last != finalWindowStart {
            candidateStarts.append(finalWindowStart)
        }

        for windowStart in candidateStarts {
            var squaredSampleSum = 0.0
            for sample in self[windowStart..<(windowStart + windowCount)] {
                let value = Double(sample)
                squaredSampleSum += value * value
            }
            let meanSquaredEnergy = squaredSampleSum / Double(windowCount)
            if meanSquaredEnergy < lowestEnergy {
                lowestEnergy = meanSquaredEnergy
                quietestStart = windowStart
            }
        }

        return quietestStart
    }
}
