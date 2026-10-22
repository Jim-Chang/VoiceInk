# TEA-ASR 詞彙表:辨識時給模型一份專有名詞清單

2026-10-22。只寫查證結果、做法和量測計畫,App 還沒改。動手前要使用者同意(見「待使用者決定」)。

## 為什麼做

英文技術名詞拼錯、中文同音字選錯,是現在聽寫最常要手改的地方。資料集調查的結論是先不微調模型,依序做三件便宜的事:辨識時給模型一份詞彙表、用 Word Replacements 修固定的錯、收集「錄音 + 改好的文字」當自己的測試集。這份是第一件。第三件(完整的個人測試集)這次先不做:量測改成只判斷兩版不同的地方,不需要整份參考答案(見「量測計畫」)。

## 目標

1. VoiceInk 已經有的詞彙表(「Dictionary → Vocabulary」)在用 TEA-ASR 時也送進模型,讓它認得這些詞。不新增介面、不加開關:清單是空的就和現在完全一樣。
2. 用實際的聽寫量出效果:專有名詞有沒有變對、有沒有憑空多出清單裡的詞、其他字有沒有變差、有沒有變慢。

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

- **憑空多出清單裡的詞**:模型可能在沒講到的地方插入清單的詞,或把整份清單吐出來(短句、靜音、雜音最容易)。上游文件說 Qwen3-ASR-0.6B 比 1.7B 常這樣;TEA 是 1.7B 微調過的,不知道。這是最主要的風險,量測的「憑空插入」、大清單和靜音錄音就是在抓這個。
- **改錯一般的字**:發音相近的普通詞被換成清單裡的詞。看沒有涉及清單詞的差異裡,新版是不是弄壞的比修好的多。
- **中文詞效果較弱**(見查證結果 6)。
- **換套件的風險**:數值變化讓原本對的字變了、GGUF 載不起來、新的錯誤路徑、更新後第一次聽寫多等 10 秒、自己維護鏡像、合併上游時 `project.pbxproj` 衝突。
- **變慢**:提示變長,每段多算幾十到上百個 token。
- **隱私**:詞彙表是個人資料(專案名、人名)。不寫進公開文件和紀錄;實驗用的清單只放私人 repo。

## 量測計畫

照之前評測的慣例(見 [`../development.md`](../development.md)):先 commit 這份設計,實際資料和結果只放私人 repo `voiceink-zhtw-data` 的資料夾 `2026-10-22-tea-vocabulary/`,公開文件只寫統計。**跑之前先問使用者**:不能在使用者聽寫時跑,也不能和其他對話的實驗同時跑(GPU 互搶,時間會不準)。

### 做法:只判斷兩版不一樣的地方

這次要回答的是「加詞彙表前後哪個比較好」,不是「TEA 整體對幾成」。兩版結果相同的地方,對就一起對、錯就一起錯,不影響比較,所以**不做整份參考答案**,只判斷兩版不同的地方(2026-10-22 使用者決定;原本的設計要使用者校對 80–100 段、20–30 分鐘)。

- 少掉的:整體錯誤率和專有名詞召回率的絕對數字;一份完整的個人測試集(之後真的要考慮微調時再慢慢建)。
- 判斷分兩層:
  1. **我先看文字判斷**:每一處差異標成「新版對」「舊版對」「都對(只是寫法不同)」「都錯」或「要聽錄音」。英文名詞拼對沒有、這個詞放在這句話合不合理,多半看前後文就知道。
  2. **要聽錄音的交給使用者**:我聽不到錄音,「當時到底有沒有講這個詞」只有使用者能確認,尤其是新版多出清單詞、前後文又說得通的地方。做成頁面(每題附那段錄音和兩個版本,A/B 位置平衡),使用者選哪個對。另外抽 3–5 處我有把握的放進去(使用者不知道是哪幾題),檢查我看文字的判斷準不準;不準的話,我判斷過的全部改成給使用者聽。
