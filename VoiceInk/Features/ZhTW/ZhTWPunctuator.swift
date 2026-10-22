import Foundation
import SherpaOnnxC

/// voiceink-zhtw：辨識完直接補標點，不經過 AI 潤稿。
///
/// 用 CT-Transformer（FunASR 的中英文標點模型，sherpa-onnx 轉的 int8 版，跟著 App 一起裝），
/// 在 App 自己的行程裡用 CPU 跑，每段幾毫秒。模型用簡體訓練：先轉簡體給它判斷，
/// 再用 `ZhTWPunctuation.merge` 把標點插回繁體原文，輸出的每個字都來自辨識原文。
/// 和語音辨識模型一樣用完就放：開始錄音時載入（約 0.14 秒，藏在講話時間裡），
/// 聽寫結束時（VoiceInkEngine.cleanupResources）釋放，平常不佔記憶體（載入後約 250MB）。
/// 設計見 docs/plan/2026-10-22-ct-punctuation.md。
actor ZhTWPunctuator {
    static let shared = ZhTWPunctuator()

    static let modelFolderName = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
    /// 查問題時關掉：defaults write com.prakashjoshipax.VoiceInk ZhTWPunctuationEnabled -bool false
    static let enabledKey = "ZhTWPunctuationEnabled"

    static var modelURL: URL? {
        Bundle.main.url(forResource: "model.int8", withExtension: "onnx", subdirectory: modelFolderName)
    }

    private var punctuation: OpaquePointer?
    private var loadFailed = false
    private var didNotifyFailure = false
    private let modelPath: String?

    init(modelPath: String? = ZhTWPunctuator.modelURL?.path) {
        self.modelPath = modelPath
    }

    /// 開始錄音時在背景載入，講完就不用等。
    nonisolated static func preload() {
        Task.detached(priority: .utility) { await shared.load() }
    }

    nonisolated static func shouldPunctuate(_ text: String) -> Bool {
        guard UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true else { return false }
        return ZhTWPunctuation.needsPunctuation(text)
    }

    /// 補標點；不需要補、模型載入失敗或出錯時回傳原文。模型還沒載入就先載入。
    /// 不是聽寫的流程（匯入音檔、在紀錄裡重新辨識）沒有聽寫結束的時機，用 `unloadAfterwards` 補完就放。
    func punctuate(_ text: String, unloadAfterwards: Bool = false) async -> String {
        defer { if unloadAfterwards { unload() } }
        guard Self.shouldPunctuate(text) else { return text }
        let started = ContinuousClock.now
        let loadDuration = load()
        guard let punctuation else {
            await notifyFailureOnce()
            return text
        }

        let modelStarted = ContinuousClock.now
        let input = ZhTWPunctuation.modelInput(for: text)
        guard let raw = SherpaOfflinePunctuationAddPunct(punctuation, input) else { return text }
        let modelOutput = String(cString: raw)
        SherpaOfflinePunctuationFreeText(raw)

        let mergeStarted = ContinuousClock.now
        let merged = ZhTWPunctuation.merge(original: text, modelOutput: modelOutput)
        let finished = ContinuousClock.now
        ZhTWTiming.logger.notice(
            "punct chars=\(text.count, privacy: .public) load=\(ZhTWTiming.seconds(loadDuration), privacy: .public) model=\(ZhTWTiming.seconds(mergeStarted - modelStarted), privacy: .public) merge=\(ZhTWTiming.seconds(finished - mergeStarted), privacy: .public) total=\(ZhTWTiming.seconds(finished - started), privacy: .public)"
        )
        return merged
    }

    /// 載入模型；回傳這次花的時間（已經載入過就是 0）。
    @discardableResult
    func load() -> Duration {
        guard punctuation == nil, !loadFailed else { return .zero }
        let started = ContinuousClock.now
        guard let modelPath else {
            loadFailed = true
            ZhTWTiming.logger.error("punct model missing")
            return .zero
        }
        punctuation = modelPath.withCString { model in
            "cpu".withCString { provider in
                var config = SherpaOnnxOfflinePunctuationConfig()
                config.model.ct_transformer = model
                config.model.num_threads = 2
                config.model.provider = provider
                return SherpaOnnxCreateOfflinePunctuation(&config)
            }
        }
        let duration = ContinuousClock.now - started
        if punctuation == nil {
            loadFailed = true
            ZhTWTiming.logger.error("punct load failed")
        } else {
            ZhTWTiming.logger.notice("punct-load load=\(ZhTWTiming.seconds(duration), privacy: .public)")
        }
        return duration
    }

    func unload() {
        guard let punctuation else { return }
        SherpaOnnxDestroyOfflinePunctuation(punctuation)
        self.punctuation = nil
        ZhTWTiming.logger.notice("punct-unload")
    }

    private func notifyFailureOnce() async {
        guard !didNotifyFailure else { return }
        didNotifyFailure = true
        await MainActor.run {
            NotificationManager.shared.showNotification(title: "補標點模型載入失敗，暫時不補標點", type: .warning)
        }
    }
}
