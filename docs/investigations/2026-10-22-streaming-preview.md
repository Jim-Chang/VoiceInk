# 邊講邊出字:錄音時在面板上先顯示辨識中的文字

2026-10-22 開始。這份先寫好「為什麼做」、「查到的」和「實驗設計」再跑量測,結果依日期往下加;看完結果才加的測試標「追加」。含實際聽寫內容的原始輸出放在私人 repo `voiceink-zhtw-data` 的 `2026-10-22-streaming-preview/`,這裡只放統計數字。只調查,不改 App 的程式。

## 為什麼做

- 現在講話時錄音面板只有音量條,放開快捷鍵後約 0.5–1.1 秒(短句)才一次貼上。使用者想要像即時字幕一樣,講的時候就看到字。
- **貼出去的文字照舊**:錄音結束後整段用 TEA-ASR-1.1 辨識、`ZhTWTranscript.clean` 整理、CT 補標點,和現在完全一樣。講話時顯示的只是「預覽」,只出現在 VoiceInk 自己的錄音面板,不打進輸入框。
- 架構文件把「邊講邊把字打進輸入框」列為非目標;這次只看「面板上的預覽」做不做得到、代價多少。

要回答四個問題:

1. VoiceInk 現在的即時轉錄怎麼運作?transcribe.cpp(TEA)要接上去要改哪些檔案?
2. Qwen3-ASR(TEA-ASR-1.1 的基底)本身能不能串流?transcribe.cpp 有沒有做?
3. 不能真的串流的話,錄音中每隔約 1 秒把錄音重新辨識一次(「假串流」),速度、GPU、記憶體的代價多少?會不會讓放開快捷鍵後等更久?
4. 換個方式:預覽另外用一個小的串流模型(sherpa-onnx)或 macOS 內建的語音辨識,最後的文字仍由 TEA 產生,行不行?

## 事先查到的

### VoiceInk 現在的即時轉錄

- **開關**:模式設定裡的「Real-time」只在模型 `supportsStreaming` 為真時出現(`TranscriptionRealtimeSupport.isAvailable`)。transcribe.cpp 的模型(`TranscribeCppModel`)沒有這個屬性,一律是假,所以 TEA 現在沒有這個選項。設定頁另有「Live Text Display」(預設開)控制面板要不要顯示。
- **流程**:
  1. 開始錄音時,`VoiceInkEngine` 看模式有沒有開即時轉錄;有的話由 `TranscriptionServiceRegistry.createSession` 建 `StreamingTranscriptionSession` + `StreamingTranscriptionService`,依模型挑一個 provider(`StreamingTranscriptionService.createProvider`,現在只有 FluidAudio 和雲端)。
  2. 錄音器把每一小段聲音(16 位元、16kHz、單聲道)交給 provider;provider 還沒準備好時,`RealtimeAudioChunkGate` 先存著(最多 2,048 段)。錄音檔照樣寫到硬碟。
  3. provider 送出 `.partial`(暫定文字)、`.committed`(定稿)事件 → `VoiceInkEngine.partialTranscript` → 錄音面板的 `LiveTranscriptView`(`MiniRecorderView`、`NotchRecorderView` 都有;12pt 字、高 56pt、自動捲到最後)。
  4. 放開快捷鍵:`StreamingTranscriptionSession.transcribe` 問 provider 的 `stopDisposition`。回答 `.useBatchFallback` 時,改用錄音檔走一般的辨識(就是現在 TEA 的流程)。
- **現成的「假串流」範例**:`FluidAudioStreamingProvider`(Parakeet TDT)每隔 1 秒把「還沒定稿的錄音」重新辨識一次,用字的時間戳記和 `WordAgreementEngine`(同一個字連續 3 次一樣才定稿)決定哪些字固定下來,定稿後把那段錄音丟掉;定稿的段落太少時,放開快捷鍵就改走整段辨識。
- **所以面板不用改**:只要寫一個 transcribe.cpp 的 provider,錄音中送 `.partial`,結束時一律回答 `.useBatchFallback`,貼出去的文字就和現在一樣。

### Qwen3-ASR 和 transcribe.cpp 的串流