- 使用者要花的時間:確認詞彙表草稿約 2 分鐘,聽錄音的題目估計十幾題、5–10 分鐘(實際題數要跑完才知道)。

### 資料

- 錄音:私人 repo 裡 2026-10-21 13:10 到 2026-10-22 16:34 的 218 段聽寫(共 34.8 分鐘,中位 5.4 秒,最長 108 秒):91 段在 `2026-10-21-latency/recordings/`,另外 127 段 2026-10-22 複製進 `2026-10-22-tea-vocabulary/recordings/`(VoiceInk 只留 3 天)。當時用的辨識模型 Breeze 134 段、TEA 84 段,但這次全部用 TEA 重跑,所以都能用。
- 沒講話或不到 1 秒的錄音(有的話)一定放進來,專門抓「憑空吐詞」。
- **詞彙表**:我從這 218 段 App 貼出去的文字整理草稿:英文詞、技術名詞,和看前後文判斷被聽錯的詞(例如英文產品名被寫成發音相近的中文或拼錯)。使用者刪掉不對的、補上常講但沒出現的(專案、工具、套件名),確認後**固定下來、先 commit,才跑加詞彙表的那組**,避免看了結果再改清單。另外做一份「大清單」:固定清單加約 70 個使用者不常講的技術名詞當干擾,模擬清單變長以後的情況。
- 注意:清單是從同一批錄音整理的,效果會看起來比實際好一點(清單剛好包含這些錄音講到的詞)。大清單的干擾詞可以檢查另一個方向:沒講到的詞會不會被插進去。固定清單後使用者照常用一兩天,可以再收一批新錄音照同樣方法比一次(選用)。

### 比較的組

全部用同一個 Q8_0 GGUF(SHA256 `2e4aeb45…98d0`)、每 30 秒切段、語言中文,工具是 `scripts/bench/tc_bench.c`(加 `--vocabulary-file`:一行一個詞)。原生程式用 App 實際會用的那份:A 組用 Beingpax 的 856d7c1 xcframework(在 `.local-build/SourcePackages/artifacts/`),B、C 組用上游 v0.4.0 的 xcframework(要下載 `TranscribeCpp.xcframework.zip`,10.2MB,來源 handy-computer/transcribe.cpp 的 GitHub release,核對 SHA256)。

| 組 | transcribe.cpp | 詞彙表 | 和誰比、看什麼 |
|---|---|---|---|
| A | 856d7c1(現在) | 無 | 基準 |
| B | v0.4.0 | 無 | 和 A 比:只升級的影響 |
| C | v0.4.0 | 固定清單 | 和 B 比:詞彙表的效果 |
| C2 | v0.4.0 | 大清單 | 和 B 比:清單變長會不會亂插詞、變慢 |

每組跑兩輪,時間取較快的一次(和之前的評測一樣)。記憶體用 `/usr/bin/time -l` 看 A、B 有沒有差。

### 怎麼找差異、怎麼算

- 文字先用 App 同一份 `ZhTWTranscript.clean` 整理(`scripts/bench/punct-ct.sh` 的工具,刪私用區字元、簡體專用字轉繁體),再去掉標點、英文轉小寫、全形轉半形。**不轉成簡體再比**(TEA 官方評測會這樣做,但「裡/里」這種差別正是使用者在意的)。
- 兩版逐字對齊(中文一個字、英文一個詞算一個單位),連在一起的不同處算「一處差異」。每處標記有沒有涉及清單詞(英文不分大小寫、要整個詞相符,中文要完全相同)。
- 每一組比較統計:
  - 逐字相同的錄音比例。
  - 差異處依判斷結果分類:新版修好、新版弄壞、都對、都錯。
  - 涉及清單詞的另外算:**修好**(舊版錯、新版變成清單詞而且對)、**弄壞**(舊版對、新版錯)、**憑空插入**(新版多出清單詞,但其實沒講);一段裡插入 3 個以上的算「整份吐出來」。
  - 沒有涉及清單詞的差異:有沒有讓其他字變差。
  - 5 秒以下短句的辨識時間中位數。

