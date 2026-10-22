# 架構與設計規劃

這份文件是這個 fork「想做什麼、已經決定什麼、現在進行到哪裡」的唯一真相來源(single source of truth)。研究細節與來源在 [../investigations/](../investigations/),執行步驟與紀錄在 [../plan/](../plan/),這裡只放結論與決策。

最後更新:2026-10-22(決定補標點換成 CT-Transformer;目前程式仍是 v2:補標點由 VoiceInk Refine 的引擎執行)。

## 專案目標

1. **在 Mac 上用語音輸入台灣繁體中文**,主要用在 Claude Code 等文字輸入框。輸出**一定是繁體**。
2. **自動加上標點符號**,而且不能改動講的字。
3. **全部在本機執行**,不把聲音或文字送到雲端。
4. **換一台 Mac 也能很快裝好**。

## 非目標

- **邊講邊把字打進輸入框**:VoiceInk 的即時轉錄只把文字顯示在自己的錄音面板,講完才一次貼上;Breeze-ASR-25 屬於 Whisper 類模型,本來就要聽完一段才辨識(見 [../investigations/2026-10-21-dictation-app-and-asr.md](../investigations/2026-10-21-dictation-app-and-asr.md))。真的需要時用 macOS 內建聽寫。
- **回饋給原作者**:這個 fork 不會發 PR 回 [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk),所以照自己的慣例改(文件、README、腳本),不用為了上游而壓低改動量。但仍會定期合併上游更新(見 [../development.md](../development.md))。
- **雲端辨識或潤稿服務**、**Intel Mac**、**16GB 以下記憶體的 Mac**(VoiceInk Refine 的限制)。

## 指導原則

- **繁體由程式保證,不靠模型。** 語言模型只負責「建議標點」;最後輸出的每個字都來自語音辨識的原文(`ZhTWPunctuation.merge`)。模型改字、轉成簡體、改寫句子、跑去回答問題,都不會出現在結果裡。
- **出錯就貼原文,不卡住。** 模型沒載入、對齊失敗,一律回傳沒標點的原文。
- **用 VoiceInk 已經有的機制。** 語音辨識用它的 whisper.cpp 模型管理,補標點用它的 VoiceInk Refine(App 內的 MLX 引擎,跑在獨立的 XPC 子程序)。不另外架伺服器、不需要開機自動啟動。
- **模型固定版本、核對 SHA256。** 兩個模型都是社群轉檔,固定在測過的 revision。
- **用實際的聽寫內容做決策。** 模型選擇、參數調整都先跑測試、留數據(見 [../investigations/2026-10-21-punctuation-model-benchmark.md](../investigations/2026-10-21-punctuation-model-benchmark.md))。

## 架構

```
按快捷鍵說話
   ↓
VoiceInk.app
   ├─ 開始錄音的同時,在 VoiceInkRefineXPC 子程序載入 Breeze2-3B(背景進行)
   ├─ 語音辨識:Breeze-ASR-25(whisper.cpp)→ 繁體、沒標點          約 1.2–2 秒
   │    └─ 中文 Whisper 提示詞必須是繁體句子(否則會被帶成簡體)
   ├─ Word Replacements(固定錯字替換)
   ├─ AI 潤稿 = VoiceInk Refine → Breeze2-3B 建議標點               短句約 0.3 秒(模型已載入時)
   │    ├─ 繁中指示 + 多輪範例(包成 JSON,由 XPC 引擎展開)、temperature 0
   │    ├─ 固定的指示和範例算成 prefix cache,每句只算逐字稿;超過 120 字分段補
   │    └─ ZhTWPunctuation.merge:對齊原文,只取前後字相鄰的標點
   └─ 貼到游標位置
   (模型用完 5 分鐘沒再用就卸載,釋放約 2GB 記憶體)
```

### 元件與位置

