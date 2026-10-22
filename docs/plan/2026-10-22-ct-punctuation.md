# 補標點換成 CT-Transformer

2026-10-22。依據 [`../investigations/2026-10-21-latency.md`](../investigations/2026-10-21-latency.md) 的實驗 C 和使用者盲測(CT-Transformer 8 題較好、Breeze2 3 題、差不多 4 題),這裡不重複推導,只寫要做什麼。

## 背景與目標

現在補標點是 AI 潤稿(VoiceInk Refine)裡的 Breeze2-3B:短句 0.26 秒、長句中位 2.7 秒,要 2GB 記憶體和 GPU,長的逐字稿要分段才不會答非所問。CT-Transformer int8 每段 2–35 毫秒、模型 75MB、只用 CPU,盲測也比較好。

先把基礎架構做好(使用者 2026-10-22 決定的範圍):

1. App 裡加 sherpa-onnx(它包著 ONNX Runtime),在 App 自己的行程裡用 CPU 跑 CT-Transformer int8。辨識完直接補標點,不經過 AI 潤稿,不需要 XPC 子程序、不需要預先載入。
2. 結果和離線評測一模一樣:同一版 sherpa-onnx(1.13.8)、同一個模型檔、同一套轉簡體和合併邏輯。
3. 模型內建進 App(使用者 2026-10-22 同意),換一台 Mac 不用另外下載補標點模型。

## 非目標

- 補標點的設定介面:不加開關(見「使用者體驗」)。
- Intel Mac:App 仍只 build arm64。sherpa-onnx 有 universal2 版,需要時再換。
- 改合併邏輯:沿用 `ZhTWPunctuation.merge`。
- 盲測裡 CT 輸的 3 種狀況(逗號斷在詞中間、短問句少問號、問句中間多斷一次):先不處理,用一陣子看多常發生再說。

## 使用者體驗

- **不用設定。** 裝好 App、講中文,貼出來就有標點。沒有開關、不用選模型、不用開 AI 潤稿。
- **什麼時候補**,看的是這次辨識出來的文字,不是語言設定:
  - 有中文字才補。只講英文的指令(例如「git push」)不會被加上「。」;語言設成自動偵測也照樣有效。
  - 原文已經有句號、問號或驚嘆號就不補:表示用的是自己會加標點的辨識模型(例如雲端的)。Breeze-ASR-25 的 91 段實際聽寫沒有一段有這些標點。
  - 原文有零星的逗號等標點時,先拿掉再給模型判斷,合併時保留原文的標點、不重複加。
- **CT 一定會在結尾補上句號或問號**,單講一個「好」會變成「好。」。Breeze2 也一樣。
- **出錯就貼原文。** 模型載入失敗時,每次開 App 跳一次通知,說「暫時不補標點」,之後聽寫照常貼沒標點的原文,不會卡住。
- **速度**:補標點從短句約 0.3–0.5 秒、長句中位 2.7 秒,變成幾毫秒到幾十毫秒。不和語音辨識搶 GPU,閒置 5 分鐘後第一句也不會變慢。
- **記憶體**:和語音辨識模型一樣用完就放。開始錄音時載入(約 0.14 秒,藏在講話時間裡),聽寫結束就釋放;App 閒著時不佔記憶體(載入時約 250MB)。
- **紀錄**:紀錄裡的「原文」就是有標點的版本,不會另外出現 AI 潤稿的結果。要沒標點的原文時,把標點拿掉就是(合併只插標點、不改字)。
- **模式的「文字格式化」關掉。** 它是原作者給英文設計的(`ParagraphFormatter`):句子之間用空格接起來,每約 50 個詞空一行分段。以前補標點在它後面,它拿到沒標點的文字,什麼都沒做;現在補標點在前面,中文句號後面會多一個空格。`configure_voiceink.py` 會把它關掉,效果和以前一樣。
- **要關掉時**(查問題用):`defaults write com.prakashjoshipax.VoiceInk ZhTWPunctuationEnabled -bool false`,重新聽寫就生效。以後真的需要開關,放在模式設定裡「文字格式化」旁邊(VoiceInk 放類似設定的地方)。

## 設計

### 放在流程的哪裡

辨識完、`TranscriptionOutputFilter` 和去掉頭尾空白之後,段落格式化和 Word Replacements 之前。VoiceInk 有三個地方走這段流程,三處都加同一行:

| 檔案 | 用途 |
|---|---|
| `VoiceInk/Features/Recording/Workflows/TranscriptionPipeline.swift` | 按快捷鍵聽寫(放在觸發詞切換模式之後) |
| `VoiceInk/Features/AudioImport/Workflows/AudioFileTranscriptionManager.swift` | 匯入音檔 |
| `VoiceInk/Features/History/Workflows/AudioFileTranscriptionService.swift` | 在紀錄裡重新辨識 |