### 假設和通過標準(先寫好,看結果前不改)

1. **只升級不改結果**:B 對 A 至少 90% 的錄音逐字相同;差異處 B 弄壞的不超過 3 處、也不多於修好的;沒有新的失敗。不成立就先查原因,不跑 C。
2. **詞彙表有用**:C 對 B 修好的清單詞至少 5 處,而且至少是「弄壞 + 憑空插入」的 3 倍。
3. **不亂插詞**:C 憑空插入的清單詞總共不超過 1 處、沒有「整份吐出來」,靜音或極短的錄音一處都沒有。C2 也要符合。
4. **其他字不變差**:沒有涉及清單詞的差異裡,C 弄壞的不超過 3 處、也不多於修好的。
5. **不明顯變慢**:5 秒以下的短句,C 的辨識時間中位數比 B 多不到 50 毫秒。

1–5 都成立才建議採用,最後由使用者決定。只有 3 不成立時,追加試:清單縮短、改用 `prompt` 放一句說明(例如「以下是程式開發相關的詞:…」),標成追加。

## 結果(2026-10-22)

2026-10-22 17:05–17:30 跑完兩輪(開始前 GPU 閒置,主對話暫停 GPU 工作,使用者沒有聽寫)。218 段全部成功(30 秒切段,最長 108 秒那段也正常),每一組兩輪的文字逐字相同。差異是我看文字和前後文判斷的(沒聽錄音);判斷不了的 12 處沒給使用者聽,因為不管它們算好算壞,結論都一樣(見最後)。逐處的判斷在私人 repo 的 `analysis/judgments.json`。

### 只升級(A → B):沒有差別

- 218 段裡 217 段逐字相同;唯一的一處是「為」變「爲」(異體字,算寫法不同)。
- 5 秒以下的短句(103 段)辨識時間中位數 227 → 225 毫秒,全部 386 → 392 毫秒;記憶體(peak footprint)3.64 → 3.65GB。
- 假設 1 成立:升到 v0.4.0 本身不會讓辨識變好或變壞。

### 加詞彙表(B → C):清單詞改對不少,但整句都被影響、也變慢

- 218 段裡 76 段(35%)結果變了,共 127 處差異,其中只有 25 處和清單詞有關。
- 和清單詞有關的 25 處:**修好 16 處**(原本聽錯的英文名詞、產品名、同音字變對);**弄壞 6 處**(原本對的清單詞變錯,例如英文縮寫被拆成一個一個字母、一個詞被拆成兩半);**憑空換成清單詞 2 處**(講的是別的詞,被換成清單裡的詞);判斷不了 1 處。清單裡也有一些詞照樣聽錯,例如 Claude Code。
- 和清單詞**無關**的 102 處:變好 23、變壞 34、寫法不同 19、兩個都錯 15、判斷不了 11。也就是說,詞彙表不只影響清單裡的詞,整句話怎麼聽都會跟著變,而且變壞的比變好的多。
- 沒講話的 1 段照樣是空的,1.5 秒以下的 10 段都沒變,沒有「整份清單吐出來」。
- 速度:短句辨識時間中位數 225 → 317 毫秒(**多 92 毫秒**),全部 392 → 488 毫秒。記憶體不變。

### 大清單(B → C2)

- 69 段結果變了,111 處差異(70 處和 C 一樣);78 個干擾詞一個都沒有被插進結果。清單詞修好的比 C 少(清單越長,每個詞的效果越淡)。
- 短句多 **220 毫秒**(225 → 445),全部 392 → 598 毫秒。
- 沒有逐處判斷:C 已經不合格,C2 更慢、修得更少。

### 對照假設

