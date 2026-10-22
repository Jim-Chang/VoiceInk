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
            capabilitiesMaximumMilliseconds: try nativeModel.capabilities.maxAudioMs
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
        // voiceink-zhtw：段數多（轉錄音檔）時每 4 段一批（docs/plan/2026-10-23-tea-batch.md）
        var batchedPieces: [[(text: String, language: String?)]]?
        if chunks.count >= Self.minimumBatchedChunks {
            batchedPieces = try await runBatched(
                chunks,
                model: nativeModel,
                options: options,
                energyWindowCount: artifact.boundaryEnergyWindowSamples,
                stats: &guardStats
            )
        }

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let pieces: [(text: String, language: String?)]
            if let batchedPieces {
                pieces = batchedPieces[index]
            } else {
                pieces = try await runGuarded(
                    chunk,
                    model: nativeModel,
                    options: options,
                    energyWindowCount: artifact.boundaryEnergyWindowSamples,
                    stats: &guardStats
                )
            }
            for piece in pieces where !piece.text.isEmpty {
                chunkTranscripts.append((text: piece.text, language: piece.language ?? language))
            }
        }
        ZhTWTiming.logger.notice(
            "asr-chunks chunks=\(chunks.count, privacy: .public) batch=\(batchedPieces == nil ? 1 : Self.batchSize, privacy: .public) retried=\(guardStats.retried, privacy: .public) truncated=\(guardStats.truncated, privacy: .public)"
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

    /// 再切成兩半重跑的最短段長（4 秒）
    private static let minimumRetrySamples = 4 * 16_000

    /// 一段沒辨識完就停下（多半是模型鬼打牆：碰到產生上限，或 transcribe.cpp 0.4 起偵測到重複提早停）時：
    /// 段長 4 秒以上就在中間附近最安靜的地方切成兩半各跑一次，哪一半還是停下就再切，切到不到 4 秒為止；
    /// 不到 4 秒還是停下，就留已辨識的字、縮掉結尾的重複。其他錯誤和取消照舊往外丟。
    /// 從哪裡開始送會不會卡住幾乎是碰運氣（兩人同時講的地方，起點差一秒結果就不同），換個切法常常就過了；
    /// 0.4 起偵測到重複一兩秒就停，多試幾次不太花時間；30 秒的一段最多往下切四層。
    private func runGuarded(
        _ chunk: TranscribeCppSpeechSegmenter.Chunk,
        model: Model,
        options: RunOptions,
        energyWindowCount: Int,
        stats: inout ChunkGuardStats
    ) async throws -> [(text: String, language: String?)] {
        try await runSplittingOnStop(
            chunk.samples,
            offset: 0,
            of: chunk,
            model: model,
            options: options,
            energyWindowCount: energyWindowCount,
            stats: &stats
        )
    }

    /// `samples` 是 `chunk` 從第 `offset` 個樣本開始的一部分（紀錄用來對回原始錄音的位置）。
    private func runSplittingOnStop(
        _ samples: [Float],
        offset: Int,
        of chunk: TranscribeCppSpeechSegmenter.Chunk,
        model: Model,
        options: RunOptions,
        energyWindowCount: Int,
        stats: inout ChunkGuardStats
    ) async throws -> [(text: String, language: String?)] {
        do {
            return [try await runChunk(samples, model: model, options: options)]
        } catch let error as TranscribeError where error.isTruncated {
            return try await retryStopped(
                error,
                samples,
                offset: offset,
                of: chunk,
                model: model,
                options: options,
                energyWindowCount: energyWindowCount,
                stats: &stats
            )
        }
    }

    /// `samples` 跑完停下（`error`）之後：段長 4 秒以上切兩半各跑一次（`runSplittingOnStop`，還是停下就再切），
    /// 不到 4 秒留已辨識的字。一段一段跑和批次（`runBatched`）共用。
    private func retryStopped(
        _ error: TranscribeError,
        _ samples: [Float],
        offset: Int,
        of chunk: TranscribeCppSpeechSegmenter.Chunk,
        model: Model,
        options: RunOptions,
        energyWindowCount: Int,
        stats: inout ChunkGuardStats
    ) async throws -> [(text: String, language: String?)] {
        let startSample = chunk.sourcePosition(ofOffset: offset)
        guard samples.count >= Self.minimumRetrySamples else {
            return [salvage(error.partial, startSample: startSample, sampleCount: samples.count, stats: &stats)]
        }
        stats.retried += 1
        ZhTWTiming.logger.notice(
            "asr-retry at=\(String(format: "%.1f", Double(startSample) / 16_000), privacy: .public) length=\(String(format: "%.1f", Double(samples.count) / 16_000), privacy: .public)"
        )
        // 上限設成原長度的六成、在中間兩成裡找最安靜的地方，剛好切成兩半
        let halves = samples.energyAwareChunks(
            maximumCount: samples.count * 6 / 10,
            boundarySearchCount: samples.count * 2 / 10,
            energyWindowCount: energyWindowCount
        )
        var results: [(text: String, language: String?)] = []
        var halfOffset = offset
        for half in halves {
            try Task.checkCancellation()
            results += try await runSplittingOnStop(
                half,
                offset: halfOffset,
                of: chunk,
                model: model,
                options: options,
                energyWindowCount: energyWindowCount,
                stats: &stats
            )
            halfOffset += half.count
        }
        return results
    }

    // MARK: - voiceink-zhtw：段數多時批次辨識（docs/plan/2026-10-23-tea-batch.md）

    /// 8 段以上（約 4 分鐘以上的錄音）才批次。平常的聽寫只有一段；長短混在一起的少數幾段批次也不會比較快。
    private static let minimumBatchedChunks = 8
    /// 每批 4 段：1 小時 43 分的會議錄音比一段一段快 1.67 倍、尖峰記憶體多約 0.5GB；8 段沒有更快、多 1.2GB。
    private static let batchSize = 4

    /// 依長度由長到短排好、每 4 段送一次 `runBatch`，回傳照原本的段順序。長度相近的放同一批，
    /// 短的段才不用補到最長那段的長度、陪它跑完（不排序只快 1.34 倍）。
    /// 某段停下（鬼打牆）時照一段一段的方式切兩半重跑；一個檔案只有幾段，不再批次。其他錯誤照舊往外丟。
    private func runBatched(
        _ chunks: [TranscribeCppSpeechSegmenter.Chunk],
        model: Model,
        options: RunOptions,
        energyWindowCount: Int,
        stats: inout ChunkGuardStats
    ) async throws -> [[(text: String, language: String?)]] {
        let order = chunks.indices.sorted { a, b in
            let (countA, countB) = (chunks[a].samples.count, chunks[b].samples.count)
            return countA != countB ? countA > countB : a < b
        }
        var results = [[(text: String, language: String?)]](repeating: [], count: chunks.count)
        var start = 0
        while start < order.count {
            try Task.checkCancellation()
            let group = Array(order[start..<Swift.min(start + Self.batchSize, order.count)])
            start += group.count
            let session = try model.session()
            let outcomes = try await session.runBatch(group.map { chunks[$0].samples }, options: options)
            for (index, outcome) in zip(group, outcomes) {
                switch outcome {
                case .success(let transcript):
                    results[index] = [
                        (transcript.text.trimmingCharacters(in: .whitespacesAndNewlines), transcript.language)
                    ]
                case .failure(let error as TranscribeError) where error.isTruncated:
                    results[index] = try await retryStopped(
                        error,
                        chunks[index].samples,
                        offset: 0,
                        of: chunks[index],
                        model: model,
                        options: options,
                        energyWindowCount: energyWindowCount,
                        stats: &stats
                    )
                case .failure(let error):
                    throw error
                }
            }
        }
        return results
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