為什麼不放在 AI 潤稿裡:

- 補標點是辨識的一部分,不是潤稿。放在 AI 潤稿裡,模式要開 AI 潤稿、選 Provider 和提示詞,VoiceInk Refine 還限定 Apple Silicon + 16GB;CT 都不需要。
- 之後如果另外開 AI 潤稿(例如雲端模型改寫),拿到的是有標點的文字。

### 怎麼執行

- 新增 `VoiceInk/Features/ZhTW/ZhTWPunctuator.swift`:一個 actor,包 sherpa-onnx 的 C API(`SherpaOnnxCreateOfflinePunctuation`、`SherpaOfflinePunctuationAddPunct`、`SherpaOfflinePunctuationFreeText`)。專案用 synchronized folders,新的 Swift 檔放進資料夾就會加入專案。
- 步驟:繁體原文 → 拿掉原有標點 → ICU `Traditional-Simplified` 轉簡體(字數變了就用原文,和評測一樣)→ CT → `ZhTWPunctuation.merge(original:modelOutput:)` 把標點插回繁體原文。
- 不分段:CT 的實作本來就會切成小段,帶著前一段的尾巴往下算。評測裡 582 字那段正常。
- 開始錄音時在背景載入(`VoiceInkEngine` 裡原作者準備模型的地方),聽寫結束時釋放(`VoiceInkEngine.cleanupResources`,語音辨識模型也在這裡釋放)。補標點時還沒載入就先載入。匯入音檔、在紀錄裡重新辨識沒有「聽寫結束」,補完就釋放。
- CPU、2 個執行緒。用 actor,`@MainActor` 的聽寫流程不會卡住主執行緒。
- 計時:`ZhTWTiming` 加一筆 `punct chars= load= model= merge= total=`(只有數字),`scripts/timing_report.py` 加一欄。

### 函式庫和模型放哪

照 whisper.xcframework 的做法:用腳本準備好放在 `~/VoiceInk-Dependencies/`,Xcode 專案引用那裡的檔案,build 時放進 App,不放進 git。

| 檔案 | 來源(固定版本、核對 SHA256) | 放進 App 的位置 |
|---|---|---|
| `libsherpa-onnx-c-api.dylib`(3MB)、`libonnxruntime.dylib`(29MB) | sherpa-onnx v1.13.8(2026-09-10)的 `sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts-lib.tar.bz2` | `Contents/Frameworks/`,嵌入時重新簽名 |
| `c-api.h` | sherpa-onnx v1.13.8 的原始碼 | 只在編譯時用。加一個 module map,Swift 用 `import SherpaOnnxC` |
| `model.int8.onnx`(75MB) | sherpa-onnx `punctuation-models` 的 `sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2` | `Contents/Resources/` |

