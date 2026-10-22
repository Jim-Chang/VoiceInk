# 架構與設計規劃

這份文件是這個 fork「想做什麼、已經決定什麼、現在進行到哪裡」的唯一真相來源(single source of truth)。研究細節與來源在 [../investigations/](../investigations/),執行步驟與紀錄在 [../plan/](../plan/),這裡只放結論與決策。

最後更新:2026-10-22(長音檔:語音偵測切段、鬼打牆的保險、長文字分段補標點、批次辨識;transcribe.cpp 升到 0.4.0)。

## 專案目標

1. **在 Mac 上用語音輸入台灣繁體中文**,主要用在 Claude Code 等文字輸入框。輸出**一定是繁體**。
2. **自動加上標點符號**,而且不能改動講的字。
3. **全部在本機執行**,不把聲音或文字送到雲端。
4. **換一台 Mac 也能很快裝好**。

## 非目標

- **邊講邊把字打進輸入框**:VoiceInk 的即時轉錄只把文字顯示在自己的錄音面板,講完才一次貼上;Breeze-ASR-25 屬於 Whisper 類模型、TEA-ASR 在 transcribe.cpp 也沒有串流,都要聽完一段才辨識(見 [../investigations/2026-10-21-dictation-app-and-asr.md](../investigations/2026-10-21-dictation-app-and-asr.md))。真的需要時用 macOS 內建聽寫。
- **回饋給原作者**:這個 fork 不會發 PR 回 [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk),所以照自己的慣例改(文件、README、腳本),不用為了上游而壓低改動量。但仍會定期合併上游更新(見 [../development.md](../development.md))。
- **雲端辨識或潤稿服務**、**Intel Mac**。記憶體只在 32GB 測過(聽寫時約用 3.7GB,聽寫完釋放)。

## 指導原則

- **繁體由程式保證,不靠模型。** 補標點模型只負責「建議標點」;最後輸出的每個字都來自語音辨識的原文(`ZhTWPunctuation.merge`),只有辨識模型漏出的簡體專用字由程式轉成繁體(`ZhTWTranscript.clean`)。模型改字、轉成簡體、改寫句子、跑去回答問題,都不會出現在結果裡。
- **出錯就貼原文,不卡住。** 模型沒載入、對齊失敗,一律回傳沒標點的原文。
- **用 VoiceInk 已經有的機制,少改原作者的程式。** 語音辨識用它內建的 transcribe.cpp 和模型下載(選用的 Breeze 備用則是 whisper.cpp);補標點是我們加的 sherpa-onnx,但只在辨識完的地方加一行呼叫。不另外架伺服器、不需要開機自動啟動。
- **模型固定版本、核對 SHA256。** 兩個模型都是社群轉檔,固定在測過的 revision。
- **用實際的聽寫內容做決策。** 模型選擇、參數調整都先跑測試、留數據(見 [../investigations/2026-10-21-punctuation-model-benchmark.md](../investigations/2026-10-21-punctuation-model-benchmark.md))。

## 架構

```
按快捷鍵說話
   ↓
VoiceInk.app(全部在同一個行程)
   ├─ 開始錄音時在背景載入:TEA-ASR-1.1(transcribe.cpp)、CT-Transformer(sherpa-onnx,約 0.1 秒)
   ├─ 語音辨識:TEA-ASR-1.1 → 繁體、幾乎沒標點                      短句約 0.2 秒
   │    ├─ 每段最多 30 秒;超過 30 秒的錄音先用語音偵測(Silero)只送講話的部分,在停頓處切段
   │    ├─ 8 段以上(轉錄音檔)依長度排序、每 4 段一批送進模型(runBatch)
   │    └─ 一段鬼打牆沒辨識完 → 切兩半重跑,還不行再切,不到 4 秒就留已辨識的字
   ├─ 整理(ZhTWTranscript.clean):刪私用區字元、簡體專用字轉繁體、拿掉 TEA 零星的標點
   ├─ 補標點(ZhTWPunctuator):有中文字、原文還沒有句號問號才補      幾毫秒
   │    ├─ 超過 400 字(轉錄音檔)切成重疊的 300 字視窗逐段送,再接回
   │    ├─ 繁轉簡(只給模型看)→ CT-Transformer int8(CPU)
   │    └─ ZhTWPunctuation.merge:標點插回繁體原文
   ├─ Word Replacements(固定錯字替換)
   ├─ AI 潤稿、文字格式化:關掉
   └─ 貼到游標位置
   聽寫結束就釋放兩個模型(和原作者處理語音辨識模型的方式一樣)
```

