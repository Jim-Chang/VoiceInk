# 補標點換成 CT-Transformer

2026-10-22。依據 [`../investigations/2026-10-21-latency.md`](../investigations/2026-10-21-latency.md) 的實驗 C 和使用者盲測(CT-Transformer 8 題較好、Breeze2 3 題、差不多 4 題),這裡不重複推導,只寫要做什麼。

## 背景與目標

現在補標點是 AI 潤稿(VoiceInk Refine)裡的 Breeze2-3B:短句 0.26 秒、長句中位 2.7 秒,要 2GB 記憶體和 GPU,長的逐字稿要分段才不會答非所問。CT-Transformer int8 每段 2–35 毫秒、模型 75MB、只用 CPU,盲測也比較好。

這次先把基礎架構做好(使用者 2026-10-22 決定的範圍):

1. App 裡加 sherpa-onnx(它包著 ONNX Runtime),在 App 自己的行程裡用 CPU 跑 CT-Transformer int8。辨識完直接補標點,不經過 AI 潤稿,不需要 XPC 子程序、不需要預先載入。
2. 結果和離線評測一模一樣:同一版 sherpa-onnx(1.13.8)、同一個模型檔、同一套轉簡體和合併邏輯。
3. 模型先用腳本放到 Application Support 的固定資料夾(像現在放 Breeze2 那樣),App 找到模型就用 CT 補標點。

## 非目標

- **模型內建進 App 或在 App 內下載的介面:之後再處理。** 傾向內建(見「之後要決定的事」)。
- 在介面上開關或換補標點模型:找到模型、文字有中文就補。要關掉用 `defaults write`(見「放在流程的哪裡」)。
- Intel Mac:App 仍只 build arm64。sherpa-onnx 有 universal2 版,需要時再換。
- 改合併邏輯:沿用 `ZhTWPunctuation.merge`。
- 盲測裡 CT 輸的 3 種狀況(逗號斷在詞中間、短問句少問號、問句中間多斷一次):先不處理,用一陣子看多常發生再說。

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
- 段落格式化要靠句號分段,先有標點才分得出來。
- 紀錄裡的原文就是有標點的版本。之後如果另外開 AI 潤稿(例如雲端模型改寫),拿到的也是有標點的文字。

什麼時候補:找到模型檔且載入成功、文字裡有漢字、`ZhTWPunctuationEnabled` 不是 false(沒設就是開)。沒有模型或任何錯誤都回傳原文(指導原則「出錯就貼原文」)。

### 怎麼執行

- 新增 `VoiceInk/Features/ZhTW/ZhTWPunctuator.swift`:一個 actor,包 sherpa-onnx 的 C API(`SherpaOnnxCreateOfflinePunctuation`、`SherpaOfflinePunctuationAddPunct`、`SherpaOfflinePunctuationFreeText`)。專案用 synchronized folders,新的 Swift 檔放進資料夾就會加入專案。
- 步驟:繁體原文 → ICU `Traditional-Simplified` 轉簡體(字數變了就用原文,和評測一樣)→ CT → `ZhTWPunctuation.merge(original:modelOutput:)` 把標點插回繁體原文。
- 不分段:CT 的實作本來就會切成小段,帶著前一段的尾巴往下算。評測裡 582 字那段正常。
- App 啟動時如果找到模型,就在背景載入(約 0.2 秒),之後常駐不卸載。第一次聽寫時還沒載完就等它。步驟 2 量記憶體,太大再考慮閒置卸載。
- CPU、2 個執行緒。用 actor,`@MainActor` 的聽寫流程不會卡住主執行緒。
- 計時:`ZhTWTiming` 加一筆 `punct chars= load= model= merge= total=`(只有數字),`scripts/timing_report.py` 加一欄。

### 函式庫和模型放哪

函式庫照 whisper.xcframework 的做法:用腳本準備好放在 `~/VoiceInk-Dependencies/`,Xcode 專案引用那裡的檔案,不放進 git。模型照 Breeze2 的做法放 Application Support。

