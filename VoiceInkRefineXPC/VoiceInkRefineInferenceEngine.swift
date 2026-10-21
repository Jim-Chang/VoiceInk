import Foundation

#if arch(arm64)
    import MLX
    import MLXHuggingFace
    import MLXLLM
    import MLXLMCommon
    import Tokenizers
#endif

enum VoiceInkRefineInferenceError: LocalizedError {
    case unavailable
    case modelNotLoaded
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "VoiceInk Refine requires Apple silicon."
        case .modelNotLoaded:
            return "VoiceInk Refine could not load the selected model."
        case .emptyOutput:
            return "VoiceInk Refine returned an empty response."
        }
    }
}

actor VoiceInkRefineInferenceEngine {
    #if arch(arm64)
        private struct PreparationIdentity: Equatable {
            let modelDirectoryPath: String
            let systemPrompt: String
        }

        private static let activeCacheLimitBytes = 64 * 1_024 * 1_024
        private static let maximumGenerationTokens = 8_192

        private var modelContainer: MLXLMCommon.ModelContainer?
        private var preparationTask: Task<Void, Error>?
        private var preparationIdentity: PreparationIdentity?
        private var isWarmed = false
        /// voiceink-zhtw：上一次補標點做完的時間，用來記錄閒置多久
        private var lastEnhanceFinishedAt: ContinuousClock.Instant?
    #endif

    func prepare(
        modelDirectory: URL,
        systemPrompt: String
    ) async throws {
        #if arch(arm64)
            let requestedIdentity = PreparationIdentity(
                modelDirectoryPath: modelDirectory.path,
                systemPrompt: systemPrompt
            )

            if isWarmed, preparationIdentity == requestedIdentity {
                return
            }

            if let preparationTask, preparationIdentity == requestedIdentity {
                try await preparationTask.value
                return
            }

            if preparationTask != nil || preparationIdentity != nil {
                await unload()
            }

            Memory.cacheLimit = Self.activeCacheLimitBytes
            preparationIdentity = requestedIdentity
            let task = Task {
                try await prepareModel(
                    modelDirectory: modelDirectory,
                    systemPrompt: systemPrompt
                )
            }
            preparationTask = task

            do {
                try await waitForPreparationTask(task)
                preparationTask = nil
            } catch {
                preparationTask = nil
                preparationIdentity = nil
                await unload()
                throw error
            }
        #else
            throw VoiceInkRefineInferenceError.unavailable
        #endif
    }

    func enhance(
        transcript: String,
        modelDirectory: URL,
        systemPrompt: String,
        requestID: UUID? = nil
    ) async throws -> String {
        #if arch(arm64)
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return transcript
            }

            let clock = ContinuousClock()
            let startedAt = clock.now
            let wasWarm = isWarmed && modelContainer != nil
            let idle = lastEnhanceFinishedAt.map { ZhTWTiming.seconds(startedAt - $0) } ?? "-"

            try await prepare(
                modelDirectory: modelDirectory,
                systemPrompt: systemPrompt
            )
            let preparedAt = clock.now

            guard let modelContainer else {
                throw VoiceInkRefineInferenceError.modelNotLoaded
            }

            let inputTokenCount = await modelContainer.encode(transcript).count
            let encodedAt = clock.now
            let maximumOutputTokens = Self.maximumOutputTokens(
                forInputTokenCount: inputTokenCount
            )
            let session = makeSession(
                using: modelContainer,
                systemPrompt: systemPrompt,
                maximumOutputTokens: maximumOutputTokens
            )

            var output = ""
            var completionInfo: GenerateCompletionInfo?

            do {
                for try await event in session.streamDetails(to: transcript) {
                    try Task.checkCancellation()
                    switch event {
                    case .chunk(let text):
                        output.append(contentsOf: text)
                    case .info(let info):
                        completionInfo = info
                    case .toolCall:
                        break
                    }
                }
                await session.clear()
            } catch {
                await session.clear()
                throw error
            }

            let finishedAt = clock.now
            lastEnhanceFinishedAt = finishedAt
            Self.logEnhanceTiming(
                requestID: requestID,
                wasWarm: wasWarm,
                idle: idle,
                prepare: preparedAt - startedAt,
                encode: encodedAt - preparedAt,
                inputTokenCount: inputTokenCount,
                info: completionInfo,
                total: finishedAt - startedAt
            )

            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceInkRefineInferenceError.emptyOutput
            }

            return output
        #else
            throw VoiceInkRefineInferenceError.unavailable
        #endif
    }

    func unload() async {
        #if arch(arm64)
            var activePreparationTask = preparationTask
            let hadActivePreparation = activePreparationTask != nil
            activePreparationTask?.cancel()
            if let activePreparationTask {
                _ = try? await activePreparationTask.value
            }
            activePreparationTask = nil

            let hadLoadedResources =
                hadActivePreparation || modelContainer != nil || isWarmed
            preparationTask = nil
            preparationIdentity = nil

            if hadLoadedResources {
                Stream.gpu.synchronize()

                Memory.cacheLimit = 0
                autoreleasepool {
                    modelContainer = nil
                    isWarmed = false
                }

                Stream.gpu.synchronize()
                Memory.clearCache()
                Stream.gpu.synchronize()
            } else {
                Memory.cacheLimit = 0
                isWarmed = false
            }
        #endif
    }

    #if arch(arm64)
        private func prepareModel(
            modelDirectory: URL,
            systemPrompt: String
        ) async throws {
            let clock = ContinuousClock()
            let startedAt = clock.now
            let container = try await loadContainerIfNeeded(from: modelDirectory)
            let loadedAt = clock.now

            guard !isWarmed else { return }

            let warmupSession = makeSession(
                using: container,
                systemPrompt: systemPrompt,
                maximumOutputTokens: 1
            )
            do {
                _ = try await warmupSession.respond(to: "Speech")
                await warmupSession.clear()
            } catch {
                await warmupSession.clear()
                throw error
            }
            try Task.checkCancellation()

            isWarmed = true
            ZhTWTiming.logger.notice(
                "engine-prepare load=\(ZhTWTiming.seconds(loadedAt - startedAt), privacy: .public) warmup=\(ZhTWTiming.seconds(clock.now - loadedAt), privacy: .public) qos=\(ZhTWTiming.currentQoS, privacy: .public)"
            )
        }

        /// voiceink-zhtw：延遲調查用，只記時間和 token 數
        private static func logEnhanceTiming(
            requestID: UUID?,
            wasWarm: Bool,
            idle: String,
            prepare: Duration,
            encode: Duration,
            inputTokenCount: Int,
            info: GenerateCompletionInfo?,
            total: Duration
        ) {
            let id = requestID.map(ZhTWTiming.shortID) ?? "-"
            let promptTokens = info.map { String($0.promptTokenCount) } ?? "-"
            let promptTime = info.map { ZhTWTiming.seconds($0.promptTime) } ?? "-"
            let outputTokens = info.map { String($0.generationTokenCount) } ?? "-"
            let generateTime = info.map { ZhTWTiming.seconds($0.generateTime) } ?? "-"
            let stop = info.map { String(describing: $0.stopReason) } ?? "-"
            ZhTWTiming.logger.notice(
                "engine-enhance id=\(id, privacy: .public) warm=\(wasWarm ? 1 : 0, privacy: .public) idle=\(idle, privacy: .public) prepare=\(ZhTWTiming.seconds(prepare), privacy: .public) encode=\(ZhTWTiming.seconds(encode), privacy: .public) inputTokens=\(inputTokenCount, privacy: .public) promptTokens=\(promptTokens, privacy: .public) prompt=\(promptTime, privacy: .public) outputTokens=\(outputTokens, privacy: .public) generate=\(generateTime, privacy: .public) stop=\(stop, privacy: .public) total=\(ZhTWTiming.seconds(total), privacy: .public) thermal=\(ZhTWTiming.thermalState, privacy: .public) lowPower=\(ZhTWTiming.lowPowerMode, privacy: .public) qos=\(ZhTWTiming.currentQoS, privacy: .public)"
            )
        }

        private func loadContainerIfNeeded(
            from modelDirectory: URL
        ) async throws -> MLXLMCommon.ModelContainer {
            if let modelContainer {
                return modelContainer
            }

            let loadedContainer = try await loadModelContainer(
                from: modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
            try Task.checkCancellation()

            modelContainer = loadedContainer
            return loadedContainer
        }

        private func makeSession(
            using container: MLXLMCommon.ModelContainer,
            systemPrompt: String,
            maximumOutputTokens: Int
        ) -> ChatSession {
            // voiceink-zhtw：繁中補標點的範例要用多輪對話餵給模型，並用 temperature 0
            if let fewShot = Self.decodeFewShot(systemPrompt) {
                var history: [Chat.Message] = [.system(fewShot.system)]
                for example in fewShot.examples where example.count == 2 {
                    history.append(.user(example[0]))
                    history.append(.assistant(example[1]))
                }
                return ChatSession(
                    container,
                    history: history,
                    generateParameters: GenerateParameters(
                        maxTokens: maximumOutputTokens,
                        temperature: 0
                    ),
                    additionalContext: ["enable_thinking": false]
                )
            }

            return ChatSession(
                container,
                instructions: systemPrompt,
                generateParameters: GenerateParameters(
                    maxTokens: maximumOutputTokens,
                    temperature: 0.3
                ),
                additionalContext: ["enable_thinking": false]
            )
        }

        /// 對應 App 端 ZhTWPunctuation.encodedInstructions（XPC 是另一個 target，看不到那個檔案）
        private struct FewShot: Decodable {
            let system: String
            let examples: [[String]]
        }

        private static let fewShotMarker = "ZHTW_FEW_SHOT_JSON:"

        private static func decodeFewShot(_ systemPrompt: String) -> FewShot? {
            guard systemPrompt.hasPrefix(fewShotMarker) else { return nil }
            let json = Data(systemPrompt.dropFirst(fewShotMarker.count).utf8)
            return try? JSONDecoder().decode(FewShot.self, from: json)
        }

        private func waitForPreparationTask(
            _ task: Task<Void, Error>
        ) async throws {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }

        private static func maximumOutputTokens(
            forInputTokenCount inputTokenCount: Int
        ) -> Int {
            let scaledTokenLimit =
                inputTokenCount > maximumGenerationTokens / 2
                ? maximumGenerationTokens
                : inputTokenCount * 2
            return min(max(scaledTokenLimit, 256), maximumGenerationTokens)
        }
    #endif
}
