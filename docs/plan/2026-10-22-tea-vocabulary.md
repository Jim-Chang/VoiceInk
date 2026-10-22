# TEA-ASR 詞彙表:辨識時給模型一份專有名詞清單

2026-10-22。只寫查證結果、做法和量測計畫,App 還沒改。動手前要使用者同意(見「待使用者決定」)。

## 為什麼做

英文技術名詞拼錯、中文同音字選錯,是現在聽寫最常要手改的地方。資料集調查的結論是先不微調模型,依序做三件便宜的事:辨識時給模型一份詞彙表、用 Word Replacements 修固定的錯、收集「錄音 + 改好的文字」當自己的測試集。這份是第一件,也順便把第三件做起來(量測要用)。

## 目標

1. VoiceInk 已經有的詞彙表(「Dictionary → Vocabulary」)在用 TEA-ASR 時也送進模型,讓它認得這些詞。不新增介面、不加開關:清單是空的就和現在完全一樣。
2. 用實際的聽寫量出效果:專有名詞有沒有變對、有沒有憑空多出清單裡的詞、其他字有沒有變差、有沒有變慢。
3. 量測的副產品:一份有人工校對文字的個人測試集,以後換模型、調參數、考慮微調都能用。

## 非目標

- 微調模型。
- Word Replacements 的內容(另外做;它在辨識之後替換,和這份不衝突)。
- 依游標所在的 App 或畫面內容自動產生清單(之後再說)。
- 其他 transcribe.cpp 模型(SenseVoice、Cohere 不支援詞彙表)。

## 查證結果

### 1. 模型本身會用系統提示裡的詞