| 檔案 | 來源(固定版本、核對 SHA256) | 放在哪 |
|---|---|---|
| `libsherpa-onnx-c-api.dylib`(3MB)、`libonnxruntime.dylib`(29MB) | sherpa-onnx v1.13.8(2026-09-10)的 `sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts-lib.tar.bz2` | 準備在 `~/VoiceInk-Dependencies/sherpa-onnx/`;build 時嵌入 App 的 `Contents/Frameworks/` 並重新簽名 |
| `c-api.h` | sherpa-onnx v1.13.8 的原始碼 | 只在編譯時用。加一個 module map,Swift 用 `import SherpaOnnxC` |
| `model.int8.onnx`(75MB) | sherpa-onnx `punctuation-models` 的 `sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2` | `~/Library/Application Support/com.prakashjoshipax.VoiceInk/ZhTWPunctuation/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/model.int8.onnx` |

- 新增 `scripts/deps-sherpa-onnx.sh`:下載函式庫和標頭檔、驗 SHA256、解壓到 `~/VoiceInk-Dependencies/sherpa-onnx/`、產生 module map;已經有就跳過。`setup.sh`、`update.sh` 在 `make local` 前呼叫。
- `setup.sh install` 下載模型、驗 SHA256、解壓到上表的資料夾;`check` 也檢查它。模型放在 GitHub release 的附件,作者可能換檔;SHA256 對不上就停下來,不會默默換模型。
- 連結、嵌入 dylib 和標頭檔路徑要改專案檔(`project.pbxproj`),和 whisper.xcframework 的設定放在一起。
- **用動態函式庫。** 只有兩個檔案,sherpa-onnx 自己的程式碼都在 C API 那個檔案裡,不用處理十幾個靜態函式庫和 C++ 的連結參數。Xcode 嵌入 dylib 不順的話,改用靜態版(`static-no-tts-lib`)。
- App 多約 33MB(兩個 dylib)。
- **授權:** sherpa-onnx 是 Apache-2.0、ONNX Runtime 是 MIT。原始模型 [punc_ct-transformer_zh-cn-common-vocab272727-pytorch](https://modelscope.cn/models/iic/punc_ct-transformer_zh-cn-common-vocab272727-pytorch) 在 ModelScope 標示 Apache License 2.0;FunASR repo 的通用模型授權也允許散布,條件是註明來源和作者、保留模型名稱。README 加來源說明。

## 步驟

每一步單獨 commit、驗證後再做下一步。

1. **函式庫放進專案**:`deps-sherpa-onnx.sh`;Xcode 專案連結、嵌入兩個 dylib,加 module map。先寫一個最小的呼叫,確認 build、簽名、啟動都沒問題。
2. **模型和 `ZhTWPunctuator`,離線核對**:`setup.sh` 下載模型;寫 actor。`scripts/bench/` 加一個小工具,編譯同一份 Swift 檔案,跑實驗 C 的 91 段,和 `C-ct-merged-int8.json` 逐字比對(預期 91 段全部相同)。順便量載入時間和常駐記憶體。
3. **接進三個流程**:加判斷條件、計時紀錄,`timing_report.py` 加新欄位。`configure_voiceink.py` 把模式的 AI 潤稿關掉(補標點已經不靠它)。
4. **裝到這台、實際用**:跑 `setup.sh install` 和 `configure`,聽寫短句和長句,看計時和紀錄。用幾天。
5. **Breeze2 那條路:待使用者決定**(見下一節)。
6. **文件**:
   - 架構文件:架構圖、元件位置、改了哪些檔案、決策紀錄、進度。
   - `development.md`:合併上游時要注意 `project.pbxproj` 和三個流程檔案。
   - README。
   - App 內下載計畫:步驟 b 改寫(見「之後要決定的事」)。

## 之後要決定的事

### Breeze2 那條路要不要留著當備用(待使用者決定)

| | 拆掉(建議) | 留著當備用 |
|---|---|---|
| 改原作者的程式 | Refine 的 5 個檔案改回原作者的版本,少 446 行新增、45 行刪除(XPC 引擎就占 376 行:prefix cache、多輪範例等) | 維持現狀,每次合併上游都要處理這些衝突 |
| 備用的意義 | 沒有;CT 出錯時貼沒標點的原文 | CT 的模型不在時,打開 AI 潤稿就會用 Breeze2 補 |
| 記憶體、硬碟 | 刪掉這台的模型資料夾可省 2GB(刪之前先問使用者) | 模型留著;AI 潤稿關著時不佔記憶體 |
| 要回來 | git 歷史都在,可以還原 | — |

建議拆掉:CT 在結構上不會改字、不會答非所問,也沒有載入時間,需要「備用」的情況很少;拆掉後改原作者的程式變少,合併上游比較不會衝突。

拆掉的話要做:

- `VoiceInkRefineService.swift`、`VoiceInkRefineXPCClient.swift`、`VoiceInkRefineXPC/` 的改動還原成原作者的版本,刪掉 XPC 那份 `ZhTWTiming.swift`。
- `ZhTWPunctuation.swift` 拿掉 Breeze2 的資料夾、指示、範例、分段,測試拿掉分段的案例。
- `scripts/bench/` 只給 Breeze2 用的工具刪掉。git 歷史留著,調查文件註明。
- `setup.sh` 不再下載 Breeze2。
- 架構文件的非目標拿掉「16GB 以下記憶體的 Mac」:不再需要 VoiceInk Refine。

### 模型內建進 App,還是在 App 內下載(之後處理)

- 傾向內建:模型 75MB,App 從 159MB 變成約 270MB,換一台 Mac 不用另外下載補標點模型。內建的話,暫停中的 [App 內下載模型](2026-10-21-in-app-model-download.md) 步驟 b 直接拿掉。
- 在 App 內下載的話,步驟 b 改成下載 CT 的模型(一個檔案、驗 SHA256),取代原本的 Breeze2 下載器。
- 授權已查過,兩種都可以(見「函式庫和模型放哪」)。

## 驗證

```bash
scripts/test-punctuation.sh   # 合併邏輯沒被動到
scripts/setup.sh check        # 安裝狀態
```

| 步驟 | 怎麼驗 |
|---|---|
| 1 | `make local` 成功;`Contents/Frameworks/` 有兩個 dylib;`codesign --verify --deep --strict` 通過;`otool -L` 看得到 `@rpath/libsherpa-onnx-c-api.dylib`;App 能啟動 |
| 2 | 91 段和評測逐字相同;載入時間和常駐記憶體(`footprint`)寫進紀錄 |
| 3 | 測試通過;模型資料夾移走時回傳原文 |
| 4 | `timing_report.py` 的補標點欄位在 50 毫秒以下、沒有 XPC 的紀錄;紀錄裡的文字有標點、沒有 AI 潤稿的結果 |

實際聽寫的核對資料放私人 repo `voiceink-zhtw-data` 的新資料夾 `2026-10-22-ct-punctuation/`。

## 紀錄

- 2026-10-22 寫 plan。SHA256:`sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts-lib.tar.bz2` 是 `f3e0cbd86cc3f38dad30c97921b40e9a8bcc6f2c943777eb76ad77176993e417`,`c-api.h`(v1.13.8)是 `2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce`,模型壓縮檔是 `c0d5aa5f8eeb686032345e180bedf39319dc2e0556781c6264bcadba8328a6e1`(和 release 的 `checksum.txt`、評測用的那份相同),解開後的 `model.int8.onnx` 是 `65a3fb9f5ad7bfb96bf69e0dc4481df97f6ee60513c1d94ce981ba6effd524b1`。
- 2026-10-22 範圍縮小(使用者在另一個對話決定「先把基礎架構做好」):模型先放 Application Support,內建或 App 內下載之後再處理;Breeze2 要不要留著備用列為待決定。