### 元件與位置

| 元件 | 位置 | 說明 |
|---|---|---|
| VoiceInk.app | `/Applications/VoiceInk.app` | 這個 fork 的 `zhtw` 分支自己 build |
| whisper.cpp 函式庫 | `~/VoiceInk-Dependencies/` | build 用,Xcode 專案寫死這個路徑,**別刪** |
| sherpa-onnx 和補標點模型 | `~/VoiceInk-Dependencies/sherpa-onnx/` | build 用,`scripts/deps-sherpa-onnx.sh` 準備(固定 v1.13.8、核對 SHA256)。兩個 dylib(sherpa-onnx C API 3MB、ONNX Runtime 29MB)嵌入 App 的 `Contents/Frameworks/`,CT 模型(75MB)放進 `Contents/Resources/`,所以裝好的 App 不需要這個資料夾 |
| 語音辨識模型 | `~/Library/Application Support/com.prakashjoshipax.VoiceInk/TranscribeCpp/tea-asr-1.1/TEA-ASR-1.1-Q8_0.gguf` | [TEA-ASR-1.1](https://huggingface.co/JacobLinCool/TEA-ASR-1.1) 自己轉的 transcribe.cpp GGUF(2.18GB),旁邊的 `.TEA-ASR-1.1-Q8_0.gguf.sha256` 讓 App 當成已安裝 |
| 補標點模型 | App 裡的 `Contents/Resources/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/model.int8.onnx` | FunASR 的 CT-Transformer,sherpa-onnx 轉的 int8 版(75MB),跟著 App 一起裝 |
| 備用語音辨識模型(選用) | `~/Library/Application Support/com.prakashjoshipax.VoiceInk/WhisperModels/ggml-breeze-asr-25-q8_0.bin` | [Breeze-ASR-25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25) 的 whisper.cpp 轉檔(1.7GB),`scripts/setup.sh --with-breeze` 才下載 |
| 設定 | UserDefaults 網域 `com.prakashjoshipax.VoiceInk` | 由 `scripts/setup.sh configure` 寫入,或用 VoiceInk 內建的匯出、匯入從另一台帶過來 |

### 相關的 repo

| repo | 公開/私人 | 本機位置 | 放什麼 |
|---|---|---|---|
| [Jim-Chang/VoiceInk](https://github.com/Jim-Chang/VoiceInk)(`zhtw` 分支) | 公開 | `~/Documents/koding_work/VoiceInk` | 這個 fork:App 程式、安裝和設定腳本、評測工具、文件。只放程式和統計數字,不放實際聽寫內容 |
| `Jim-Chang/voiceink-zhtw-data` | 私人 | `~/Documents/koding_work/voiceink-zhtw-data` | 實驗用的實際聽寫資料:錄音、辨識結果、評測輸出、盲測題目和答案。每個實驗一個資料夾,名稱對應這裡的調查文件或計畫 |
| `Jim-Chang/voiceink-zhtw-lmstudio` | 私人 | `~/Documents/koding_work/voiceink-zhtw-lmstudio` | v1(VoiceInk + LM Studio 兩個 App)的封存,標籤 `v1-two-apps`,含當時的評測資料。不再更新 |
| [dorajim15/TEA-ASR-1.1-transcribe-cpp](https://huggingface.co/dorajim15/TEA-ASR-1.1-transcribe-cpp)(Hugging Face) | 公開 | — | 語音辨識模型 TEA-ASR-1.1 轉成 transcribe.cpp 的 GGUF(2.18GB)。App 的下載按鈕和 `setup.sh` 從這裡下載,固定 commit 和 SHA256 |

不是我們的、但會用到:[Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk)(原作者,`update.sh` 從這裡合併更新,不推東西過去);build 時下載的 sherpa-onnx 和 CT 模型([k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 的 release)、whisper.cpp;選用的 Breeze-ASR-25 模型(Hugging Face)。

### 修改了原作者的哪些檔案

| 檔案 | 改了什麼 |
|---|---|
| `VoiceInk/Features/ZhTW/ZhTWPunctuation.swift`(新增) | 合併邏輯;CT 的輸入規則(`needsPunctuation`、`modelInput`) |
| `VoiceInk/Features/ZhTW/ZhTWPunctuator.swift`(新增) | CT 補標點:包 sherpa-onnx 的 C API、開始錄音時載入、聽寫結束釋放、長文字分段送(`ZhTWPunctuation.windows`、`stitch`)、計時紀錄 |
| `VoiceInk.xcodeproj/project.pbxproj` | 連結、嵌入 sherpa-onnx 的兩個 dylib,CT 模型放進 Resources,標頭檔和函式庫的搜尋路徑 |
| `VoiceInk/Features/ZhTW/ZhTWTiming.swift`(新增) | 延遲調查的計時紀錄(只記時間和數量) |
| `VoiceInk/Infrastructure/Providers/Transcription/Whisper/WhisperPrompt.swift` | 中文提示詞的預設值改成繁體 |
| `VoiceInk/Features/ZhTW/ZhTWTranscript.swift`、`ZhTWSimplifiedOnly.swift`(新增) | 辨識完、補標點前整理:刪私用區字元、簡體專用字轉繁體、TEA 的零星標點拿掉;縮掉鬼打牆留下的結尾重複、接段補空格的判斷;對照表由 `scripts/gen-zhtw-simplified.py` 產生 |
| `TranscriptionPipeline.swift`、`AudioFileTranscriptionManager.swift`、`AudioFileTranscriptionService.swift` | 辨識完、去掉頭尾空白之後:`ZhTWTranscript.clean` 再 `ZhTWPunctuator.punctuate`;`TranscriptionPipeline` 另記辨識計時 |
| `VoiceInk/Features/Recording/Workflows/VoiceInkEngine.swift` | 開始錄音時載入 CT(`ZhTWPunctuator.preload`)、`cleanupResources` 釋放;載入 transcribe.cpp 模型的計時 |
| `TranscribeCppModelCatalog.swift`、`TranscriptionModelRegistry.swift`、`LanguageDictionary.swift` | 模型清單加 TEA-ASR-1.1(下載位置、大小、SHA256、每 30 秒切段;只給中文) |
| `VoiceInk/Features/ModelLibrary/Models/TranscriptionModel.swift` | 單一語言的模型顯示那個語言(原作者一律顯示 English) |
| `VoiceInk/Infrastructure/Providers/Transcription/TranscribeCpp/OfflineTranscribeCppService.swift` | 長音檔:超過 30 秒、VAD 設定開著時先用語音偵測切段;一段鬼打牆(`isTruncated`)不讓整個檔案失敗,切兩半重跑、還不行再切,最後留已辨識的字、縮掉結尾的重複;8 段以上依長度排序、每 4 段一批(`runBatch`);接段時英文、數字之間補空格;計時紀錄。transcribe.cpp 0.4 的 `capabilities` 要 `try` |
| `VoiceInk/Infrastructure/Providers/Transcription/TranscribeCpp/TranscribeCppSpeechSegmenter.swift`(新增) | 用 App 內建 whisper.cpp 的 Silero 語音偵測找出講話的區間,接成最多 30 秒的段,記住每段來自原始錄音的哪裡 |
| `VoiceInk.xcodeproj/project.pbxproj`、`Package.resolved` 的 `transcribe-cpp-swift` | 套件從原作者的 `Beingpax/Transcribe-cpp-swift` 0.2.0-dev.856d7c1 換成我們的 [Jim-Chang/Transcribe-cpp-swift](https://github.com/Jim-Chang/Transcribe-cpp-swift) 0.4.0(官方 v0.4.0 的 Swift 原始碼原封不動,原生程式直接下載官方 release、核對 SHA256) |
| 初始設定 6 個檔案:`OnboardingCoordinator`、`OnboardingFlowController`、`OnboardingView`、`OnboardingModelScreen`、`OnboardingTranscriptionSetupCard`、`TranscriptionModelDownloadCard` | 「模型」那一步的本機模型從 Parakeet V3 換成 TEA-ASR-1.1:型別從 FluidAudio 換成 transcribe.cpp 的模型和下載狀態,下載用模型頁同一個 `TranscribeCppModelManager`;卡片的說明、圖示、標籤跟著換 |
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
- **2026-10-22 語音辨識決定換成 TEA-ASR-1.1(transcribe.cpp)。** 使用者盲測對 Breeze 7:2、對 TEA-mini 6:2;短句辨識 1.20 → 0.21 秒、長句中位 4.8 → 2.2 秒;原生繁體、台灣用詞,英文詞保留和 Breeze 差不多。代價是聽寫時記憶體 3.7GB(Breeze 2.7GB,聽寫完都會釋放)、幾乎不加標點(照舊接 CT)。用 VoiceInk 已內建的 transcribe.cpp,不加新函式庫;Breeze 留著當備用。見 [../investigations/2026-10-22-asr-models.md](../investigations/2026-10-22-asr-models.md)、[../plan/2026-10-22-tea-asr.md](../plan/2026-10-22-tea-asr.md)。
- **2026-10-22 拆掉 Breeze2 補標點(VoiceInk Refine 那條路)。** 那是借用原作者 AI 潤稿的 VoiceInk Refine:裝了 Breeze2 就讓 App 以為 Refine 已下載,實際載入 Breeze2、換成繁中指示、輸出再合併,改了 4 個原作者的檔案。換成 CT 之後已經沒用到,留著反而讓模型清單看起來像裝了 Refine、合併上游時多 4 個檔案要處理。4 個檔案還原成原作者的版本(Refine 回到原作者的功能,要用要自己下載它的模型),`ZhTWPunctuation` 只留合併和 CT 的輸入規則,拿掉分段補標點和 `refine-bench`;這台的 Breeze2(2GB)和備用的 Breeze-ASR-25(1.7GB)也刪掉(Breeze-ASR 還是可以用 `setup.sh --with-breeze` 下載)。預設模式改名「繁中聽寫(TEA-ASR 1.1)」,名稱帶模型名,不會和 Breeze 時代的設定搞混。見 [../plan/2026-10-22-ct-punctuation.md](../plan/2026-10-22-ct-punctuation.md) 步驟 5。

- **2026-10-22 初始設定的本機模型換成 TEA-ASR-1.1。** 原作者的初始設定只能下載 Parakeet V3(不支援中文)才能繼續,裝新 Mac 時要多下載一個用不到的模型。改成「Local」直接一鍵下載 TEA;語言自動選中文、即時轉錄自動關閉(TEA 不支援),體驗步驟建立的模式就是用 TEA。考慮過的其他做法:讓「模型」那一步可以略過(要另外建一個模式,不然錄音會失敗)、在初始設定裡放完整的模型選單(要搬模型頁的介面,改動大);使用者選了只換成 TEA。也確認了另一台 Mac 不用編譯:把裝好的 App 複製過去就能用(見 README)。新 Mac 第一次聽寫多等約 10 秒(載入 10.4 秒):transcribe.cpp 把 Metal 程式以原始碼放在 App 裡(`GGML_METAL_EMBED_LIBRARY`,115 個 kernel),第一次用時由 macOS 編譯,之後用快取;第二句放開到貼上 1.36 秒。那台 16GB、當時記憶體吃緊(swap 用了 9.8GB),載入 TEA 3.1 秒、CT 5.4 秒(這台約 0.9、0.1 秒),但載入和錄音同時進行,短句才感覺得到。
- **2026-10-22 長音檔:語音偵測切段、鬼打牆的保險、長文字分段補標點。** 用「轉錄音檔」轉 1 小時 43 分的會議錄音時,某一段讓 TEA 同一句重複到產生上限,整個檔案失敗。改成:一段沒辨識完就切兩半重跑、還不行再切(到不到 4 秒為止),最後只留已辨識的字、縮掉結尾的重複,文字裡不加記號、只在紀錄寫時間位置;超過 30 秒的錄音先用 App 內建的 Silero 語音偵測只送講話的部分(跟著原作者的 VAD 設定;短句聽寫比較過沒有變好,所以不用);補標點超過 400 字時切成重疊的 300 字視窗(整段送時 3 萬字要 103 秒)。同一段會議錄音:原本失敗 → 轉完約 6 分半(語音偵測 20 秒、辨識 370 秒、補標點 5 秒),沒有卡住的段。見 [../plan/2026-10-22-long-audio-segmentation.md](../plan/2026-10-22-long-audio-segmentation.md)。
- **2026-10-22 TEA 不加詞彙表;transcribe.cpp 升到 0.4.0。** transcribe.cpp 0.3 起可以給模型一份專有名詞清單。218 段實際聽寫量測:清單詞修好 16 處,但和清單無關的地方變壞 34、變好 23,短句多 92 毫秒,事先定的標準沒過,不採用(固定聽錯的詞可以用 Word Replacements 改)。只升級到 0.4.0 則 218 段有 217 段逐字相同、速度和記憶體一樣,又多了「偵測到重複就提早停」,所以升級。原作者的套件還在 0.2,照他的做法自己做一份可安裝的副本 [Jim-Chang/Transcribe-cpp-swift](https://github.com/Jim-Chang/Transcribe-cpp-swift)(官方 Swift 原始碼原封不動,原生程式直接下載官方 release、核對 SHA256);原作者追上以後換回他的。見 [../plan/2026-10-22-tea-vocabulary.md](../plan/2026-10-22-tea-vocabulary.md)。
- **2026-10-22 轉錄音檔時批次辨識。** transcribe.cpp 0.x 同一個模型一次只能跑一個辨識,要加快只能用官方的 `runBatch` 一次送好幾段。同一段 1 小時 43 分的會議錄音(274 段)量測:照時間順序每 4 段一批只快 1.34 倍(同一批的短段要補長、陪最長那段跑);先依長度排序再分批快 1.67 倍(辨識 361 → 217 秒),尖峰記憶體多 0.54GB,269 段和一段一段跑逐字相同(差 5 字),鬼打牆的段照樣切兩半救回來;每批 8 段沒有更快、記憶體多 1.2GB。短句長短混在一起時批次沒有好處,所以只在 8 段以上(約 4 分鐘以上的錄音)用,平常的聽寫不變。見 [../plan/2026-10-23-tea-batch.md](../plan/2026-10-23-tea-batch.md)。

## 目前進度

- 目前:TEA-ASR-1.1 + CT-Transformer,在 M1 Pro 32GB 上使用中。
- 完成:延遲調查,見 [../investigations/2026-10-21-latency.md](../investigations/2026-10-21-latency.md)。
- 完成:換語音辨識模型的調查,見 [../investigations/2026-10-22-asr-models.md](../investigations/2026-10-22-asr-models.md)。
- 進行中:語音辨識換成 TEA-ASR-1.1,見 [../plan/2026-10-22-tea-asr.md](../plan/2026-10-22-tea-asr.md)。2026-10-22 起這台改用 TEA(步驟 1–4 完成,步驟 5 實際使用中);README 等文件(步驟 6)用過再改。
- 完成:補標點換成 CT-Transformer、拆掉 Breeze2 補標點,見 [../plan/2026-10-22-ct-punctuation.md](../plan/2026-10-22-ct-punctuation.md)。
- 完成:長音檔(語音偵測切段、鬼打牆的保險、長文字分段補標點),見 [../plan/2026-10-22-long-audio-segmentation.md](../plan/2026-10-22-long-audio-segmentation.md)。
- 完成:TEA 詞彙表的量測(不採用)和 transcribe.cpp 升到 0.4.0,見 [../plan/2026-10-22-tea-vocabulary.md](../plan/2026-10-22-tea-vocabulary.md)。
- 完成:轉錄音檔的批次辨識,見 [../plan/2026-10-23-tea-batch.md](../plan/2026-10-23-tea-batch.md)。
- 暫停:邊講邊出字(錄音時在面板顯示預覽,貼出去的文字不變),只查了資料、寫好實驗設計,量測沒跑。見 [../investigations/2026-10-22-streaming-preview.md](../investigations/2026-10-22-streaming-preview.md)。
- 暫停:模型改成在 App 介面下載、預設值寫進 App(省掉 `configure`)、打包成 zip 給其他 Mac 安裝(不需要 Xcode)。見 [../plan/2026-10-21-in-app-model-download.md](../plan/2026-10-21-in-app-model-download.md)。CT、TEA 都換好了,步驟 a1、b、c 大多不用做;要接著做時先改寫這份計畫。