| 假設 | 結果 |
|---|---|
| 1. 只升級不改結果 | 成立(217/218 逐字相同,速度、記憶體一樣) |
| 2. 詞彙表有用(修好 ≥ 5 處,而且 ≥ 弄壞 + 憑空插入的 3 倍) | **不成立**:修好 16,弄壞 + 憑空插入 8(要 ≤ 5) |
| 3. 不亂插詞(憑空插入 ≤ 1 處,沒有整份吐出來) | **不成立**:憑空換成清單詞 2 處;沒有整份吐出來,靜音和極短的錄音沒事,大清單的干擾詞沒被插入 |
| 4. 其他字不變差(弄壞 ≤ 3 處,而且不多於修好的) | **不成立**:變壞 34、變好 23 |
| 5. 短句慢不到 50 毫秒 | **不成立**:多 92 毫秒(大清單多 220 毫秒) |

判斷不了的 12 處就算全部算成變好,假設 2(17 對 8)、4(34 對 34)、5 的結論都不變,所以沒有請使用者聽錄音。

### 結論和建議

- **照事先寫好的標準,不採用詞彙表。** 白話說:詞彙表不是讓模型「查字典」,而是像在速記員旁邊放一張小抄,清單上的詞比較常寫對,但他整句都會分心,其他地方反而更常聽錯,而且每句多想 0.1 秒。
- **改用 Word Replacements 修固定會錯的詞**:這次看到的錯很多是每次都錯成同一個樣子(例如某個英文產品名固定被聽成另一個英文詞),辨識之後替換,不會影響其他字、也不會變慢。只修「每次都錯成一樣」的,不固定的錯修不了。
- **升級 transcribe.cpp 到 v0.4.0 可以另外考慮**:只升級完全不影響聽寫結果和速度,又能拿到 #165(長段的產生上限放寬)和 #166(鬼打牆保險),對[長音檔計畫](2026-10-22-long-audio-segmentation.md)有用。要不要升、套件放哪,和詞彙表無關,另外決定。
- 追加的選項(要使用者決定才做):只放幾個 TEA 一直聽錯的詞,看整句被影響的程度和延遲會不會小很多。我覺得機會不大:這次的副作用在和清單詞無關的地方,而且短句的延遲是每一段都要多算系統提示,清單短一點只會少一點。

## 步驟

每一步單獨 commit,驗證後再做下一步。

1. **收資料**:錄音和聽寫紀錄複製到私人 repo(2026-10-22 完成)。我整理詞彙表草稿,使用者確認後固定。
2. **工具**:`tc_bench.c` 加 `--vocabulary-file`,分別連結兩份 xcframework;新增 `scripts/bench/tea_vocab_diff.py`(整理、對齊、找差異、統計,只讀參數給的路徑,不含資料)。
3. **跑 A、B**(先問使用者):確認 v0.4.0 載得起來、只升級的影響(假設 1)。
4. **跑 C、C2**:我先看文字判斷差異;要聽錄音的做成頁面給使用者;統計假設 2–5,寫結果(公開文件只寫統計,實際內容放私人 repo)。
5. **改 App**(使用者決定採用後):換套件(依使用者選的做法)、`ZhTWVocabulary`、五行修改、測試案例;build、裝到這台;用紀錄裡的「重新辨識」核對幾段和量測結果相同。
6. **文件**:架構文件(架構圖、改了哪些檔案、決策紀錄)、`development.md`(合併上游時注意套件那兩個檔案)、README(詞彙表的用法);長音檔計畫補上 `.outputRepetition`。

## 待使用者決定

1. **套件放哪**:2026-10-22 使用者選自己的鏡像 repo,已建好(見紀錄)。
2. **詞彙表內容**:2026-10-22 定案(見紀錄);量測後不採用詞彙表。

## 紀錄

