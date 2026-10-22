# 開發慣例

跟架構決策無關,純粹是「怎麼操作比較順」的約定,寫下來避免每次重新摸索。

## 分支與 remote

- 這是 [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) 的公開 fork(GitHub 規定公開專案的 fork 只能公開),我們的東西都在 **`zhtw` 分支**。
- clone 裡 `origin` = [Jim-Chang/VoiceInk](https://github.com/Jim-Chang/VoiceInk)、`upstream` = 原作者。
- **不會發 PR 回上游**,所以照自己的慣例:文件繁中、放 `docs/`;commit 訊息英文,格式 `area: 說明`(`zhtw:`、`docs:`、`scripts:`),結尾加 `Co-Authored-By`。
- **公開 repo,不放個人資料**:測試案例和文件裡的例句用自己編的,不放實際聽寫內容;實際聽寫的資料放私人 repo:v2 之後的實驗放 `voiceink-zhtw-data`(每個實驗一個資料夾,名稱和 `docs/investigations/` 的文件相同),v1 的補標點評測在 `voiceink-zhtw-lmstudio`。

## 合併上游更新

```bash
scripts/update.sh        # fetch upstream → merge upstream/main → build → 安裝
git push origin zhtw
```

- 用 **merge 不用 rebase**:我們的修改紀錄一直保留,也不用 force push。
- 會衝突的地方:
  - `README.md`:一律保留我們的(`git checkout --ours README.md`)。
  - 改過的上游檔案(清單見 [architecture/README.md](architecture/README.md#修改了原作者的哪些檔案)):手動合併。特別注意:
    - 三個辨識流程(`TranscriptionPipeline`、`AudioFileTranscriptionManager`、`AudioFileTranscriptionService`)在去掉頭尾空白之後呼叫 `ZhTWTranscript.clean` 和 `ZhTWPunctuator.punctuate`;上游改了這段流程,要確認呼叫還在、順序還是在段落格式化和 Word Replacements 之前。
    - `VoiceInkEngine` 開始錄音時的 `ZhTWPunctuator.preload()` 和 `cleanupResources` 裡的 `unload()`。
    - `project.pbxproj`:sherpa-onnx 的兩個 dylib、CT 模型和搜尋路徑(ID 都以 `E1C7F001` 開頭),和 whisper.xcframework 的設定放在一起;衝突時保留兩邊。
    - `VoiceInkRefineService`、`VoiceInkRefineInferenceEngine`:Breeze2 補標點的舊改動,還沒拆掉前要注意介面有沒有變。
  - 模型清單的三個檔案(`TranscribeCppModelCatalog`、`TranscriptionModelRegistry`、`LanguageDictionary`)各加了一筆 TEA-ASR-1.1,衝突時保留兩邊。上游換了 `Transcribe-cpp-swift` 的版本時,TEA 要重新驗證:GGUF 是用 `856d7c1` 的轉檔程式轉的,新版可能有 #165(依長度調整產生上限)、可以拿掉每 30 秒切段。
- 合併後先跑 `scripts/test-punctuation.sh`,再實際聽寫一句,用 `python3 -I scripts/timing_report.py --last 10m` 確認有補標點(`punct` 欄位)、語音辨識用的是 TEA。

## Build

- **第一次**:`make local`(或 `scripts/update.sh --no-pull`)。會在 `~/VoiceInk-Dependencies/` 編 whisper.cpp 的 xcframework(iOS、macOS、visionOS、tvOS 全部,約 10–20 分鐘),Xcode 專案寫死這個路徑,**別刪**。
- **Xcode 26 要另外下載 Metal 工具鏈**:`xcodebuild -downloadComponent MetalToolchain`。沒有的話 mlx-swift 的 `.metal` 檔會編不過。
- `make local` 每次都先刪掉 `.local-build/` 整個重編(暫存約 3.6GB)。**只改幾個檔案時用增量 build**(約 1 分 44 秒),參數照 Makefile 的 `local`:

  ```bash
  ID=$(security find-identity -v -p codesigning | awk '/"Apple Development: / {print $2; exit}')
  xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Release \
    -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig \
    CODE_SIGN_IDENTITY="$ID" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
    CODE_SIGN_ENTITLEMENTS="$PWD/VoiceInk/VoiceInk.local.entitlements" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
    -skipPackagePluginValidation -skipMacroValidation build
  ```

  產出在 `.local-build/Build/Products/Release/VoiceInk.app`,關掉 VoiceInk 後用 `ditto` 蓋掉 `/Applications/VoiceInk.app`。
- **簽章**:鑰匙圈裡剛好一張 Apple Development 憑證時,`make local` 會自動用它。簽章固定,重新 build 後麥克風、輔助使用權限不用重給;沒有憑證時用 ad-hoc 簽章,每次 build 後可能要重給。
- 新的 `.swift` 檔放在 `VoiceInk/` 底下會自動加進 App target(Xcode 的 synchronized group),不用改 `project.pbxproj`;`VoiceInkRefineXPC/` 是另一個 target,看不到 App 的檔案。

## 查延遲

語音辨識(`asr`、開始錄音時載入 transcribe.cpp 模型的 `asr-prepare`)和補標點的每一段時間都記在系統紀錄(category `ZhTWTiming`,只有時間和數量):

```bash
python3 -I scripts/timing_report.py --last 1h       # 每次聽寫一行
python3 -I scripts/bench/sample_load.py load.tsv 900 # 另開一個終端機:記 15 分鐘的 GPU、CPU 負載
python3 -I scripts/timing_report.py --last 1h --load load.tsv
```

欄位說明在 `scripts/timing_report.py` 開頭。系統紀錄會保留幾天,要更久就把輸出存起來。

## 離線評測工具

`scripts/bench/` 底下是延遲調查用的工具,實際聽寫的內容只放私人 repo `voiceink-zhtw-data`:

| 工具 | 用途 |
|---|---|
| `refine-bench.sh` | 編譯 App 裡同一份補標點引擎(`VoiceInkRefineInferenceEngine`、`ZhTWPunctuation`)成命令列工具,離線跑一批逐字稿;可切換 prefix cache / 原作者做法、整段 / 分段。第一次要編 MLX(數分鐘) |
| `asr_bench.py` | 用 whisper-cli 以 VoiceInk 的參數跑一批錄音,比較 Breeze-ASR-25 各版本的速度和結果 |
| `punct_ct.py`、`punct-tool.sh` | 專門的標點模型(CT-Transformer,sherpa-onnx)補標點,再用 App 的合併邏輯插回繁體原文 |
| `punct-ct.sh` | 編譯 App 裡同一份 CT 補標點(`ZhTWPunctuator`)成命令列工具,離線跑一批逐字稿;列有 `model` 欄時先照 App 的流程跑 `ZhTWTranscript.clean` |
| `asr_models_run.sh`、`tc_bench.c`、`asr_models.py`、`tea_prepare.py` | 換語音辨識模型的評測:用 transcribe.cpp 跑一批錄音、統計、盲測;`tea_prepare.py` 整理 TEA-ASR 的 tokenizer 再轉 GGUF(見 [investigations/2026-10-22-asr-models.md](investigations/2026-10-22-asr-models.md)) |
| `sample_load.py` | 每 0.5 秒記 GPU、CPU 負載 |

跑評測時不要同時聽寫,也不要同時跑兩個評測(互搶 GPU,時間會失真)。

## 測試

- `scripts/test-punctuation.sh`:只編 `ZhTWPunctuation.swift`、`ZhTWTranscript.swift` 加測試程式,跑 `scripts/fixtures/punctuation-cases.json` 和辨識結果整理的案例,不用 build App、不用模型。改合併或整理邏輯時先加案例。
- 簡體專用字對照表(`ZhTWSimplifiedOnly.swift`)由 `python3 -I scripts/gen-zhtw-simplified.py` 產生(OpenCC 固定在 1.1.7),不要手改。
- **聽寫紀錄和錄音只留 3 天**(見架構文件的決策紀錄),要做實驗先複製到私人 repo。
- 實際聽寫的結果在 `~/Library/Application Support/com.prakashjoshipax.VoiceInk/default.store`(SQLite,`ZTRANSCRIPTION` 表):`ZTEXT` 是辨識結果、`ZENHANCEDTEXT` 是補標點後、`ZAIENHANCEMENTMODELNAME`、`ZENHANCEMENTDURATION`、`ZTRANSCRIPTIONDURATION`。查詢指令見 [plan/2026-10-21-v2-single-app.md](plan/2026-10-21-v2-single-app.md#驗證)。
- VoiceInk 的 log 不會留在系統紀錄裡(`log show` 查不到),要看時間就查上面的資料庫。

## 改 VoiceInk 的設定

- 設定存在 UserDefaults 網域 `com.prakashjoshipax.VoiceInk`。模式在 `modeConfigurationsV2`(JSON 的 Data)、中文 Whisper 提示詞在 `CustomLanguagePrompts`。
- **一定要先關掉 VoiceInk 再寫**,不然它結束時會蓋回去。`scripts/setup.sh configure` 會自動關、備份(到 `~/Library/Application Support/com.prakashjoshipax.VoiceInk/zhtw-backups/`)、寫入、再打開。
- 自己的設定值:`ZhTWRefineKeepWarmSeconds`(模型閒置多久卸載,預設 300)。