- 新增 `scripts/deps-sherpa-onnx.sh`:下載三樣東西、驗 SHA256、解壓到 `~/VoiceInk-Dependencies/sherpa-onnx/`、產生 module map;已經有就跳過。`setup.sh`、`update.sh` 在 `make local` 前呼叫。沒準備好時 build 會失敗,不會做出沒有模型的 App。
- 模型放在 GitHub release 的附件,作者可能換檔。SHA256 對不上就停下來,不會默默換模型。
- 連結、嵌入 dylib、模型和標頭檔路徑要改專案檔(`project.pbxproj`),和 whisper.xcframework 的設定放在一起。
- **用動態函式庫。** 只有兩個檔案,sherpa-onnx 自己的程式碼都在 C API 那個檔案裡,不用處理十幾個靜態函式庫和 C++ 的連結參數。Xcode 嵌入 dylib 不順的話,改用靜態版(`static-no-tts-lib`)。
- App 從 159MB 變成約 270MB(兩個 dylib 33MB、模型 75MB)。
- **授權:** sherpa-onnx 是 Apache-2.0、ONNX Runtime 是 MIT。原始模型 [punc_ct-transformer_zh-cn-common-vocab272727-pytorch](https://modelscope.cn/models/iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch) 在 ModelScope 標示 Apache License 2.0;FunASR repo 的通用模型授權也允許散布,條件是註明來源和作者、保留模型名稱。README 加來源說明。

## 步驟

每一步單獨 commit、驗證後再做下一步。

1. **函式庫和模型放進專案**:`deps-sherpa-onnx.sh`;Xcode 專案連結、嵌入兩個 dylib,模型加進 Resources,加 module map。先寫一個最小的呼叫,確認 build、簽名、啟動都沒問題。
2. **`ZhTWPunctuator`,離線核對**:寫 actor。`scripts/bench/` 加一個小工具,編譯同一份 Swift 檔案,跑實驗 C 的 91 段,和 `C-ct-merged-int8.json` 逐字比對(預期 91 段全部相同)。順便量載入時間和常駐記憶體。
3. **接進三個流程**:加判斷條件、載入失敗的通知、計時紀錄,`timing_report.py` 加新欄位。`configure_voiceink.py` 把模式的 AI 潤稿關掉(補標點已經不靠它)。
4. **裝到這台、實際用**:跑 `configure`,聽寫短句和長句,看計時和紀錄。用幾天。
5. **Breeze2 那條路:拆掉**(使用者決定,見下一節)。
6. **文件**:
   - 架構文件:架構圖、元件位置、改了哪些檔案、決策紀錄、進度。
   - `development.md`:合併上游時要注意 `project.pbxproj` 和三個流程檔案。
   - README:補標點模型的來源和授權。
   - App 內下載計畫:拿掉步驟 b;步驟 c 的預設模式不再開 AI 潤稿。

## Breeze2 那條路要不要留著當備用(決定:拆掉)

| | 拆掉(建議) | 留著當備用 |
|---|---|---|
| 改原作者的程式 | Refine 的 5 個檔案改回原作者的版本,少 446 行新增、45 行刪除(XPC 引擎就占 376 行:prefix cache、多輪範例等) | 維持現狀,每次合併上游都要處理這些衝突 |
| 備用的意義 | 沒有;CT 出錯時貼沒標點的原文 | CT 載入失敗時,打開 AI 潤稿就會用 Breeze2 補 |
| 記憶體、硬碟 | 刪掉這台的模型資料夾可省 2GB(刪之前先問使用者) | 模型留著;AI 潤稿關著時不佔記憶體 |
| 要回來 | git 歷史都在,可以還原 | — |

建議拆掉:模型內建在 App 裡,不會有「模型不見」的情況;CT 在結構上不會改字、不會答非所問,也沒有載入時間,需要備用的情況很少。拆掉後改原作者的程式變少,合併上游比較不會衝突。原本規劃的介面改名(Provider 顯示「本機（MLX）」、模型「Breeze2-3B 補標點」)也不用做了。

拆掉的話要做:

- `VoiceInkRefineService.swift`、`VoiceInkRefineXPCClient.swift`、`VoiceInkRefineXPC/` 的改動還原成原作者的版本,刪掉 XPC 那份 `ZhTWTiming.swift`。
- `ZhTWPunctuation.swift` 拿掉 Breeze2 的資料夾、指示、範例、分段,測試拿掉分段的案例。
- `scripts/bench/` 只給 Breeze2 用的工具刪掉。git 歷史留著,調查文件註明。
- `setup.sh` 不再下載 Breeze2。
- 架構文件的非目標拿掉「16GB 以下記憶體的 Mac」:不再需要 VoiceInk Refine。

## 驗證

```bash
scripts/test-punctuation.sh   # 合併邏輯沒被動到
scripts/setup.sh check        # 安裝狀態
```

| 步驟 | 怎麼驗 |
|---|---|
| 1 | `make local` 成功;`Contents/Frameworks/` 有兩個 dylib、`Contents/Resources/` 有模型;`codesign --verify --deep --strict` 通過;`otool -L` 看得到 `@rpath/libsherpa-onnx-c-api.dylib`;App 能啟動 |
| 2 | 91 段和評測逐字相同;小工具給錯模型路徑時回傳原文;載入時間和常駐記憶體(`footprint`)寫進紀錄 |
| 3 | 測試通過;測試案例涵蓋「沒有中文字不補」「已有句號不補」「原有逗號不重複」 |
| 4 | `timing_report.py` 的補標點欄位在 50 毫秒以下、沒有 XPC 的紀錄;紀錄裡的文字有標點、沒有 AI 潤稿的結果 |

實際聽寫的核對資料放私人 repo `voiceink-zhtw-data` 的新資料夾 `2026-10-22-ct-punctuation/`。

## 紀錄

- 2026-10-22 寫 plan。SHA256:`sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts-lib.tar.bz2` 是 `f3e0cbd86cc3f38dad30c97921b40e9a8bcc6f2c943777eb76ad77176993e417`,`c-api.h`(v1.13.8)是 `2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce`,模型壓縮檔是 `c0d5aa5f8eeb686032345e180bedf39319dc2e0556781c6264bcadba8328a6e1`(和 release 的 `checksum.txt`、評測用的那份相同),解開後的 `model.int8.onnx` 是 `65a3fb9f5ad7bfb96bf69e0dc4481df97f6ee60513c1d94ce981ba6effd524b1`。
- 2026-10-22 範圍:使用者在另一個對話決定「先把基礎架構做好」;Breeze2 要不要留著備用列為待決定。
- 2026-10-22 使用者同意模型內建進 App。補充使用者體驗:不加開關,看辨識結果有沒有中文字、有沒有句號決定要不要補。用 sherpa-onnx 1.13.8 實測:「git push」「OK」會被補成「git push。」「OK。」,所以沒有中文字時不補;原文已有逗號時模型會再補一個(「好的，，」),所以先拿掉原有標點再給模型。
- 2026-10-22 步驟 1–3 完成(commit `31416a5`、`25d3ab3`),裝到這台,模式的 AI 潤稿已關掉。
  - Xcode 嵌入 dylib 沒問題,不用改靜態版。App 裡兩個 dylib 都用同一張 Apple Development 憑證重新簽名,`codesign --verify --deep --strict` 通過;App 從 159MB 變成 261MB。
  - 離線核對:`scripts/bench/punct-ct.sh` 用 App 裡同一份 Swift 程式跑 91 段,和評測的 `C-ct-merged-int8.json` 逐字相同 91/91。
  - 速度(2 執行緒,只算補標點):短句中位 2.0 毫秒(最大 2.7)、中 6.5 毫秒(最大 17.2)、長 29.5 毫秒(最大 97)。載入 0.11–0.14 秒。
  - 記憶體:模型載入後常駐約 250MB(工具本身的 footprint 253MB),比預估的 100MB 大。載入只要 0.14 秒,要省記憶體可以改成閒置就卸載、開始錄音時再載入。
  - 判斷要不要補、給模型的版本(拿掉全形標點、轉簡體)放在 `ZhTWPunctuation`,`scripts/test-punctuation.sh` 加了 8 個案例,23/23 通過。
- 2026-10-22 使用者決定補標點模型和語音辨識模型一樣用完就放(原本 App 啟動時載入、常駐約 250MB)。量到的組成:模型和計算空間約 88MB、27 萬詞的查詢表約 33MB、載入時用過但記憶體管理器沒還給系統的約 124MB(試過 `malloc_zone_pressure_relief`,收不回來)。改完後 App 閒著時 footprint 180MB(常駐版是 343MB)。啟動時不再載入,`AppDelegate` 的改動拿掉;改在 `VoiceInkEngine` 開始錄音時載入、`cleanupResources` 釋放。
- 2026-10-22 實測發現句號後面多一個空格(「了解。␣所以…」):模式開著「文字格式化」,`ParagraphFormatter` 用空格接句子。以前它拿到的是沒標點的文字,所以沒作用。使用者選擇把它關掉(另一個選項是改成適合中文、保留自動分段,要改原作者的程式);`configure_voiceink.py` 加上 `isTextFormattingEnabled: false`,`setup.sh check` 也檢查。這台已經套用。
- 2026-10-22 使用者實測(TEA 換上之前的 build `f5b7cd6`):7 句聽寫每次開始錄音都載入(0.08–0.14 秒)、結束都釋放;補標點 2–14 毫秒;短句放開快捷鍵到貼上 1.41–1.64 秒;句號後面沒有空格;只講英文的「git status」沒有補(貼出來的「GET status.」是語音辨識自己的輸出)。取消錄音沒有測到。
- 2026-10-22 步驟 6 完成:架構文件(架構圖、元件位置、改了哪些檔案、進度)、`development.md`(合併上游要注意的地方)、README(模型和函式庫的來源與授權)一起改成 TEA + CT 的現況。App 內下載計畫在使用者決定只內建中文提示詞時已經記過。剩下步驟 5(Breeze2 補標點那條路要不要拆)待使用者決定;拆的話 `setup.sh` 也不再下載 Breeze2(現在還會下載 2GB,但沒用到)、不再要求 16GB。
- 2026-10-22 步驟 5 完成:使用者決定拆掉,也刪掉這台的兩個 Breeze 模型(補標點的 Breeze2 2GB、備用語音辨識的 Breeze-ASR-25 1.7GB,移到垃圾桶由使用者清)。
  - Refine 的 4 個檔案還原成原作者的版本(和合併基準 `22e5ec5` 相同),刪掉 XPC 那份 `ZhTWTiming.swift`;`git diff` 對原作者只剩 TEA、CT、繁體提示詞的改動。模型清單的 VoiceInk Refine 回到原作者的狀態(沒下載它的模型時顯示下載)。
  - `ZhTWPunctuation` 只留合併和 CT 的輸入規則,測試拿掉分段的 3 個案例(27/27 通過)。`scripts/bench/` 刪掉 `refine-bench.sh` 和 `RefineBench/`;`timing_report.py` 拿掉 Breeze2 的欄位(pre 到 xpc、therm、qos)。
  - `setup.sh` 不再下載 Breeze2、不再要求 16GB(只提示「只在 32GB 測過」);Breeze-ASR-25 還是可以用 `--with-breeze` 下載。
  - 使用者另外要求預設模式改名「繁中聽寫(TEA-ASR 1.1)」(原本叫「Breeze」),`configure_voiceink.py` 寫入、`setup.sh check` 檢查。