- 2026-10-22 寫 plan。查證:Qwen3-ASR 技術報告、TEA model card(`bda08df7`)、`qwen-asr` 0.0.6 原始碼、transcribe.cpp `856d7c10`..`db678a03`(2026-10-20 的 `main`)、Beingpax/Transcribe-cpp-swift、VoiceInk 的詞彙表程式碼;TEA tokenizer 的檢查用 Python 照 merges 模擬編碼。沒有跑任何辨識。
- 2026-10-22 使用者覺得校對 100 段太花時間。改成只判斷兩版不同的地方:我先看文字判斷,要聽錄音的才給使用者(見「做法」)。假設和通過標準跟著改成以差異處計算(還沒跑任何量測)。
- 2026-10-22 使用者同意後,把 218 段聽寫的紀錄(`history.json`)和 127 段新錄音複製到私人 repo `2026-10-22-tea-vocabulary/`(另外 91 段原本就在 `2026-10-21-latency/`)。沒複製會議錄音和「重新辨識」產生的 2 段副本。
- 2026-10-22 詞彙表定案:52 個詞(看前後文判斷被聽錯的 22 個、工作上常講的 21 個、這個 fork 常用的 9 個),大清單再加 78 個沒出現在這批錄音的技術名詞當干擾。清單有工作上的系統名稱和帳號,只放私人 repo(`2026-10-22-tea-vocabulary/terms.txt`、`terms-large.txt`),這裡只記數量。
- 2026-10-22 步驟 2 的工具完成:`tc_bench.c` 加 `--vocabulary-file`、`--prompt`(編譯時加 `-DTC_PROMPTING`);`tea_vocab_run.sh` 依序跑 A、B、C、C2 兩輪;`tea_vocab_diff.py` 產生清單、整理文字(接 `punct-ct.sh`,App 同一份 `ZhTWTranscript.clean`)、找差異、統計。上游 v0.4.0 的 `TranscribeCpp.xcframework.zip` 下載後 SHA256 和 GitHub 的 digest 相同;兩個版本各連結一份 `tc_bench`。用評測留下的 91 段 TEA 結果故意改 3 處自我測試:3 處都抓到、涉及清單詞的 2 處、「一段多 3 個清單詞」1 段,和預期相同。還沒用 GPU 跑任何辨識。估計一輪 4 組約 11 分鐘(218 段共 34.8 分鐘,評測時 TEA 跑 16 分鐘的錄音花 64 秒),兩輪約 25 分鐘。
- 2026-10-22 步驟 3、4:兩輪跑完(17:05–17:30),結果見「結果」。只升級沒有差別;加詞彙表修好 16 處清單詞,但和清單詞無關的地方變壞 34、變好 23,短句多 92 毫秒,假設 2–5 不成立,建議不採用,改用 Word Replacements。使用者聽錄音的判斷沒做(不影響結論)。
- 2026-10-22 使用者決定只升級 transcribe.cpp,升級後的套件照原作者的做法自己做一份可安裝的副本:公開 repo [Jim-Chang/Transcribe-cpp-swift](https://github.com/Jim-Chang/Transcribe-cpp-swift),tag `0.4.0`(commit `90169959`)。內容是上游 v0.4.0 的 `bindings/swift` 原始碼、測試和授權檔(31 個檔案,和上游逐位元組相同),`Package.swift` 的 binaryTarget 指向上游 release 的 `TranscribeCpp.xcframework.zip`(checksum `3da069d2…0453`,就是量測用的那份),`UPSTREAM.md` 記來源。本機驗證:套件編譯、不需要模型的 19 個測試通過(55 個要模型的略過);照 `OfflineTranscribeCppService` 的用法寫的小程式(`try` capabilities、`vocabulary`、`isTruncated`)編譯成功;從 GitHub 網址重新安裝也成功,執行時 Swift 和原生程式都是 0.4.0。套件名稱(identity)和原作者的一樣是 `transcribe-cpp-swift`,VoiceInk 只要改網址、版本和 `Package.resolved` 那一筆。App 這邊的修改交給主對話,和長音檔計畫步驟 1 一起做。