- **Qwen3-ASR 官方的「串流」是假串流,而且只有 vLLM 版**([QwenLM/Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) README;`qwen_asr/inference/qwen3_asr.py`):每收到一段(預設 2 秒)就把到目前為止的全部錄音重新送進模型,同時把上一次的結果去掉最後 5 個 token 當成開頭提示,讓模型從那裡接著寫(前幾段不給提示)。不能批次、沒有時間戳記。transformers 版直接報錯。
- 技術報告([arXiv 2601.21337](https://arxiv.org/html/2601.21337)):音訊編碼器用 1–8 秒的動態注意力視窗;串流(2 秒一段)的中文錯誤率比整段辨識略差(FLEURS 中文,1.7B:2.41 → 2.84)。沒有公布串流的延遲。
- **TEA-ASR-1.1** 的 [model card](https://huggingface.co/JacobLinCool/TEA-ASR-1.1) 沒提到串流;它是 Qwen3-ASR 相容的 LoRA 微調,理論上能用官方的假串流,但沒人測過。
- **transcribe.cpp 有串流 API,但 Qwen3-ASR 不支援**(VoiceInk 用的 `856d7c1` 和 2026-10-20 的 main `db678a0` 都一樣,[handy-computer/transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)):
  - `transcribe_stream_begin/feed/finalize`,文字分「已定稿」和「暫定」,定稿規則可以選「連續 3 次一樣才定稿」。
  - Qwen3-ASR 的串流函式都沒實作(`src/arch/qwen3_asr/model.cpp`),文件 `docs/models/qwen3-asr.md` 把「real-time streaming」列為不支援。能串流的是 Parakeet / Nemotron、Moonshine、Voxtral realtime;其中能講中文的只有 nemotron-3.5(簡體,FLEURS zh-CN 錯誤率 18.87%)。
  - 作者在 issue [#99](https://github.com/handy-computer/transcribe.cpp/issues/99) 說:不能串流的模型要做假串流,由使用函式庫的程式自己做。
- **沒有逐字回呼,而且辨識跑到一半停不下來**:只有記錄(log)和中止(abort)兩種回呼。中止回呼照說明是每個 token 檢查一次,但 Qwen3-ASR 只在開始前檢查一次(原始碼註解:Qwen3-ASR 一次跑完,這是唯一的檢查點)。所以**正在跑的那次辨識不能取消**,放開快捷鍵時如果剛好在跑,要等它跑完才能開始最後那次辨識。
- **Swift 包裝**([Beingpax/Transcribe-cpp-swift](https://github.com/Beingpax/Transcribe-cpp-swift) `0.2.0-dev.856d7c1`,原樣複製上游的 `bindings/swift`):有 `Session.stream()`,但 Qwen3-ASR 會丟 `.notImplemented`;`CancellationToken` 接到中止回呼(對 Qwen3-ASR 一樣停不了正在跑的那次)。
- **這版 transcribe.cpp 不能給 Qwen3-ASR 開頭提示**(TEA 計畫也記了:不支援 context),所以官方「把上次結果當開頭」的省時方法用不到,每次都要從頭產生整段文字:錄音越長,每次越久。要嘛限制每次辨識的長度(切段),要嘛自己改 transcribe.cpp。

結論:TEA 要邊講邊出字,只能在 App 裡自己做假串流:錄音中定時把錄音重新辨識一次。

### 預覽改用別的模型

- **sherpa-onnx 的串流中文模型**:App 為了 CT 補標點已經內建 sherpa-onnx 1.13.8 的函式庫,裡面就有串流辨識的 C API(`SherpaOnnxCreateOnlineRecognizer`),不用加新函式庫,只要多一個模型。

  | 模型 | int8 大小 | 訓練資料 | 公布的錯誤率 |
  |---|---|---|---|
  | streaming-zipformer-zh-int8-2025-06-30(約 1.6 億參數) | 壓縮檔 126MB | multi_zh-hans | AISHELL-1 1.91%、WenetSpeech 8.54% / 7.91% |
  | streaming-zipformer-ctc-zh-int8-2025-06-30 | 122MB | multi_zh-hans | WenetSpeech 10.62% |
  | streaming-zipformer-multi-zh-hans-2023-12-12 | 59MB | 約 1.4 萬小時 | — |
  | streaming-zipformer-small-ctc-zh-int8-2025-04-01 | 20MB | — | — |
  | streaming bilingual zh-en(zipformer / paraformer) | 約 100–200MB | 「數萬小時」內部資料 | — |
  | X-ASR zh-en(2026-06) | 約 127MB | 約 100 萬小時 | WenetSpeech 6.97% / 8.40%(960 毫秒一段) |

  來源:sherpa-onnx 的 asr-models release 和文件、[icefall multi_zh-hans 結果](https://github.com/k2-fsa/icefall/blob/master/egs/multi_zh-hans/ASR/RESULTS.md)、[X-ASR](https://github.com/Gilgamesh-J/X-ASR)。**全部是中國大陸的資料、輸出簡體**,沒找到用台灣華語訓練、或直接輸出繁體的串流模型;要先轉繁體(而且是大陸用詞)。sherpa-onnx 的 Qwen3-ASR 只有離線版(串流的需求 [#3865](https://github.com/k2-fsa/sherpa-onnx/issues/3865) 還開著)。這次不量:要另外下載模型,台灣華語的準確度只能自己測。
- **macOS 26 內建的 SpeechTranscriber(SpeechAnalyzer)**:Apple 的本機辨識,有串流(volatile results:中途的猜測會一直更新)。這台(macOS 26.7)查 `SpeechTranscriber.supportedLocales` 有 zh-TW,而且 zh-TW 已經安裝。VoiceInk 本來就用它做「Apple」那個模型(`NativeAppleTranscriptionService`,目前只做整段辨識)。辨識在系統行程裡跑,不佔 App 的記憶體,可能用 Neural Engine 而不是 GPU(要量)。中文準確度 Apple 沒公布,唯一找到的數據是會議錄音字錯率約 34%(見 [2026-10-21-dictation-app-and-asr.md](2026-10-21-dictation-app-and-asr.md))。

## 做法

| | A. TEA 假串流 | B. sherpa-onnx 串流模型只做預覽 | C. macOS SpeechTranscriber 只做預覽 |
|---|---|---|---|
| 預覽的字 | 和最後貼出去的同一個模型,差異應該小 | 另一個模型,簡體轉繁、大陸用詞 | 另一個模型,繁體(要確認) |
| 速度、GPU | 每次重跑 TEA(GPU);和最後那次辨識搶 GPU,正在跑的停不下來 | CPU,和 TEA 不搶 GPU | 系統行程,可能不用 GPU |
| 記憶體 | 同一個模型,應該不增加 | 多 100–200MB,App 多 120MB 左右 | App 不增加,系統行程另計 |
| 要改的 | 新 provider + 原作者 4–5 個檔案(見結果) | 新 provider + 模型下載或內建 | 新 provider(可以參考原作者的 SpeechAnalyzer 程式) |

## 實驗設計

### 資料

延遲調查的 91 段實際聽寫錄音(私人 repo `2026-10-21-latency/recordings/`)。

- **重新辨識一次要多久**(prefix):30 秒以上的 10 段,各取前 2、5、10、20、30 秒;60 秒以上的 2 段另取前 60 秒。每個長度跑 3 次取中位數。
- **模擬一次聽寫**(loop):13 段,依長度平均挑:30 秒以上 5 段、10–20 秒 4 段、3–5 秒 4 段,合計 329 秒。

### 跑法

- 用 VoiceInk 鎖定的同一版 transcribe.cpp(`856d7c1`,Metal)和 App 下載的同一個 TEA-ASR-1.1 Q8_0 GGUF,語言 `zh`。程式在 `scripts/bench/`:`tc_stream_sim.c`(prefix 和 loop 兩種模式)、`apple_stream_sim.swift`、`stream_preview.py`(挑錄音、記 GPU 使用率、整理結果)、`stream_preview_run.sh`(依序跑全部)。
- **loop 照真實時間跑**(錄音多長就跑多久),模擬 App 裡的 provider:
  - 第 1 秒開始(App 開始錄音時載入模型約 1 秒),辨識「目前這一段」:從上次切點到現在的錄音。辨識完等 1 秒再跑下一次(和 `FluidAudioStreamingProvider` 一樣)。
  - 三種做法:**w0**(不顯示,就是現在的 App,當對照組)、**w30**(目前這一段超過 30 秒就在最後 3 秒找最安靜的地方切,和 App 整段辨識時的切段規則相同)、**w10**(每 10 秒切)。切的時候把切點前那段再辨識一次當成定稿,面板顯示「各段定稿 + 目前這一段最新的結果」。
  - 錄音結束時,如果有一次正在跑就等它跑完(停不下來),再照 App 現在的做法把整段辨識一次(每 30 秒切一段):這就是會貼出去的文字。**結束後的等待** = 這次辨識完成的時間 − 錄音長度。
- **macOS SpeechTranscriber**:每 100 毫秒餵一小段(zh-TW、volatile results),照真實時間跑同樣 13 段,記每次更新的時間和文字。**和 TEA(w0,照真實時間)同時跑、每段對齊開始**,看 Apple 在旁邊跑會不會拖慢最後那次 TEA 辨識。
- **GPU**:每 0.5 秒記 `ioreg` 的 GPU「Device Utilization %」(不需要 sudo),開始前先記 20 秒閒置時的。**電池**沒辦法直接量(`powermetrics` 要 sudo),用「講話期間 GPU 忙碌的比例」代替。
- **記憶體**:每輪記 `/usr/bin/time -l` 的 peak memory footprint;Apple 那輪另外每 2 秒記名稱含 speech 的系統行程記憶體。
- 跑的時候不聽寫、不跑其他評測、接電源。

### 指標

1. **重新辨識一次的時間**:每個長度的中位數和最大值,編碼和產生文字各佔多少。
2. **loop 每種做法**:
   - 開始講後多久出現第一個字;面板多久更新一次;顯示的字落後講話多少秒。
   - 每次辨識的時間;講話期間 GPU 忙碌的比例和 GPU 使用率。
   - 已經顯示的字被改掉的頻率和字數(會不會一直跳)。
   - **結束後的等待**,和對照組比多等多少。
   - 最後一次預覽和貼出去的文字差多少(去標點的字元差異率)。
   - 有沒有顯示,貼出去的文字是不是逐字相同(應該要相同)。
3. **macOS SpeechTranscriber**:同上的時間指標;和 TEA 最後結果差多少;簡體字數、標點;TEA 最後那次辨識有沒有變慢。

### 事先的假設

1. 重新辨識一次的時間大致和長度成正比(主要花在逐字產生):2 秒約 0.15 秒、5 秒約 0.25、10 秒約 0.45、20 秒約 0.9、30 秒約 1.4、60 秒約 3 秒。所以每次都重跑整段只撐得了前 10–20 秒,一定要切段。
2. w10 每次 0.5 秒內,約 1.5 秒更新一次,講話時 GPU 約 25–30% 時間在忙;w30 每次最多約 1.5 秒,約 2.5 秒更新一次,約一半時間在忙。
3. **使用者最會感覺到的代價是結束後多等**:正在跑的那次停不下來,平均多等半次:w10 約 0.2 秒(最多 0.5)、w30 約 0.5 秒(最多 1.5)。
4. 預覽最後幾個字常常被改;最後一次預覽和貼出去的文字差 5–10%。
5. macOS SpeechTranscriber 更新更快(1 秒內)、幾乎不用 GPU、不拖慢 TEA、輸出繁體,但和 TEA 的結果差 20–30%。

### 判斷標準(事先訂)

建議做 **A(TEA 假串流)** 要同時符合(以 w10、w30 較好的一個):

- 結束後比現在多等:中位數 ≤ 0.15 秒、最多 ≤ 0.5 秒。現在短句總共 0.5–1.1 秒,換 TEA 就是為了快。
- 面板更新間隔中位數 ≤ 2 秒,顯示落後中位數 ≤ 2.5 秒(才像即時)。
- 有沒有顯示,貼出去的文字逐字相同(13 段全部)。
- 記憶體多 ≤ 0.3GB。
- 講話期間 GPU 忙碌 ≤ 50%。

建議做 **C(macOS SpeechTranscriber 預覽)** 要同時符合:

- 面板更新間隔中位數 ≤ 1.5 秒。
- TEA 最後那次辨識的時間,和沒有 Apple 在旁邊跑時比,中位數慢不超過 0.1 秒。
- 輸出繁體(簡體專用字 ≈ 0)。
- 和 TEA 最後結果的字元差異中位數 ≤ 25%(差太多的話,預覽和貼出去的字對不上,反而困擾)。

都不符合就建議不做,維持非目標。這次不改 App 的程式;做不做由使用者看完結果決定。

## 暫停(2026-10-22)

使用者看完「事先查到的」之後決定先停在這裡,**量測沒有跑**,上面的假設都沒驗證。到這裡知道的:

- 面板不用改;TEA 只能在 App 裡自己做假串流(定時重新辨識),transcribe.cpp 和 Qwen3-ASR 都沒有現成的串流。
- 最可能的代價是放開快捷鍵後多等:正在跑的那次辨識停不下來。
- macOS 內建的 SpeechTranscriber(zh-TW)可以只拿來顯示預覽,不佔 App 記憶體,準確度較差。

要接著做時:量測工具都在 `scripts/bench/`(`stream_preview_run.sh` 依序跑全部,約 30 分鐘),先問使用者能不能跑,再照上面的設計和判斷標準。