- **Qwen3-ASR 技術報告**([arXiv 2601.21337](https://arxiv.org/abs/2601.21337),2026-01-29):SFT 階段的資料包含 context biasing,模型學會把系統提示(system prompt)裡的文字當成背景知識,讓使用者得到客製化的辨識結果。報告裡沒有這項的評測數字。
- **TEA-ASR-1.1 的 model card**(revision `bda08df7`):可以傳 `context=` 熱詞(人名、術語),「和原本的 Qwen3-ASR 一樣」。沒有 TEA 自己用 context 的評測。
- **官方 `qwen-asr` 套件**(0.0.6,`_build_messages`):`context` 原封不動放進 system 訊息,再用模型的 tokenizer 編碼。TEA 的 `chat_template.jinja` 也是把 system 文字放在 `<|im_start|>system\n` 和 `<|im_end|>` 之間。
- TEA 是在 Qwen3-ASR-1.7B 的解碼器上加 LoRA 微調、用少於 10 小時的公開語料;微調時大概沒有放 context,所以「看提示用詞」的能力保留多少不知道,要量。

### 2. 我們用的 transcribe.cpp 不能傳,新版可以

- VoiceInk 鎖在 `Transcribe-cpp-swift` **0.2.0-dev.856d7c1**(原生程式是 transcribe.cpp `856d7c10`,2026-08-07)。這版 Qwen3-ASR 的 system 訊息固定是空的(程式註解「System prompt is empty」),Swift 的 `RunOptions` 沒有相關欄位。
- 上游 [handy-computer/transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) 的 **`e85b30edac87533168863283c1e595bf39bd7d15`**「generic prompting in interface (#178)」,2026-09-30:
  - C API `transcribe_run_params` 加 `vocabulary`(字串陣列,依優先順序)、`n_vocabulary`、`prompt`(背景文字)、`prefix`;`include/transcribe.h`。
  - Qwen3-ASR(`src/arch/qwen3_asr/model.cpp` 的 `encode_system_context`):詞彙**用空格接起來**,有 `prompt` 再接一個空格和 `prompt`,都放進 system 訊息。註解說他們量過空格比逗號好,比較少把整份詞彙表吐進結果。
  - `src/arch/qwen3_asr/capabilities.cpp` 對 Qwen3-ASR **一律**打開 `VOCABULARY`、`CONTEXT_PROMPT`,不看 GGUF 裡的設定,所以我們的 GGUF 不用重轉。
  - 太長時(超過解碼器的 context 視窗)從清單尾端丟詞並記 WARN;含 `<|...|>` 這類控制 token 的文字直接拒絕(`src/transcribe-prompting.cpp`)。
  - Swift:`RunOptions(vocabulary: [String], prompt: String?, prefix: String?)`,用 `model.supports(.vocabulary)` 檢查。
- 第一個包含它的 release 是 **v0.3.0**(`077110eb`,2026-10-03),最新是 **v0.4.0**(`f1dcd15858c4bbba87ca97862b4e448b2cf15b8f`,2026-10-12)。`856d7c10` 到 v0.4.0 共 55 個 commit,v0.4.0 之後 `main` 又有 14 個(到 2026-10-20)。

### 3. Swift 套件沒有新版,但上游每個 release 都附 xcframework

- [Beingpax/Transcribe-cpp-swift](https://github.com/Beingpax/Transcribe-cpp-swift)(原作者自己的鏡像)只有 `0.2.0-dev.856d7c1` 一個 tag,2026-08-09 之後沒更新。原作者 VoiceInk 到 2026-10-20(`22e5ec54`)也還鎖在這版。
- 上游打算做的官方鏡像 `handy-computer/transcribe-cpp-swift` 還不存在(404)。網路上另外兩個第三方鏡像比較舊,不用。
- 上游每個 release 都附 `TranscribeCpp.xcframework.zip`:v0.4.0 是 10,205,009 bytes,SHA256 `3da069d288b79475adb257e4425c7c00f7026a90d0ef06af2214b7355dcd0453`(GitHub 提供的 digest,就是 SwiftPM `binaryTarget` 要的 checksum)。和 `856d7c10` 用同一支 `scripts/ci/build_xcframework.sh`(動態 framework、macOS arm64 內嵌 Metal),所以**不用自己編**。Swift 原始碼在同一個 tag 的 `bindings/swift/Sources/TranscribeCpp`(MIT)。

### 4. 換到 v0.4.0 還會改到什麼

| 項目 | 結論 |
|---|---|
| TEA 的 GGUF 能不能用 | 應該可以,不用重轉。`scripts/convert-qwen3_asr.py` 在 `856d7c10` 到 v0.4.0 之間完全沒改;`scripts/lib/gguf_common.py` 只多寫「沒宣告的 capability 一律 false」(舊檔沒有這些 key 時,載入程式用模型家族的預設值);Qwen3-ASR 的載入程式沒有新的必要欄位。我們的 GGUF 有 `tokenizer.ggml.pre = qwen2` 和 merges(現在的「language Chinese」提示就是靠它編碼)。步驟 3 實際載入、跑 91 段確認 |
| Swift API | VoiceInk 只有 `OfflineTranscribeCppService.swift` 用到 transcribe.cpp。唯一要改的是 `capabilities` 變成會丟錯(`throws`),第 119 行要加 `try`。`ModelOptions.gpuDevice` 換成 `device`(VoiceInk 沒用)。新的錯誤 `.outputRepetition`、`.unsupportedRole`、`.inputTooShort`,和 `error.isTruncated`、`error.partial` |
| #165 產生上限 `ed3468f3`(2026-09-21) | 每段最多產生的 token 改成 `max(256, 秒數 × 12)`:30 秒的段 360 個,21 秒以下照舊 256。單次可輸入的長度(`maxAudioMs`,約 87 分鐘)算法沒變,所以 `effectiveMaximumChunkSeconds` 還是取 30。**我們每 30 秒切一段的做法不用改**,只是長的段多一點餘裕;長音檔計畫的語音偵測切段也是 ≤ 30 秒 |
| #166 鬼打牆保險 `db096815`(2026-09-26) | 同一段話重複夠多次就提早停(例如 8–27 個 token 的片段重複 8 次;片段越短要重複越多次,1 個 token 要 64 次,所以「對對對」不會被切),丟出 `.outputRepetition`,`partial` 是已經刪掉重複的文字。VoiceInk 現在的迴圈遇到錯誤還是整個檔案失敗,只是失敗得比較快。[長音檔計畫](2026-10-22-long-audio-segmentation.md)的步驟 1 要改成兩種錯誤都接(`isTruncated`),它自己的 `collapseTrailingRepetition` 變成第二層保險 |
| ggml 升級(0.20.2 → 0.25 → 0.26.0) | 數值和速度可能有小差異,所以要先量「只升級、不加詞彙表」(下面的 B 組)。更新後每台 Mac 第一次聽寫會再編譯一次 Metal(約 10 秒,只有一次) |
| #150 `9aa6599f` | 每次辨識完釋放暫存記憶體,可能稍微省一點 |
| VAD #201 `c63b18e2`(v0.4.0) | transcribe.cpp 自己也有 Silero 語音偵測了,長音檔計畫步驟 3 多一個選項(不在這份的範圍) |
| 還沒 release 的(只在 `main`) | #195 `9f102d1a` 用 mmap 載入權重、#220 `ef1e23e7` 不再複製 gate/up 權重:兩個都會讓 TEA 少用記憶體(現在聽寫時 3.7GB)。等下一版 release 再評估 |

### 5. VoiceInk 的詞彙表在哪、現在給誰用

- 資料:SwiftData 的 `VocabularyWord`(`word`、`dateAdded`),存在 `dictionary.store`。介面在「Dictionary → Vocabulary」(`VocabularyView.swift`)和快速新增面板。「Export Settings」會帶走(`BackupTypes.swift` 的 `vocabularyWords`),所以會跟著設定到另一台 Mac。
- 現在只有兩個地方用:AI 潤稿的提示(`CustomVocabularyService`,「Important Vocabulary: …」)和雲端辨識服務(`CloudTranscriptionService.getCustomDictionaryTerms`:去頭尾空白、不分大小寫去重、依字母排序)。
- **本機 Whisper 沒有用到詞彙表**(研究報告說「當成 Whisper 提示」不對)。Whisper 的提示是每個語言一段固定文字(`WhisperPrompt`),非 Whisper 的模型連這段都拿不到(`TranscriptionRequestContext.scoped` 把 `prompt` 設成 nil)。
- 這台 Mac 現在詞彙表 0 筆、Word Replacements 0 筆。清單要從頭建(步驟 1)。
- 注意:原作者的 Auto Learn 會自動往詞彙表加詞。我們的設定把它關掉了;如果打開,自動加的詞也會影響辨識。

### 6. TEA 的私用區 token:詞彙用一般繁體文字就好,不用也不能先切 token

TEA 的繁體是「換 tokenizer 的顯示文字」做出來的(model card 說的 tokenizer-first):Qwen 原本的簡體 token 改顯示成繁體(和台灣用詞),和既有 token 撞名的就在後面加一個私用區字元(U+E000–U+F8FF)區分。拿 TEA 的 `tokenizer.json`(和 `bda08df7` 的 git blob 相同)檢查:

- 151,643 個 token 裡 1,161 個尾端有私用區字元,都是一到四個字(例如「數」「時間」「用戶」「數據」各有一個這種版本)。常用字的輸出常是這些版本(評測 91 段的 TEA 結果裡有 725 個私用區字元,App 的 `ZhTWTranscript.clean` 會刪掉)。
- 把一般文字編碼成 token 時(transcribe.cpp 和 Hugging Face 都是:qwen2 的正規表示式先切、再照 merges 合併),私用區字元不算文字,會被切成獨立的一塊,所以**任何文字都編不出這些 token**。也就是說沒辦法、也不需要「先切成模型輸出用的 token」;硬加私用區字元只會多出幾個無意義的位元組 token。
- 一般繁體會變成 Qwen 原本就有的繁體 token,和官方 `qwen-asr` 用 TEA 的 tokenizer 處理 `context=` 的結果一樣。例如(用 `tokenizer.json` 的 vocab 和 merges 模擬,GGUF 就是從這份轉的):

| 詞 | token |
|---|---|
| 部署 | `部署` |
| 資料庫 | `資料` `庫` |
| 伺服器 | `伺服` `器` |
| 程式碼 | `程式` `碼` |
| Claude Code | ` Claude` ` Code` |
| Kubernetes、PostgreSQL、SwiftUI | 各一個 token |
| transcribe.cpp | ` trans` `cribe` `.cpp` |
| 数据(簡體) | 4 個位元組碎片 |

- **詞彙不能轉成簡體**(和送給 CT 補標點不一樣):TEA 改寫了 merges,被改成繁體的簡體字已經編不成原本的 token,只剩位元組碎片。
- 中文詞的風險:模型輸出時「想的」是原本的簡體 token,提示裡的卻是 Qwen 原本的繁體 token,中文詞的效果可能比英文詞弱。英文詞沒有這個問題。要量。
- transcribe.cpp 編碼前不做 Unicode NFC 正規化(Hugging Face 會),所以我們送之前自己做 NFC。

## 設計

### 換套件:transcribe.cpp v0.4.0

| | 自己的鏡像 repo(建議) | fork 裡放本機套件 | 等原作者更新 |
|---|---|---|---|
| 做法 | 新增公開 repo(例如 `Jim-Chang/Transcribe-cpp-swift`),照 Beingpax 的格式放 v0.4.0 的 Swift 原始碼和 `Package.swift`(`binaryTarget` 指向上游 release 的 xcframework、checksum 用上面的 SHA256),打 tag `0.4.0` | 在 fork 新增 `Packages/TranscribeCpp/`,內容同左 | 不動 |
| VoiceInk 要改 | `project.pbxproj` 的套件網址和版本(944–947 行)、`Package.resolved`(228–234 行) | `project.pbxproj` 從遠端套件改成本機套件(改的行比較多)、`Package.resolved` 拿掉一筆 | 無 |
| 合併上游 | 原作者也更新時,這幾行會衝突,取較新的那個;原作者追上 v0.4.0 以後可以換回他的 | 同左,衝突範圍大一點 | 無 |
| 缺點 | 多一個公開 repo(要使用者建或同意我建) | fork 裡多一份上游的 Swift 程式(約 1,000 行) | 不知道要等多久 |

建議自己的鏡像:VoiceInk 這邊只改兩個檔案的幾行,格式和原作者的一樣,以後換回去也簡單。

### 詞彙表送進 TEA

新檔 `VoiceInk/Features/ZhTW/ZhTWVocabulary.swift`(約 30 行):

- `refresh(from: ModelContext)`(在主執行緒呼叫):讀 `VocabularyWord`,去頭尾空白、NFC、不分大小寫去重、依 `word` 排序(固定順序,結果才可重現),最多 N 個(先定 100,依量測調);存成一份快照(加鎖)。整理規則寫成純函式,`scripts/test-punctuation.sh` 加案例。
- `current`:辨識時讀快照。
- 不轉簡體、不加私用區字元(見查證結果 6)。紀錄只寫數量,不寫詞。

改原作者的檔案(都是一行,前三個本來就有我們的 `ZhTWTranscript.clean` 呼叫,這行加在辨識**之前**):

| 檔案 | 改什麼 |
|---|---|
| `TranscriptionPipeline.swift`(約 103 行,`if let session` 之前) | `ZhTWVocabulary.refresh(from: modelContext)`(聽寫) |
| `AudioFileTranscriptionManager.swift`(約 174 行之前) | 同上(「Transcribe Audio」轉錄音檔) |
| `AudioFileTranscriptionService.swift`(約 72 行之前) | 同上(紀錄裡的「重新辨識」) |
| `OfflineTranscribeCppService.swift` 111–116 行 `RunOptions(...)` | 加 `vocabulary: nativeModel.supports(.vocabulary) ? ZhTWVocabulary.current : []` |
| 同一個檔案 119 行 | `try nativeModel.capabilities.maxAudioMs`(換套件要的) |

- 每一段(30 秒)用同一份詞彙。`supports(.vocabulary)` 在我們的模型清單裡只有 TEA 是 true。
- 詞彙表空的時候 `vocabulary` 是空陣列,送進模型的提示和現在逐 token 相同。
- 選用:`ZhTWTiming` 的 `asr` 那行加 `vocab=<個數>`,`timing_report.py` 才看得出延遲和清單長度的關係。

## 風險

- **憑空多出清單裡的詞**:模型可能在沒講到的地方插入清單的詞,或把整份清單吐出來(短句、靜音、雜音最容易)。上游文件說 Qwen3-ASR-0.6B 比 1.7B 常這樣;TEA 是 1.7B 微調過的,不知道。這是最主要的風險,量測的「精確率」和「沒講到詞的錄音」就是在抓這個。
- **改錯一般的字**:發音相近的普通詞被換成清單裡的詞。看「沒有清單詞的錄音」的錯誤率有沒有變差。
- **中文詞效果較弱**(見查證結果 6)。
- **換套件的風險**:數值變化讓原本對的字變了、GGUF 載不起來、新的錯誤路徑、更新後第一次聽寫多等 10 秒、自己維護鏡像、合併上游時 `project.pbxproj` 衝突。
- **變慢**:提示變長,每段多算幾十到上百個 token。
- **隱私**:詞彙表是個人資料(專案名、人名)。不寫進公開文件和紀錄;實驗用的清單只放私人 repo。

## 量測計畫

照之前評測的慣例(見 [`../development.md`](../development.md)):先 commit 這份設計,實際資料和結果只放私人 repo `voiceink-zhtw-data` 的新資料夾 `2026-10-22-tea-vocabulary/`,公開文件只寫統計。**跑之前先問使用者**:不能在使用者聽寫時跑,也不能和其他對話的實驗同時跑(GPU 互搶,時間會不準)。

### 資料

- 錄音:私人 repo 的 `2026-10-21-latency/recordings/`(91 段,共 16 分鐘,中位 3.9 秒;TEA 的結果裡 28 段有英文詞,共 104 個)。再加上 2026-10-21 之後用 TEA 聽寫的錄音裡、有英文或技術名詞的 30–50 段。VoiceInk 的錄音只留 3 天(這台現在有 212 段,最早的 2026-10-24 13:10 起會被刪),要先複製到私人 repo。
- 另外放幾段沒講話或不到 1 秒的錄音,專門抓「憑空吐詞」。
- **參考答案(人工校對)**:每段先填 TEA 現在的結果,做一個頁面(錄音嵌在頁面裡,和之前的盲測頁面一樣)讓使用者邊聽邊改。80–100 段大約 20–30 分鐘。這就是資料集調查建議的個人測試集,以後也能用。
- **詞彙表**:從校對時改到的專有名詞(TEA 錯的)、使用者常講的詞(專案、工具、套件名)整理成清單,使用者確認後**固定下來、先 commit,才跑加詞彙表的那組**,避免看了結果再改清單。另外做一份「大清單」:固定清單加約 70 個使用者不常講的技術名詞當干擾,模擬清單變長以後的情況。

### 比較的組

全部用同一個 Q8_0 GGUF(SHA256 `2e4aeb45…98d0`)、每 30 秒切段、語言中文,工具是 `scripts/bench/tc_bench.c`(加 `--vocabulary-file`:一行一個詞)。原生程式用 App 實際會用的那份:A 組用 Beingpax 的 856d7c1 xcframework(在 `.local-build/SourcePackages/artifacts/`),B、C 組用上游 v0.4.0 的 xcframework(要下載 `TranscribeCpp.xcframework.zip`,10.2MB,來源 handy-computer/transcribe.cpp 的 GitHub release,核對 SHA256)。

| 組 | transcribe.cpp | 詞彙表 | 看什麼 |
|---|---|---|---|
| A | 856d7c1(現在) | 無 | 基準 |
| B | v0.4.0 | 無 | 只升級的影響 |
| C | v0.4.0 | 固定清單 | 詞彙表的效果(和 B 比) |
| C2 | v0.4.0 | 大清單 | 清單變長會不會亂插詞、變慢 |

每組跑兩輪,時間取較快的一次(和之前的評測一樣)。記憶體用 `/usr/bin/time -l` 看 A、B 有沒有差。

### 怎麼算分

- 文字先用 App 同一份 `ZhTWTranscript.clean` 整理(`scripts/bench/punct-ct.sh` 的工具,刪私用區字元、簡體專用字轉繁體),再去掉標點、英文轉小寫、全形轉半形。**不轉成簡體再比**(TEA 官方評測會這樣做,但「裡/里」這種差別正是使用者在意的,要算錯)。
- **混合錯誤率(MER)**:中文一個字算一個單位、英文一個詞算一個單位,(替換 + 刪除 + 插入)/ 參考答案的單位數。
- **專有名詞**(只算清單裡的詞;英文不分大小寫、要整個詞相符,中文要完全相同):
  - 召回率:參考答案裡出現的清單詞,辨識結果也有的比例。
  - 精確率:辨識結果裡的清單詞,參考答案也有的比例。
  - 插入:參考答案沒有、辨識結果卻有的清單詞次數;一段裡插入 3 個以上的算「整份吐出來」。
  - 逐詞列出「B 錯、C 對」和「B 對、C 錯」。
- 沒有清單詞的錄音另外算 MER 和插入次數。
- 結果另外分「建清單時看過的錄音」和「清單固定後才錄的錄音」兩群報告(後者是比較誠實的數字;如果固定清單後使用者照常用一兩天,就收那幾天有技術名詞的錄音再校對一批)。

### 假設和通過標準(先寫好,看結果前不改)

1. **只升級不改結果**:B 對 A 至少 90% 的錄音逐字相同,整體 MER 差在 0.5 個百分點以內,沒有新的失敗。不成立就先查原因,不跑 C。
2. **詞彙表有用**:C 的專有名詞召回率比 B 高至少 10 個百分點(或 B 錯的清單詞至少改對三成)。
3. **不亂插詞**:C 在沒有清單詞的錄音和靜音錄音裡,插入的清單詞總共不超過 1 次、沒有「整份吐出來」;C 的精確率不比 B 低超過 2 個百分點。C2 也要符合。
4. **其他字不變差**:沒有清單詞的錄音,C 的 MER 不比 B 高超過 0.5 個百分點。
5. **不明顯變慢**:5 秒以下的短句,C 的辨識時間中位數比 B 多不到 50 毫秒。

1–5 都成立才建議採用。之後從 B、C 結果不同的錄音挑 10–15 段做使用者盲測(要聽錄音,A/B 位置平衡),最後由使用者決定。只有 3 不成立時,追加試:清單縮短、改用 `prompt` 放一句說明(例如「以下是程式開發相關的詞:…」),標成追加。

## 步驟

每一步單獨 commit,驗證後再做下一步。

1. **收資料**(使用者同意後):把 2026-10-21 之後的 TEA 錄音複製到私人 repo(趕在自動刪除前);挑錄音;做校對頁面,使用者校對;整理詞彙表,使用者確認後固定。
2. **工具**:`tc_bench.c` 加 `--vocabulary-file`,分別連結兩份 xcframework;新增 `scripts/bench/tea_vocab_score.py`(算 MER、召回率、精確率、插入,只讀參數給的路徑,不含資料)。
3. **跑 A、B**(先問使用者):確認 v0.4.0 載得起來、只升級的影響(假設 1)。
4. **跑 C、C2**:假設 2–5;寫結果(公開文件只寫統計,實際內容放私人 repo)。
5. **使用者盲測**。
6. **改 App**(使用者決定採用後):換套件(依使用者選的做法)、`ZhTWVocabulary`、五行修改、測試案例;build、裝到這台;用紀錄裡的「重新辨識」核對幾段和量測結果相同。
7. **文件**:架構文件(架構圖、改了哪些檔案、決策紀錄)、`development.md`(合併上游時注意套件那兩個檔案)、README(詞彙表的用法);長音檔計畫補上 `.outputRepetition`。

## 待使用者決定

1. **要不要做量測**:會花使用者 20–30 分鐘校對文字,和大約 15 分鐘不能聽寫的時間(跑 A–C2)。
2. **要不要先複製錄音**:2026-10-21 之後的錄音 2026-10-24 起會被自動刪掉,不管做不做量測,先複製到私人 repo 都比較保險。
3. **套件放哪**:自己的鏡像 repo(建議)、fork 裡的本機套件、或等原作者。
4. **詞彙表的內容**:我先從校對結果整理一份草稿,使用者增刪。

## 紀錄

- 2026-10-22 寫 plan。查證:Qwen3-ASR 技術報告、TEA model card(`bda08df7`)、`qwen-asr` 0.0.6 原始碼、transcribe.cpp `856d7c10`..`db678a03`(2026-10-20 的 `main`)、Beingpax/Transcribe-cpp-swift、VoiceInk 的詞彙表程式碼;TEA tokenizer 的檢查用 Python 照 merges 模擬編碼。沒有跑任何辨識。