| 元件 | 位置 | 說明 |
|---|---|---|
| VoiceInk.app | `/Applications/VoiceInk.app` | 這個 fork 的 `zhtw` 分支自己 build |
| whisper.cpp 函式庫 | `~/VoiceInk-Dependencies/` | build 用,Xcode 專案寫死這個路徑,**別刪** |
| 語音辨識模型 | `~/Library/Application Support/com.prakashjoshipax.VoiceInk/WhisperModels/ggml-breeze-asr-25-q8_0.bin` | [Breeze-ASR-25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25) 的 whisper.cpp 轉檔(1.7GB) |
| 補標點模型 | `~/Library/Application Support/com.prakashjoshipax.VoiceInk/ZhTWPunctuation/Llama-Breeze2-3B-Instruct-Text-mlx-4Bit/` | [Breeze2-3B](https://huggingface.co/MediaTek-Research/Llama-Breeze2-3B-Instruct) 的 MLX 4bit 轉檔(2GB);資料夾存在時 VoiceInk Refine 就改用它 |
| 設定 | UserDefaults 網域 `com.prakashjoshipax.VoiceInk` | 由 `scripts/setup.sh configure` 寫入 |

### 修改了原作者的哪些檔案

| 檔案 | 改了什麼 |
|---|---|
| `VoiceInk/Features/ZhTW/ZhTWPunctuation.swift`(新增) | 模型位置、繁中指示、範例、合併邏輯、長逐字稿分段 |
| `VoiceInk/Features/ModelLibrary/State/VoiceInkRefineService.swift` | 有 Breeze2 時改用它的資料夾與指示,輸出後合併;計時紀錄 |
| `VoiceInkRefineXPC/VoiceInkRefineInferenceEngine.swift` | 範例展開成多輪對話、temperature 0;prefix cache;換指示不重新載入模型;計時紀錄 |
| `VoiceInk/Infrastructure/Providers/Enhancement/VoiceInkRefine/VoiceInkRefineXPCClient.swift` | 閒置卸載時間改成可設定,預設 5 分鐘;計時紀錄 |
| `VoiceInk/Features/ZhTW/ZhTWTiming.swift`、`VoiceInkRefineXPC/ZhTWTiming.swift`(新增) | 延遲調查的計時紀錄(只記時間和數量) |
| `VoiceInkRefineXPC/VoiceInkRefineXPCService.swift` | 計時紀錄 |
| `VoiceInk/Infrastructure/Providers/Transcription/Whisper/WhisperPrompt.swift` | 中文提示詞的預設值改成繁體 |
| `README.md` | 換成這個 fork 的說明 |

## 決策紀錄

- **2026-10-21 不用 Claude Code 內建的語音輸入。** 它的聽寫語言清單沒有中文,講普通話會輸出簡體,沒有設定能改(上游 issue [anthropics/claude-code#78728](https://github.com/anthropics/claude-code/issues/78728))。改用外部聽寫 App,把文字貼進輸入框。
- **2026-10-21 選 VoiceInk + Breeze-ASR-25。** VoiceInk 開源(GPLv3)、能匯入 whisper.cpp 格式的模型;Breeze-ASR-25 針對台灣華語和中英夾雜,直接輸出繁體。macOS 內建聽寫能出繁體,但中文準確度沒有可靠數據。比較見 [../investigations/2026-10-21-dictation-app-and-asr.md](../investigations/2026-10-21-dictation-app-and-asr.md)。
- **2026-10-21 自己 build VoiceInk。** 官網版要買授權(25 美元起);自己 build 免費、合法,也才能改程式。
- **2026-10-21 中文 Whisper 提示詞改成繁體。** VoiceInk 內建的中文提示詞是簡體,把 Breeze 帶成簡體輸出(見 [../investigations/2026-10-21-traditional-output.md](../investigations/2026-10-21-traditional-output.md))。2026-10-22 起直接改 App 內建的預設值(`WhisperPrompt.swift`),新裝的 App 不用另外設定。
- **2026-10-21 v1:LM Studio + Breeze2-3B 補標點(兩個 App)。** 比較 Qwen3.5-2B、Qwen3.5-4B、Breeze2-3B 後選 Breeze2(最快、品質接近 4B、繁中特化)。VoiceInk 用 Local CLI 呼叫 Python 腳本,腳本呼叫 LM Studio。見 [../plan/2026-10-21-v1-lmstudio-two-apps.md](../plan/2026-10-21-v1-lmstudio-two-apps.md)。
- **2026-10-21 合併時只取「前後字相鄰」的標點。** Breeze2 會把對話口吻的句子改寫(「我」改成「你」),原本整句退回原文;改成只採用可靠位置的標點。
- **2026-10-21 v2:改成單一 App。** 發現 VoiceInk 內建的 VoiceInk Refine 就是 App 內的 MLX 語言模型引擎,讓它載入 Breeze2 即可,拿掉 LM Studio、Python 腳本、背景伺服器。見 [../investigations/2026-10-21-single-app-via-refine.md](../investigations/2026-10-21-single-app-via-refine.md)、[../plan/2026-10-21-v2-single-app.md](../plan/2026-10-21-v2-single-app.md)。
- **2026-10-21 範例一定要用多輪對話。** 範例寫在系統指示裡時,16 句有 7 句模型改寫或回答問題;XPC 只能傳一段字串,所以把範例包成 JSON 由引擎展開。
- **2026-10-21 模型閒置 5 分鐘才卸載。** 原作者寫死 10 秒,短句來不及在錄音期間載入,閒置後第一句要多等約 2 秒。
- **2026-10-21 用公開 fork、不回饋上游、照自己的慣例。** GitHub 規定公開專案的 fork 只能公開。文件繁中、commit 訊息英文。v1 的完整紀錄(含實際聽寫的測試數據)留在私人 repo `voiceink-zhtw-lmstudio`(標籤 `v1-two-apps`)。
- **2026-10-21 實際聽寫的實驗資料另開私人 repo `voiceink-zhtw-data`。** v1 的 repo 名稱綁著 LM Studio,不適合放 v2 之後的資料;公開文件只放統計數字。
- **2026-10-21 修正:補標點偶爾多 1.6 秒是模型被重新載入。** 傳給 XPC 的指示字串由 Swift 字典轉 JSON,key 順序不固定,引擎以為指示換了就卸載重來。改成只產生一次、key 排序。見 [../investigations/2026-10-21-latency.md](../investigations/2026-10-21-latency.md)。
- **2026-10-21 換指示不重新載入模型、用 prefix cache。** 模型權重和指示無關;原作者每句重讀約 330 個 token 的固定指示和範例。短句補標點 0.82 → 0.26 秒(91 段實際聽寫離線量測,89 段輸出和原本逐字相同)。
- **2026-10-21 長的逐字稿分段補標點(每段最多 120 字)。** 太長時 Breeze2 會把整段當成要回應的話,合併對不上就整段沒有標點(582 字的實例)。
- **2026-10-21 語音辨識維持 Breeze-ASR-25 q8_0 + Metal。** q5、q4 沒變快反而錯更多;Core ML 編碼器更慢且第一次要編譯 14.5 分鐘;只處理實際長度錯誤率約 20%。見 [../investigations/2026-10-21-latency.md](../investigations/2026-10-21-latency.md) 實驗 B。
- **2026-10-22 補標點換成 CT-Transformer int8(sherpa-onnx)。** 使用者盲測 15 題:CT 8 題較好、Breeze2 3 題、差不多 4 題;每段 2–35 毫秒(Breeze2 0.26–2.7 秒)、模型 75MB、只用 CPU、結構上不會改字或答非所問。在 App 行程內用 sherpa-onnx 跑,辨識完直接補,不再經過 AI 潤稿。模型內建進 App、不加開關(辨識結果有中文字、沒有句號才補)。Breeze2 要不要留著備用,之後再決定。見 [../plan/2026-10-22-ct-punctuation.md](../plan/2026-10-22-ct-punctuation.md)。
- **2026-10-22 其他設定用 VoiceInk 內建的匯出、匯入帶到另一台 Mac。** 「設定 → Export Settings」會帶模式(語音模型、語言、AI 潤稿、文字格式化)、快捷鍵、Word Replacements、詞彙表,不含 API key、中文提示詞和模型;所以只有中文提示詞寫進 App,其他不另外寫預設值。
- **2026-10-22 聽寫紀錄和錄音保留 3 天。** VoiceInk 預設不刪,錄音約每分鐘 1.9MB,一天講 30 分鐘一個月約 1.7GB。用 VoiceInk 內建的「Auto-delete Transcript History」(`configure_voiceink.py` 寫入,也會跟著內建匯出帶走);它也會刪掉沒有對應紀錄的錄音檔。要拿實際聽寫做實驗時,三天內先複製到私人 repo。

## 目前進度

- v2 完成並在 M1 Pro 32GB 上使用中。
- 完成:延遲調查,見 [../investigations/2026-10-21-latency.md](../investigations/2026-10-21-latency.md)。
- 進行中:補標點換成 CT-Transformer,見 [../plan/2026-10-22-ct-punctuation.md](../plan/2026-10-22-ct-punctuation.md)。
- 暫停:模型改成在 App 介面下載、預設值寫進 App(省掉 `configure`)、打包成 zip 給其他 Mac 安裝(不需要 Xcode)。見 [../plan/2026-10-21-in-app-model-download.md](../plan/2026-10-21-in-app-model-download.md)。換完 CT 再接著做,步驟 b 拿掉。
