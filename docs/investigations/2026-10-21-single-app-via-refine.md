# 單一 App:用 VoiceInk Refine 的引擎跑補標點模型

2026-10-21。背景:v1 要裝兩個 App(VoiceInk + LM Studio),還要 Python 腳本、LM Studio 開機自動啟動、VoiceInk 的模式要同時設 Provider 和 Prompt(少一個就默默不潤稿)。換電腦很麻煩。想知道能不能把補標點模型直接放進 VoiceInk。

## 發現:VoiceInk 已經有 App 內的語言模型引擎

build VoiceInk 時需要 Metal 工具鏈,是因為它連結了 `mlx-swift-lm`(`MLXLLM`、`MLXLMCommon`、`MLXHuggingFace`)。用途是「VoiceInk Refine」:

| 項目 | 原作者的實作 |
|---|---|
| 模型 | `beingpax/VoiceInk-Refine-V1`(Qwen3.5 基底、英文潤稿),固定 revision 下載到 `Application Support/.../VoiceInkRefine/` |
| 執行位置 | 獨立的 XPC 子程序 `VoiceInkRefineXPC`(`VoiceInkRefineInferenceEngine`),用 `ChatSession` 生成 |
| 介面 | `prepare(modelDirectory:systemPrompt:)`、`enhance(transcript:modelDirectory:systemPrompt:)` |
| 載入時機 | 開始錄音時,如果模式的潤稿是 Refine,就在背景 `prepareForRecording()` |
| 卸載 | 用完 10 秒(`warmGracePeriod`,寫死)沒再用就結束 XPC 子程序 |
| 條件 | Apple Silicon、16GB 以上記憶體 |
| 模式設定 | Provider 選 Refine 時不需要 Prompt,也會自動關掉剪貼簿 / 螢幕等前後文 |

引擎本身是通用的:給任何 MLX 模型資料夾加一段系統指示就能跑,而且已經傳 `enable_thinking: false`。Breeze2-3B 是 Llama 架構,`MLXLLM` 支援。

## 考慮過的做法

| 做法 | App 數量 | 換電腦 | 維護 |
|---|---|---|---|
| v1 維持:VoiceInk + LM Studio | 2 | 要裝 LM Studio、手動開「登入時啟動」 | 不改 VoiceInk |
| LM Studio 換成背景服務(LaunchAgent 跑 `mlx_lm.server`) | 1 + 背景服務 | 要裝 Python 環境 | 自己維護服務 |
| **fork VoiceInk,讓 Refine 改跑 Breeze2** | **1** | 只要 VoiceInk | 要合併上游更新 |

## 要解決的問題

1. **範例要用多輪對話。** XPC 只傳一段 `systemPrompt` 字串,但範例寫在系統指示裡效果很差(16 句有 7 句改寫或回答問題,見 [2026-10-21-punctuation-model-benchmark.md](2026-10-21-punctuation-model-benchmark.md))。`ChatSession` 有 `init(_:instructions:history:...)`,引擎每次都開新的 session,所以可以每次帶入範例。做法:App 端把系統指示和範例包成 `ZHTW_FEW_SHOT_JSON:{...}`,引擎看到前綴就展開成 `[.system, .user, .assistant, ...]`。不用改 XPC 的介面。
2. **temperature。** 原本 0.3,補標點要穩定,用 0。
3. **合併。** `punct.py` 的對齊邏輯改寫成 Swift(`String.applyingTransform` 做簡繁轉換、`difference(from:)` 做逐字對齊),24 個案例和 Python 版結果完全一致。
4. **10 秒卸載太短。** 見下方實測。

## 實測(M1 Pro 32GB,LM Studio 已關閉)

| 情況 | 錄音長度 | 補標點耗時 |
|---|---|---|
| 閒置後第一句 | 7.0 秒 | 2.82 秒 |
| 閒置後第一句 | 3.9 秒 | 2.65 秒 |
| 連續講(模型已載入) | 1.9–4.2 秒 | 0.78–0.83 秒 |

- 模型已載入時約 0.8 秒,比 LM Studio(0.4–0.6 秒)慢一點:LM Studio 會快取每次都一樣的範例前綴,`ChatSession` 每次重算。差距可以接受。
- 閒置 10 秒就卸載,短句的錄音時間不夠在背景載完,所以要多等。改成可設定、預設 5 分鐘(`ZhTWRefineKeepWarmSeconds`)。
- 對照:v1 的 LM Studio 閒置 1 小時才卸載,之後的冷啟動約 7 秒。

## 建議

**fork VoiceInk,讓 Refine 改跑 Breeze2。** 只剩一個 App,模型的載入、卸載由 VoiceInk 自己管。改動集中在 4 個檔案(見 [../architecture/README.md](../architecture/README.md#修改了原作者的哪些檔案)),沒裝 Breeze2 時 Refine 行為不變。
