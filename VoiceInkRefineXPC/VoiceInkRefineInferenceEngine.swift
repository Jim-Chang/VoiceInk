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
        /// voiceink-zhtw：目前載入的模型資料夾。模型權重和指示無關，只有它變了才重新載入
        private var loadedModelDirectoryPath: String?
        /// voiceink-zhtw：固定的指示和範例先算好的 KV cache（prefix cache），每句複製一份接著算
        private var promptPrefix: PromptPrefix?

        private final class PromptPrefix: @unchecked Sendable {
            let tokens: [Int]
            let cache: [KVCache]

            init(tokens: [Int], cache: [KVCache]) {
                self.tokens = tokens
                self.cache = cache
            }
        }

        /// ChatSession 內部也是這樣把對話傳進 container.perform（Chat.Message 沒標 Sendable）
        private struct UncheckedSendable<Value>: @unchecked Sendable {
            let value: Value
        }

        private struct Generated: Sendable {
            let output: String
            let info: GenerateCompletionInfo?
            let usedPromptPrefix: Bool
        }
    #endif

    /// voiceink-zhtw：false 時每句都從頭讀指示（原作者的做法），只給 scripts/bench 比對輸出用
    private let usesPromptPrefixCache: Bool

    init(usesPromptPrefixCache: Bool = true) {
        self.usesPromptPrefixCache = usesPromptPrefixCache
    }

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

            // voiceink-zhtw：模型權重和指示無關，只有換模型才卸載。
            // 只換指示時，等進行中的準備做完、模型留著，重算 prefix cache 就好。
            if let preparationTask {
                _ = try? await preparationTask.value
                if isWarmed, preparationIdentity == requestedIdentity {
                    return
                }
            }
            if let loadedModelDirectoryPath,
                loadedModelDirectoryPath != requestedIdentity.modelDirectoryPath
            {
                await unload()
            }

            Memory.cacheLimit = Self.activeCacheLimitBytes
            preparationIdentity = requestedIdentity
            isWarmed = false
            let task = Task {
                try await prepareModel(
                    modelDirectory: modelDirectory,
                    systemPrompt: systemPrompt
                )
            }
            preparationTask = task

            do {
                try await waitForPreparationTask(task)
                if preparationTask == task {
                    preparationTask = nil
                }
            } catch {
                if preparationTask == task {
                    preparationTask = nil
                    preparationIdentity = nil
                    await unload()
                }
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
            let generated: Generated
            if usesPromptPrefixCache {
                generated = try await generateWithPromptPrefix(
                    using: modelContainer,
                    systemPrompt: systemPrompt,
                    transcript: transcript,
                    maximumOutputTokens: maximumOutputTokens
                )
            } else {
                generated = try await generateWithSession(
                    using: modelContainer,
                    systemPrompt: systemPrompt,
                    transcript: transcript,
                    maximumOutputTokens: maximumOutputTokens
                )
            }
            let output = generated.output
            let completionInfo = generated.info

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
                usedPromptPrefix: usesPromptPrefixCache ? generated.usedPromptPrefix : nil,
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
                    promptPrefix = nil
                    isWarmed = false
                }
                loadedModelDirectoryPath = nil

                Stream.gpu.synchronize()
                Memory.clearCache()
                Stream.gpu.synchronize()
            } else {
                Memory.cacheLimit = 0
                promptPrefix = nil
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

            if usesPromptPrefixCache {
                // voiceink-zhtw：算好 prefix cache，再用它跑一次很短的補標點，
                // 讓讀入和產生文字的 GPU 程式都先準備好（取代原本的暖機）
                promptPrefix = try await Self.buildPromptPrefix(
                    using: container,
                    systemPrompt: systemPrompt
                )
                _ = try await generateWithPromptPrefix(
                    using: container,
                    systemPrompt: systemPrompt,
                    transcript: "好",
                    maximumOutputTokens: 2
                )
            } else {
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
            }
            try Task.checkCancellation()

            isWarmed = true
            ZhTWTiming.logger.notice(
                "engine-prepare load=\(ZhTWTiming.seconds(loadedAt - startedAt), privacy: .public) warmup=\(ZhTWTiming.seconds(clock.now - loadedAt), privacy: .public) prefixTokens=\(self.promptPrefix?.tokens.count ?? 0, privacy: .public) qos=\(ZhTWTiming.currentQoS, privacy: .public)"
            )
        }

        // MARK: - voiceink-zhtw：prefix cache

        /// 同一組指示配兩句不同的逐字稿，共同的開頭 token 就是每句都一樣的部分
        /// （系統指示、範例、使用者那一輪的開頭）。算一次 KV cache 存起來。
        private static func buildPromptPrefix(
            using container: MLXLMCommon.ModelContainer,
            systemPrompt: String
        ) async throws -> PromptPrefix {
            let first = UncheckedSendable(value: chatMessages(systemPrompt: systemPrompt, transcript: "甲"))
            let second = UncheckedSendable(value: chatMessages(systemPrompt: systemPrompt, transcript: "乙"))
            let parameters = generateParameters(systemPrompt: systemPrompt, maximumOutputTokens: 1)
            return try await container.perform { context in
                let firstTokens = try await context.processor.prepare(input: userInput(first.value))
                    .text.tokens.asArray(Int.self)
                let secondTokens = try await context.processor.prepare(input: userInput(second.value))
                    .text.tokens.asArray(Int.self)
                let tokens = zip(firstTokens, secondTokens).prefix { $0 == $1 }.map(\.0)

                let cache = context.model.newCache(parameters: parameters)
                _ = try TokenIterator(
                    input: LMInput(tokens: MLXArray(tokens)),
                    model: context.model,
                    cache: cache,
                    parameters: parameters
                )
                eval(cache)
                return PromptPrefix(tokens: tokens, cache: cache)
            }
        }

        /// 和原作者的 ChatSession 用一樣的對話範本、一樣的產生方式；
        /// 差別只在開頭和 prefix cache 一樣時，複製 cache、只算後面的部分。
        private func generateWithPromptPrefix(
            using container: MLXLMCommon.ModelContainer,
            systemPrompt: String,
            transcript: String,
            maximumOutputTokens: Int
        ) async throws -> Generated {
            let messages = UncheckedSendable(
                value: Self.chatMessages(systemPrompt: systemPrompt, transcript: transcript))
            let parameters = Self.generateParameters(
                systemPrompt: systemPrompt,
                maximumOutputTokens: maximumOutputTokens
            )
            let prefix = promptPrefix
            return try await container.perform { context in
                let prepared = try await context.processor.prepare(input: Self.userInput(messages.value))
                let fullTokens = prepared.text.tokens.asArray(Int.self)

                let input: LMInput
                let cache: [KVCache]
                let usedPromptPrefix: Bool
                if let prefix, fullTokens.count > prefix.tokens.count,
                    fullTokens.starts(with: prefix.tokens)
                {
                    input = LMInput(tokens: MLXArray(Array(fullTokens.dropFirst(prefix.tokens.count))))
                    cache = prefix.cache.map { $0.copy() }
                    usedPromptPrefix = true
                } else {
                    input = prepared
                    cache = context.model.newCache(parameters: parameters)
                    usedPromptPrefix = false
                }

                var output = ""
                var info: GenerateCompletionInfo?
                for await event in try generate(
                    input: input, cache: cache, parameters: parameters, context: context)
                {
                    try Task.checkCancellation()
                    switch event {
                    case .chunk(let text):
                        output.append(contentsOf: text)
                    case .info(let completion):
                        info = completion
                    case .toolCall:
                        break
                    }
                }
                return Generated(output: output, info: info, usedPromptPrefix: usedPromptPrefix)
            }
        }

        /// 原作者的做法：每句建新的 ChatSession，從頭讀指示
        private func generateWithSession(
            using container: MLXLMCommon.ModelContainer,
            systemPrompt: String,
            transcript: String,
            maximumOutputTokens: Int
        ) async throws -> Generated {
            let session = makeSession(
                using: container,
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
            return Generated(output: output, info: completionInfo, usedPromptPrefix: false)
        }

        private static let additionalContext: [String: any Sendable] = ["enable_thinking": false]

        /// 和 ChatSession 組出來的對話一樣：繁中範例展開成多輪，否則只有系統指示
        private static func chatMessages(systemPrompt: String, transcript: String) -> [Chat.Message] {
            var messages: [Chat.Message]
            if let fewShot = decodeFewShot(systemPrompt) {
                messages = [.system(fewShot.system)]
                for example in fewShot.examples where example.count == 2 {
                    messages.append(.user(example[0]))
                    messages.append(.assistant(example[1]))
                }
            } else {
                messages = [.system(systemPrompt)]
            }
            messages.append(.user(transcript))
            return messages
        }

        private static func userInput(_ messages: [Chat.Message]) -> UserInput {
            UserInput(
                chat: messages,
                processing: .init(resize: CGSize(width: 512, height: 512)),
                additionalContext: additionalContext
            )
        }

        private static func generateParameters(
            systemPrompt: String,
            maximumOutputTokens: Int
        ) -> GenerateParameters {
            GenerateParameters(
                maxTokens: maximumOutputTokens,
                temperature: decodeFewShot(systemPrompt) != nil ? 0 : 0.3
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
            usedPromptPrefix: Bool?,
            total: Duration
        ) {
            let id = requestID.map(ZhTWTiming.shortID) ?? "-"
            let promptTokens = info.map { String($0.promptTokenCount) } ?? "-"
            let promptTime = info.map { ZhTWTiming.seconds($0.promptTime) } ?? "-"
            let outputTokens = info.map { String($0.generationTokenCount) } ?? "-"
            let generateTime = info.map { ZhTWTiming.seconds($0.generateTime) } ?? "-"
            let stop = info.map { String(describing: $0.stopReason) } ?? "-"
            let prefix = usedPromptPrefix.map { $0 ? "1" : "0" } ?? "-"
            ZhTWTiming.logger.notice(
                "engine-enhance id=\(id, privacy: .public) warm=\(wasWarm ? 1 : 0, privacy: .public) idle=\(idle, privacy: .public) prepare=\(ZhTWTiming.seconds(prepare), privacy: .public) encode=\(ZhTWTiming.seconds(encode), privacy: .public) inputTokens=\(inputTokenCount, privacy: .public) promptTokens=\(promptTokens, privacy: .public) prompt=\(promptTime, privacy: .public) outputTokens=\(outputTokens, privacy: .public) generate=\(generateTime, privacy: .public) stop=\(stop, privacy: .public) prefix=\(prefix, privacy: .public) total=\(ZhTWTiming.seconds(total), privacy: .public) thermal=\(ZhTWTiming.thermalState, privacy: .public) lowPower=\(ZhTWTiming.lowPowerMode, privacy: .public) qos=\(ZhTWTiming.currentQoS, privacy: .public)"
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
            loadedModelDirectoryPath = modelDirectory.path
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
